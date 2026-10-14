local autowire = require("verilog.autowire")
local ts = require("verilog.ts")

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	.. "/fixtures"

local function run_in_buffer(lines, fn)
	local saved_cwd = vim.fn.getcwd()
	vim.api.nvim_set_current_dir(fixture_dir)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].filetype = "verilog"
	vim.treesitter.start(buf, ts.lang)
	vim.treesitter.get_parser(buf, ts.lang):parse()
	-- Place cursor inside the parent module so find_target_module finds it.
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

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

describe("autowire.run", function()
	it("declares undeclared nets with the source's type/width", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			assert.equals(3, autowire.run(buf))
			local text = buf_text(buf)
			-- bare logic for clk-style ports
			assert.matches("logic my_rst;", text)
			-- [7:0] for the bus ports
			assert.matches("logic %[7:0%] my_data;", text)
			assert.matches("logic %[7:0%] my_out;", text)
		end)
	end)

	it("does not redeclare a net that's already a port", function()
		run_in_buffer({
			"module parent (input clk, input rst_n);",
			"    simple u_simple (.clk(clk), .rst_n(rst_n), .data_in(my_data), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			assert.equals(2, autowire.run(buf))
			local text = buf_text(buf)
			-- clk and rst_n already declared as ports — must not appear as logic decls
			assert.is_nil(text:match("logic clk;"), "clk should not be redeclared: " .. text)
			assert.is_nil(text:match("logic rst_n;"), "rst_n should not be redeclared: " .. text)
			-- the rest are declared
			assert.matches("logic %[7:0%] my_data;", text)
			assert.matches("logic %[7:0%] my_out;", text)
		end)
	end)

	it("does not redeclare a net that's already a local declaration", function()
		run_in_buffer({
			"module parent (input clk);",
			"    logic [7:0] my_data;",
			"    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			assert.equals(2, autowire.run(buf))
			local text = buf_text(buf)
			-- my_data was already declared, only one declaration of it
			assert.equals(1, count(text, "logic %[7:0%] my_data;"))
			-- my_rst and my_out are new
			assert.matches("logic my_rst;", text)
			assert.matches("logic %[7:0%] my_out;", text)
		end)
	end)

	it("declares each shared net only once across multiple instantiations", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_a (.clk(clk), .rst_n(shared_rst), .data_in(a_in), .data_out(a_out));",
			"    simple u_b (.clk(clk), .rst_n(shared_rst), .data_in(a_out), .data_out(b_out));",
			"endmodule",
		}, function(buf)
			-- a_out is connected to both u_a's output and u_b's input — declared once.
			assert.equals(4, autowire.run(buf))
			local text = buf_text(buf)
			assert.equals(1, count(text, "logic shared_rst;"))
			assert.equals(1, count(text, "logic %[7:0%] a_in;"))
			assert.equals(1, count(text, "logic %[7:0%] a_out;"))
			assert.equals(1, count(text, "logic %[7:0%] b_out;"))
		end)
	end)

	it("skips connections that are not bare identifiers", function()
		run_in_buffer({
			"module parent (input clk);",
			"    logic [15:0] wide_bus;",
			"    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(wide_bus[7:0]), .data_out({a, b}));",
			"endmodule",
		}, function(buf)
			-- Only my_rst is a bare-identifier undeclared net.
			-- The slice and concat connections are skipped (user declares manually).
			assert.equals(1, autowire.run(buf))
			local text = buf_text(buf)
			assert.matches("logic my_rst;", text)
		end)
	end)

	it("skips empty port connections", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(clk), .rst_n(), .data_in(), .data_out());",
			"endmodule",
		}, function(buf)
			assert.equals(0, autowire.run(buf))
		end)
	end)

	it("skips an instantiation whose source file cannot be found", function()
		run_in_buffer({
			"module parent (input clk);",
			"    nonexistent_module u_x (.foo(some_net));",
			"endmodule",
		}, function(buf)
			local before = buf_text(buf)
			assert.equals(0, autowire.run(buf))
			assert.equals(before, buf_text(buf))
		end)
	end)

	it("substitutes source parameter defaults into port widths", function()
		-- parameterized.sv has WIDTH=8 default and ports `logic [WIDTH-1:0]`.
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized u_p (.clk(clk), .data_in(my_in), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			autowire.run(buf)
			local text = buf_text(buf)
			assert.matches("logic %[8%-1:0%] my_in;", text)
			assert.matches("logic %[8%-1:0%] my_out;", text)
		end)
	end)

	it("uses an instantiation parameter override in port widths", function()
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized #(.WIDTH(16)) u_p (.clk(clk), .data_in(my_in), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			autowire.run(buf)
			local text = buf_text(buf)
			assert.matches("logic %[16%-1:0%] my_in;", text)
		end)
	end)

	it("preserves the parameter identifier when parent has a matching parameter", function()
		run_in_buffer({
			"module parent #(parameter int WIDTH = 4) (input clk);",
			"    parameterized #(.WIDTH(WIDTH)) u_p (.clk(clk), .data_in(my_in), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			autowire.run(buf)
			local text = buf_text(buf)
			assert.matches("logic %[WIDTH%-1:0%] my_in;", text)
		end)
	end)

	it("skips a port whose width references an identifier not in scope", function()
		-- Override WIDTH with an identifier that is not declared in the parent.
		-- We should refuse to declare rather than emit a syntactically broken decl.
		run_in_buffer({
			"module parent (input clk);",
			"    parameterized #(.WIDTH(MY_UNDEFINED)) u_p (.data_in(my_in));",
			"endmodule",
		}, function(buf)
			assert.equals(0, autowire.run(buf))
			local text = buf_text(buf)
			assert.is_nil(text:match("my_in;"), "must not emit a decl with unresolved width")
		end)
	end)

	it("inserts declarations just above the first instantiation", function()
		run_in_buffer({
			"module parent (input clk);",
			"    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));",
			"endmodule",
		}, function(buf)
			autowire.run(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			-- The line containing the instantiation must come AFTER the new decls.
			local inst_line, first_decl_line
			for i, line in ipairs(lines) do
				if line:match("simple u_simple") and not inst_line then
					inst_line = i
				end
				if line:match("logic .*;") and not first_decl_line then
					first_decl_line = i
				end
			end
			assert.is_not_nil(first_decl_line)
			assert.is_not_nil(inst_line)
			assert.is_true(first_decl_line < inst_line, "decls should precede instantiation")
		end)
	end)
end)
