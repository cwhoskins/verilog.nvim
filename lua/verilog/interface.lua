local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local file = require("verilog.file")

-- Try to load `type_name` as a SystemVerilog interface declaration.
-- Returns { type_name, signal_names = { ordered list } } if the resolved file
-- contains an interface_declaration, else nil. Does NOT return modport info
-- (first iteration only needs signal names for matching).
function M.read_interface(type_name)
	local source_buf = file.read_file_into_new_buffer(type_name, false)
	if source_buf == nil then
		return nil
	end

	local nodes = ts.get_query_nodes(source_buf, "((source_file) @file)")
	if nodes == nil or #nodes == 0 then
		vim.api.nvim_buf_delete(source_buf, { force = true })
		return nil
	end

	local ifaces = ts.filter_children(nodes[1], function(v)
		return v:type() == "interface_declaration"
	end)
	if #ifaces == 0 then
		vim.api.nvim_buf_delete(source_buf, { force = true })
		return nil
	end

	local iface = ifaces[1]
	local signals = {}
	local seen = {}

	-- Walk for both data_declaration and net_declaration (the verilog grammar
	-- splits these inconsistently for `logic foo;` vs `mytype_t foo;`).
	for _, decl in ipairs(ts.filter_children(iface, function(v)
		return v:type() == "data_declaration" or v:type() == "net_declaration"
	end)) do
		for _, asgn in ipairs(ts.filter_children(decl, function(v)
			return v:type() == "variable_decl_assignment" or v:type() == "net_decl_assignment"
		end)) do
			if asgn:named_child_count() >= 1 then
				local name = TS.get_node_text(asgn:named_child(0), source_buf)
				if name and not seen[name] then
					seen[name] = true
					table.insert(signals, name)
				end
			end
		end
	end

	vim.api.nvim_buf_delete(source_buf, { force = true })

	return { type_name = type_name, signal_names = signals }
end

-- Discover interface variables in the parent module's scope. Returns list of:
--   { var_name, type_name, modport (optional), kind = "port"|"instance" }
-- "port" entries come from the parent module's port list (interface_port_header).
-- "instance" entries are body declarations parsed as module_instantiation that
-- happen to resolve to an interface_declaration in their source file.
function M.find_candidates(module_node, buffer, interface_cache)
	interface_cache = interface_cache or {}

	local function lookup(name)
		if interface_cache[name] == nil then
			interface_cache[name] = M.read_interface(name) or false
		end
		return interface_cache[name] or nil
	end

	local candidates = {}

	-- Interface ports of the parent module
	for _, port in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "ansi_port_declaration"
	end)) do
		local header = port:named_child(0)
		if header and header:type() == "interface_port_header" and port:named_child_count() >= 2 then
			local iface_text = TS.get_node_text(header, buffer)
			-- header text is e.g. "axis_t_if.s" or "axis_t_if"
			local iface_name, modport = iface_text:match("^([%w_]+)%.?([%w_]*)$")
			if iface_name and lookup(iface_name) then
				table.insert(candidates, {
					var_name = TS.get_node_text(port:named_child(1), buffer),
					type_name = iface_name,
					modport = (modport ~= "" and modport) or nil,
					kind = "port",
				})
			end
		end
	end

	-- Body instances (parsed as module_instantiation; check if the type is
	-- actually an interface_declaration in its source file).
	for _, inst in ipairs(ts.filter_children(module_node, function(v)
		return v:type() == "module_instantiation"
	end)) do
		local type_node = inst:named_child(0)
		if type_node then
			local type_name = TS.get_node_text(type_node, buffer)
			if lookup(type_name) then
				local hi = ts.search_children_for_type(inst, "hierarchical_instance")
				if hi then
					local name_of_inst = ts.search_children_for_type(hi, "name_of_instance")
					if name_of_inst and name_of_inst:named_child_count() >= 1 then
						table.insert(candidates, {
							var_name = TS.get_node_text(name_of_inst:named_child(0), buffer),
							type_name = type_name,
							modport = nil,
							kind = "instance",
						})
					end
				end
			end
		end
	end

	return candidates
end

return M
