local wildcard = require("verilog.wildcard")

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	.. "/fixtures"

local function run_in_buffer(lines, fn)
	local saved_cwd = vim.fn.getcwd()
	vim.api.nvim_set_current_dir(fixture_dir)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].filetype = "verilog"
	vim.treesitter.start(buf, "verilog")
	vim.treesitter.get_parser(buf, "verilog"):parse()

	local ok, err = pcall(fn, buf)

	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	vim.api.nvim_set_current_dir(saved_cwd)

	if not ok then
		error(err)
	end
end

local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function count(haystack, needle)
	local _, n = haystack:gsub(needle, "")
	return n
end

describe("wildcard.expand_file", function()
	it("expands a sole .* to all source ports, same-name connections", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_a (.*);",
			"endmodule",
		}, function(buf)
			assert.equals(1, wildcard.expand_file(buf))
			local text = buf_text(buf)
			for _, p in ipairs({ "clk", "rst_n", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%(" .. p .. "%)", text)
			end
			assert.is_nil(text:match("%.%*"), "wildcard token should be gone: " .. text)
		end)
	end)

	it("preserves explicit overrides and only expands the missing ports", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_b (.clk(my_clk), .*);",
			"endmodule",
		}, function(buf)
			assert.equals(1, wildcard.expand_file(buf))
			local text = buf_text(buf)
			assert.matches("%.clk%(my_clk%)", text)
			-- override is preserved exactly once (no duplicate from expansion)
			assert.equals(1, count(text, "%.clk%("))
			-- the rest of the ports are present, connected to same-name nets
			for _, p in ipairs({ "rst_n", "data_in", "data_out" }) do
				assert.matches("%." .. p .. "%(" .. p .. "%)", text)
			end
		end)
	end)

	it("leaves an instantiation without .* unchanged", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_c (.clk(my_clk));",
			"endmodule",
		}, function(buf)
			local before = buf_text(buf)
			assert.equals(0, wildcard.expand_file(buf))
			assert.equals(before, buf_text(buf))
		end)
	end)

	it("processes multiple instantiations independently in one buffer", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_a (.*);",
			"    simple u_b (.clk(my_clk), .*);",
			"endmodule",
		}, function(buf)
			assert.equals(2, wildcard.expand_file(buf))
			local text = buf_text(buf)
			-- Each instantiation got its own clk: one wildcard-expanded, one explicit override
			assert.equals(2, count(text, "%.clk%("))
			-- Non-clk ports show up once per instantiation
			assert.equals(2, count(text, "%.data_in%("))
			assert.is_nil(text:match("%.%*"), "no wildcards should remain: " .. text)
		end)
	end)

	it("skips an instantiation whose source file cannot be found", function()
		run_in_buffer({
			"module parent (input clk);",
			"    nonexistent_module u_x (.*);",
			"endmodule",
		}, function(buf)
			local before = buf_text(buf)
			assert.equals(0, wildcard.expand_file(buf))
			assert.equals(before, buf_text(buf))
		end)
	end)

	it("removes a redundant .* when every port is already explicit", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_d (.clk(c), .rst_n(r), .data_in(di), .data_out(d_o), .*);",
			"endmodule",
		}, function(buf)
			assert.equals(1, wildcard.expand_file(buf))
			local text = buf_text(buf)
			assert.is_nil(text:match("%.%*"), "redundant wildcard should be removed: " .. text)
			-- The four explicit connections survive
			assert.matches("%.clk%(c%)", text)
			assert.matches("%.rst_n%(r%)", text)
			assert.matches("%.data_in%(di%)", text)
			assert.matches("%.data_out%(d_o%)", text)
			-- And no dangling comma sequence
			assert.is_nil(text:match(",%s*%)"), "no dangling comma before close paren: " .. text)
		end)
	end)
end)
