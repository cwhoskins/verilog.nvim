local M = {}

local h = vim.health or require("health")
local start = h.start or h.report_start
local ok = h.ok or h.report_ok
local warn = h.warn or h.report_warn
local err = h.error or h.report_error

local function has_module(name)
	return pcall(require, name)
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

	local ts = require("verilog.ts")
	if ts.has_lang("systemverilog") then
		ok("treesitter systemverilog parser available")
	elseif ts.has_lang("verilog") then
		warn("using the old treesitter verilog parser", {
			"nvim-treesitter renamed it to systemverilog; update nvim-treesitter and run :TSInstall systemverilog",
		})
	else
		err("treesitter systemverilog parser not available", {
			"Install it with nvim-treesitter (:TSInstall systemverilog) or put systemverilog.so in a parser/ directory on 'runtimepath'",
		})
	end

	if vim.fn.executable("rg") == 1 then
		ok("ripgrep (rg) available")
	else
		warn("ripgrep (rg) not on PATH", { "Install ripgrep — used by :AutoInst telescope picker" })
	end
end

return M
