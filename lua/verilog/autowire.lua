local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")

-- Find the module the cursor is in, falling back to the first module in the buffer.
local function find_target_module(buffer)
	local node = ts.get_node_at_cursor()
	if node then
		local m = ts.search_parents_for_type(node, "module_declaration")
		if m then
			return m
		end
	end
	local source_file_nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if source_file_nodes == nil or #source_file_nodes == 0 then
		return nil
	end
	local modules = ts.filter_children(source_file_nodes[1], function(v)
		return v:type() == "module_declaration"
	end)
	return modules[1]
end

-- Collect every name already declared in the module: ports, variable/net decls,
-- and instance names. Returns a set keyed by name.
local function collect_declared_names(module_node, buffer)
	local names = {}

	for _, p in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "ansi_port_declaration"
	end)) do
		if p:named_child_count() >= 2 then
			names[TS.get_node_text(p:named_child(1), buffer)] = true
		end
	end

	for _, p in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "port_declaration"
	end)) do
		for _, list in ipairs(ts.filter_children(p, function(v)
			return v:type() == "list_of_variable_port_identifiers"
				or v:type() == "list_of_port_identifiers"
				or v:type() == "list_of_variable_identifiers"
		end)) do
			for c in list:iter_children() do
				if c:type() == "simple_identifier" then
					names[TS.get_node_text(c, buffer)] = true
				end
			end
		end
	end

	for _, v in ipairs(ts.filter_children(module_node, function(n)
		return n:type() == "variable_decl_assignment"
	end)) do
		if v:named_child_count() >= 1 then
			names[TS.get_node_text(v:named_child(0), buffer)] = true
		end
	end

	for _, n in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "net_decl_assignment"
	end)) do
		if n:named_child_count() >= 1 then
			names[TS.get_node_text(n:named_child(0), buffer)] = true
		end
	end

	-- Instance names — so we don't try to redeclare `u_foo` as a wire.
	for _, n in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "name_of_instance"
	end)) do
		if n:named_child_count() >= 1 then
			names[TS.get_node_text(n:named_child(0), buffer)] = true
		end
	end

	return names
end

-- Read the source file for `inst_type`. Returns:
--   { types = name → type-string, defaults = param_name → default_value }
-- or nil if the file can't be read. Handles non-ANSI multi-id declarations
-- (`input clk, rst, data;`) by spreading the type across all identifiers.
local function read_source_data(inst_type)
	local source_buf = file.read_file_into_new_buffer(inst_type, false)
	if source_buf == nil then
		return nil
	end
	local ports = query.get_ports_from_buffer(source_buf)
	if ports == nil then
		vim.api.nvim_buf_delete(source_buf, { force = true })
		return nil
	end
	local types = {}
	for _, p in ipairs(ports) do
		if p:type() == "ansi_port_declaration" then
			local _, ptype, name = query.get_port_breakdown(p, source_buf)
			if name and ptype then
				types[name] = ptype
			end
		elseif p:type() == "port_declaration" then
			local _, ptype = query.get_port_breakdown(p, source_buf)
			if ptype then
				for _, list in ipairs(ts.filter_children(p, function(v)
					return v:type() == "list_of_variable_port_identifiers"
						or v:type() == "list_of_port_identifiers"
						or v:type() == "list_of_variable_identifiers"
				end)) do
					for c in list:iter_children() do
						if c:type() == "simple_identifier" then
							types[TS.get_node_text(c, source_buf)] = ptype
						end
					end
				end
			end
		end
	end

	local defaults = {}
	local source_params = query.get_parameters_from_buffer(source_buf) or {}
	for _, sp in ipairs(source_params) do
		local pa = ts.search_children_for_type(sp, "param_assignment")
		if pa and pa:named_child_count() >= 2 then
			local name = TS.get_node_text(pa:named_child(0), source_buf)
			local value = TS.get_node_text(pa:named_child(1), source_buf)
			defaults[name] = value
		end
	end

	vim.api.nvim_buf_delete(source_buf, { force = true })
	return { types = types, defaults = defaults }
end

-- The `#(.X(value))` overrides on a specific instantiation node.
local function instantiation_param_overrides(inst, buffer)
	local overrides = {}
	for _, npa in ipairs(ts.filter_children(inst, function(v)
		return v:type() == "named_parameter_assignment"
	end)) do
		if npa:named_child_count() >= 2 then
			local name = TS.get_node_text(npa:named_child(0), buffer)
			local value = TS.get_node_text(npa:named_child(1), buffer)
			overrides[name] = value
		end
	end
	return overrides
end

