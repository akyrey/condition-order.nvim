--- Shared utilities for condition-order.nvim
local M = {}

--- Get the source text of a Treesitter node.
--- Uses the parser's cached buffer view — O(1), no string splitting.
---@param node TSNode
---@param bufnr integer
---@return string
function M.node_text(node, bufnr)
	return vim.treesitter.get_node_text(node, bufnr)
end

--- Trim whitespace and truncate a string for display.
---@param s string
---@param max? integer  default 40
---@return string
function M.display(s, max)
	s = vim.trim(s)
	max = max or 40
	if #s > max then
		return s:sub(1, max - 1) .. "…"
	end
	return s
end

return M
