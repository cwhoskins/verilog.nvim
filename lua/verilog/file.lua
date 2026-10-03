local M = {}

local Util = require("verilog.util")

function M.read_file_into_new_buffer(file_name, is_path)
	is_path = is_path or false
	local file_path
	if is_path then
		file_path = file_name
	else
		file_path = Util.file_search(file_name)
	end
	if file_path == nil or file_path == "" then
		return nil
	end
	local f = io.open(file_path, "r")
	if f == nil then
		return nil
	end
	local stext = f:read("*a")
	f:close()
	local new_buffer = vim.api.nvim_create_buf(false, true)
	local lines = {}
	for line in string.gmatch(stext, "([^\n]*)\n?") do
		table.insert(lines, line)
	end
	vim.api.nvim_buf_set_text(new_buffer, 0, 0, 0, 0, lines)
	vim.treesitter.start(new_buffer, "verilog")
	return new_buffer
end

return M
