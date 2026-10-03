local connect = require("verilog.connect")
local Util = require("verilog.util")

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	.. "/fixtures"

-- Queue-based mocks so a single test can prescribe multi-step UI flows.
local telescope_queue = {}
local input_queue = {}

local original_telescope_ports = Util.telescope_ports
Util.telescope_ports = function(entries, cb, _opts)
	local responder = table.remove(telescope_queue, 1)
	if responder == nil then
		error("telescope queue empty — test forgot to enqueue a response")
	end
	cb(responder(entries))
end

local original_input = vim.ui.input
vim.ui.input = function(_opts, on_choice)
	local val = table.remove(input_queue, 1)
	on_choice(val)
end

-- connect_ports entries are { npc, module_type, instance_name, port_name }.
local function pick_port(instance_name, port_name)
	return function(entries)
		for _, e in ipairs(entries) do
			if e[3] == instance_name and e[4] == port_name then
				return e
			end
		end
		error("no entry matching '" .. instance_name .. " | " .. port_name .. "'")
	end
end

local function reset_queues()
	telescope_queue = {}
	input_queue = {}
end

local function run_in_buffer(lines, cursor, fn)
	local saved_cwd = vim.fn.getcwd()
	vim.api.nvim_set_current_dir(fixture_dir)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].filetype = "verilog"
	vim.treesitter.start(buf, "verilog")
	vim.treesitter.get_parser(buf, "verilog"):parse()
	vim.api.nvim_win_set_cursor(0, cursor)

	local ok, err = pcall(fn, buf)

	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	vim.api.nvim_set_current_dir(saved_cwd)
	reset_queues()

	if not ok then
		error(err)
	end
end

local function buf_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local TWO_INSTANCES = {
	"module top (input clk);",
	"    simple u_a (",
	"        .clk(clk),",
	"        .rst_n(),",
	"        .data_in(),",
	"        .data_out()",
	"    );",
	"    simple u_b (",
	"        .clk(clk),",
	"        .rst_n(),",
	"        .data_in(),",
	"        .data_out()",
	"    );",
	"endmodule",
}

describe("connect.connect_ports", function()
	it("declares a new net directly above the source instantiation", function()
		table.insert(telescope_queue, pick_port("u_b", "data_in"))
		table.insert(input_queue, "a_to_b")
		run_in_buffer(TWO_INSTANCES, { 6, 10 }, function(buf)
			connect.connect()
			local lines = buf_lines(buf)
			local text = table.concat(lines, "\n")
			-- The declaration must sit between the module header and the first
			-- instantiation, not above the `module` line.
			assert.equals("module top (input clk);", lines[1], text)
			assert.matches("^%s*logic %[7:0%] a_to_b;$", lines[2], text)
			assert.matches("%.data_out%(a_to_b%)", text)
			assert.matches("%.data_in%(a_to_b%)", text)
		end)
	end)

	it("declares a new net directly above the target when the target comes first", function()
		table.insert(telescope_queue, pick_port("u_a", "data_out"))
		table.insert(input_queue, "a_to_b")
		run_in_buffer(TWO_INSTANCES, { 11, 10 }, function(buf)
			connect.connect()
			local lines = buf_lines(buf)
			local text = table.concat(lines, "\n")
			assert.equals("module top (input clk);", lines[1], text)
			assert.matches("^%s*logic %[7:0%] a_to_b;$", lines[2], text)
			assert.matches("%.data_out%(a_to_b%)", text)
			assert.matches("%.data_in%(a_to_b%)", text)
		end)
	end)

	it("connects single-line instantiations", function()
		-- :AutoInst emits each instantiation on one line.
		table.insert(telescope_queue, pick_port("u_b", "data_in"))
		table.insert(input_queue, "a_to_b")
		run_in_buffer({
			"module top (input clk);",
			"    simple u_a (.clk(clk), .rst_n(), .data_in(), .data_out());",
			"    simple u_b (.clk(clk), .rst_n(), .data_in(), .data_out());",
			"endmodule",
		}, { 2, 50 }, function(buf)
			connect.connect()
			local lines = buf_lines(buf)
			local text = table.concat(lines, "\n")
			assert.equals("module top (input clk);", lines[1], text)
			assert.matches("^%s*logic %[7:0%] a_to_b;$", lines[2], text)
			assert.matches("%.data_out%(a_to_b%)", lines[3])
			assert.matches("%.data_in%(a_to_b%)", lines[4])
		end)
	end)
end)

-- Restore globals when this spec module unloads (in case tests are reloaded).
-- Plenary spawns a fresh nvim per file so this is mainly defensive.
return {
	cleanup = function()
		Util.telescope_ports = original_telescope_ports
		vim.ui.input = original_input
	end,
}
