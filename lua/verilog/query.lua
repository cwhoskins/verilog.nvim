local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local Util = require("verilog.util")

function M.get_port_declaration_at_cursor()
	local cursor_port = ts.get_node_at_cursor()
	cursor_port = ts.search_parents_for_type(cursor_port, "named_port_connection")
	return cursor_port
end

function M.get_declaration_from_name(name)
	local node = ts.get_node_at_cursor()
	local module = ts.search_parents_for_type(node, "module_declaration")
	local declarations = ts.filter_children(module, function(val)
		local search_table = {
			"name_of_instance",
			"ansi_port_declaration",
			"variable_decl_assignment",
			"net_decl_assignment",
			"list_of_port_identifiers",
			"list_of_variable_identifiers",
			"list_of_variable_port_identifiers",
			"list_of_interface_identifiers",
		}
		return Util.is_member(search_table, val:type())
	end)
	for i, declaration in ipairs(declarations) do
		if declaration:type() == "ansi_port_declaration" then
			if TS.get_node_text(declaration:named_child(1), 0) == name then
				return declaration
			end
		elseif declaration:type() == "variable_decl_assignment" then
			if TS.get_node_text(declaration:named_child(0), 0) == name then
				return declaration:parent():parent()
			end
		elseif declaration:type() == "name_of_instance" then
			if TS.get_node_text(declaration:named_child(0), 0) == name then
				return declaration:parent():parent()
			end
		elseif declaration:type() == "net_decl_assignment" then
			if TS.get_node_text(declaration:child(0), 0) == name then
				return declaration:parent():parent()
			end
		elseif string.find(declaration:type(), "list_of") then
			for c in declaration:iter_children() do
				if c:type() == "simple_identifier" and name == TS.get_node_text(c, 0) then
					return declaration:parent()
				end
			end
		else
			vim.print(declaration:type(), " unaccounted for")
		end
	end
	return nil
end

function M.get_modules_from_buffer(buffer)
	local nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if #nodes == 0 then
		return nil
	end
	return ts.filter_children(nodes[1], function(val)
		return val:type() == "module_declaration" or val:type() == "interface_declaration"
	end)
end

function M.get_packages_from_buffer(buffer)
	local nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if #nodes == 0 then
		vim.print("Could not find source file in buffer")
		vim.api.nvim_buf_delete(buffer, { force = true })
		return nil
	end
	return ts.filter_children(nodes[1], function(val)
		return val:type() == "package_declaration"
	end)
end

function M.get_parameters_from_buffer(buffer)
	local nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if nodes == nil or #nodes == 0 then
		vim.print("Could not find source file in buffer: ", buffer)
		return nil
	end
	local modules = ts.filter_children(nodes[1], function(val)
		return val:type() == "module_declaration" or val:type() == "interface_declaration"
	end)
	if #modules == 0 then
		vim.print("Could not find module in buffer: ", buffer)
		return nil
	end
	return ts.filter_children(modules[1], function(val)
		return val:type() == "parameter_declaration"
	end)
end

function M.get_ports_from_buffer(buffer)
	local nodes = ts.get_query_nodes(buffer, "((source_file) @file)")
	if nodes == nil or #nodes == 0 then
		vim.print("Could not find source file in buffer: ", buffer)
		return nil
	end
	local modules = ts.filter_children(nodes[1], function(val)
		return val:type() == "module_declaration" or val:type() == "interface_declaration"
	end)
	if #modules == 0 then
		vim.print("Could not find module in buffer: ", buffer)
		return nil
	end
	return ts.filter_children(modules[1], function(val)
		return val:type() == "port_declaration" or val:type() == "ansi_port_declaration"
	end)
end

function M.get_port_breakdown(port, buffer)
	buffer = buffer or 0
	if port == nil then
		return nil
	end
	local direction
	local port_type
	local name
	if port:type() == "ansi_port_declaration" then
		local subport = port:named_child(0)
		name = TS.get_node_text(port:named_child(1), buffer)
		if subport:type() == "net_port_header" then
			direction = TS.get_node_text(subport:named_child(0), buffer)
			if subport:named_child_count() == 2 then
				port_type = TS.get_node_text(subport:named_child(1), buffer)
			else
				port_type = "wire"
			end
		elseif subport:type() == "interface_port_header" then
			port_type = TS.get_node_text(subport:named_child(0), buffer)
			direction = TS.get_node_text(subport:named_child(1), buffer)
		elseif subport:type() == "variable_port_header" then
			direction = TS.get_node_text(subport:named_child(0), buffer)
			port_type = TS.get_node_text(subport:named_child(1), buffer)
		else
			vim.print("Invalid ANSI port " .. subport:type())
			return nil
		end
	elseif port:type() == "port_declaration" then
		local subport = port:named_child(0)
		if subport:type() == "output_declaration" or subport:type() == "input_declaration" or subport:type() == "inout_declaration" then
			if subport:type() == "output_declaration" then
				direction = "output"
			elseif subport:type() == "inout_declaration" then
				direction = "inout"
			else
				direction = "input"
			end
			local nptype = ts.search_children_for_type(port, "net_port_type")
			if nptype ~= nil then
				port_type = TS.get_node_text(nptype, buffer)
			end
			local vptype = ts.search_children_for_type(port, "variable_port_type")
			if vptype ~= nil then
				port_type = TS.get_node_text(vptype, buffer)
			end
			-- Implicit type on a non-ANSI port (e.g. `input clk;`) defaults to wire
			port_type = port_type or "wire"
			local names = ts.filter_children(port, function(val)
				return val:type() == "list_of_variable_port_identifiers"
					or val:type() == "list_of_port_identifiers"
					or val:type() == "list_of_variable_identifiers"
			end)
			name = TS.get_node_text(names[1]:named_child(0), buffer)
		elseif subport:type() == "interface_port_declaration" then
			port_type = TS.get_node_text(subport:named_child(0), buffer)
			direction = TS.get_node_text(subport:named_child(1), buffer)
			local names = ts.filter_children(port, function(val)
				return val:type() == "list_of_interface_identifiers"
			end)
			name = TS.get_node_text(names[1]:named_child(0), buffer)
		end
	else
		vim.print("Invalid port type")
		return nil
	end
	-- Replace wire/reg with logic for easier compatibility checking
	if string.sub(port_type, 1, 4) == "wire" then
		port_type = "logic" .. string.sub(port_type, 5)
	elseif string.sub(port_type, 1, 3) == "reg" then
		port_type = "logic" .. string.sub(port_type, 4)
	end
	return direction, port_type, name
end

return M
