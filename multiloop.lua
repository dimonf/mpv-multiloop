-- multiloop.lua (JSON persistence next to media file) + reload (r)
local mp = require("mp")
local assdraw = require("mp.assdraw")
local input = require("mp.input")
local mpopts = require("mp.options")
local utils = require("mp.utils")

local options = {
	keybind = "M",
	message_duration = 1,
	save_ext = ".mab.json",
	list_font_size = 42,
}

mpopts.read_options(options, "multiloop")

local positions = {} -- array of {start, end, name, selected}
local ab = {} -- temporary {start} while setting A then B
local looping = false
local menu_active = false
local p_count = 1
local positions_list_visible = false
local stop_looping
local deletePositionByIndex
local toggleSelectedByIndex

local function removeListBindings()
	mp.remove_key_binding("multiloop-delete")
	mp.remove_key_binding("multiloop-toggle-selected-space")
	mp.remove_key_binding("multiloop-toggle-selected-m")
end

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
	removeListBindings()
	positions_list_visible = false
	local window_w, window_h = mp.get_osd_size()
	local ass = assdraw.ass_new()
	ass:new_event()
	ass:append(string.format("{\\fs%d}", options.list_font_size))
	ass:append(" \\N\\N")
	ass:append("{\\b1}Multiloop{\\b0}\\N")
	ass:append("{\\b1}1{\\b0} set start time\\N")
	ass:append("{\\b1}2{\\b0} set end time\\N")
	ass:append("{\\b1}d{\\b0} duplicate last a-b point\\N")
	ass:append("{\\b1}s{\\b0} save positions to file (JSON)\\N")
	ass:append("{\\b1}r{\\b0} reload positions from file (JSON)\\N")
	ass:append("{\\b1}l{\\b0} loop / end loop\\N")
	ass:append("{\\b1}p{\\b0} show loop entries\\N")
	ass:append("{\\b1}- / +{\\b0} decrease / increase OSD font size\\N")
	ass:append("{\\b1}ESC{\\b0} hide\\N")
	mp.set_osd_ass(window_w, window_h, ass.text)
end

local function clearMenu()
	removeListBindings()
	positions_list_visible = false
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

local function json_escape(value)
	return tostring(value):gsub('[%z\1-\31\\"]', function(char)
		local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
		return escapes[char] or string.format("\\u%04x", char:byte())
	end)
end

local function get_media_file_name()
	return mp.get_property("filename") or ""
end

local function save_positions_json()
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

	f:write('{\n  "version": 2,\n')
	f:write('  "mediaFileName": "' .. json_escape(get_media_file_name()) .. '",\n')
	f:write('  "cutSegments": [')
	local written = 0
	for _, seg in ipairs(positions) do
		local a, b = seg.start, seg["end"]
		if type(a) == "number" and type(b) == "number" and b > a then
			f:write(written == 0 and "\n" or ",\n")
			f:write("    {\n")
			f:write(string.format('      "start": %.15g,\n', a))
			f:write(string.format('      "end": %.15g,\n', b))
			f:write('      "name": "' .. json_escape(seg.name or "") .. '",\n')
			f:write('      "selected": ' .. (seg.selected == false and "false" or "true") .. "\n")
			f:write("    }")
			written = written + 1
		end
	end
	f:write("\n  ]\n}\n")

	f:close()
	message("saved: " .. spath)
	return true
end

local function parse_positions_json(spath)
	local f, e = io.open(spath, "r")
	if not f then
		return nil, ("open failed: " .. tostring(e))
	end

	local contents = f:read("*a")
	f:close()
	local data, err = utils.parse_json(contents)
	if not data then
		return nil, ("invalid JSON: " .. tostring(err))
	end
	if type(data) ~= "table" or data.version ~= 2 or type(data.cutSegments) ~= "table" then
		return nil, "expected version 2 with a cutSegments array"
	end

	local out = {}
	for _, seg in ipairs(data.cutSegments) do
		local a = tonumber(seg.start)
		local b = tonumber(seg["end"])
		if a and b and b > a then
			out[#out + 1] = {
				start = a,
				["end"] = b,
				name = type(seg.name) == "string" and seg.name or "",
				selected = seg.selected ~= false,
			}
		end
	end
	return out, nil
end

