local M = {}

local h = vim.health or require("health")
local start = h.start or h.report_start
local ok = h.ok or h.report_ok
local warn = h.warn or h.report_warn
local err = h.error or h.report_error

local function has_module(name)
	return pcall(require, name)
end

-- language.add throws on 0.10 but returns nil, err on 0.11+ when the parser is
-- missing, so confirm with inspect, which errors on an unloaded language.
local function has_ts_lang(lang)
	pcall(vim.treesitter.language.add, lang)
	return (pcall(vim.treesitter.language.inspect, lang))
end

function M.check()
	start("verilog.nvim")

	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim >= 0.10")
	else
		err("Neovim < 0.10 — plugin requires 0.10+ (vim.lsp.get_clients)")
	end

	if has_module("telescope") then
		ok("telescope.nvim installed")
	else
		err("telescope.nvim not found", { "Install nvim-telescope/telescope.nvim" })
	end

	if has_ts_lang("verilog") then
		ok("treesitter verilog parser available")
	else
		err("treesitter verilog parser not available", {
			"Install it with nvim-treesitter (:TSInstall verilog) or put verilog.so in a parser/ directory on 'runtimepath'",
		})
	end

	if vim.fn.executable("rg") == 1 then
		ok("ripgrep (rg) available")
	else
		warn("ripgrep (rg) not on PATH", { "Install ripgrep — used by :AutoInst telescope picker" })
	end
end

return M
