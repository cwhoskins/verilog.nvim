local M = {}

local TS = vim.treesitter
local Util = require("verilog.util")
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")
local interface = require("verilog.interface")

-- Returns ordered list of port names from the source file of `inst_type`.
-- Handles non-ANSI multi-id declarations by spreading across all identifiers.
local function read_source_port_names(inst_type)
	local source_buf = file.read_file_into_new_buffer(inst_type, false)
	if source_buf == nil then
		return nil
	end
	local ports = query.get_ports_from_buffer(source_buf)
	if ports == nil then
		vim.api.nvim_buf_delete(source_buf, { force = true })
		return nil
	end
	local names = {}
	for _, p in ipairs(ports) do
		if p:type() == "ansi_port_declaration" then
			local _, _, name = query.get_port_breakdown(p, source_buf)
			if name then
				table.insert(names, name)
			end
		elseif p:type() == "port_declaration" then
			for _, list in ipairs(ts.filter_children(p, function(v)
				return v:type() == "list_of_variable_port_identifiers"
					or v:type() == "list_of_port_identifiers"
					or v:type() == "list_of_variable_identifiers"
			end)) do
				for c in list:iter_children() do
					if c:type() == "simple_identifier" then
						table.insert(names, TS.get_node_text(c, source_buf))
					end
				end
			end
		end
	end
	vim.api.nvim_buf_delete(source_buf, { force = true })
	return names
end

-- Strip a leading direction prefix (i_, o_, b_) from a port name.
local function strip_direction(name)
	local stripped = name:gsub("^[iob]_", "")
	return stripped
end

-- Pattern-escape a literal so it can be used inside a Lua pattern.
local function pattern_escape(s)
	return (s:gsub("([^%w])", "%%%1"))
end

-- For a source port name, find the interface signal it should connect to.
-- Returns the matched signal name, or nil. Match heuristic:
--   1. Strip leading direction prefix (i_, o_, b_).
--   2. Accept a signal whose name equals the stripped port, or whose name is
--      a `_<signal>`-suffix of the stripped port (handles `i_axis_vld` ↔ `vld`).
local function match_port_to_signal(port_name, signal_names)
	local stripped = strip_direction(port_name)
	for _, sig in ipairs(signal_names) do
		if stripped == sig then
			return sig
		end
	end
	for _, sig in ipairs(signal_names) do
		if stripped:match("_" .. pattern_escape(sig) .. "$") then
			return sig
		end
	end
	return nil
end

-- For each source port, decide which interface signal (if any) it should match.
-- Returns map { port_name -> signal_name }.
local function compute_matches(source_port_names, interface_signals)
	local matches = {}
	for _, port in ipairs(source_port_names) do
		local sig = match_port_to_signal(port, interface_signals)
		if sig then
			matches[port] = sig
		end
	end
	return matches
end

