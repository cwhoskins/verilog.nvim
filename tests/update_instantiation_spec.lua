local instantiate = require("verilog.instantiate")
local ts = require("verilog.ts")

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	.. "/fixtures"

-- Default responder for vim.ui.select: pick the "[delete]" option (or cancel
-- if no such option exists). Tests can override `select_responder` to drive
-- the rename UI deterministically.
local select_responder = function(items, on_choice)
	for _, item in ipairs(items) do
		if type(item) == "table" and item.action == "delete" then
			on_choice(item)
			return
		end
	end
	on_choice(nil)
end

local original_ui_select = vim.ui.select
vim.ui.select = function(items, _opts, on_choice)
	select_responder(items, on_choice)
end

local function run_in_buffer(lines, cursor, fn)
	local saved_cwd = vim.fn.getcwd()
	vim.api.nvim_set_current_dir(fixture_dir)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].filetype = "verilog"
	vim.treesitter.start(buf, ts.lang)
	-- Force a synchronous parse; on fresh scratch buffers the parser is otherwise
	-- not ready when the cursor lookup first asks for it.
	vim.treesitter.get_parser(buf, ts.lang):parse()
	vim.api.nvim_win_set_cursor(0, cursor)

	local ok, err = pcall(fn, buf)

	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	vim.api.nvim_set_current_dir(saved_cwd)

	if not ok then
		error(err)
	end
end

-- Set the vim.ui.select responder for the next test. The responder receives
-- the items list and the on_choice callback, and is responsible for calling
-- on_choice with one of the items (or nil to cancel).
local function with_select_responder(responder, fn)
	local saved = select_responder
	select_responder = responder
	local ok, err = pcall(fn)
	select_responder = saved
	if not ok then
		error(err)
	end
end

local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("update_instantiation_at_cursor", function()
	it("populates an empty instantiation with all source ports", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple ();",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			for _, p in ipairs({ "clk", "rst_n", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%s*%(", text)
			end
		end)
	end)

	it("populates parameters and ports for a parameterized module", function()
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized u_param ();",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.matches("%.WIDTH%(8%)", text)
			assert.matches("%.DEPTH%(16%)", text)
			for _, p in ipairs({ "clk", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%s*%(", text)
			end
		end)
	end)

	it("preserves an existing port connection", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(parent_clk));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.matches("%.clk%s*%(parent_clk%)", text)
			for _, p in ipairs({ "rst_n", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%s*%(", text)
			end
		end)
	end)

	it("removes a port that no longer exists in the source", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(parent_clk), .fake_port(garbage));",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.is_nil(text:match("fake_port"), "fake_port should be removed: " .. text)
			assert.is_nil(text:match("garbage"), "garbage net should be removed: " .. text)
			assert.matches("%.clk%s*%(parent_clk%)", text)
			for _, p in ipairs({ "rst_n", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%s*%(", text)
			end
		end)
	end)

	it("removes a parameter that no longer exists in the source", function()
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized #(.fake_param(99)) u_param ();",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.is_nil(text:match("fake_param"), "fake_param should be removed: " .. text)
			assert.matches("%.WIDTH%(8%)", text)
			assert.matches("%.DEPTH%(16%)", text)
		end)
	end)

	it("preserves a comment line between existing port connections", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (",
			"        .clk(my_clk),",
			"        // a critical timing comment",
			"        .rst_n(my_rst),",
			"        .data_in(my_data),",
			"        .data_out(my_out)",
			"    );",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.matches("// a critical timing comment", text)
			-- All existing connections should still be present
			assert.matches("%.clk%s*%(my_clk%)", text)
			assert.matches("%.rst_n%s*%(my_rst%)", text)
			assert.matches("%.data_in%s*%(my_data%)", text)
			assert.matches("%.data_out%s*%(my_out%)", text)
		end)
	end)

	it("preserves a trailing comment after an untouched instantiation", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(my_clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));",
			"    // post-instantiation note that must stay",
			"endmodule",
		}, { 2, 6 }, function(buf)
			instantiate.update_instantiation_at_cursor()
			local text = buf_text(buf)
			assert.matches("// post%-instantiation note that must stay", text)
			assert.matches("%.clk%s*%(my_clk%)", text)
		end)
	end)

	it("renames a stale port to a missing one when the user pairs them", function()
		-- The user pairs the stale .old_clk with the missing .clk; the connection
		-- value (parent_clk) must be preserved on the renamed port.
		local responder = function(items, on_choice)
			for _, item in ipairs(items) do
				if item.action == "rename" and item.target.name == "clk" then
					on_choice(item)
					return
				end
			end
			on_choice(nil)
		end
		with_select_responder(responder, function()
			run_in_buffer({
				"module parent (input clk);",
				"    simple u_simple (.old_clk(parent_clk));",
				"endmodule",
			}, { 2, 6 }, function(buf)
				instantiate.update_instantiation_at_cursor()
				local text = buf_text(buf)
				assert.matches("%.clk%s*%(parent_clk%)", text)
				assert.is_nil(text:match("old_clk"), "old_clk should be renamed away: " .. text)
				for _, p in ipairs({ "rst_n", "data_in", "data_out" }) do
					assert.matches("%." .. p .. "%s*%(", text)
				end
			end)
		end)
	end)

	it("leaves the buffer unchanged when the source file is missing", function()
		run_in_buffer({
			"module parent (input clk);",
			"    nonexistent_module u_thing ();",
			"endmodule",
		}, { 2, 6 }, function(buf)
			local before = buf_text(buf)
			instantiate.update_instantiation_at_cursor()
			local after = buf_text(buf)
			assert.equals(before, after)
		end)
	end)
end)
