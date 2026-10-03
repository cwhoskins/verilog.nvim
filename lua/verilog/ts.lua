local M = {}

local TS = vim.treesitter

-- Always parse with the verilog grammar. Asking by filetype would look for a
-- "systemverilog" parser on .sv buffers unless something registered the mapping.
M.lang = "verilog"

function M.get_parser(bufnr)
	return TS.get_parser(bufnr, M.lang)
end

-- Smallest named node under the cursor in the current window. Parses first:
-- on a fresh buffer the tree may not exist yet.
function M.get_node_at_cursor()
	M.get_parser(0):parse()
	return TS.get_node({ bufnr = 0, lang = M.lang, ignore_injections = true })
end

function M.search_parents_for_type(node, type)
	local cur_node = node
	while cur_node ~= nil do
		if cur_node:type() == type then
			return cur_node
		end
		cur_node = cur_node:parent()
	end
	return
end

function M.search_children_for_type(node, type)
	if node:type() == type then
		return node
	end
	for child in node:iter_children() do
		if child:type() == type then
			return child
		end
		local search_node = M.search_children_for_type(child, type)
		if search_node ~= nil then
			return search_node
		end
	end
	return
end

function M.filter_children(node, filt)
	local result = {}
	if node == nil then
		return nil
	end
	if filt(node) then
		table.insert(result, node)
	else
		for child in node:iter_children() do
			local a = M.filter_children(child, filt)
			for _, v in ipairs(a) do
				table.insert(result, v)
			end
		end
	end
	return result
end

function M.filter(t, filt)
	local result = {}
	for _, elem in ipairs(t) do
		if filt(elem) then
			table.insert(result, elem)
		end
	end
	return result
end

function M.get_query_nodes(stext, query_string, root)
	local parser
	if type(stext) == "string" then
		parser = TS.get_string_parser(stext, "verilog")
	elseif type(stext) == "number" then
		parser = M.get_parser(stext)
	else
		print("Invalid type for stext")
		return
	end
	local ok, query = pcall(TS.query.parse, parser:lang(), query_string)

	if not ok then
		print("Failed to parse query")
		print(query_string)
		return
	end

	local tree = parser:parse()[1]

	local nodes = {}
	if root == nil then
		root = tree:root()
	end
	for id, node, metadata in query:iter_captures(root, 0, 0, -1) do
		table.insert(nodes, node)
	end
	return nodes
end

return M