local function load_positions_json()
	local spath = get_save_path()
	if not spath or not file_exists(spath) then
		return false
	end

	local out, err = parse_positions_json(spath)
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
			positions[#positions + 1] = { start = start_time, ["end"] = end_time, name = "", selected = true }
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
	positions[#positions + 1] = { start = last.start, ["end"] = last["end"], name = last.name, selected = last.selected }
	message("point duplicated!")
end

local function savePositions()
	if #ab == 1 then
		message("ab point without an end time")
	elseif #positions == 0 then
		message("nothing to save")
	else
		save_positions_json()
	end
end

local function format_time(seconds)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	return string.format("%02d:%02d:%06.3f", hours, minutes, secs)
end

local function drawPositionsList()
	clearMenu()
	local window_w, window_h = mp.get_osd_size()
	local ass = assdraw.ass_new()
	ass:new_event()
	ass:append(string.format("{\\fs%d}", options.list_font_size))
	ass:append("{\\b1}Loop entries{\\b0}\\N")
	ass:append("{\\b1}x{\\b0} delete entry by index\\N\\N")
	ass:append("{\\b1}SPACE / m{\\b0} toggle selected by index\\N\\N")

	if #positions == 0 then
		ass:append("No loop entries")
	else
		for index, segment in ipairs(positions) do
			ass:append(string.format(
				"%d. %s - %s%s\\N",
				index,
				format_time(segment.start),
				format_time(segment["end"]),
				segment.selected and " *" or ""
			))
		end
	end

	mp.set_osd_ass(window_w, window_h, ass.text)
	positions_list_visible = true
	mp.add_forced_key_binding("x", "multiloop-delete", deletePositionByIndex)
	mp.add_forced_key_binding("SPACE", "multiloop-toggle-selected-space", toggleSelectedByIndex)
	mp.add_forced_key_binding("m", "multiloop-toggle-selected-m", toggleSelectedByIndex)
end

local function showPositions()
	if positions_list_visible then
		clearMenu()
		drawMenu()
	else
		drawPositionsList()
	end
end

local function firstSelectedIndex()
	for index, segment in ipairs(positions) do
		if segment.selected then return index end
	end
end

deletePositionByIndex = function()
	if not positions_list_visible then
		return
	end

	if #positions == 0 then
		message("No loop entries")
		return
	end

	input.get({
		prompt = "Delete loop entry index: ",
		submit = function(text)
			local index = tonumber(text)
			if not index or index ~= math.floor(index) or index < 1 or index > #positions then
				message("Invalid loop entry index")
				return
			end

			table.remove(positions, index)
			if index < p_count then
				p_count = p_count - 1
			end
			if #positions == 0 then
				p_count = 1
				if looping then
					looping = false
					stop_looping()
				end
			elseif p_count > #positions then
				p_count = #positions
			end
			if looping then
				local selected_index = firstSelectedIndex()
				if selected_index then
					p_count = selected_index
					mp.set_property_native("time-pos", positions[p_count].start)
				else
					looping = false
					stop_looping()
				end
			end
			drawPositionsList()
		end,
	})
end

toggleSelectedByIndex = function()
	if not positions_list_visible or #positions == 0 then
		return
	end

	input.get({
		prompt = "Toggle selected entry index: ",
		submit = function(text)
			local index = tonumber(text)
			if not index or index ~= math.floor(index) or index < 1 or index > #positions then
				message("Invalid loop entry index")
				return
			end

			local segment = positions[index]
			local previous = segment.selected
			segment.selected = not segment.selected
			if not save_positions_json() then
				segment.selected = previous
				return
			end
			if looping then
				local selected_index = firstSelectedIndex()
				if selected_index then
					p_count = selected_index
					mp.set_property_native("time-pos", positions[p_count].start)
				else
					looping = false
					stop_looping()
				end
			end
			drawPositionsList()
		end,
	})
end

local function changeFontSize(delta)
	local showing_positions = positions_list_visible
	options.list_font_size = math.max(12, math.min(120, options.list_font_size + delta))

	if showing_positions then
		drawPositionsList()
	else
		drawMenu()
	end
end

local function decreaseFontSize()
	changeFontSize(-4)
end

local function increaseFontSize()
	changeFontSize(4)
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
	if not seg or not seg["end"] then
		return
	end

	if t >= seg["end"] then
		local next_index = p_count
		repeat
			next_index = next_index == #positions and 1 or next_index + 1
		until positions[next_index].selected or next_index == p_count
		if positions[next_index].selected then
			p_count = next_index
			mp.set_property_native("time-pos", positions[p_count].start)
		end
	end
end

local function start_looping_if_possible()
	local first_selected = firstSelectedIndex()

	if first_selected then
		p_count = first_selected
		mp.set_property_native("time-pos", positions[p_count].start)
		mp.observe_property("time-pos", "string", on_timepos_change)
		return true
	else
		message("you have to select some points first!")
		drawMenu()
		return false
	end
end

stop_looping = function()
	mp.unobserve_property(on_timepos_change)
end

local function loop()
	if not looping then
		looping = true
		clearMenu()
		if not start_looping_if_possible() then
			looping = false
		end
	else
		looping = false
		stop_looping()
		drawMenu()
	end
end

-- Reload positions from JSON on disk (so you can edit it externally).
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

	local out, err = parse_positions_json(spath)
	if not out then
		message("reload failed: " .. tostring(err))
		return
	end

	positions = out
	ab = {}
	p_count = 1

	if looping then
		stop_looping()
		if start_looping_if_possible() then
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
	{ "-", "multiloop-font-decrease", decreaseFontSize },
	{ "+", "multiloop-font-increase", increaseFontSize },
	{ "ESC", "multiloop-hide", clearMenu },
}

local function deactivate()
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

	load_positions_json()
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
