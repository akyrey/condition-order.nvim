--- Go language spec for condition-order.nvim
---
--- Register via:  require("condition-order.cost").register_language("go", spec)
--- This file is loaded automatically by cost.lua.

local M = {}

M.filetype = "go"
M.ts_lang = "go"

-- ── Cost table ───────────────────────────────────────────────────────────────

---@type table<string, integer>
M.costs = {
	-- Literals
	["true"] = 1,
	["false"] = 1,
	["nil"] = 1,
	["int_literal"] = 1,
	["float_literal"] = 1,
	["rune_literal"] = 1,
	["raw_string_literal"] = 1,
	["interpreted_string_literal"] = 1,

	-- Identifiers
	["identifier"] = 2,

	-- Field access
	["selector_expression"] = 4,

	-- Index / slice
	["index_expression"] = 4,
	["slice_expression"] = 5,

	-- Type assertions / conversions
	["type_assertion_expression"] = 5,
	["type_conversion_expression"] = 4,

	-- Function/method calls
	["call_expression"] = 8,

	-- Composite literals
	["composite_literal"] = 10,

	-- Compound (scored recursively — 0 means "look at children")
	["unary_expression"] = 0,
	["binary_expression"] = 0,
	["parenthesized_expression"] = 0,
}

-- ── Known functions ──────────────────────────────────────────────────────────

---@type table<string, integer>
M.known_functions = {
	-- Builtins (compiler intrinsics)
	["len"] = 2,
	["cap"] = 2,
	["make"] = 6,
	["new"] = 6,
	["append"] = 5,
	["copy"] = 5,
	["delete"] = 4,
	["close"] = 3,
	["panic"] = 1,

	-- strings
	["strings.Contains"] = 5,
	["strings.HasPrefix"] = 4,
	["strings.HasSuffix"] = 4,
	["strings.EqualFold"] = 5,
	["strings.Index"] = 6,
	["strings.Count"] = 6,
	["strings.ToLower"] = 5,
	["strings.ToUpper"] = 5,
	["strings.TrimSpace"] = 4,
	["strings.Split"] = 7,
	["strings.Join"] = 7,
	["strings.Replace"] = 7,
	["strings.ReplaceAll"] = 7,

	-- strconv
	["strconv.Itoa"] = 5,
	["strconv.Atoi"] = 5,
	["strconv.FormatInt"] = 5,
	["strconv.ParseInt"] = 5,

	-- fmt (allocates)
	["fmt.Sprintf"] = 8,
	["fmt.Errorf"] = 8,

	-- Regex
	["regexp.MatchString"] = 10,
	["regexp.MustCompile"] = 12,
	[".MatchString"] = 9,
	[".FindString"] = 9,
	[".FindStringSubmatch"] = 10,

	-- Reflection
	["reflect.TypeOf"] = 8,
	["reflect.ValueOf"] = 8,

	-- Encoding
	["json.Marshal"] = 12,
	["json.Unmarshal"] = 12,
	["json.NewDecoder"] = 10,
	["json.NewEncoder"] = 10,

	-- IO / network / filesystem (high cost, also impure)
	["os.Open"] = 20,
	["os.ReadFile"] = 20,
	["os.Stat"] = 15,
	["io.ReadAll"] = 20,
	["http.Get"] = 25,
	["http.Post"] = 25,

	-- Database (also impure)
	["sql.Open"] = 25,
	[".Query"] = 20,
	[".QueryRow"] = 20,
	[".Exec"] = 20,
	[".Prepare"] = 15,

	-- Sorting (mutates in-place — impure)
	["sort.Strings"] = 8,
	["sort.Ints"] = 8,
	["sort.Slice"] = 9,
	["sort.Sort"] = 9,

	-- Sync (impure)
	[".Lock"] = 3,
	[".Unlock"] = 3,
	[".RLock"] = 3,
	[".RUnlock"] = 3,

	-- Errors
	["errors.New"] = 4,
	["errors.Is"] = 4,
	["errors.As"] = 5,
	["errors.Unwrap"] = 3,
}

-- Go functions that mutate state / perform I/O — unsafe to move earlier.
---@type table<string, boolean>
M.impure_functions = {
	["os.Open"] = true,
	["os.ReadFile"] = true,
	["os.Stat"] = true,
	["io.ReadAll"] = true,
	["http.Get"] = true,
	["http.Post"] = true,
	["sql.Open"] = true,
	[".Query"] = true,
	[".QueryRow"] = true,
	[".Exec"] = true,
	[".Prepare"] = true,
	["sort.Strings"] = true,
	["sort.Ints"] = true,
	["sort.Slice"] = true,
	["sort.Sort"] = true,
	[".Lock"] = true,
	[".Unlock"] = true,
	[".RLock"] = true,
	[".RUnlock"] = true,
	["close"] = true,
	["delete"] = true,
}

-- ── AST walking hints ────────────────────────────────────────────────────────

---@type table<string, boolean>
M.condition_starters = {
	if_statement = true,
	for_statement = true, -- Go uses for for all loops
	expression_switch_statement = true,
}

---@type table<string, boolean>
M.body_nodes = {
	block = true,
	declaration_list = true,
}

---@type table<string, boolean>
M.func_boundaries = {
	function_declaration = true,
	method_declaration = true,
	func_literal = true,
	source_file = true,
}

---@type table<string, boolean>
M.call_node_types = {
	call_expression = true,
}

---@type table<string, boolean>
M.logical_binary_node_types = {
	binary_expression = true,
}

M.negation_node_types = { "unary_expression" }
M.negation_ops = { "!" }

-- ── Call name resolver ───────────────────────────────────────────────────────

--- Extract function/method name from a Go call_expression.
--- Returns full name (e.g. "strings.Contains") and optional method suffix (e.g. ".Contains").
---@param node TSNode
---@param bufnr integer
---@return string?  full name
---@return string?  method suffix (e.g. ".MatchString") for dot-method lookups
function M.resolve_call_name(node, bufnr)
	local get_text = vim.treesitter.get_node_text
	local func_node = node:named_child(0)
	if not func_node then
		return nil, nil
	end

	local ntype = func_node:type()

	if ntype == "identifier" then
		return get_text(func_node, bufnr), nil
	end

	if ntype == "selector_expression" then
		local operand = func_node:named_child(0)
		local field = func_node:named_child(1)
		if operand and field then
			local full = get_text(operand, bufnr) .. "." .. get_text(field, bufnr)
			local suffix = "." .. get_text(field, bufnr)
			return full, suffix
		end
	end

	return get_text(func_node, bufnr), nil
end

return M
