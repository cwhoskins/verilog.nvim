local connectparam = require("verilog.connectparam")
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

-- Helpers to enqueue picker responses.
local function pick_by_name(name)
	return function(entries)
		for _, e in ipairs(entries) do
			if e[1] == name then
				return e
			end
		end
		error("no entry matching '" .. name .. "'")
	end
end

local function enqueue_telescope(...)
	for _, r in ipairs({ ... }) do
		table.insert(telescope_queue, r)
	end
end

local function enqueue_input(...)
	for _, v in ipairs({ ... }) do
		table.insert(input_queue, v)
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

local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("connectparam.connect_params", function()
	it("wires source param to an existing parent parameter", function()
		enqueue_telescope(pick_by_name("WIDTH"), pick_by_name("OUTER_WIDTH"))
		run_in_buffer({
			"module parent #(parameter int OUTER_WIDTH = 16) (input clk);",
			"    parameterized u_p (.clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			connectparam.connect_params()
			local text = buf_text(buf)
			assert.matches("parameterized %#%(%.WIDTH%(OUTER_WIDTH%)%) u_p", text)
		end)
	end)

	it("replaces an existing override value", function()
		enqueue_telescope(pick_by_name("WIDTH"), pick_by_name("OUTER_WIDTH"))
		run_in_buffer({
			"module parent #(parameter int OUTER_WIDTH = 32) (input clk);",
			"    parameterized #(.WIDTH(8)) u_p (.clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			connectparam.connect_params()
			local text = buf_text(buf)
			assert.matches("%.WIDTH%(OUTER_WIDTH%)", text)
			assert.is_nil(text:match("%.WIDTH%(8%)"), "old value should be gone")
		end)
	end)

	it("creates a new parent parameter and wires the override", function()
		enqueue_telescope(pick_by_name("WIDTH"), pick_by_name("[new parameter]"))
		enqueue_input("OUTER_WIDTH")
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized u_p (.clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			connectparam.connect_params()
			local text = buf_text(buf)
			-- parent module gained a parameter
			assert.matches("module parent %#%(parameter int OUTER_WIDTH = 8%)", text)
			-- instantiation wires the new parameter
			assert.matches("%.WIDTH%(OUTER_WIDTH%)", text)
		end)
	end)

	it("appends to an existing parameter port list", function()
		enqueue_telescope(pick_by_name("DEPTH"), pick_by_name("[new parameter]"))
		enqueue_input("DEEP_PARAM")
		run_in_buffer({
			"module parent #(parameter int OUTER_W = 16) (input clk);",
			"    parameterized u_p (.clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			connectparam.connect_params()
			local text = buf_text(buf)
			-- new parameter appended after the existing one
			assert.matches("OUTER_W = 16, parameter int DEEP_PARAM = 16", text)
			assert.matches("%.DEPTH%(DEEP_PARAM%)", text)
		end)
	end)

	it("dispatches via :Connect when cursor is on a specific named_parameter_assignment", function()
		-- Cursor inside `.WIDTH(8)` — the dispatcher should skip Picker A
		-- and only ask Picker B for where to wire. Only one telescope response
		-- needed; if we incorrectly ran the full flow, the test would error
		-- on an empty queue.
		enqueue_telescope(pick_by_name("OUTER_WIDTH"))
		run_in_buffer({
			"module parent #(parameter int OUTER_WIDTH = 16) (input clk);",
			"    parameterized #(.WIDTH(8)) u_p (.clk(clk));",
			"endmodule",
		}, { 2, 22 }, function(buf)
			connect.connect()
			local text = buf_text(buf)
			assert.matches("%.WIDTH%(OUTER_WIDTH%)", text)
			assert.is_nil(text:match("%.WIDTH%(8%)"))
		end)
	end)

	it("creates a new localparam and wires the override", function()
		enqueue_telescope(pick_by_name("WIDTH"), pick_by_name("[new localparam]"))
		enqueue_input("LOCAL_W")
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized u_p (.clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			connectparam.connect_params()
			local text = buf_text(buf)
			assert.matches("localparam int LOCAL_W = 8;", text)
			assert.matches("%.WIDTH%(LOCAL_W%)", text)
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