local function map_size(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

-- Existing connection map for an instantiation: port_name → connection text
-- (or `""` for an empty `.port()` slot).
local function existing_connections(inst, buffer)
	local result = {}
	for _, npc in ipairs(ts.filter_children(inst, function(v)
		return v:type() == "named_port_connection"
	end)) do
		if npc:named_child_count() >= 1 then
			local name = TS.get_node_text(npc:named_child(0), buffer)
			local val = ""
			if npc:named_child_count() >= 2 then
				val = TS.get_node_text(npc:named_child(1), buffer)
			end
			result[name] = { node = npc, value = val }
		end
	end
	return result
end

-- Apply all matches: for each source port that mapped to an interface signal,
-- ensure the instantiation has `.port(<var>.<signal>)`. Skips ports already
-- explicitly connected to a non-empty value (don't override the user).
--
-- All edits come from a single TS snapshot. Adds are batched into one
-- insert at the end of the existing connection list. Replaces of empty
-- `.port()` slots are emitted separately. Edits are sorted by start position
-- descending so an earlier replace's position stays valid even though a
-- later-positioned add lengthens the buffer.
local function apply_matches(inst, var_name, matches, buffer)
	local existing = existing_connections(inst, buffer)

	local source_port_order = {}
	for port in pairs(matches) do
		table.insert(source_port_order, port)
	end
	table.sort(source_port_order)

	local edits = {}
	local additions = {}

	for _, port in ipairs(source_port_order) do
		local sig = matches[port]
		local value = var_name .. "." .. sig
		local current = existing[port]
		if current == nil then
			table.insert(additions, "." .. port .. "(" .. value .. ")")
		elseif current.value == "" then
			-- Empty `.port()` — replace the whole npc with `.port(value)` so
			-- this works whether or not the grammar exposes an empty value child.
			local sr, sc, er, ec = TS.get_node_range(current.node, 0)
			table.insert(edits, {
				sr = sr, sc = sc, er = er, ec = ec,
				replacement = { "." .. port .. "(" .. value .. ")" },
			})
		end
		-- else: explicit connection with a non-empty value — leave alone.
	end

	if #additions > 0 then
		local existing_npcs = ts.filter_children(inst, function(v)
			return v:type() == "named_port_connection"
		end)
		if #existing_npcs > 0 then
			local last = existing_npcs[#existing_npcs]
			local _, _, er, ec = TS.get_node_range(last, 0)
			table.insert(edits, {
				sr = er, sc = ec, er = er, ec = ec,
				replacement = { ", " .. table.concat(additions, ", ") },
			})
		else
			local hi = ts.search_children_for_type(inst, "hierarchical_instance")
			if hi then
				local name_node = ts.search_children_for_type(hi, "name_of_instance")
				if name_node then
					local _, _, ner, nec = TS.get_node_range(name_node, 0)
					local _, _, her, hec = TS.get_node_range(hi, 0)
					table.insert(edits, {
						sr = ner, sc = nec, er = her, ec = hec,
						replacement = { " (" .. table.concat(additions, ", ") .. ")" },
					})
				end
			end
		end
	end

	-- Apply backwards by position so earlier-positioned edits stay valid.
	table.sort(edits, function(a, b)
		if a.sr ~= b.sr then return a.sr > b.sr end
		if a.sc ~= b.sc then return a.sc > b.sc end
		if a.er ~= b.er then return a.er > b.er end
		return a.ec > b.ec
	end)

	for _, e in ipairs(edits) do
		vim.api.nvim_buf_set_text(0, e.sr, e.sc, e.er, e.ec, e.replacement)
	end
end

function M.wire_to_interface()
	local node = ts.get_node_at_cursor()
	local inst = ts.search_parents_for_type(node, "module_instantiation")
	if inst == nil then
		vim.print("Cursor is not inside a module_instantiation")
		return
	end
	local module_node = ts.search_parents_for_type(node, "module_declaration")
	if module_node == nil then
		vim.print("Cursor is not inside a module_declaration")
		return
	end

	local inst_type = TS.get_node_text(inst:named_child(0), 0)
	local source_ports = read_source_port_names(inst_type)
	if source_ports == nil or #source_ports == 0 then
		vim.print("No source ports found for: " .. inst_type)
		return
	end

	local cache = {}
	local candidates = interface.find_candidates(module_node, 0, cache)
	if #candidates == 0 then
		vim.print("No interface variables in scope")
		return
	end

	-- Score each candidate
	local scored = {}
	for _, c in ipairs(candidates) do
		local iface = cache[c.type_name]
		if iface then
			local matches = compute_matches(source_ports, iface.signal_names)
			local count = map_size(matches)
			if count > 0 then
				table.insert(scored, {
					candidate = c,
					interface = iface,
					matches = matches,
					score = count,
				})
			end
		end
	end

	if #scored == 0 then
		vim.print("No interface candidates matched any source ports")
		return
	end

	table.sort(scored, function(a, b)
		return a.score > b.score
	end)

	-- Picker
	local entries = {}
	for _, s in ipairs(scored) do
		local type_str = s.candidate.type_name
		if s.candidate.modport then
			type_str = type_str .. "." .. s.candidate.modport
		end
		table.insert(entries, {
			s.candidate.var_name,
			s.candidate.var_name,
			type_str,
			string.format("match %d/%d", s.score, #source_ports),
			_scored = s,
		})
	end

	Util.telescope_ports(entries, function(picked)
		local s = picked._scored
		apply_matches(inst, s.candidate.var_name, s.matches, 0)
	end)
end

return M
