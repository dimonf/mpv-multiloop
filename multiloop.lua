-- multiloop.lua (TSV persistence next to media file) + reload (r)
local mp = require("mp")
local assdraw = require("mp.assdraw")
local mpopts = require("mp.options")

local options = {
	keybind = "M",
	message_duration = 1,
	save_ext = ".mab.tsv",
	list_font_size = 42,
}

mpopts.read_options(options, "multiloop")

local positions = {} -- array of {start, end}
local ab = {} -- temporary {start} while setting A then B
local looping = false
local menu_active = false
local p_count = 1
local positions_message_timer = nil

local function file_exists(name)
	local f = io.open(name, "r")
	if f ~= nil then
		f:close()
		return true
	end
	return false
end

local function message(text, duration)
	local ass = mp.get_property_osd("osd-ass-cc/0") or ""
	ass = ass .. text
	return mp.osd_message(ass, duration or options.message_duration)
end

local function drawMenu()
	local window_w, window_h = mp.get_osd_size()
	local ass = assdraw.ass_new()
	ass:new_event()
	ass:append(" \\N\\N")
	ass:append("{\\b1}Multiloop{\\b0}\\N")
	ass:append("{\\b1}1{\\b0} set start time\\N")
	ass:append("{\\b1}2{\\b0} set end time\\N")
	ass:append("{\\b1}d{\\b0} duplicate last a-b point\\N")
	ass:append("{\\b1}s{\\b0} save positions to file (TSV)\\N")
	ass:append("{\\b1}r{\\b0} reload positions from file (TSV)\\N")
	ass:append("{\\b1}l{\\b0} loop / end loop\\N")
	ass:append("{\\b1}p{\\b0} show loop entries\\N")
	ass:append("{\\b1}ESC{\\b0} hide\\N")
	mp.set_osd_ass(window_w, window_h, ass.text)
end

local function clearMenu()
	local window_w, window_h = mp.get_osd_size()
	mp.set_osd_ass(window_w, window_h, "")
	mp.osd_message("", 0)
end

-- Return a save path next to the currently played file.
-- For URLs/streams, returns nil (cannot reliably save "next to" them).
local function get_save_path()
	local path = mp.get_property("path")
	if not path or path == "" then
		return nil
	end
	if path:match("://") then
		return nil
	end
	local no_ext = path:gsub("%.[^%.%/\\]+$", "")
	return no_ext .. options.save_ext
end

local function save_positions_tsv()
	local spath = get_save_path()
	if not spath then
		message("cannot save: not a local file path")
		return false
	end

	local f, e = io.open(spath, "w")
	if not f then
		message("save failed: " .. tostring(e))
		return false
	end

	f:write("# multiloop A-B points (start<TAB>end), seconds\n")
	for _, seg in ipairs(positions) do
		local a, b = seg[1], seg[2]
		if type(a) == "number" and type(b) == "number" and b > a then
			f:write(string.format("%.6f\t%.6f\n", a, b))
		end
	end

	f:close()
	message("saved: " .. spath)
	return true
end

