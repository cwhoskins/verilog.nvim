local M = {}

local TS = vim.treesitter
local ts = require("verilog.ts")
local query = require("verilog.query")

local function set_attribute_on_declaration(node, attr, value)
	local mitem = ts.search_parents_for_type(node, "module_item")
	if mitem == nil then
		mitem = node:prev_sibling()
	end
	local attributes = ts.filter_children(mitem, function(a)
		return a:type() == "attr_spec"
	end)
	for _, attribute in ipairs(attributes) do
		if TS.get_node_text(attribute:child(0), 0) == attr and TS.get_node_text(attribute:child(2), 0) == value then
			return
		elseif TS.get_node_text(attribute:child(0), 0) == attr then
			local sr, sc, er, ec = TS.get_node_range(attribute:child(2), 0)
			vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { value })
			return
		end
	end
	local attribute_declaration = attr .. " = " .. value
	if #attributes == 0 then
		local sr, sc, _, _ = TS.get_node_range(node, 0)
		attribute_declaration = "(* " .. attribute_declaration .. " *) "
		vim.api.nvim_buf_set_text(0, sr, sc, sr, sc, { attribute_declaration })
	else
		local sr, sc, _, _ = TS.get_node_range(attributes[1], 0)
		attribute_declaration = attribute_declaration .. ", "
		vim.api.nvim_buf_set_text(0, sr, sc, sr, sc, { attribute_declaration })
	end
end

local function get_attribute_on_declaration(node, attr)
	local mitem = ts.search_parents_for_type(node, "module_item")
	if mitem == nil then
		mitem = node:prev_sibling()
		if mitem:type() ~= "attribute_instance" then
			return nil
		end
	end
	local attributes = ts.filter_children(mitem, function(a)
		return a:type() == "attr_spec"
	end)
	for _, attribute in ipairs(attributes) do
		if TS.get_node_text(attribute:child(0), 0) == attr then
			return TS.get_node_text(attribute:child(2), 0)
		end
	end
	return nil
end

function M.toggle_attribute(attr)
	local net = ts.get_node_at_cursor()
	local net_name = TS.get_node_text(net, 0)
	local declaration = query.get_declaration_from_name(net_name)
	if declaration ~= nil then
		local attr_value = get_attribute_on_declaration(declaration, attr)
		local new_value = ""
		if attr_value == nil or string.upper(attr_value) == '"FALSE"' then
			new_value = '"TRUE"'
		elseif string.upper(attr_value) == '"TRUE"' then
			new_value = '"FALSE"'
		elseif string.upper(attr_value) == '"YES"' then
			new_value = '"no"'
		elseif string.upper(attr_value) == '"NO"' then
			new_value = '"yes"'
		else
			vim.print("Attribute value is not toggle-able")
			return
		end
		set_attribute_on_declaration(declaration, attr, new_value)
	else
		vim.print("Declaration not found")
	end
end

function M.set_attribute_on_cursor(attr, value)
	local net = ts.get_node_at_cursor()
	local net_name = TS.get_node_text(net, 0)
	local declaration = query.get_declaration_from_name(net_name)
	if declaration ~= nil then
		set_attribute_on_declaration(declaration, attr, value)
	else
		vim.print("Declaration not found")
	end
end

return M
