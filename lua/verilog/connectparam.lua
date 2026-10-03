local M = {}

local TS = vim.treesitter
local Util = require("verilog.util")
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")

-- Pull name + (best-effort) type + default value from a parameter_declaration
-- or local_parameter_declaration node. Skips entries without a default since
-- the new-param / new-localparam paths need something to insert.
local function extract_param_info(pd, buffer)
	local pa = ts.search_children_for_type(pd, "param_assignment")
	if pa == nil or pa:named_child_count() < 2 then
		return nil
	end
	local name = TS.get_node_text(pa:named_child(0), buffer)
	local value = TS.get_node_text(pa:named_child(1), buffer)

	local type_str
	for c in pd:iter_children() do
		local t = c:type()
		if
			t == "data_type"
			or t == "data_type_or_implicit"
			or t == "integer_vector_type"
			or t == "integer_atom_type"
			or t == "non_integer_type"
			or t == "type_reference"
			or t == "implicit_data_type"
		then
			type_str = TS.get_node_text(c, buffer)
			break
		end
	end

	return { name = name, type = type_str, value = value }
end

local function read_source_params(inst_type)
	local source_buf = file.read_file_into_new_buffer(inst_type, false)
	if source_buf == nil then
		return nil
	end
	local result = {}
	local params = query.get_parameters_from_buffer(source_buf) or {}
	for _, pd in ipairs(params) do
		local info = extract_param_info(pd, source_buf)
		if info then
			table.insert(result, info)
		end
	end
	vim.api.nvim_buf_delete(source_buf, { force = true })
	return result
end

-- Returns list of { kind = "parameter"|"localparam", name, type, value }.
local function read_parent_params(module_node, buffer)
	local result = {}
	for _, pd in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "parameter_declaration"
	end)) do
		local info = extract_param_info(pd, buffer)
		if info then
			info.kind = "parameter"
			table.insert(result, info)
		end
	end
	for _, lpd in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "local_parameter_declaration"
	end)) do
		local info = extract_param_info(lpd, buffer)
		if info then
			info.kind = "localparam"
			table.insert(result, info)
		end
	end
	return result
end

local function inst_override_map(inst, buffer)
	local result = {}
	for _, npa in ipairs(ts.filter_children(inst, function(v)
		return v:type() == "named_parameter_assignment"
	end)) do
		if npa:named_child_count() >= 2 then
			local name = TS.get_node_text(npa:named_child(0), buffer)
			result[name] = npa:named_child(1)
		end
	end
	return result
end

-- Set or add an override `.<source_name>(<value_text>)` on the instantiation.
local function set_override(inst, source_name, value_text, buffer)
	local overrides = inst_override_map(inst, buffer)
	if overrides[source_name] then
		local sr, sc, er, ec = TS.get_node_range(overrides[source_name], 0)
		vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { value_text })
		return
	end

	local existing = ts.filter_children(inst, function(v)
		return v:type() == "named_parameter_assignment"
	end)
	if #existing > 0 then
		local last = existing[#existing]
		local _, _, er, ec = TS.get_node_range(last, 0)
		vim.api.nvim_buf_set_text(0, er, ec, er, ec, { ", ." .. source_name .. "(" .. value_text .. ")" })
		return
	end

	-- No #(...) yet — synthesize one between instance_type and hierarchical_instance.
	local instance_type = inst:named_child(0)
	local hi = ts.search_children_for_type(inst, "hierarchical_instance")
	if instance_type == nil or hi == nil then
		return
	end
	local _, _, ier, iec = TS.get_node_range(instance_type, 0)
	local hsr, hsc = TS.get_node_range(hi, 0)
	local replacement = " #(." .. source_name .. "(" .. value_text .. ")) "
	vim.api.nvim_buf_set_text(0, ier, iec, hsr, hsc, { replacement })
end

local function format_param_decl(prefix, type_str, name, value)
	local out = prefix
	if type_str and type_str ~= "" then
		out = out .. " " .. type_str
	end
	return out .. " " .. name .. " = " .. value
end

-- Add a new parameter to the module's parameter port list. Creates `#(...)` if
-- the module doesn't have one yet.
local function add_parent_parameter(module_node, name, type_str, value, buffer)
	local ppl = ts.search_children_for_type(module_node, "parameter_port_list")
	if ppl then
		local pds = ts.filter_children(ppl, function(v)
			return v:type() == "parameter_port_declaration" or v:type() == "parameter_declaration"
		end)
		if #pds > 0 then
			local last = pds[#pds]
			local _, _, er, ec = TS.get_node_range(last, 0)
			local text = ", " .. format_param_decl("parameter", type_str, name, value)
			vim.api.nvim_buf_set_text(0, er, ec, er, ec, { text })
			return
		end
	end

	-- No parameter_port_list yet. Insert `#(parameter ... = ...)` after the
	-- module identifier in the header.
	local header
	for _, h in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "module_ansi_header" or v:type() == "module_nonansi_header"
	end)) do
		header = h
		break
	end
	if header == nil then
		return
	end
	local id = ts.search_children_for_type(header, "simple_identifier")
	if id == nil then
		return
	end
	local _, _, er, ec = TS.get_node_range(id, 0)
	local text = " #(" .. format_param_decl("parameter", type_str, name, value) .. ")"
	vim.api.nvim_buf_set_text(0, er, ec, er, ec, { text })
end

