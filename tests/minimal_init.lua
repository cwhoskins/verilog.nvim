local function find_plugin(name)
	local patterns = {
		vim.fn.stdpath("data") .. "/lazy/" .. name,
		vim.fn.stdpath("data") .. "/site/pack/*/start/" .. name,
		vim.fn.stdpath("data") .. "/site/pack/*/opt/" .. name,
	}
	for _, pattern in ipairs(patterns) do
		for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
			if vim.fn.isdirectory(path) == 1 then
				return path
			end
		end
	end
	return nil
end

local repo_root = vim.fn.fnamemodify(
	vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"),
	":h"
)
vim.opt.runtimepath:prepend(repo_root)

local missing = {}
for _, plugin in ipairs({ "plenary.nvim", "telescope.nvim", "nvim-treesitter" }) do
	local p = find_plugin(plugin)
	if p then
		vim.opt.runtimepath:prepend(p)
	else
		table.insert(missing, plugin)
	end
end

if #missing > 0 then
	io.stderr:write("Missing test dependencies: " .. table.concat(missing, ", ") .. "\n")
end

vim.cmd("runtime plugin/plenary.vim")