local function parse_positions_tsv(spath)
	local f, e = io.open(spath, "r")
	if not f then
		return nil, ("open failed: " .. tostring(e))
	end

	local out = {}
	for line in f:lines() do
		if line ~= "" and not line:match("^%s*#") then
			local a_s, b_s = line:match("^%s*([%d%.%-]+)%s*\t%s*([%d%.%-]+)%s*$")
			local a = tonumber(a_s)
			local b = tonumber(b_s)
			if a and b and b > a then
				out[#out + 1] = { a, b }
			end
		end
	end

	f:close()
	return out, nil
end

local function load_positions_tsv()
	local spath = get_save_path()
	if not spath or not file_exists(spath) then
		return false
	end

	local out, err = parse_positions_tsv(spath)
	if not out then
		message("load failed: " .. tostring(err))
		return false
	end

	if #out > 0 then
		positions = out
		p_count = 1
		return true
	end
	return false
end

local function setStartTime()
	local start_time = mp.get_property_number("time-pos")
	clearMenu()
	ab = { start_time }
	message("start time set")
end

local function setEndTime()
	if #ab == 1 then
		local end_time = mp.get_property_number("time-pos")
		local start_time = ab[1]
		if end_time and start_time and end_time > start_time then
			positions[#positions + 1] = { start_time, end_time }
			ab = {}
			message("end time set")
		else
			message("end time must be > start time")
		end
	else
		message("you have to set a start time")
	end
	drawMenu()
end

local function duplicateLastPoint()
	if #positions == 0 then
		message("nothing to duplicate")
		return
	end
	local last = positions[#positions]
	positions[#positions + 1] = { last[1], last[2] }
	message("point duplicated!")
end

local function savePositions()
	if #ab == 1 then
		message("ab point without an end time")
	elseif #positions == 0 then
		message("nothing to save")
	else
		save_positions_tsv()
	end
end

local function format_time(seconds)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	return string.format("%02d:%02d:%06.3f", hours, minutes, secs)
end

local function showPositions()
	local duration = math.max(options.message_duration, 5)
	if positions_message_timer then
		positions_message_timer:kill()
		positions_message_timer = nil
	end
	clearMenu()

	if #positions == 0 then
		message("No loop entries", duration)
	else
		local lines = {
			string.format("{\\fs%d\\b1}Loop entries{\\b0}", options.list_font_size),
		}
		for index, segment in ipairs(positions) do
			lines[#lines + 1] = string.format(
				"%d. %s - %s",
				index,
				format_time(segment[1]),
				format_time(segment[2])
			)
		end
		message(table.concat(lines, "\\N"), duration)
	end

	positions_message_timer = mp.add_timeout(duration, function()
		positions_message_timer = nil
		if menu_active and not looping then
			drawMenu()
		end
	end)
end

local function on_timepos_change()
	if #positions == 0 then
		return
	end
	local t = mp.get_property_number("time-pos")
	if not t then
		return
	end

	local seg = positions[p_count]
	if not seg or not seg[2] then
		return
	end

	if t >= seg[2] then
		if p_count ~= #positions then
			p_count = p_count + 1
		else
			p_count = 1
		end
		mp.set_property_native("time-pos", positions[p_count][1])
	end
end

local function start_looping_if_possible()
	if #positions ~= 0 then
		mp.set_property_native("time-pos", positions[p_count][1])
		mp.observe_property("time-pos", "string", on_timepos_change)
	else
		message("you have to set some points first!")
		drawMenu()
	end
end

local function stop_looping()
	mp.unobserve_property(on_timepos_change)
end

local function loop()
	if not looping then
		looping = true
		clearMenu()
		start_looping_if_possible()
	else
		looping = false
		stop_looping()
		drawMenu()
	end
end

-- Reload positions from TSV on disk (so you can edit it externally).
-- Keeps looping state: if looping, re-start observer and seek to new first segment.
local function reloadPositions()
	local spath = get_save_path()
	if not spath then
		message("cannot reload: not a local file path")
		return
	end
	if not file_exists(spath) then
		message("reload failed: file not found")
		return
	end

	local out, err = parse_positions_tsv(spath)
	if not out then
		message("reload failed: " .. tostring(err))
		return
	end

	positions = out
	ab = {}
	p_count = 1

	if looping then
		stop_looping()
		if #positions > 0 then
			start_looping_if_possible()
			message("reloaded (" .. tostring(#positions) .. " segments)")
		else
			-- nothing to loop; stop looping mode
			looping = false
			message("reloaded (0 segments); looping stopped")
			drawMenu()
		end
	else
		message("reloaded (" .. tostring(#positions) .. " segments)")
		drawMenu()
	end
end

local menu_bindings = {
	{ "1", "multiloop-set-a", setStartTime },
	{ "2", "multiloop-set-b", setEndTime },
	{ "d", "multiloop-dup", duplicateLastPoint },
	{ "s", "multiloop-save", savePositions },
	{ "r", "multiloop-reload", reloadPositions },
	{ "l", "multiloop-loop", loop },
	{ "p", "multiloop-show-positions", showPositions },
	{ "ESC", "multiloop-hide", clearMenu },
}

local function deactivate()
	if positions_message_timer then
		positions_message_timer:kill()
		positions_message_timer = nil
	end

	for _, binding in ipairs(menu_bindings) do
		mp.remove_key_binding(binding[2])
	end

	if looping then
		looping = false
		stop_looping()
	end

	clearMenu()
	menu_active = false
end

local function activate()
	for _, binding in ipairs(menu_bindings) do
		mp.add_forced_key_binding(binding[1], binding[2], binding[3])
	end

	load_positions_tsv()
	menu_active = true
	drawMenu()
end


local function main()
	if menu_active then
		deactivate()
	else
		activate()
	end
end

mp.add_key_binding(options.keybind, "display-multiloop", main)
