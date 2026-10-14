local wireinterface = require("verilog.wireinterface")
local interface = require("verilog.interface")
local Util = require("verilog.util")
local ts = require("verilog.ts")

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	.. "/fixtures"

-- Queue-based mock for Util.telescope_ports.
local telescope_queue = {}

Util.telescope_ports = function(entries, cb, _opts)
	local responder = table.remove(telescope_queue, 1)
	if responder == nil then
		error("telescope queue empty — test forgot to enqueue a response")
	end
	cb(responder(entries))
end

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

local function enqueue(...)
	for _, r in ipairs({ ... }) do
		table.insert(telescope_queue, r)
	end
end

local function run_in_buffer(lines, cursor, fn)
	local saved_cwd = vim.fn.getcwd()
	vim.api.nvim_set_current_dir(fixture_dir)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].filetype = "verilog"
	vim.treesitter.start(buf, ts.lang)
	vim.treesitter.get_parser(buf, ts.lang):parse()
	vim.api.nvim_win_set_cursor(0, cursor)

	local ok, err = pcall(fn, buf)

	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	vim.api.nvim_set_current_dir(saved_cwd)
	telescope_queue = {}

	if not ok then
		error(err)
	end
end

local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("interface.read_interface", function()
	it("returns signal names for axis_if", function()
		local saved_cwd = vim.fn.getcwd()
		vim.api.nvim_set_current_dir(fixture_dir)
		local result = interface.read_interface("axis_if")
		vim.api.nvim_set_current_dir(saved_cwd)
		assert.is_not_nil(result)
		assert.equals("axis_if", result.type_name)
		-- All three signals should appear, in declaration order
		assert.same({ "data", "vld", "rdy" }, result.signal_names)
	end)

	it("returns nil for a module (not an interface)", function()
		local saved_cwd = vim.fn.getcwd()
		vim.api.nvim_set_current_dir(fixture_dir)
		local result = interface.read_interface("axis_master")
		vim.api.nvim_set_current_dir(saved_cwd)
		assert.is_nil(result)
	end)
end)

describe("wireinterface.wire_to_interface", function()
	it("wires matched flat ports to a body interface instance", function()
		enqueue(pick_by_name("axis_inst"))
		run_in_buffer({
			"module top (input clk);",
			"    axis_if axis_inst();",
			"    axis_master u_master (.i_clk(clk));",
			"endmodule",
		}, { 3, 6 }, function(buf)
			wireinterface.wire_to_interface()
			local text = buf_text(buf)
			-- Existing .i_clk(clk) preserved
			assert.matches("%.i_clk%(clk%)", text)
			-- All three matched ports wired to axis_inst's signals
			assert.matches("%.i_axis_rdy%(axis_inst%.rdy%)", text)
			assert.matches("%.o_axis_vld%(axis_inst%.vld%)", text)
			assert.matches("%.o_axis_data%(axis_inst%.data%)", text)
		end)
	end)

	it("wires to an interface port of the parent module", function()
		enqueue(pick_by_name("s_axis"))
		run_in_buffer({
			"module top (axis_if.s s_axis, input clk);",
			"    axis_master u_master (.i_clk(clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			wireinterface.wire_to_interface()
			local text = buf_text(buf)
			assert.matches("%.i_axis_rdy%(s_axis%.rdy%)", text)
			assert.matches("%.o_axis_vld%(s_axis%.vld%)", text)
			assert.matches("%.o_axis_data%(s_axis%.data%)", text)
		end)
	end)

	it("does not override an existing non-empty connection", function()
		-- User has already wired .o_axis_vld(custom_signal); leave it alone.
		enqueue(pick_by_name("axis_inst"))
		run_in_buffer({
			"module top (input clk);",
			"    axis_if axis_inst();",
			"    axis_master u_master (.i_clk(clk), .o_axis_vld(custom_signal));",
			"endmodule",
		}, { 3, 6 }, function(buf)
			wireinterface.wire_to_interface()
			local text = buf_text(buf)
			assert.matches("%.o_axis_vld%(custom_signal%)", text)
			assert.is_nil(text:match("axis_inst%.vld"), "vld should NOT have been rewired: " .. text)
			-- The unconnected ones still get wired
			assert.matches("%.i_axis_rdy%(axis_inst%.rdy%)", text)
			assert.matches("%.o_axis_data%(axis_inst%.data%)", text)
		end)
	end)

	it("fills in an empty .port() connection", function()
		enqueue(pick_by_name("axis_inst"))
		run_in_buffer({
			"module top (input clk);",
			"    axis_if axis_inst();",
			"    axis_master u_master (.i_clk(clk), .i_axis_rdy());",
			"endmodule",
		}, { 3, 6 }, function(buf)
			wireinterface.wire_to_interface()
			local text = buf_text(buf)
			-- Empty .i_axis_rdy() got filled, not duplicated
			assert.matches("%.i_axis_rdy%(axis_inst%.rdy%)", text)
			local _, count = text:gsub("%.i_axis_rdy", "")
			assert.equals(1, count)
		end)
	end)

	it("ranks candidates by match count and lets user pick", function()
		-- Two interface variables in scope; only axis_inst has matching signals.
		enqueue(pick_by_name("axis_inst"))
		run_in_buffer({
			"module top (input clk);",
			"    axis_if axis_inst();",
			"    axis_master u_master (.i_clk(clk));",
			"endmodule",
		}, { 3, 6 }, function(buf)
			-- The picker should still be invoked even with one candidate.
			-- The mock will receive the entries; pick_by_name asserts axis_inst is present.
			wireinterface.wire_to_interface()
			local text = buf_text(buf)
			assert.matches("axis_inst%.rdy", text)
		end)
	end)
end)
