local M = {}

local TS = vim.treesitter
local Util = require("verilog.util")
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")
local template = require("verilog.template")
local module_ops = require("verilog.module")
local ui = require("verilog.ui")

-- Returns ordered list of { name, value } from the source buffer.
local function collect_declared_params(source_buf)
	local result = {}
	local params = query.get_parameters_from_buffer(source_buf) or {}
	for _, declp in ipairs(params) do
		local pa = ts.search_children_for_type(declp, "param_assignment")
		if pa then
			local name = TS.get_node_text(pa:named_child(0), source_buf)
			local value = TS.get_node_text(pa:named_child(1), source_buf)
			table.insert(result, { name = name, value = value })
		end
	end
	return result
end

-- Returns ordered list of { name } from the source buffer.
local function collect_declared_ports(source_buf)
	local result = {}
	local ports = query.get_ports_from_buffer(source_buf) or {}
	for _, p in ipairs(ports) do
		local _, _, name = query.get_port_breakdown(p, source_buf)
		if name then
			table.insert(result, { name = name })
		end
	end
	return result
end

-- Returns ordered list of { name, value, node } for existing parameters.
local function collect_existing_params(inst)
	local params = ts.filter_children(inst, function(v)
		return v:type() == "named_parameter_assignment"
	end)
	local result = {}
	for _, p in ipairs(params) do
		local name = TS.get_node_text(p:named_child(0), 0)
		local value = ""
		if p:named_child_count() > 1 then
			value = TS.get_node_text(p:named_child(1), 0)
		end
		table.insert(result, { name = name, value = value, node = p })
	end
	return result
end

-- Returns ordered list of { name, value, node } for existing port connections.
local function collect_existing_ports(inst)
	local ports = ts.filter_children(inst, function(v)
		return v:type() == "named_port_connection"
	end)
	local result = {}
	for _, p in ipairs(ports) do
		local name = TS.get_node_text(p:named_child(0), 0)
		local value = ""
		if p:named_child_count() > 1 then
			value = TS.get_node_text(p:named_child(1), 0)
		end
		table.insert(result, { name = name, value = value, node = p })
	end
	return result
end

-- Diff declared and existing entries by name. Preserves order.
-- This is the seam for a future rename UI: stale × missing pairs can be
-- converted to in-place rename edits before plan_edits is called.
local function diff_entries(declared, existing)
	local declared_set = {}
	for _, d in ipairs(declared) do
		declared_set[d.name] = d
	end
	local existing_set = {}
	for _, e in ipairs(existing) do
		existing_set[e.name] = e
	end

	local matched, stale = {}, {}
	for _, e in ipairs(existing) do
		if declared_set[e.name] then
			table.insert(matched, e)
		else
			table.insert(stale, e)
		end
	end

	local missing = {}
	for _, d in ipairs(declared) do
		if not existing_set[d.name] then
			table.insert(missing, d)
		end
	end

	return { matched = matched, stale = stale, missing = missing }
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

-- For a list of existing entries (each with a TS node) and a diff result,
-- produce delete edits collapsing consecutive stale runs.
-- Each run is deleted as a single edit that swallows the leading or trailing
-- comma+whitespace, depending on which side has a surviving neighbor.
-- The all-stale case (no surviving neighbors anywhere) is handled by the caller
-- via a full-list replacement.
local function plan_deletions(existing, diff)
	local declared_set = {}
	for _, m in ipairs(diff.matched) do
		declared_set[m.name] = true
	end

	local edits = {}
	local i = 1
	while i <= #existing do
		if not declared_set[existing[i].name] then
			local start_idx = i
			while i <= #existing and not declared_set[existing[i].name] do
				i = i + 1
			end
			local end_idx = i - 1

			-- Find the closest surviving neighbor on each side
			local left_idx
			for j = start_idx - 1, 1, -1 do
				if declared_set[existing[j].name] then
					left_idx = j
					break
				end
			end
			local right_idx
			for j = end_idx + 1, #existing do
				if declared_set[existing[j].name] then
					right_idx = j
					break
				end
			end

			if left_idx then
				-- Delete from end of left neighbor to end of last stale (eats leading comma+ws)
				local _, _, ler, lec = TS.get_node_range(existing[left_idx].node, 0)
				local _, _, ser, sec = TS.get_node_range(existing[end_idx].node, 0)
				table.insert(edits, make_edit(ler, lec, ser, sec, {}))
			elseif right_idx then
				-- Delete from start of first stale to start of right neighbor (eats trailing comma+ws)
				local fsr, fsc = TS.get_node_range(existing[start_idx].node, 0)
				local rsr, rsc = TS.get_node_range(existing[right_idx].node, 0)
				table.insert(edits, make_edit(fsr, fsc, rsr, rsc, {}))
			end
			-- All-stale case (neither neighbor): no edit emitted; full-replace is used instead
		else
			i = i + 1
		end
	end
	return edits
