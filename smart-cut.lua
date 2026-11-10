-- Smart-render selected segments from multiloop's JSON sidecar.
-- Re-encodes segment edges and stream-copies the keyframe-aligned middle.
local mp = require("mp")
local msg = require("mp.msg")
local mpopts = require("mp.options")
local utils = require("mp.utils")

local options = {
	keybind = "Ctrl+Alt+c",
	output_file = "",
	sidecar_ext = ".mab.json",
	ffmpeg = "ffmpeg",
	ffprobe = "ffprobe",
	exiftool = "exiftool",
	crf = 18,
	preset = "medium",
	audio_bitrate = "192k",
}

mpopts.read_options(options, "smart-cut")

local running = false
local temp_dir = nil
local temp_files = {}

local function osd(text, duration)
	mp.osd_message("Smart cut: " .. text, duration or 3)
	msg.info(text)
end

local function subprocess(args, callback)
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = args,
	}, function(success, result, error_text)
		if not success then
			callback(false, result or {}, error_text or "subprocess failed")
			return
		end
		local ok = result and result.status == 0
		local detail = (result and result.stderr and result.stderr ~= "" and result.stderr)
			or error_text
			or ("process exited with status " .. tostring(result and result.status))
		callback(ok, result or {}, detail)
	end)
end

local function cleanup()
	for i = #temp_files, 1, -1 do
		os.remove(temp_files[i])
	end
	if temp_dir then
		os.remove(temp_dir)
	end
	temp_files = {}
	temp_dir = nil
end

local function finish_error(text)
	cleanup()
	running = false
	osd("failed: " .. tostring(text), 8)
end

local function finish_success(output)
	cleanup()
	running = false
	osd("created " .. output, 6)
end

local function is_absolute(path)
	return path:match("^/") or path:match("^%a:[/\\]")
end

