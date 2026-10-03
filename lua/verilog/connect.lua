local M = {}

local TS = vim.treesitter
local Util = require("verilog.util")
local ts = require("verilog.ts")
local file = require("verilog.file")
local query = require("verilog.query")
local template = require("verilog.template")
local module_ops = require("verilog.module")
local connectparam = require("verilog.connectparam")

local function connect_port(named_port_connection, net_name)
	if named_port_connection:type() ~= "named_port_connection" or named_port_connection:has_error() then
		vim.print("Input Argument must be a TS node with a type of named_port_connection without errors")
		return
	end
	if named_port_connection:named_child_count() == 2 then
		local sr, sc, er, ec = TS.get_node_range(named_port_connection:named_child(1), 0)
		vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { net_name })
	else
		local port_name = TS.get_node_text(named_port_connection:named_child(0), 0)
		local port_connection = "." .. port_name .. "(" .. net_name .. ")"
		if string.find(TS.get_node_text(named_port_connection, 0), ",") then
			port_connection = port_connection .. ","
		end
		local sr, sc, er, ec = TS.get_node_range(named_port_connection, 0)
		vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { port_connection })
	end
end

local function gather_potential_ports(module, buffer, ft, fn, port_name, cur_module_name)
	local potential_ports = {}
	local all_modules = ts.filter_children(module, function(val)
		return val:type() == "module_instantiation"
	end)
	for _, m in ipairs(all_modules) do
		local module_type = TS.get_node_text(m:named_child(0), 0)
		local module_name = TS.get_node_text(ts.search_children_for_type(m, "hierarchical_instance"):named_child(0), 0)
		local curbuf = file.read_file_into_new_buffer(module_type, false)
		if curbuf == nil then
			-- Could not find the source file to confirm type, automatically add all ports
			for _, p in ipairs(ts.filter_children(m, function(val) return val:type() == "named_port_connection" end)) do
				table.insert(potential_ports, { p, module_type, module_name, TS.get_node_text(p:named_child(0), 0) })
			end
		else
			-- Filter out ports with a different type
			for _, p in ipairs(query.get_ports_from_buffer(curbuf)) do
				local _, pt, pn = query.get_port_breakdown(p, curbuf)
				if ft == pt then
					for _, np in ipairs(ts.filter_children(m, function(val) return val:type() == "named_port_connection" end)) do
						if TS.get_node_text(np:named_child(0), 0) == pn then
							table.insert(potential_ports, { np, module_type, module_name, TS.get_node_text(np:named_child(0), 0) })
						end
					end
				end
			end
			vim.api.nvim_buf_delete(curbuf, { force = true })
		end
	end
	-- Add same-type ports from the current module
	for _, p in ipairs(query.get_ports_from_buffer(0)) do
		local _, pt, pn = query.get_port_breakdown(p, 0)
		if ft == pt then
			table.insert(potential_ports, { nil, cur_module_name, "current module", pn })
		end
	end
	-- Option to break out the port
	table.insert(potential_ports, { nil, cur_module_name, "Breakout Port", fn })
	return potential_ports
end

function M.connect_ports()
	-- Wires together two modules with some intelligence (i.e. filtering out ports that are the wrong type)
	local source_port = query.get_port_declaration_at_cursor()
	local port_name = TS.get_node_text(source_port:named_child(0), 0)
	local module = ts.search_parents_for_type(source_port, "module_declaration")
	local module_key = ts.search_children_for_type(module, "module_keyword")
	local cur_module_name = TS.get_node_text(module_key:next_named_sibling(), 0)
	local source_inst = ts.search_parents_for_type(source_port, "module_instantiation")
	local ssr = TS.get_node_range(source_inst, 0)
	local buffer = file.read_file_into_new_buffer(TS.get_node_text(source_inst:named_child(0), 0))
	if buffer == nil then
		vim.print("Could not find module definition")
		return
	end

	local fd, ft, fn
	local is_interface = true
	for _, port in ipairs(query.get_ports_from_buffer(buffer)) do
		local _, _, cn = query.get_port_breakdown(port, buffer)
		if cn == port_name then
			fd, ft, fn = query.get_port_breakdown(port, buffer)
			if fd == "input" or fd == "output" or fd == "inout" then
				is_interface = false
			end
			break
		end
	end

	if ft == nil then
		-- Source port not found in target module
		vim.api.nvim_buf_delete(buffer, { force = true })
		return
	end

	local potential_ports = gather_potential_ports(module, buffer, ft, fn, port_name, cur_module_name)

	local function port_cb(val)
		if val[1] ~= nil then
			-- Internal connection to another module
			local valconn = val[1]:named_child(1)
			local net_name
			local declare = false
			local declaration_row
			local declaration
			if source_port:named_child(1) ~= nil then
				net_name = TS.get_node_text(source_port:named_child(1), 0)
			elseif valconn ~= nil then
				net_name = TS.get_node_text(valconn, 0)
			else
				vim.ui.input({ prompt = "Enter net name: " }, function(input) net_name = tostring(input) end)
				local target_instantiation = ts.search_parents_for_type(val[1], "module_instantiation")
				local tsr = TS.get_node_range(target_instantiation, 0)
				-- Declare directly above whichever instantiation comes first.
				declaration_row = math.min(ssr, tsr)
				if is_interface then
					local intf_buffer = file.read_file_into_new_buffer(ft, false)
					local modules = query.get_modules_from_buffer(intf_buffer)
					declaration = template.generate_module_instantiation(modules[1], intf_buffer, net_name)
					vim.api.nvim_buf_delete(intf_buffer, { force = true })
				else
					declaration = ft .. " " .. net_name .. ";"
				end
				declare = true
			end
			connect_port(val[1], net_name)
			connect_port(source_port, net_name)
			if declare then
				vim.api.nvim_buf_set_lines(0, declaration_row, declaration_row, false, { declaration })
			end
		else
			-- Port Connection
			local port_type = fd .. " " .. ft
			if is_interface then
				port_type = ft .. "." .. fd
			end
			connect_port(source_port, val[4])
			module_ops.add_port(port_type, val[4])
		end
	end

	Util.telescope_ports(potential_ports, port_cb)
	vim.api.nvim_buf_delete(buffer, { force = true })
end

-- Unified connect entry point. Routes by cursor context:
--   on a named_parameter_assignment → connect that specific parameter
--   on a named_port_connection      → connect_ports flow
--   inside a module_instantiation   → connect_params (full picker flow)
function M.connect()
	local node = ts.get_node_at_cursor()
	if node == nil then
		vim.print("No node at cursor")
		return
	end

	local npa = ts.search_parents_for_type(node, "named_parameter_assignment")
	if npa then
		connectparam.connect_specific_param(npa)
		return
	end

	local npc = ts.search_parents_for_type(node, "named_port_connection")
	if npc then
		M.connect_ports()
		return
	end

	if ts.search_parents_for_type(node, "module_instantiation") then
		connectparam.connect_params()
		return
	end

	vim.print("Cursor is not on a port connection, parameter assignment, or module instantiation")
end

return M
