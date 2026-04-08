-- ══════════════════════════════════════════════
-- Code Action Provider
-- ══════════════════════════════════════════════
-- Injects condition-order fixes into vim.lsp.buf.code_action() so they appear
-- in the same lightbulb menu as LSP-provided actions.
--
-- The handler is wrapped only once (guarded by _registered) regardless of how
-- many times setup() is called (e.g. after :Lazy reload).

local analyzer = require("condition-order.analyzer")
local config = require("condition-order.config")

local M = {}

-- Registration guard — prevents cumulative wrapping of the LSP handler.
local _registered = false
local _original_handler = nil

--- Diagnostic namespace (shared with init.lua via get_namespace()).
---@return integer
local function get_ns()
	return vim.api.nvim_create_namespace("condition_order")
end

--- Return true if a diagnostic overlaps a cursor range.
---@param diag vim.Diagnostic
---@param range_start integer  0-indexed line
---@param range_end integer    0-indexed line
---@return boolean
local function diag_overlaps(diag, range_start, range_end)
	local diag_end = diag.end_lnum or diag.lnum
	return diag.lnum <= range_end and diag_end >= range_start
end

--- Apply text edits without using the deprecated apply_workspace_edit.
--- Compatible with Neovim 0.9 – 0.11+.
---@param edit table  LSP WorkspaceEdit
---@param bufnr integer
local function apply_workspace_edit(edit, bufnr)
	local uri = vim.uri_from_bufnr(bufnr)
	local encoding = "utf-8"
	local changes = (edit.changes or {})[uri]
	if changes then
		vim.lsp.util.apply_text_edits(changes, bufnr, encoding)
		return
	end
	-- Fallback for documentChanges (TextDocumentEdit array)
	if edit.documentChanges then
		for _, doc_change in ipairs(edit.documentChanges) do
			local edits = doc_change.edits or {}
			local doc_bufnr = vim.uri_to_bufnr(doc_change.textDocument and doc_change.textDocument.uri or uri)
			vim.lsp.util.apply_text_edits(edits, doc_bufnr, encoding)
		end
	end
end

--- Build an LSP-style WorkspaceEdit from a ConditionFix.
---@param fix ConditionFix
---@param bufnr integer
---@return table
local function fix_to_edit(fix, bufnr)
	local uri = vim.uri_from_bufnr(bufnr)
	return {
		changes = {
			[uri] = {
				{
					range = {
						start = { line = fix.range[1], character = fix.range[2] },
						["end"] = { line = fix.range[3], character = fix.range[4] },
					},
					newText = fix.replacement,
				},
			},
		},
	}
end

--- Build a human-readable title for a single fix action.
---@param fix ConditionFix
---@param diag vim.Diagnostic
---@return string
local function action_title(fix, diag)
	-- Include the line number so the picker distinguishes multiple fixes.
	return string.format("⚡ Reorder conditions on line %d (cheapest first)", diag.lnum + 1)
end

-- ══════════════════════════════════════════════
-- PUBLIC: GET ACTIONS
-- ══════════════════════════════════════════════

--- Return code actions for the given cursor position in bufnr.
---@param bufnr integer
---@param params table  LSP CodeActionParams (contains .range)
---@return table[]
function M.get_actions(bufnr, params)
	local ft = vim.bo[bufnr].filetype
	local actions = {}

	local ns = get_ns()
	local diags = vim.diagnostic.get(bufnr, { namespace = ns })

	local range_start = params.range and params.range.start and params.range.start.line or 0
	local range_end = params.range and params.range["end"] and params.range["end"].line or range_start

	-- Diagnostics under the cursor.
	local matching = {}
	for _, diag in ipairs(diags) do
		if diag_overlaps(diag, range_start, range_end) then
			matching[#matching + 1] = diag
		end
	end
	if #matching == 0 then
		return actions
	end

	local fixes = analyzer.get_fixes(bufnr, ft)

	-- Single-fix actions.
	for _, fix in ipairs(fixes) do
		for _, diag in ipairs(matching) do
			if fix.range[1] == diag.lnum and fix.range[2] == diag.col then
				actions[#actions + 1] = {
					title = action_title(fix, diag),
					kind = "quickfix",
					diagnostics = { diag },
					edit = fix_to_edit(fix, bufnr),
					_condition_order_fix = fix,
				}
				break
			end
		end
	end

	-- "Fix all" action when there are multiple fixable issues.
	if #fixes > 1 and #matching > 0 then
		actions[#actions + 1] = {
			title = string.format("⚡ Reorder ALL conditions in buffer (%d fixes)", #fixes),
			kind = "quickfix",
			_condition_order_fix_all = true,
		}
	end

	return actions
end

-- ══════════════════════════════════════════════
-- PUBLIC: APPLY ACTION
-- ══════════════════════════════════════════════

---@param action table
---@param bufnr integer
function M.apply_action(action, bufnr)
	-- "Fix all" delegates to init.fix().
	if action._condition_order_fix_all then
		require("condition-order").fix(bufnr)
		return
	end

	-- Single fix via workspace edit.
	if action.edit then
		apply_workspace_edit(action.edit, bufnr)
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				require("condition-order").analyze(bufnr)
			end
		end, 50)
		return
	end

	-- Direct fix data (fallback path).
	if action._condition_order_fix then
		local fix = action._condition_order_fix
		vim.api.nvim_buf_set_text(
			bufnr,
			fix.range[1],
			fix.range[2],
			fix.range[3],
			fix.range[4],
			vim.split(fix.replacement, "\n")
		)
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				require("condition-order").analyze(bufnr)
			end
		end, 50)
	end
end

-- ══════════════════════════════════════════════
-- PUBLIC: REGISTER LSP HANDLER
-- ══════════════════════════════════════════════

--- Hook into vim.lsp.buf.code_action() to merge our actions.
--- Safe to call multiple times — wraps the original handler only once.
function M.register()
	if _registered then
		return
	end
	_registered = true

	_original_handler = vim.lsp.handlers["textDocument/codeAction"]

	vim.lsp.handlers["textDocument/codeAction"] = function(err, result, ctx, lsp_config)
		result = result or {}

		local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
		local ft = vim.bo[bufnr].filetype

		if vim.tbl_contains(config.options.filetypes, ft) then
			for _, action in ipairs(M.get_actions(bufnr, ctx.params)) do
				result[#result + 1] = action
			end
		end

		if _original_handler then
			_original_handler(err, result, ctx, lsp_config)
		else
			-- No LSP attached — show our own picker.
			if #result == 0 then
				vim.notify("No code actions available", vim.log.levels.INFO)
				return
			end
			vim.ui.select(result, {
				prompt = "Code actions:",
				format_item = function(a)
					return a.title
				end,
			}, function(action)
				if action then
					M.apply_action(action, bufnr)
				end
			end)
		end
	end
end

--- Register :ConditionOrderActions standalone command (works without LSP).
function M.register_standalone()
	vim.api.nvim_create_user_command("ConditionOrderActions", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local line = cursor[1] - 1 -- 0-indexed

		local params = {
			range = {
				start = { line = line, character = 0 },
				["end"] = { line = line, character = 999 },
			},
		}

		local actions = M.get_actions(bufnr, params)
		if #actions == 0 then
			vim.notify("condition-order: no actions at cursor", vim.log.levels.INFO)
			return
		end

		vim.ui.select(actions, {
			prompt = "Condition Order Actions:",
			format_item = function(a)
				return a.title
			end,
		}, function(action)
			if action then
				M.apply_action(action, bufnr)
			end
		end)
	end, { desc = "Show condition-order code actions at cursor" })
end

return M
