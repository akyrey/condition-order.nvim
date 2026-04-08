local M = {}

---@class ConditionOrderConfig
---@field filetypes string[]
---@field threshold integer
---@field auto_analyze boolean
---@field severity integer
---@field cost_overrides table<string, integer>
---@field expensive_patterns string[]
---@field register_code_actions boolean
---@field assume_pure string[]
---@field max_buffer_bytes integer?
---@field analyze_debounce_ms integer
---@field ignore_comment string

---@type ConditionOrderConfig
local defaults = {
	-- Filetypes to analyze
	filetypes = { "php", "go", "python" },

	-- Minimum cost difference between adjacent operands to trigger a warning
	threshold = 2,

	-- Auto-analyze on BufWritePost / BufReadPost
	auto_analyze = true,

	-- Diagnostic severity
	severity = vim.diagnostic.severity.HINT,

	-- Custom cost overrides: function_name → cost
	cost_overrides = {},

	-- Patterns considered "IO/expensive" (matched against function names)
	expensive_patterns = {
		-- PHP
		"query",
		"fetch",
		"find",
		"load",
		"file_get_contents",
		"curl",
		"Http::get",
		"Http::post",
		"DB::table",
		"DB::select",
		-- Go
		"ReadFile",
		"WriteFile",
		"ReadAll",
		"ReadDir",
		"ListenAndServe",
		"Dial",
		"LookupHost",
		".Scan",
		".Next",
	},

	-- Register as an LSP code action source (lightbulb menu)
	register_code_actions = true,

	-- Function names to treat as side-effect-free (safe to reorder to earlier positions).
	-- By default, only stdlib known-functions are considered pure.
	-- Add your application's pure helpers here, e.g.:
	--   assume_pure = { "Cache::get", "myhelper.IsPending" }
	assume_pure = {},

	-- Skip analysis when buffer exceeds this many bytes (nil = no limit)
	max_buffer_bytes = nil,

	-- Milliseconds to debounce autocmd-triggered analysis
	analyze_debounce_ms = 300,

	-- Comment text that suppresses a diagnostic on the same line(s).
	-- Set to "" to disable the feature.
	-- Usage: if ($a && $b) { // condition-order: ignore
	ignore_comment = "condition-order: ignore",
}

---@type ConditionOrderConfig
M.options = vim.deepcopy(defaults)

---@param opts? table
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return M
