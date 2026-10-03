local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local query = require("verilog.query")

function M.add_port(port_type, port_name)
	local porta = query.get_port_declaration_at_cursor()
	local module = ts.search_parents_for_type(porta, "module_declaration")
	local current_ports = query.get_ports_from_buffer(0)
	for _, p in ipairs(current_ports) do
		local _, _, decl_name = query.get_port_breakdown(p, 0)
		if decl_name == port_name then
			return
		end
	end
	local port_list = ts.search_children_for_type(module, "list_of_ports")
	if port_list ~= nil then
		-- Non-ANSI declaration
		local port = port_list:child(port_list:child_count() - 2)
		local sr, _, er, _ = TS.get_node_range(port, 0)
		local lines = vim.api.nvim_buf_get_lines(0, sr, er + 1, false)
		lines[#lines] = lines[#lines] .. ","
		table.insert(lines, port_name)
		vim.api.nvim_buf_set_lines(0, sr, er + 1, true, lines)
		local declarations = ts.filter_children(module, function(val)
			return val:type() == "port_declaration"
		end)
		local _, _, der, _ = TS.get_node_range(declarations[#declarations], 0)
		vim.api.nvim_buf_set_lines(0, der + 2, der + 2, true, { port_type .. " " .. port_name .. ";" })
	end
	port_list = ts.search_children_for_type(module, "list_of_port_declarations")
	if port_list ~= nil then
		-- ANSI port declarations
		local port = port_list:child(port_list:child_count() - 2)
		local sr, _, er, _ = TS.get_node_range(port, 0)
		local lines = vim.api.nvim_buf_get_lines(0, sr, er + 1, false)
		lines[#lines] = lines[#lines] .. ","
		table.insert(lines, port_type .. " " .. port_name)
		vim.api.nvim_buf_set_lines(0, sr, er + 1, true, lines)
	end
end

function M.add_localparam(param_type, param_name, default_value)
	local node = ts.get_node_at_cursor()
	local module = ts.search_parents_for_type(node, "module_declaration")
	local header = ts.filter_children(module, function(val)
		return val:type() == "module_ansi_header" or val:type() == "module_nonansi_header"
	end)
	local _, _, er, _ = TS.get_node_range(header[1], 0)
	local decl = "localparam " .. param_type .. " " .. param_name .. " = " .. default_value .. ";"
	vim.api.nvim_buf_set_lines(0, er, er, true, { decl })
end

function M.import_package(name)
	local node = ts.get_node_at_cursor()
	local module = ts.search_parents_for_type(node, "module_declaration")
	if module ~= nil then
		module = module:child(0)
		local packages = ts.filter_children(module, function(val)
			return val:type() == "package_import_item"
		end)
		for i, p in ipairs(packages) do
			if name == TS.get_node_text(p:child(0), 0) then
				return
			elseif i == #packages then
				local _, _, er, ec = TS.get_node_range(p, 0)
				vim.api.nvim_buf_set_text(0, er, ec, er, ec, { ", " .. name .. "::*" })
				return
			end
		end
		local _, _, er, ec = TS.get_node_range(module:named_child(1), 0)
		vim.api.nvim_buf_set_text(0, er, ec, er, ec, { " import " .. name .. "::*;" })
		return
	end
	local pkg = ts.search_parents_for_type(node, "package_declaration")
	if pkg ~= nil then
		local packages = ts.filter_children(pkg, function(val)
			return val:type() == "package_import_item"
		end)
		for _, p in ipairs(packages) do
			if name == TS.get_node_text(p:child(0), 0) then
				return
			end
		end
		local _, _, er, _ = TS.get_node_range(pkg, 0)
		vim.api.nvim_buf_set_lines(0, er, er, true, { "import " .. name .. "::*;" })
		return
	end
	vim.print("Could not import package")
end

return M
