local instantiate = require("verilog.instantiate")
local connect = require("verilog.connect")
local attribute = require("verilog.attribute")
local wildcard = require("verilog.wildcard")
local autowire = require("verilog.autowire")
local wireinterface = require("verilog.wireinterface")

local function setup(opt)
	opt = opt or {}
	local autoinst_cmd = opt.cmd or "AutoInst"
	local connect_cmd = "ConnectPorts"
	local toggle_cmd = "ToggleAttribute"
	local set_attr_cmd = "SetAttribute"
	local debug_cmd = "DebugVerilog"
	local expand_cmd = "ExpandWildcards"

	vim.api.nvim_create_user_command(autoinst_cmd, function(opts)
		instantiate.auto_instantiation(opts.args)
	end, { nargs = "?" })

	-- :Connect dispatches by cursor context — port connections, parameter
	-- overrides, and "anywhere inside an instantiation" all route to the
	-- right sub-flow. The legacy command name is kept for muscle memory.
	vim.api.nvim_create_user_command(connect_cmd, function()
		connect.connect()
	end, { nargs = "?" })

	vim.api.nvim_create_user_command(toggle_cmd, function(opts)
		attribute.toggle_attribute(opts.fargs[1])
	end, { nargs = 1 })

	vim.api.nvim_create_user_command(set_attr_cmd, function(opts)
		if #opts.fargs ~= 2 then
			vim.print("Must supply 2 arguments: attribute name, attribute value")
			return
		end
		attribute.set_attribute_on_cursor(opts.fargs[1], opts.fargs[2])
	end, { nargs = "+" })

	vim.api.nvim_create_user_command(expand_cmd, function()
		wildcard.expand_file(0)
	end, {})

	vim.api.nvim_create_user_command("AutoWire", function()
		autowire.run(0)
	end, {})

	vim.api.nvim_create_user_command("WireInterface", function()
		wireinterface.wire_to_interface()
	end, {})

	vim.api.nvim_create_user_command(debug_cmd, function() end, { nargs = "*" })

	-- NOTE: This autocmd races with async formatters (LSP-based format-on-save,
	-- conform.nvim with async=true, etc.). The formatter captures buffer state at
	-- request time and later replaces the buffer with that pre-expansion text,
	-- silently dropping our edits. If you use a formatter on save, prefer chaining
	-- expansion into the formatter pipeline explicitly — see README.
	if opt.expand_wildcards_on_save then
		vim.api.nvim_create_autocmd("BufWritePre", {
			pattern = { "*.v", "*.sv", "*.svh", "*.vh" },
			callback = function()
				wildcard.expand_file(0)
			end,
		})
	end
end

return {
	setup = setup,
}