-- Add a new localparam line right after the module header.
local function add_parent_localparam(module_node, name, type_str, value, buffer)
	local header
	for _, h in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "module_ansi_header" or v:type() == "module_nonansi_header"
	end)) do
		header = h
		break
	end
	if header == nil then
		return
	end
	local _, _, er = TS.get_node_range(header, 0)
	local text = format_param_decl("localparam", type_str, name, value) .. ";"
	vim.api.nvim_buf_set_lines(0, er + 1, er + 1, false, { text })
end

-- Resolve the instantiation again from the cursor — needed after a parent edit
-- that shifts buffer positions.
local function refresh_inst()
	local node = ts.get_node_at_cursor()
	return ts.search_parents_for_type(node, "module_instantiation")
end

-- Apply the user's chosen wiring for one source parameter.
-- target = { kind = "existing" | "new_parameter" | "new_localparam", name = string (existing only) }
function M.apply(inst, module_node, source_param, target, new_name)
	if target.kind == "existing" then
		set_override(inst, source_param.name, target.name, 0)
		return
	end

	if target.kind == "new_parameter" then
		add_parent_parameter(module_node, new_name, source_param.type, source_param.value, 0)
	elseif target.kind == "new_localparam" then
		add_parent_localparam(module_node, new_name, source_param.type, source_param.value, 0)
	else
		return
	end

	-- Buffer shifted; re-find the inst by cursor.
	local refreshed = refresh_inst() or inst
	set_override(refreshed, source_param.name, new_name, 0)
end

-- Resolve the inst + module + source params + current overrides from cursor.
-- Returns a context table or nil if any step fails.
local function build_context()
	local node = ts.get_node_at_cursor()
	if node == nil then
		return nil, "no node at cursor"
	end
	local inst = ts.search_parents_for_type(node, "module_instantiation")
	if inst == nil then
		return nil, "cursor is not inside a module_instantiation"
	end
	local module_node = ts.search_parents_for_type(node, "module_declaration")
	if module_node == nil then
		return nil, "cursor is not inside a module_declaration"
	end
	local inst_type = TS.get_node_text(inst:named_child(0), 0)
	local source_params = read_source_params(inst_type)
	if source_params == nil or #source_params == 0 then
		return nil, "no parameters with defaults in source module: " .. inst_type
	end
	return {
		inst = inst,
		module = module_node,
		source_params = source_params,
		overrides = inst_override_map(inst, 0),
	}
end

-- Picker B + apply, given a pre-chosen source_param.
-- Util.telescope_ports displays entry slots [2]..[4] separated by " | ", so:
--   [2] = target name (the most identifying field)
--   [3] = kind (parameter / localparam / new)
--   [4] = type (or "(untyped)")
-- Slot [1] is duplicated as the name so tests can still match by entry[1].
local function pick_target_and_wire(ctx, source_param)
	local picker_b = {}
	for _, pp in ipairs(read_parent_params(ctx.module, 0)) do
		table.insert(picker_b, {
			pp.name,
			pp.name,
			pp.kind,
			pp.type or "(untyped)",
			_target = { kind = "existing", name = pp.name },
		})
	end
	table.insert(picker_b, {
		"[new parameter]",
		"[new parameter]",
		"new",
		source_param.type or "(untyped)",
		_target = { kind = "new_parameter" },
	})
	table.insert(picker_b, {
		"[new localparam]",
		"[new localparam]",
		"new",
		source_param.type or "(untyped)",
		_target = { kind = "new_localparam" },
	})

	Util.telescope_ports(picker_b, function(picked_b)
		local target = picked_b._target

		if target.kind == "existing" then
			M.apply(ctx.inst, ctx.module, source_param, target)
			return
		end

		vim.ui.input(
			{
				prompt = "New " .. (target.kind == "new_parameter" and "parameter" or "localparam") .. " name:",
				default = source_param.name,
			},
			function(input)
				if input == nil or input == "" then
					return
				end
				M.apply(ctx.inst, ctx.module, source_param, target, input)
			end
		)
	end)
end

-- Full flow: pick source param via Picker A, then run pick_target_and_wire.
function M.connect_params()
	local ctx, err = build_context()
	if ctx == nil then
		vim.print(err)
		return
	end

	-- Util.telescope_ports displays entry slots [2]..[4]. Layout:
	--   [2] = source param name (most identifying)
	--   [3] = type (or "(untyped)")
	--   [4] = override status / default value
	-- Slot [1] is duplicated as the name so tests can still match by entry[1].
	local picker_a = {}
	for _, sp in ipairs(ctx.source_params) do
		local status
		if ctx.overrides[sp.name] then
			status = "override=" .. TS.get_node_text(ctx.overrides[sp.name], 0)
		else
			status = "default=" .. sp.value
		end
		table.insert(picker_a, {
			sp.name,
			sp.name,
			sp.type or "(untyped)",
			status,
			_source = sp,
		})
	end

	Util.telescope_ports(picker_a, function(picked_a)
		pick_target_and_wire(ctx, picked_a._source)
	end)
end

-- Skip Picker A: use the source param matching the cursor's
-- named_parameter_assignment, then run pick_target_and_wire.
function M.connect_specific_param(npa)
	local ctx, err = build_context()
	if ctx == nil then
		vim.print(err)
		return
	end
	if npa:named_child_count() < 1 then
		vim.print("named_parameter_assignment has no name")
		return
	end
	local name = TS.get_node_text(npa:named_child(0), 0)
	local source_param
	for _, sp in ipairs(ctx.source_params) do
		if sp.name == name then
			source_param = sp
			break
		end
	end
	if source_param == nil then
		vim.print("Source parameter '" .. name .. "' not found in module: " .. TS.get_node_text(ctx.inst:named_child(0), 0))
		return
	end
	pick_target_and_wire(ctx, source_param)
end

return M