end

-- Append missing entries after the last matched existing entry.
local function plan_append_after_last_match(existing, diff, format_fn)
	if #diff.missing == 0 or #diff.matched == 0 then
		return nil
	end
	local declared_set = {}
	for _, m in ipairs(diff.matched) do
		declared_set[m.name] = true
	end
	local last_match
	for i = #existing, 1, -1 do
		if declared_set[existing[i].name] then
			last_match = existing[i]
			break
		end
	end
	if not last_match then
		return nil
	end

	local _, _, er, ec = TS.get_node_range(last_match.node, 0)
	local parts = {}
	for _, m in ipairs(diff.missing) do
		table.insert(parts, ", " .. format_fn(m))
	end
	return make_edit(er, ec, er, ec, { table.concat(parts) })
end

local function format_param(p)
	return "." .. p.name .. "(" .. p.value .. ")"
end

local function format_port(p)
	return "." .. p.name .. "()"
end

-- Build a multi-line formatted port list "(.a(), .b(), ...)".
local function format_port_list_lines(ports)
	if #ports == 0 then
		return { "()" }
	end
	local lines = { "(" }
	for i, p in ipairs(ports) do
		local sep = (i < #ports) and "," or ""
		table.insert(lines, format_port(p) .. sep)
	end
	table.insert(lines, ")")
	return lines
end

-- Build a multi-line formatted parameter block "#(.A(v), .B(v), ...)".
local function format_param_list_lines(params)
	if #params == 0 then
		return { "#()" }
	end
	local lines = { "#(" }
	for i, p in ipairs(params) do
		local sep = (i < #params) and "," or ""
		table.insert(lines, format_param(p) .. sep)
	end
	table.insert(lines, ")")
	return lines
end

-- An in-place identifier swap on a named_*_connection / named_parameter_assignment
-- node, used for rename pairings. The first named child is the simple_identifier
-- holding the port/param name; we replace just that range.
local function rename_edit(stale_entry, new_name)
	local id = stale_entry.node:named_child(0)
	local sr, sc, er, ec = TS.get_node_range(id, 0)
	return make_edit(sr, sc, er, ec, { new_name })
end

-- For each rename pair: emit a rename edit, move the stale entry from
-- diff.stale into diff.matched (so it counts as a survivor for downstream
-- planning), and drop the matching missing entry. Mutates `diff` in place.
local function apply_renames_to_diff(diff, renames, edits)
	for _, r in ipairs(renames) do
		table.insert(edits, rename_edit(r.from, r.to.name))
		for i, s in ipairs(diff.stale) do
			if s == r.from then
				table.insert(diff.matched, s)
				table.remove(diff.stale, i)
				break
			end
		end
		for i, m in ipairs(diff.missing) do
			if m == r.to then
				table.remove(diff.missing, i)
				break
			end
		end
	end
end

-- Plan all edits for parameters.
-- Full-replace targets the whole region between instance_type and hierarchical_instance,
-- regardless of whether a parameter_value_assignment node currently exists, so the
-- empty/missing cases are handled uniformly.
local function plan_param_edits(edits, declared_params, existing_params, diff, inst)
	if #diff.matched == 0 and (#diff.stale > 0 or #diff.missing > 0) then
		local instance_type = inst:named_child(0)
		local hi = ts.search_children_for_type(inst, "hierarchical_instance")
		if hi == nil then
			return
		end
		local _, _, ier, iec = TS.get_node_range(instance_type, 0)
		local hsr, hsc = TS.get_node_range(hi, 0)
		local replacement
		if #declared_params == 0 then
			replacement = { " " }
		else
			local block = format_param_list_lines(declared_params)
			block[1] = " " .. block[1]
			block[#block] = block[#block] .. " "
			replacement = block
		end
		table.insert(edits, make_edit(ier, iec, hsr, hsc, replacement))
		return
	end

	if #diff.stale == 0 and #diff.missing == 0 then
		return
	end

	-- Mixed: some matched. Emit per-group deletions and a single append.
	for _, e in ipairs(plan_deletions(existing_params, diff)) do
		table.insert(edits, e)
	end
	local app = plan_append_after_last_match(existing_params, diff, format_param)
	if app then
		table.insert(edits, app)
	end
end

-- Plan all edits for ports.
-- Full-replace targets the whole "(...)" region of hierarchical_instance, regardless of
-- whether a list_of_port_connections node currently exists (it doesn't for empty parens).
local function plan_port_edits(edits, declared_ports, existing_ports, diff, inst)
	if #diff.matched == 0 and (#diff.stale > 0 or #diff.missing > 0) then
		local hi = ts.search_children_for_type(inst, "hierarchical_instance")
		if hi == nil then
			return
		end
		local name = ts.search_children_for_type(hi, "name_of_instance")
		if name == nil then
			return
		end
		local _, _, ner, nec = TS.get_node_range(name, 0)
		local _, _, her, hec = TS.get_node_range(hi, 0)
		local replacement
		if #declared_ports == 0 then
			replacement = { " ()" }
		else
			local block = format_port_list_lines(declared_ports)
			block[1] = " " .. block[1]
			replacement = block
		end
		table.insert(edits, make_edit(ner, nec, her, hec, replacement))
		return
	end

	if #diff.stale == 0 and #diff.missing == 0 then
		return
	end

	for _, e in ipairs(plan_deletions(existing_ports, diff)) do
		table.insert(edits, e)
	end
	local app = plan_append_after_last_match(existing_ports, diff, format_port)
	if app then
		table.insert(edits, app)
	end
end

-- Sort edits by start position descending, breaking ties by end position descending.
-- The end-descending tiebreaker ensures a delete fires before an insertion at the
-- same start point — important when missing entries are appended right where stale
-- ones were.
local function sort_edits(edits)
	table.sort(edits, function(a, b)
		if a.start_row ~= b.start_row then
			return a.start_row > b.start_row
		end
		if a.start_col ~= b.start_col then
			return a.start_col > b.start_col
		end
		if a.end_row ~= b.end_row then
			return a.end_row > b.end_row
		end
		return a.end_col > b.end_col
	end)
end

function M.update_instantiation_at_cursor()
	local node = ts.get_node_at_cursor()
	local inst = ts.search_parents_for_type(node, "module_instantiation")
	if inst == nil then
		vim.print("No module instantiation at cursor")
		return
	end

	local inst_type = TS.get_node_text(inst:named_child(0), 0)
	local source_buf = file.read_file_into_new_buffer(inst_type, false)
	if source_buf == nil then
		vim.print("Could not find module definition")
		return
	end

	local declared_params = collect_declared_params(source_buf)
	local declared_ports = collect_declared_ports(source_buf)
	vim.api.nvim_buf_delete(source_buf, { force = true })

	local existing_params = collect_existing_params(inst)
	local existing_ports = collect_existing_ports(inst)

	local param_diff = diff_entries(declared_params, existing_params)
	local port_diff = diff_entries(declared_ports, existing_ports)

	-- Sequence the rename UI: params first, then ports, then plan & apply.
	-- pick_renames returns synchronously (calls on_done immediately) when no
	-- rename is possible (stale=0 or missing=0), so this stays sync for the
	-- common case.
	ui.pick_renames(param_diff, "parameter", function(param_renames)
		ui.pick_renames(port_diff, "port", function(port_renames)
			local edits = {}
			apply_renames_to_diff(param_diff, param_renames, edits)
			apply_renames_to_diff(port_diff, port_renames, edits)

			plan_param_edits(edits, declared_params, existing_params, param_diff, inst)
			plan_port_edits(edits, declared_ports, existing_ports, port_diff, inst)

			sort_edits(edits)

			for _, e in ipairs(edits) do
				vim.api.nvim_buf_set_text(0, e.start_row, e.start_col, e.end_row, e.end_col, e.replacement)
			end
		end)
	end)
end

function M.auto_instantiate(file_name)
	local new_buffer = file.read_file_into_new_buffer(file_name, true)
	if new_buffer == nil then
		vim.print("Could not read file: ", file_name)
		return
	end

	local modules = query.get_modules_from_buffer(new_buffer)
	if modules == nil then
		vim.print("Could not find module in file: ", file_name)
	elseif #modules == 0 then
		-- Valid read on file but no interfaces/modules. Try packages.
		local packages = query.get_packages_from_buffer(new_buffer)
		if packages and #packages ~= 0 then
			for _, pkg in ipairs(packages) do
				local pkg_name = TS.get_node_text(pkg:named_child(0), new_buffer)
				module_ops.import_package(pkg_name)
			end
		end
	else
		local instantiation_template = template.generate_module_instantiation(modules[1], new_buffer)
		if instantiation_template ~= nil then
			vim.api.nvim_put({ instantiation_template }, "l", false, true)
		end
	end
	vim.api.nvim_buf_delete(new_buffer, { force = true })
end

local function inst_with_telescope()
	Util.telescope(M.auto_instantiate)
end

function M.auto_instantiation(args)
	if args == "" then
		local node = ts.get_node_at_cursor()
		local inst = ts.search_parents_for_type(node, "module_instantiation")
		if inst ~= nil then
			M.update_instantiation_at_cursor()
		else
			inst_with_telescope()
		end
	else
		M.auto_instantiate(args)
	end
end

return M
