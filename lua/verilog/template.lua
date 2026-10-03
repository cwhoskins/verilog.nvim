local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local query = require("verilog.query")

function M.generate_module_instantiation(module, buffer, instance_name)
	local header = ts.filter_children(module, function(val)
		return val:type() == "interface_ansi_header"
			or val:type() == "interface_nonansi_header"
			or val:type() == "module_ansi_header"
			or val:type() == "module_nonansi_header"
	end)
	if #header == 0 then
		return nil
	end

	local name
	if header[1]:type() == "interface_ansi_header" or header[1]:type() == "interface_nonansi_header" then
		name = TS.get_node_text(header[1]:named_child(0), buffer)
	else
		name = TS.get_node_text(header[1]:named_child(1), buffer)
	end

	local instantiation_template = name
	local parameters = query.get_parameters_from_buffer(buffer)

	-- Build the param entries first so we can check if any actually emit
	-- (`parameter type T = ...` uses type_assignment instead of param_assignment;
	-- skip anything we can't handle rather than emitting an empty `# ( )`).
	local param_entries = {}
	for _, param in ipairs(parameters) do
		local pa = ts.search_children_for_type(param, "param_assignment")
			or ts.search_children_for_type(param, "type_assignment")
		if pa and pa:named_child_count() >= 2 then
			local param_name = TS.get_node_text(pa:named_child(0), buffer)
			local param_value = TS.get_node_text(pa:named_child(1), buffer)
			table.insert(param_entries, "." .. param_name .. "(" .. param_value .. ")")
		end
	end

	if #param_entries > 0 then
		instantiation_template = instantiation_template .. " # ( " .. table.concat(param_entries, ", ") .. ")"
	end

	if instance_name == nil then
		instance_name = "u_" .. name
	end
	instantiation_template = instantiation_template .. " " .. instance_name .. "( "

	local ports = query.get_ports_from_buffer(buffer)
	for _, port in ipairs(ports) do
		local _, _, decl_name = query.get_port_breakdown(port, buffer)
		instantiation_template = instantiation_template .. "." .. decl_name .. "(), "
	end
	if #ports > 0 then
		instantiation_template = string.sub(instantiation_template, 1, -3)
	end
	instantiation_template = instantiation_template .. ");"
	return instantiation_template
end

return M