-- Names of parameters declared in the parent module. Used to validate that
-- post-substitution identifiers in port-width expressions resolve in scope.
local function module_param_names(module_node, buffer)
	local names = {}
	for _, pd in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "parameter_declaration"
	end)) do
		local pa = ts.search_children_for_type(pd, "param_assignment")
		if pa and pa:named_child_count() >= 1 then
			names[TS.get_node_text(pa:named_child(0), buffer)] = true
		end
	end
	return names
end

-- Type-keyword identifiers we expect to see inside a port type expression and
-- never want to misinterpret as a parameter reference.
local SV_TYPE_KEYWORDS = {
	logic = true, wire = true, reg = true, bit = true,
	byte = true, integer = true, int = true, longint = true,
	shortint = true, real = true, time = true,
	signed = true, unsigned = true,
}

-- Substitute parameter references in a port type string and validate the
-- result. Returns the resolved string, or nil if the bracket expression
-- still contains identifiers we can't resolve to either parent params or
-- numeric constants.
local function resolve_type(type_str, overrides, defaults, parent_params)
	local resolved = type_str:gsub("[%a_][%w_]*", function(ident)
		if overrides[ident] then
			return overrides[ident]
		end
		if defaults[ident] then
			return defaults[ident]
		end
		return ident
	end)

	for bracket in resolved:gmatch("%[([^%]]*)%]") do
		for ident in bracket:gmatch("[%a_][%w_]*") do
			if not parent_params[ident] and not SV_TYPE_KEYWORDS[ident] then
				return nil
			end
		end
	end

	return resolved
end

-- Returns the bare identifier from a connection expression, or nil if the
-- expression is anything more complex (slice, concat, hier ref, literal, empty).
local function bare_identifier_connection(npc, buffer)
	if npc:named_child_count() < 2 then
		return nil
	end
	local expr = npc:named_child(1)
	local text = TS.get_node_text(expr, buffer)
	text = text:match("^%s*(.-)%s*$") or ""
	if text:match("^[%a_][%w_]*$") then
		return text
	end
	return nil
end

-- Walk every instantiation in the module and collect nets that need declaring.
-- Resolves parameter references in port types using inst overrides → source
-- defaults → leave-as-is, and skips ports whose width can't be resolved to
-- something valid in the parent's scope.
-- Returns ordered list of { name, type } in first-encounter order.
local function collect_undeclared_nets(module_node, declared, buffer)
	local result = {}
	local seen = {}
	local parent_params = module_param_names(module_node, buffer)

	local insts = ts.filter_children(module_node, function(v)
		return v:type() == "module_instantiation"
	end)
	for _, inst in ipairs(insts) do
		local inst_type = TS.get_node_text(inst:named_child(0), buffer)
		local source = read_source_data(inst_type)
		if source ~= nil then
			local overrides = instantiation_param_overrides(inst, buffer)
			local connections = ts.filter_children(inst, function(v)
				return v:type() == "named_port_connection"
			end)
			for _, npc in ipairs(connections) do
				if npc:named_child_count() >= 1 then
					local port_name = TS.get_node_text(npc:named_child(0), buffer)
					local net = bare_identifier_connection(npc, buffer)
					local ptype = source.types[port_name]
					if net and ptype and not declared[net] and not seen[net] then
						local resolved = resolve_type(ptype, overrides, source.defaults, parent_params)
						if resolved then
							table.insert(result, { name = net, type = resolved })
							seen[net] = true
						end
					end
				end
			end
		end
	end
	return result
end

-- Pick the row to insert at: just above the first instantiation. Returns nil if
-- there are no instantiations to anchor on.
local function insertion_row(module_node)
	local insts = ts.filter_children(module_node, function(v)
		return v:type() == "module_instantiation"
	end)
	if #insts == 0 then
		return nil
	end
	local sr = TS.get_node_range(insts[1], 0)
	return sr
end

-- Declare nets referenced by instantiations but not yet declared in the module.
-- Returns the number of declarations inserted.
function M.run(buffer)
	buffer = buffer or 0
	local module_node = find_target_module(buffer)
	if module_node == nil then
		vim.print("No module declaration in buffer")
		return 0
	end

	local declared = collect_declared_names(module_node, buffer)
	local undeclared = collect_undeclared_nets(module_node, declared, buffer)
	if #undeclared == 0 then
		return 0
	end

	local row = insertion_row(module_node)
	if row == nil then
		return 0
	end

	local lines = {}
	for _, u in ipairs(undeclared) do
		table.insert(lines, u.type .. " " .. u.name .. ";")
	end

	vim.api.nvim_buf_set_lines(buffer, row, row, false, lines)
	return #undeclared
end

return M
