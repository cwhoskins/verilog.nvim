local M = {}

M.root_patterns = { ".git", "lua" }

local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local conf = require("telescope.config").values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"

-- returns the root directory based on:
-- * lsp workspace folders
-- * lsp root_dir
-- * root pattern of filename of the current buffer
-- * root pattern of cwd
---@return string
function M.get_root()
	---@type string?
	local path = vim.api.nvim_buf_get_name(0)
	path = path ~= "" and vim.loop.fs_realpath(path) or nil
	---@type string[]
	local roots = {}
	if path then
		for _, client in pairs(vim.lsp.get_clients({ bufnr = 0 })) do
			local workspace = client.config.workspace_folders
			local paths = workspace
					and vim.tbl_map(function(ws)
						return vim.uri_to_fname(ws.uri)
					end, workspace)
				or client.config.root_dir and { client.config.root_dir }
				or {}
			for _, p in ipairs(paths) do
				if p ~= "" then
					local r = vim.loop.fs_realpath(p)
					if path:find(r, 1, true) then
						roots[#roots + 1] = r
					end
				end
			end
		end
	end
	table.sort(roots, function(a, b)
		return #a > #b
	end)
	---@type string?
	local root = roots[1]
	if not root then
		path = path and vim.fs.dirname(path) or vim.loop.cwd()
		---@type string?
		root = vim.fs.find(M.root_patterns, { path = path, upward = true })[1]
		root = root and vim.fs.dirname(root) or vim.loop.cwd()
	end
	---@cast root string
	return root
end

function M.is_member(t,e)
	for i, te in ipairs(t) do
		if(te == e) then return true end
	end
	return false
end

function M.is_not_root_pattern(path)
	return string.match(path, "^/") or string.match(path, "^[A-Za-z]:\\")
end

function M.file_search(file_name)
	local matches = vim.fs.find(function(name, _)
		return name == file_name .. ".v"
			or name == file_name .. ".sv"
			or name == file_name .. ".svh"
			or name == file_name .. ".vh"
	end, { path = vim.loop.cwd(), type = "file", limit = 1 })
	return matches[1] or ""
end

function M.telescope(fn_inst)
	local builtin = "find_files"
	local root = M.get_root()
	local opts = {
		cwd = root,
		find_command = { "rg", "-tverilog", "--color", "never", "--files" },
		attach_mappings = function(prompt_bufnr)
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			actions.select_default:replace(function()
				actions.close(prompt_bufnr)
				local selection = action_state.get_selected_entry()
				local file_path = selection.path or (root .. "/" .. selection[1])
				fn_inst(file_path)
			end)
			return true
		end,
	}
	require("telescope.builtin")[builtin](opts)
end

function M.telescope_ports(t, cb, opts)
	opts = opts or {}
	pickers.new(opts, {
		prompt_title = "Ports",
		finder = finders.new_table {
			results = t,
			entry_maker = function(entry)
				return {
					value = entry,
					display = entry[2] .. " | " .. entry[3] .. " | " .. entry[4],
					ordinal = entry[2] .. " | " .. entry[3] .. " | " .. entry[4],
				}
			end,
		},
		sorter = conf.generic_sorter(opts),
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace(function()
				actions.close(prompt_bufnr)
				cb(action_state.get_selected_entry().value)
			end)
			return true
		end,
	}):find()
end

function M.get_shared_parents(n1,n2)
	local n1p = {}
	local ids = {}
	parent = n1:parent()
	while parent ~= nil do
		table.insert(n1p, parent)
		table.insert(ids, parent:id())
		parent = parent:parent()
	end
	local shared = {}
	parent = n2:parent()
	while parent ~= nil do
		local id = parent:id()
		for idx,n1_id in ipairs(ids) do
			if n1_id == id then
				table.insert(shared, parent)
				break
			end
		end
		parent = parent:parent()
	end
	return shared
end
return M
