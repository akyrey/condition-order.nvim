local config = require("condition-order.config")

local M = {}

-- ══════════════════════════════════════════════
-- LANGUAGE REGISTRY
-- ══════════════════════════════════════════════

-- Registry: ts_lang_name → language spec
local _registry = {}

--- Register a language spec with the cost engine.
--- The spec must follow the interface defined in languages/*.lua:
---   filetype, ts_lang, costs, known_functions, impure_functions,
---   condition_starters, body_nodes, func_boundaries, call_node_types,
---   logical_binary_node_types, negation_node_types, negation_ops,
---   resolve_call_name(node, bufnr) → name?, suffix?
---@param name string  Treesitter language name (also used as filetype key)
---@param spec table   Language spec table
function M.register_language(name, spec)
	_registry[name] = spec
	-- Also index by filetype when it differs from the ts_lang name.
	if spec.filetype and spec.filetype ~= name then
		_registry[spec.filetype] = spec
	end
end

--- Return the registered spec for a language, or nil.
---@param name string
---@return table?
function M.get_language(name)
	return _registry[name]
end

-- ══════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════

-- Fallback cost for unknown expensive-pattern matches.
local EXPENSIVE_FALLBACK_COST = 20

--- Check if a function name matches any configured "expensive" pattern.
---@param name string
---@return boolean
local function is_expensive_call(name)
	local lower = name:lower()
	for _, pattern in ipairs(config.options.expensive_patterns) do
		if lower:find(pattern:lower(), 1, true) then
			return true
		end
	end
	return false
end

-- ══════════════════════════════════════════════
-- NEGATION AWARENESS
-- ══════════════════════════════════════════════
-- `!expr` / `not expr` costs the same as `expr` — the negation operator is free.
-- Double negation (!!x / not not x) unwraps fully to x.

--- Unwrap a negation node, returning the inner expression (or nil if not negation).
---@param node    TSNode
---@param bufnr   integer
---@param spec    table  language spec
---@return TSNode?
local function unwrap_negation(node, bufnr, spec)
	local ntype = node:type()

	-- Build a set of negation node types for fast lookup.
	local neg_types = spec.negation_node_types or {}
	local neg_ops = spec.negation_ops or {}

	for _, neg_ntype in ipairs(neg_types) do
		if ntype == neg_ntype then
			-- Scan unnamed children for a negation operator token.
			for i = 0, node:child_count() - 1 do
				local child = node:child(i)
				if child and not child:named() then
					local text = vim.treesitter.get_node_text(child, bufnr)
					for _, op in ipairs(neg_ops) do
						if text == op then
							local inner = node:named_child(0)
							if inner then
								-- Recurse to handle double negation (!!x → x).
								local deeper = unwrap_negation(inner, bufnr, spec)
								return deeper or inner
							end
						end
					end
				end
			end
		end
	end

	return nil
end

-- ══════════════════════════════════════════════
-- PUBLIC: CALL NAME RESOLUTION
-- ══════════════════════════════════════════════

--- Resolve a call expression's function name using the language spec.
--- Returns the full name and (for languages with method dispatch) the method suffix.
---@param node  TSNode
---@param bufnr integer
---@param lang  string
---@return string?  full name
---@return string?  method suffix
function M.resolve_call_name(node, bufnr, lang)
	local spec = _registry[lang]
	if not spec or not spec.resolve_call_name then
		return nil, nil
	end
	return spec.resolve_call_name(node, bufnr)
end

-- ══════════════════════════════════════════════
-- PUBLIC: PURITY CHECK
-- ══════════════════════════════════════════════

--- Return true if fname is a known stdlib function that has no observable side
--- effects and is therefore safe to move to an earlier position in a condition chain.
---@param fname string
---@param lang  string
---@return boolean
function M.is_known_pure(fname, lang)
	local spec = _registry[lang]
	if not spec then
		return false
	end
	if spec.impure_functions and spec.impure_functions[fname] then
		return false
	end
	return spec.known_functions ~= nil and spec.known_functions[fname] ~= nil
end

-- ══════════════════════════════════════════════
-- SCORING ENGINE
-- ══════════════════════════════════════════════

--- Recursively compute the evaluation cost score for a Treesitter node.
---@param node  TSNode
---@param bufnr integer
---@param lang  string
---@return integer
function M.score(node, bufnr, lang)
	local spec = _registry[lang]
	if not spec then
		return 1
	end

	local ntype = node:type()

	-- Negation pass-through: !expr / not expr costs the same as expr.
	local inner = unwrap_negation(node, bufnr, spec)
	if inner then
		return M.score(inner, bufnr, lang)
	end

	-- Call resolution: check known functions, user overrides, expensive patterns.
	local call_types = spec.call_node_types or {}
	if call_types[ntype] then
		local fname, method_name = spec.resolve_call_name and spec.resolve_call_name(node, bufnr) or nil, nil

		if fname then
			-- User-defined cost overrides take priority.
			local co = config.options.cost_overrides
			if co[fname] then
				return co[fname]
			end

			-- Known stdlib functions.
			if spec.known_functions then
				if spec.known_functions[fname] then
					return spec.known_functions[fname]
				end
				if method_name and spec.known_functions[method_name] then
					return spec.known_functions[method_name]
				end
			end

			-- Expensive-pattern heuristic.
			if is_expensive_call(fname) then
				return EXPENSIVE_FALLBACK_COST
			end
			if method_name and is_expensive_call(method_name) then
				return EXPENSIVE_FALLBACK_COST
			end
		end
	end

	-- Base cost lookup from the language's cost table.
	local base = spec.costs and spec.costs[ntype]
	if base and base > 0 then
		return base
	end

	-- Recursive: cost = max child cost (handles compound/binary nodes with base = 0).
	local max_cost = 1
	for child in node:iter_children() do
		local child_cost = M.score(child, bufnr, lang)
		if child_cost > max_cost then
			max_cost = child_cost
		end
	end

	return max_cost
end

-- ══════════════════════════════════════════════
-- AUTO-REGISTER BUNDLED LANGUAGES
-- ══════════════════════════════════════════════

M.register_language("php", require("condition-order.languages.php"))
M.register_language("go", require("condition-order.languages.go"))
M.register_language("python", require("condition-order.languages.python"))

return M
