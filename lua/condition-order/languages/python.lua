--- Python language spec for condition-order.nvim
---
--- Register via:  require("condition-order.cost").register_language("python", spec)
--- This file is loaded automatically by cost.lua.
---
--- Requires nvim-treesitter with the Python parser: :TSInstall python

local M = {}

M.filetype = "python"
M.ts_lang = "python"

-- ── Cost table ───────────────────────────────────────────────────────────────

---@type table<string, integer>
M.costs = {
	-- Literals
	["true"] = 1,
	["false"] = 1,
	["none"] = 1,
	["integer"] = 1,
	["float"] = 1,
	["string"] = 1,
	["concatenated_string"] = 2,

	-- Identifiers
	["identifier"] = 2,

	-- Attribute / subscript access
	["attribute"] = 4, -- obj.attr
	["subscript"] = 5, -- obj[key]

	-- Calls
	["call"] = 8,

	-- Comparisons and boolean ops (recurse into children)
	["comparison_operator"] = 0,
	["boolean_operator"] = 0,
	["not_operator"] = 0,
	["parenthesized_expression"] = 0,

	-- Data structures (construction cost)
	["list"] = 6,
	["tuple"] = 6,
	["set"] = 6,
	["dictionary"] = 8,
	["list_comprehension"] = 10,
	["dict_comprehension"] = 10,
	["generator_expression"] = 9,

	-- Lambda is deferred (doesn't execute inline)
	["lambda"] = 3,
}

-- ── Known pure functions ─────────────────────────────────────────────────────

---@type table<string, integer>
M.known_functions = {
	-- Builtins
	["len"] = 2,
	["bool"] = 2,
	["int"] = 3,
	["float"] = 3,
	["str"] = 3,
	["repr"] = 3,
	["type"] = 3,
	["id"] = 2,
	["hash"] = 4,
	["abs"] = 2,
	["round"] = 3,
	["min"] = 5,
	["max"] = 5,
	["sum"] = 5,
	["all"] = 5,
	["any"] = 5,
	["sorted"] = 8, -- returns new list, not in-place
	["reversed"] = 4,
	["range"] = 4,
	["enumerate"] = 5,
	["zip"] = 5,
	["map"] = 5,
	["filter"] = 5,
	["list"] = 4,
	["tuple"] = 4,
	["set"] = 5,
	["dict"] = 5,
	["frozenset"] = 5,
	["isinstance"] = 3,
	["issubclass"] = 3,
	["hasattr"] = 4,
	["getattr"] = 5,
	["callable"] = 3,

	-- os.path helpers (read-only)
	["os.path.exists"] = 8,
	["os.path.isfile"] = 8,
	["os.path.isdir"] = 8,
	["os.path.join"] = 4,
	["os.path.basename"] = 3,
	["os.path.dirname"] = 3,

	-- String methods (accessed via attribute call — name won't match, but cost is
	-- set via the base call cost = 8; list them here for is_known_pure accuracy)
	["str.startswith"] = 4,
	["str.endswith"] = 4,
	["str.contains"] = 4,
	["str.lower"] = 4,
	["str.upper"] = 4,
	["str.strip"] = 4,

	-- Regex (expensive but pure)
	["re.match"] = 8,
	["re.search"] = 8,
	["re.fullmatch"] = 8,
	["re.findall"] = 9,
	["re.compile"] = 9,
}

-- Functions that mutate state, perform I/O, or are non-deterministic.
---@type table<string, boolean>
M.impure_functions = {
	-- I/O
	["open"] = true,
	["print"] = true,
	["input"] = true,
	["exec"] = true,
	["eval"] = true,
	["compile"] = true,

	-- OS / filesystem mutation
	["os.remove"] = true,
	["os.rename"] = true,
	["os.makedirs"] = true,
	["os.mkdir"] = true,
	["os.rmdir"] = true,

	-- shutil
	["shutil.copy"] = true,
	["shutil.copytree"] = true,
	["shutil.move"] = true,
	["shutil.rmtree"] = true,

	-- subprocess
	["subprocess.run"] = true,
	["subprocess.call"] = true,
	["subprocess.Popen"] = true,

	-- Network
	["requests.get"] = true,
	["requests.post"] = true,
	["requests.put"] = true,
	["requests.delete"] = true,
	["urllib.request.urlopen"] = true,
	["socket.connect"] = true,

	-- Serialization (mutation / I/O side effects)
	["json.dump"] = true,
	["pickle.dump"] = true,

	-- Non-deterministic
	["random.random"] = true,
	["random.randint"] = true,
	["random.choice"] = true,
	["random.shuffle"] = true, -- in-place mutation

	-- Sorting in-place
	[".sort"] = true, -- list.sort() is in-place
	[".append"] = true, -- list.append() mutates
	[".extend"] = true,
	[".pop"] = true,
	[".remove"] = true,
	[".clear"] = true,
}

-- ── AST walking hints ────────────────────────────────────────────────────────

---@type table<string, boolean>
M.condition_starters = {
	if_statement = true,
	elif_clause = true,
	while_statement = true,
	conditional_expression = true, -- value_if_true if condition else value_if_false
}

---@type table<string, boolean>
M.body_nodes = {
	block = true,
}

---@type table<string, boolean>
M.func_boundaries = {
	function_definition = true,
	async_function_definition = true,
	class_definition = true,
	module = true,
	lambda = true,
}

-- Python uses `call` (not `call_expression`) for function calls.
---@type table<string, boolean>
M.call_node_types = {
	call = true,
}

-- Python uses `boolean_operator` (not `binary_expression`) for `and`/`or`.
---@type table<string, boolean>
M.logical_binary_node_types = {
	boolean_operator = true,
}

-- Python uses `not_operator` for `not expr`.
M.negation_node_types = { "not_operator" }
M.negation_ops = { "not" }

-- ── Call name resolver ───────────────────────────────────────────────────────

--- Extract function/method name from a Python call node.
---@param node TSNode
---@param bufnr integer
---@return string?  full name (e.g. "re.match", "isinstance")
---@return string?  method suffix (e.g. ".match") for dot-method lookups
function M.resolve_call_name(node, bufnr)
	local get_text = vim.treesitter.get_node_text
	-- In tree-sitter-python, call → function: (identifier | attribute | ...)
	local func_node = node:named_child(0)
	if not func_node then
		return nil, nil
	end

	local ntype = func_node:type()

	if ntype == "identifier" then
		return get_text(func_node, bufnr), nil
	end

	if ntype == "attribute" then
		-- attribute → object . attribute
		local obj = func_node:named_child(0)
		local attr = func_node:named_child(1)
		if obj and attr then
			local full = get_text(obj, bufnr) .. "." .. get_text(attr, bufnr)
			local suffix = "." .. get_text(attr, bufnr)
			return full, suffix
		end
	end

	return get_text(func_node, bufnr), nil
end

return M
