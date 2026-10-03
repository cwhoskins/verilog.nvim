local M = {}

-- Prompt the user to optionally pair stale entries with missing entries.
-- Skipped (calls on_done({}) immediately) when no rename is possible.
--
--   diff: { matched, stale, missing } where each list is { name, ... }
--   kind: "parameter" or "port" (used in the prompt)
--   on_done: called with a list of { from = <stale entry>, to = <missing entry> }
function M.pick_renames(diff, kind, on_done)
	if #diff.stale == 0 or #diff.missing == 0 then
		on_done({})
		return
	end

	local renames = {}
	local missing_pool = {}
	for _, m in ipairs(diff.missing) do
		table.insert(missing_pool, m)
	end

	local stale_idx = 1
	local function next_stale()
		if stale_idx > #diff.stale or #missing_pool == 0 then
			on_done(renames)
			return
		end
		local stale = diff.stale[stale_idx]
		stale_idx = stale_idx + 1

		local choices = {}
		for _, m in ipairs(missing_pool) do
			table.insert(choices, { action = "rename", target = m })
		end
		table.insert(choices, { action = "delete" })

		vim.ui.select(choices, {
			prompt = string.format("Rename stale %s .%s to:", kind, stale.name),
			format_item = function(item)
				if item.action == "rename" then
					return "rename → ." .. item.target.name
				end
				return "[delete]"
			end,
		}, function(choice)
			if choice == nil or choice.action == "delete" then
				next_stale()
				return
			end
			table.insert(renames, { from = stale, to = choice.target })
			for i, m in ipairs(missing_pool) do
				if m.name == choice.target.name then
					table.remove(missing_pool, i)
					break
				end
			end
			next_stale()
		end)
	end

	next_stale()
end

return M