local function file_exists(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

local function expand_home(path)
	if path:match("^~[/\\]") then
		local home_directory = os.getenv("HOME")
		if not home_directory or home_directory == "" then
			return nil, "cannot expand ~ because HOME is not set"
		end
		return utils.join_path(home_directory, path:sub(3))
	end
	return path
end

local function available_output_path(path)
	if not file_exists(path) then return path end
	local stem, extension = path:match("^(.*)(%.[^%./\\]+)$")
	if not stem then stem, extension = path, "" end
	local suffix = 1
	repeat
		path = string.format("%s%02d%s", stem, suffix, extension)
		suffix = suffix + 1
	until not file_exists(path)
	return path
end

local function resolve_input_path()
	local path = mp.get_property("path")
	if not path or path == "" or path:match("://") then
		return nil, "the current media is not a local file"
	end
	path = mp.command_native({ "expand-path", path })
	if not is_absolute(path) then
		path = utils.join_path(mp.get_property("working-directory") or ".", path)
	end
	return path
end

local function without_extension(path)
	return path:gsub("%.[^%.%/\\]+$", "")
end

local function resolve_output_path(input_path)
	if options.output_file == "" then
		return nil, "set output_file in script-opts/smart-cut.conf"
	end
	local output, home_error = expand_home(options.output_file)
	if not output then return nil, home_error end
	output = mp.command_native({ "expand-path", output })
	if not is_absolute(output) then
		local input_dir = select(1, utils.split_path(input_path))
		output = utils.join_path(input_dir, output)
	end
	output = available_output_path(output)
	if output == input_path then
		return nil, "output_file must differ from the input file"
	end
	return output
end

local function read_selected_segments(input_path)
	local sidecar = without_extension(input_path) .. options.sidecar_ext
	local file, open_error = io.open(sidecar, "r")
	if not file then
		return nil, "cannot open sidecar " .. sidecar .. ": " .. tostring(open_error)
	end
	local contents = file:read("*a")
	file:close()
	local data, json_error = utils.parse_json(contents)
	if type(data) ~= "table" then
		return nil, "invalid sidecar JSON: " .. tostring(json_error)
	end
	if data.version ~= 2 or type(data.cutSegments) ~= "table" then
		return nil, "sidecar must contain version 2 and a cutSegments array"
	end

	local selected = {}
	for _, segment in ipairs(data.cutSegments) do
		local start_time = tonumber(segment.start)
		local end_time = tonumber(segment["end"])
		if segment.selected == true and start_time and end_time and end_time > start_time then
			selected[#selected + 1] = { start_time = start_time, end_time = end_time }
		end
	end
	if #selected == 0 then
		return nil, "no selected segments"
	end
	return selected
end

local function first_stream(streams, codec_type)
	for _, stream in ipairs(streams or {}) do
		if stream.codec_type == codec_type then
			return stream
		end
	end
end

local function encoder_available(encoders, name)
	local escaped = name:gsub("([^%w])", "%%%1")
	return encoders:match("[ \t]" .. escaped .. "[ \t]") ~= nil
end

local function choose_encoder(encoders, codec, candidates)
	for _, candidate in ipairs(candidates[codec] or { codec }) do
		if encoder_available(encoders, candidate) then
			return candidate
		end
	end
	return nil
end

local video_encoders = {
	h264 = { "libx264", "h264" },
	hevc = { "libx265", "hevc" },
	av1 = { "libsvtav1", "libaom-av1", "av1" },
	vp9 = { "libvpx-vp9", "vp9" },
	vp8 = { "libvpx", "vp8" },
	mpeg4 = { "mpeg4" },
	mpeg2video = { "mpeg2video" },
	prores = { "prores_ks", "prores" },
}

local audio_encoders = {
	aac = { "aac" },
	opus = { "libopus", "opus" },
	vorbis = { "libvorbis", "vorbis" },
	mp3 = { "libmp3lame", "mp3" },
	flac = { "flac" },
	ac3 = { "ac3" },
	eac3 = { "eac3" },
}

local function append(target, values)
	for _, value in ipairs(values) do
		target[#target + 1] = value
	end
end

local function metadata_value(value)
	if type(value) == "table" then
		local values = {}
		for _, item in ipairs(value) do values[#values + 1] = tostring(item) end
		return table.concat(values, "; ")
	end
	return value ~= nil and tostring(value) or nil
end

local function exiftool_can_write(path)
	local extension = path:lower():match("%.([^%./\\]+)$")
	return extension == "mp4" or extension == "mov" or extension == "m4v"
		or extension == "3gp" or extension == "3g2"
end

local function encoding_options(video_encoder, audio_encoder, video_stream, audio_stream)
	local args = { "-c:v", video_encoder }
	if video_encoder == "libx264" or video_encoder == "libx265" then
		append(args, { "-preset", tostring(options.preset), "-crf", tostring(options.crf) })
	elseif video_encoder == "libvpx-vp9" or video_encoder == "libvpx" then
		append(args, { "-crf", tostring(options.crf), "-b:v", "0" })
	elseif video_encoder == "libsvtav1" then
		append(args, { "-crf", tostring(options.crf) })
	elseif video_encoder == "libaom-av1" then
		append(args, { "-crf", tostring(options.crf), "-b:v", "0" })
	else
		append(args, { "-q:v", "2" })
	end
	if video_stream.pix_fmt and video_stream.pix_fmt ~= "" then
		append(args, { "-pix_fmt", video_stream.pix_fmt })
	end
	if audio_stream then
		append(args, { "-c:a", audio_encoder })
		if audio_encoder ~= "flac" then
			append(args, { "-b:a", tostring(options.audio_bitrate) })
		end
	end
	return args
end

local function inner_keyframes(keyframes, start_time, end_time)
	local first, last
	for _, timestamp in ipairs(keyframes) do
		if timestamp > start_time + 0.000001 and timestamp < end_time - 0.000001 then
			first = first or timestamp
			last = timestamp
		end
	end
	if first and last and last - first > 0.000001 then
		return first, last
	end
	return nil, nil
end

local function make_part_path(index)
	local path = utils.join_path(temp_dir, string.format("part-%06d.mkv", index))
	temp_files[#temp_files + 1] = path
	return path
end

local function add_encoded_job(jobs, input, start_time, end_time, part_path, encode_args, has_audio)
	local args = {
		options.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
		"-ss", string.format("%.9f", start_time),
		"-t", string.format("%.9f", end_time - start_time),
		"-i", input, "-map", "0:v:0",
	}
	if has_audio then append(args, { "-map", "0:a:0?" }) end
	append(args, { "-sn", "-dn" })
	append(args, encode_args)
	append(args, { "-avoid_negative_ts", "make_zero", part_path })
	jobs[#jobs + 1] = args
end

local function add_copied_job(jobs, input, start_time, end_time, part_path, has_audio)
	local args = {
		options.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
		"-ss", string.format("%.9f", start_time),
		"-t", string.format("%.9f", end_time - start_time),
		"-i", input, "-map", "0:v:0",
	}
	if has_audio then append(args, { "-map", "0:a:0?" }) end
	append(args, { "-sn", "-dn", "-c", "copy", "-avoid_negative_ts", "make_zero", part_path })
	jobs[#jobs + 1] = args
end

local function write_concat_file(parts, durations)
	local path = utils.join_path(temp_dir, "parts.ffconcat")
	local file, write_error = io.open(path, "w")
	if not file then return nil, write_error end
	file:write("ffconcat version 1.0\n")
	for index, part in ipairs(parts) do
		local _, name = utils.split_path(part)
		file:write("file '", name, "'\n")
		file:write(string.format("outpoint %.9f\n", durations[index]))
		file:write(string.format("duration %.9f\n", durations[index]))
	end
	file:close()
	temp_files[#temp_files + 1] = path
	return path
end

local function run_jobs(jobs, index, callback)
	if index > #jobs then
		callback(true)
		return
	end
	osd(string.format("processing part %d/%d", index, #jobs), 2)
	subprocess(jobs[index], function(ok, _, detail)
		if not ok then
			callback(false, detail)
			return
		end
		run_jobs(jobs, index + 1, callback)
	end)
end

local function build_and_run(input, output, segments, probe, keyframes, encoders, source_metadata)
	local video = first_stream(probe.streams, "video")
	local audio = first_stream(probe.streams, "audio")
	if not video or not video.codec_name then
		finish_error("no video stream found")
		return
	end
	local video_encoder = choose_encoder(encoders, video.codec_name, video_encoders)
	if not video_encoder then
		finish_error("no encoder available for video codec " .. tostring(video.codec_name))
		return
	end
	local audio_encoder
	if audio then
		audio_encoder = choose_encoder(encoders, audio.codec_name, audio_encoders)
		if not audio_encoder then
			finish_error("no encoder available for audio codec " .. tostring(audio.codec_name))
			return
		end
	end

	local encode_args = encoding_options(video_encoder, audio_encoder, video, audio)
	local jobs, parts, part_durations = {}, {}, {}
	local total_duration = 0
	local function record_part(part, duration)
		parts[#parts + 1] = part
		part_durations[#part_durations + 1] = duration
		total_duration = total_duration + duration
	end
	for _, segment in ipairs(segments) do
		local first_keyframe, last_keyframe = inner_keyframes(keyframes, segment.start_time, segment.end_time)
		if not first_keyframe then
			local part = make_part_path(#parts + 1)
			record_part(part, segment.end_time - segment.start_time)
			add_encoded_job(jobs, input, segment.start_time, segment.end_time, part, encode_args, audio ~= nil)
		else
			local head = make_part_path(#parts + 1)
			record_part(head, first_keyframe - segment.start_time)
			add_encoded_job(jobs, input, segment.start_time, first_keyframe, head, encode_args, audio ~= nil)

			local middle = make_part_path(#parts + 1)
			record_part(middle, last_keyframe - first_keyframe)
			add_copied_job(jobs, input, first_keyframe, last_keyframe, middle, audio ~= nil)

			local tail = make_part_path(#parts + 1)
			record_part(tail, segment.end_time - last_keyframe)
			add_encoded_job(jobs, input, last_keyframe, segment.end_time, tail, encode_args, audio ~= nil)
		end
	end

	local concat_file, concat_error = write_concat_file(parts, part_durations)
	if not concat_file then
		finish_error("cannot write concat list: " .. tostring(concat_error))
		return
	end

	run_jobs(jobs, 1, function(ok, detail)
		if not ok then finish_error(detail); return end
		local concat_args = {
			options.ffmpeg, "-hide_banner", "-loglevel", "error",
			"-n",
			"-f", "concat", "-safe", "0", "-i", concat_file, "-i", input,
			"-t", string.format("%.9f", total_duration), "-map", "0", "-map_metadata", "1", "-c", "copy",
		}
		local relation = metadata_value(source_metadata["XMP:Relation"] or source_metadata["XMP-dc:Relation"])
		local source = metadata_value(source_metadata["XMP:Source"] or source_metadata["XMP-dc:Source"])
		if relation and relation ~= "" then append(concat_args, { "-metadata", "RELATION=" .. relation }) end
		if source and source ~= "" then append(concat_args, { "-metadata", "SOURCE=" .. source }) end
		if output:lower():match("%.mp4$") or output:lower():match("%.mov$") then
			append(concat_args, { "-movflags", "+faststart" })
		end
		concat_args[#concat_args + 1] = output
		osd("joining parts", 3)
		subprocess(concat_args, function(joined, _, join_error)
			if not joined then finish_error(join_error); return end
			if not exiftool_can_write(output) then
				finish_success(output)
				return
			end
			subprocess({
				options.exiftool, "-overwrite_original", "-TagsFromFile", input,
				"-all:all", "-XMP:all",
				"-XMP-dc:Relation<XMP-dc:Relation", "-XMP-dc:Source<XMP-dc:Source", output,
			}, function(metadata_ok, _, metadata_error)
				if not metadata_ok then
					msg.warn("output created, but ExifTool metadata copy failed: " .. tostring(metadata_error))
					cleanup()
					running = false
					osd("created " .. output .. " (metadata copy failed)", 8)
					return
				end
				finish_success(output)
			end)
		end)
	end)
end

local function probe_and_cut(input, output, segments)
	subprocess({
		options.ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", input,
	}, function(ok, result, detail)
		if not ok then finish_error(detail); return end
		local probe, parse_error = utils.parse_json(result.stdout or "")
		if type(probe) ~= "table" then finish_error("invalid ffprobe output: " .. tostring(parse_error)); return end

		subprocess({
			options.ffprobe, "-v", "error", "-select_streams", "v:0",
			"-skip_frame", "nokey", "-show_frames",
			"-show_entries", "frame=key_frame,best_effort_timestamp_time,pts_time,pkt_pts_time",
			"-of", "json", input,
		}, function(keys_ok, keys_result, keys_error)
			if not keys_ok then finish_error(keys_error); return end
			local key_data, key_parse_error = utils.parse_json(keys_result.stdout or "")
			if type(key_data) ~= "table" then finish_error("invalid keyframe probe: " .. tostring(key_parse_error)); return end
			local keyframes = {}
			for _, frame in ipairs(key_data.frames or {}) do
				if tonumber(frame.key_frame) == 1 then
					local timestamp = tonumber(frame.best_effort_timestamp_time or frame.pts_time or frame.pkt_pts_time)
					if timestamp then keyframes[#keyframes + 1] = timestamp end
				end
			end
			table.sort(keyframes)

			subprocess({ options.exiftool, "-j", "-G", "-XMP-dc:Relation", "-XMP-dc:Source", input }, function(meta_ok, meta_result, meta_error)
				if not meta_ok then finish_error(meta_error); return end
				local metadata_json, metadata_parse_error = utils.parse_json(meta_result.stdout or "")
				if type(metadata_json) ~= "table" then finish_error("invalid ExifTool output: " .. tostring(metadata_parse_error)); return end
				local source_metadata = metadata_json[1] or {}

			subprocess({ options.ffmpeg, "-hide_banner", "-encoders" }, function(enc_ok, enc_result, enc_error)
				if not enc_ok then finish_error(enc_error); return end
				subprocess({ "mktemp", "-d", "-t", "mpv-smart-cut.XXXXXX" }, function(tmp_ok, tmp_result, tmp_error)
					if not tmp_ok then finish_error(tmp_error); return end
					temp_dir = (tmp_result.stdout or ""):match("^%s*(.-)%s*$")
					if not temp_dir or temp_dir == "" then finish_error("mktemp returned no directory"); return end
					build_and_run(input, output, segments, probe, keyframes, enc_result.stdout or "", source_metadata)
				end)
			end)
			end)
		end)
	end)
end

local function smart_cut()
	if running then
		osd("already running")
		return
	end
	local input, input_error = resolve_input_path()
	if not input then osd(input_error, 6); return end
	local output, output_error = resolve_output_path(input)
	if not output then osd(output_error, 6); return end
	local segments, segment_error = read_selected_segments(input)
	if not segments then osd(segment_error, 6); return end

	running = true
	osd(string.format("probing %d selected segment(s)", #segments), 3)
	probe_and_cut(input, output, segments)
end

mp.add_key_binding(options.keybind ~= "" and options.keybind or nil, "smart-cut", smart_cut)
mp.register_script_message("run", smart_cut)
