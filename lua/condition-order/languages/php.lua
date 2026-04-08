--- PHP language spec for condition-order.nvim
---
--- Register via:  require("condition-order.cost").register_language("php", spec)
--- This file is loaded automatically by cost.lua.

local M = {}

M.filetype = "php"
M.ts_lang = "php"

-- ── Cost table ───────────────────────────────────────────────────────────────
-- Maps Treesitter node type → base evaluation cost.
-- 0 means "recurse into children and return max child cost".

---@type table<string, integer>
M.costs = {
	-- Literals: essentially free
	["boolean"] = 1,
	["null"] = 1,
	["integer"] = 1,
	["float"] = 1,
	["string"] = 1,
	["encapsed_string"] = 2, -- interpolation needs work
	["heredoc"] = 2,

	-- Variables
	["variable_name"] = 2,
	["dynamic_variable_name"] = 4, -- $$var needs double lookup

	-- Type checks / language constructs
	["cast_expression"] = 2,

	-- Array/property access
	["subscript_expression"] = 4, -- $arr['key']
	["member_access_expression"] = 5, -- $obj->prop
	["nullsafe_member_access_expression"] = 5,
	["scoped_property_access_expression"] = 5, -- Class::$prop
	["class_constant_access_expression"] = 3, -- Class::CONST

	-- Function/method calls
	["function_call_expression"] = 8,
	["method_call_expression"] = 10,
	["nullsafe_method_call_expression"] = 10,
	["scoped_call_expression"] = 10,

	-- Object creation: allocation + constructor
	["object_creation_expression"] = 12,

	-- Compound (scored recursively — 0 means "look at children")
	["binary_expression"] = 0,
	["unary_op_expression"] = 0,
	["parenthesized_expression"] = 0,
	["conditional_expression"] = 0,
	["match_expression"] = 6,
}

-- ── Known pure functions ─────────────────────────────────────────────────────
-- All entries here are considered side-effect-free and safe to reorder.

---@type table<string, integer>
M.known_functions = {
	-- Language constructs
	["isset"] = 3,
	["unset"] = 3,
	["empty"] = 3,

	-- Type checks
	["is_null"] = 3,
	["is_int"] = 3,
	["is_integer"] = 3,
	["is_long"] = 3,
	["is_float"] = 3,
	["is_double"] = 3,
	["is_string"] = 3,
	["is_bool"] = 3,
	["is_array"] = 3,
	["is_object"] = 3,
	["is_numeric"] = 3,
	["is_callable"] = 4,

	-- Comparison / identity
	["in_array"] = 6,
	["array_key_exists"] = 4,

	-- String basics
	["strlen"] = 3,
	["str_contains"] = 5,
	["str_starts_with"] = 4,
	["str_ends_with"] = 4,
	["strtolower"] = 4,
	["strtoupper"] = 4,
	["trim"] = 4,

	-- Count
	["count"] = 3,
	["sizeof"] = 3,

	-- Array basics
	["array_merge"] = 6,
	["array_map"] = 7,
	["array_filter"] = 7,

	-- Regex: expensive
	["preg_match"] = 8,
	["preg_match_all"] = 9,
	["preg_replace"] = 9,
}

-- PHP has no impure entries in the known list (all listed functions are pure).
---@type table<string, boolean>
M.impure_functions = {}

-- ── AST walking hints ────────────────────────────────────────────────────────

-- Entering these nodes puts us inside a condition context.
---@type table<string, boolean>
M.condition_starters = {
	if_statement = true,
	elseif_clause = true,
	while_statement = true,
	do_statement = true,
	for_statement = true, -- for (init; cond; incr)
	conditional_expression = true, -- ternary $a ? $b : $c
	match_expression = true, -- PHP 8 match
}

-- Entering these nodes ends the condition context (they are body blocks).
---@type table<string, boolean>
M.body_nodes = {
	compound_statement = true,
}

-- Entering these nodes resets in_condition (function/class boundaries).
---@type table<string, boolean>
M.func_boundaries = {
	function_definition = true,
	method_declaration = true,
	class_declaration = true,
	anonymous_function_creation_expression = true, -- function() use (...) { }
	arrow_function = true, -- fn($x) => expr
	program = true, -- top-level PHP root
}

-- Treesitter node types that represent call/invocation expressions.
-- Used by the purity checker in analyzer.lua.
---@type table<string, boolean>
M.call_node_types = {
	function_call_expression = true,
	scoped_call_expression = true,
	method_call_expression = true,
	nullsafe_method_call_expression = true,
	object_creation_expression = true,
}

-- Node types that are logical binary expressions (&&, ||, and, or).
---@type table<string, boolean>
M.logical_binary_node_types = {
	binary_expression = true,
}

-- Unary negation node types and their operator texts.
M.negation_node_types = { "unary_op_expression" }
M.negation_ops = { "!", "not" }

-- ── Call name resolver ───────────────────────────────────────────────────────

--- Extract the function/method name from a PHP call expression node.
---@param node TSNode
---@param bufnr integer
---@return string?  full name
---@return nil      (PHP never returns a method suffix)
function M.resolve_call_name(node, bufnr)
	local get_text = vim.treesitter.get_node_text
	local ntype = node:type()

	if ntype == "scoped_call_expression" then
		local scope = node:child(0)
		local method = node:child(2)
		if scope and method then
			return get_text(scope, bufnr) .. "::" .. get_text(method, bufnr), nil
		end
	end

	local name_node = node:named_child(0)
	if not name_node then
		return nil, nil
	end
	return get_text(name_node, bufnr), nil
end

return M
