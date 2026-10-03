local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")

-- True if the named_port_connection is a wildcard (.*) connection.
local function is_wildcard(npc)
	for c in npc:iter_children() do
		if c:type() == ".*" then
			return true
		end
	end
	return false
end

-- Set of explicitly-named ports in an instantiation (used to filter the wildcard's
-- expansion so explicit overrides aren't duplicated).
local function explicit_port_names(inst)
	local names = {}
	local connections = ts.filter_children(inst, function(v)
		return v:type() == "named_port_connection"
	end)
	for _, npc in ipairs(connections) do
		if not is_wildcard(npc) and npc:named_child_count() >= 1 then
			local name_node = npc:named_child(0)
			if name_node then
				names[TS.get_node_text(name_node, 0)] = true
			end
		end
	end
	return names
end

-- Find every module_instantiation in the buffer that contains a .* connection.
local function find_wildcards(buffer)
	local result = {}
	local source_file_nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if source_file_nodes == nil or #source_file_nodes == 0 then
		return result
	end
	local insts = ts.filter_children(source_file_nodes[1], function(v)
		return v:type() == "module_instantiation"
	end)
	for _, inst in ipairs(insts) do
		local connections = ts.filter_children(inst, function(v)
			return v:type() == "named_port_connection"
		end)
		for _, npc in ipairs(connections) do
			if is_wildcard(npc) then
				table.insert(result, {
					inst = inst,
					wildcard_npc = npc,
					explicit_names = explicit_port_names(inst),
				})
				break -- LRM allows only one .* per port list
			end
		end
	end
	return result
end

-- Read source file for the module, return ordered list of port names (or nil).
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
		local _, _, name = query.get_port_breakdown(p, source_buf)
		if name then
			table.insert(names, name)
		end
	end
	vim.api.nvim_buf_delete(source_buf, { force = true })
	return names
end

local function make_edit(sr, sc, er, ec, replacement)
	return {
		start_row = sr,
		start_col = sc,
		end_row = er,
		end_col = ec,
		replacement = replacement,
	}
end

-- For the all-explicit case (no expansion needed), find the range that swallows
-- the wildcard plus a companion comma so we don't leave dangling separators.
local function wildcard_removal_range(npc)
	local parent = npc:parent()
	local sr, sc, er, ec = TS.get_node_range(npc, 0)
	if parent == nil then
		return sr, sc, er, ec
	end

	-- Find comma immediately before npc, and comma immediately after.
	local prev_comma, next_comma
	local seen_npc = false
	local prev_node
	for c in parent:iter_children() do
		if c == npc then
			seen_npc = true
			if prev_node and prev_node:type() == "," then
				prev_comma = prev_node
			end
		elseif seen_npc and c:type() == "," and next_comma == nil then
			next_comma = c
			break
		end
		prev_node = c
	end

	if next_comma then
		local _, _, ner, nec = TS.get_node_range(next_comma, 0)
		return sr, sc, ner, nec
	elseif prev_comma then
		local pr, pc, _, _ = TS.get_node_range(prev_comma, 0)
		return pr, pc, er, ec
	end
	return sr, sc, er, ec
end

-- Expand every .* connection in the buffer in place.
-- Returns the number of wildcards expanded (0 means nothing to do).
function M.expand_file(buffer)
	buffer = buffer or 0
	local wildcards = find_wildcards(buffer)
	if #wildcards == 0 then
		return 0
	end

	local edits = {}
	for _, w in ipairs(wildcards) do
		local inst_type = TS.get_node_text(w.inst:named_child(0), buffer)
		local declared = read_source_port_names(inst_type)
		if declared then
			local parts = {}
			for _, name in ipairs(declared) do
				if not w.explicit_names[name] then
					table.insert(parts, "." .. name .. "(" .. name .. ")")
				end
			end
			if #parts > 0 then
				local sr, sc, er, ec = TS.get_node_range(w.wildcard_npc, buffer)
				table.insert(edits, make_edit(sr, sc, er, ec, { table.concat(parts, ", ") }))
			else
				-- All ports already explicit — remove the .* and its companion comma.
				local sr, sc, er, ec = wildcard_removal_range(w.wildcard_npc)
				table.insert(edits, make_edit(sr, sc, er, ec, {}))
			end
		end
	end

	-- Apply highest-position edit first so earlier edits' positions stay valid.
	table.sort(edits, function(a, b)
		if a.start_row ~= b.start_row then
			return a.start_row > b.start_row
		end
		return a.start_col > b.start_col
	end)

	for _, e in ipairs(edits) do
		vim.api.nvim_buf_set_text(buffer, e.start_row, e.start_col, e.end_row, e.end_col, e.replacement)
	end

	return #edits
end

return M
