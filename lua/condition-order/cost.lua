local config = require("condition-order.config")

local M = {}

-- ══════════════════════════════════════════════
-- PHP COST TABLES
-- ══════════════════════════════════════════════

---@type table<string, integer>
M.php_costs = {
  -- Literals: essentially free
  ["boolean"]              = 1,
  ["null"]                 = 1,
  ["integer"]              = 1,
  ["float"]                = 1,
  ["string"]               = 1,
  ["encapsed_string"]      = 2,   -- interpolation needs work
  ["heredoc"]              = 2,

  -- Variables
  ["variable_name"]        = 2,
  ["dynamic_variable_name"]= 4,   -- $$var needs double lookup

  -- Type checks / language constructs
  ["cast_expression"]      = 2,

  -- Array/property access
  ["subscript_expression"]       = 4,  -- $arr['key']
  ["member_access_expression"]   = 5,  -- $obj->prop
  ["nullsafe_member_access_expression"] = 5,
  ["scoped_property_access_expression"] = 5,  -- Class::$prop
  ["class_constant_access_expression"]  = 3,  -- Class::CONST

  -- Function/method calls
  ["function_call_expression"]   = 8,
  ["method_call_expression"]     = 10,
  ["nullsafe_method_call_expression"] = 10,
  ["scoped_call_expression"]     = 10,

  -- Object creation: allocation + constructor
  ["object_creation_expression"] = 12,

  -- Compound (scored recursively — 0 means "look at children")
  ["binary_expression"]          = 0,
  ["unary_op_expression"]        = 0,
  ["parenthesized_expression"]   = 0,
  ["conditional_expression"]     = 0,
  ["match_expression"]           = 6,
}

---@type table<string, integer>
M.php_known_functions = {
  -- Language constructs
  ["isset"]       = 3,
  ["unset"]       = 3,
  ["empty"]       = 3,

  -- Type checks
  ["is_null"]     = 3,
  ["is_int"]      = 3,
  ["is_integer"]  = 3,
  ["is_long"]     = 3,
  ["is_float"]    = 3,
  ["is_double"]   = 3,
  ["is_string"]   = 3,
  ["is_bool"]     = 3,
  ["is_array"]    = 3,
  ["is_object"]   = 3,
  ["is_numeric"]  = 3,
  ["is_callable"] = 4,

  -- Comparison / identity
  ["in_array"]    = 6,
  ["array_key_exists"] = 4,

  -- String basics
  ["strlen"]      = 3,
  ["str_contains"]= 5,
  ["str_starts_with"] = 4,
  ["str_ends_with"]   = 4,
  ["strtolower"]  = 4,
  ["strtoupper"]  = 4,
  ["trim"]        = 4,

  -- Count
  ["count"]       = 3,
  ["sizeof"]      = 3,

  -- Array basics
  ["array_merge"] = 6,
  ["array_map"]   = 7,
  ["array_filter"]= 7,

  -- Regex: expensive
  ["preg_match"]      = 8,
  ["preg_match_all"]  = 9,
  ["preg_replace"]    = 9,
}

-- ══════════════════════════════════════════════
-- GO COST TABLES
-- ══════════════════════════════════════════════

---@type table<string, integer>
M.go_costs = {
  -- Literals
  ["true"]                    = 1,
  ["false"]                   = 1,
  ["nil"]                     = 1,
  ["int_literal"]             = 1,
  ["float_literal"]           = 1,
  ["rune_literal"]            = 1,
  ["raw_string_literal"]      = 1,
  ["interpreted_string_literal"] = 1,

  -- Identifiers
  ["identifier"]              = 2,

  -- Field access
  ["selector_expression"]     = 4,

  -- Index / slice
  ["index_expression"]        = 4,
  ["slice_expression"]        = 5,

  -- Type assertions / conversions
  ["type_assertion_expression"] = 5,
  ["type_conversion_expression"] = 4,

  -- Function/method calls
  ["call_expression"]         = 8,

  -- Composite literals
  ["composite_literal"]       = 10,

  -- Compound (scored recursively)
  ["unary_expression"]        = 0,
  ["binary_expression"]       = 0,
  ["parenthesized_expression"]= 0,
}

---@type table<string, integer>
M.go_known_functions = {
  -- Builtins (compiler intrinsics)
  ["len"]     = 2,
  ["cap"]     = 2,
  ["make"]    = 6,
  ["new"]     = 6,
  ["append"]  = 5,
  ["copy"]    = 5,
  ["delete"]  = 4,
  ["close"]   = 3,
  ["panic"]   = 1,

  -- strings
  ["strings.Contains"]    = 5,
  ["strings.HasPrefix"]   = 4,
  ["strings.HasSuffix"]   = 4,
  ["strings.EqualFold"]   = 5,
  ["strings.Index"]       = 6,
  ["strings.Count"]       = 6,
  ["strings.ToLower"]     = 5,
  ["strings.ToUpper"]     = 5,
  ["strings.TrimSpace"]   = 4,
  ["strings.Split"]       = 7,
  ["strings.Join"]        = 7,
  ["strings.Replace"]     = 7,
  ["strings.ReplaceAll"]  = 7,

  -- strconv
  ["strconv.Itoa"]        = 5,
  ["strconv.Atoi"]        = 5,
  ["strconv.FormatInt"]   = 5,
  ["strconv.ParseInt"]    = 5,

  -- fmt (allocates)
  ["fmt.Sprintf"]         = 8,
  ["fmt.Errorf"]          = 8,

  -- Regex
  ["regexp.MatchString"]      = 10,
  ["regexp.MustCompile"]      = 12,
  [".MatchString"]            = 9,
  [".FindString"]             = 9,
  [".FindStringSubmatch"]     = 10,

  -- Reflection
  ["reflect.TypeOf"]      = 8,
  ["reflect.ValueOf"]     = 8,

  -- Encoding
  ["json.Marshal"]        = 12,
  ["json.Unmarshal"]      = 12,
  ["json.NewDecoder"]     = 10,
  ["json.NewEncoder"]     = 10,

  -- IO / network / filesystem
  ["os.Open"]             = 20,
  ["os.ReadFile"]         = 20,
  ["os.Stat"]             = 15,
  ["io.ReadAll"]          = 20,
  ["http.Get"]            = 25,
  ["http.Post"]           = 25,

  -- Database
  ["sql.Open"]            = 25,
  [".Query"]              = 20,
  [".QueryRow"]           = 20,
  [".Exec"]               = 20,
  [".Prepare"]            = 15,

  -- Sorting (mutates in place — impure)
  ["sort.Strings"]        = 8,
  ["sort.Ints"]           = 8,
  ["sort.Slice"]          = 9,
  ["sort.Sort"]           = 9,

  -- Sync
  [".Lock"]               = 3,
  [".Unlock"]             = 3,
  [".RLock"]              = 3,
  [".RUnlock"]            = 3,

  -- Errors
  ["errors.New"]          = 4,
  ["errors.Is"]           = 4,
  ["errors.As"]           = 5,
  ["errors.Unwrap"]       = 3,
}

-- Go functions that mutate state / perform I/O — not safe to reorder to earlier positions.
local GO_IMPURE = {
  ["os.Open"] = true, ["os.ReadFile"] = true, ["os.Stat"] = true,
  ["io.ReadAll"] = true,
  ["http.Get"] = true, ["http.Post"] = true,
  ["sql.Open"] = true,
  [".Query"] = true, [".QueryRow"] = true, [".Exec"] = true, [".Prepare"] = true,
  ["sort.Strings"] = true, ["sort.Ints"] = true,
  ["sort.Slice"] = true, ["sort.Sort"] = true,
  [".Lock"] = true, [".Unlock"] = true, [".RLock"] = true, [".RUnlock"] = true,
  ["close"] = true, ["delete"] = true,
}

-- ══════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════

--- Get the text of a node using the parser's cached buffer view.
---@param node TSNode
---@param bufnr integer
---@return string
local function node_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

--- Resolve function/method name from a PHP call expression.
---@param node TSNode
---@param bufnr integer
---@return string?
local function resolve_php_call_name(node, bufnr)
  local name_node = node:named_child(0)
  if not name_node then return nil end

  if node:type() == "scoped_call_expression" then
    local scope  = node:child(0)
    local method = node:child(2)
    if scope and method then
      return node_text(scope, bufnr) .. "::" .. node_text(method, bufnr)
    end
  end

  return node_text(name_node, bufnr)
end

--- Resolve function/method name from a Go call_expression.
--- Returns full name (e.g. "strings.Contains") and optional method suffix (e.g. ".Contains").
---@param node TSNode
---@param bufnr integer
---@return string?, string?
local function resolve_go_call_name(node, bufnr)
  local func_node = node:named_child(0)
  if not func_node then return nil end

  local ntype = func_node:type()

  if ntype == "identifier" then
    return node_text(func_node, bufnr)
  end

  if ntype == "selector_expression" then
    local operand = func_node:named_child(0)
    local field   = func_node:named_child(1)
    if operand and field then
      local full = node_text(operand, bufnr) .. "." .. node_text(field, bufnr)
      return full, "." .. node_text(field, bufnr)
    end
  end

  return node_text(func_node, bufnr)
end

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
-- `!expr` costs the same as `expr` — the negation is free.
-- PHP also supports the `not` keyword.  Double negation (!!x) unwraps to x.

--- Unwrap a negation node and return the inner expression (or nil if not negation).
---@param node TSNode
---@param bufnr integer
---@return TSNode?
local function unwrap_negation(node, bufnr)
  local ntype = node:type()

  -- PHP: unary_op_expression with "!" or "not"
  if ntype == "unary_op_expression" then
    for i = 0, node:child_count() - 1 do
      local child = node:child(i)
      if child and not child:named() then
        local text = node_text(child, bufnr)
        if text == "!" or text == "not" then
          local inner = node:named_child(0)
          if inner then
            -- Handle double negation: !!x → x
            local deeper = unwrap_negation(inner, bufnr)
            return deeper or inner
          end
        end
      end
    end
  end

  -- Go: unary_expression with "!"
  if ntype == "unary_expression" then
    for i = 0, node:child_count() - 1 do
      local child = node:child(i)
      if child and not child:named() then
        local text = node_text(child, bufnr)
        if text == "!" then
          local inner = node:named_child(0)
          if inner then
            local deeper = unwrap_negation(inner, bufnr)
            return deeper or inner
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

--- Resolve a call expression's function name.
--- Returns the full name and (for Go selectors) the method suffix.
---@param node TSNode
---@param bufnr integer
---@param lang string
---@return string?, string?
function M.resolve_call_name(node, bufnr, lang)
  if lang == "php" then
    return resolve_php_call_name(node, bufnr)
  elseif lang == "go" then
    return resolve_go_call_name(node, bufnr)
  end
  return nil
end

-- ══════════════════════════════════════════════
-- PUBLIC: PURITY CHECK
-- ══════════════════════════════════════════════

--- Return true if fname is a known stdlib function that has no observable side effects
--- and is therefore safe to move to an earlier position in a condition chain.
---@param fname string
---@param lang string
---@return boolean
function M.is_known_pure(fname, lang)
  if lang == "php" then
    -- All listed PHP known functions are pure (pure stdlib operations)
    return M.php_known_functions[fname] ~= nil
  elseif lang == "go" then
    if GO_IMPURE[fname] then return false end
    return M.go_known_functions[fname] ~= nil
  end
  return false
end

-- ══════════════════════════════════════════════
-- SCORING ENGINE
-- ══════════════════════════════════════════════
-- Fallback cost for unknown expensive-pattern matches.
local EXPENSIVE_FALLBACK_COST = 20

--- Recursively compute the cost score for a Treesitter node.
---@param node TSNode
---@param bufnr integer
---@param lang string
---@return integer
function M.score(node, bufnr, lang)
  local ntype = node:type()

  -- Negation pass-through: !expr costs the same as expr
  local inner = unwrap_negation(node, bufnr)
  if inner then
    return M.score(inner, bufnr, lang)
  end

  -- PHP call resolution
  if lang == "php" then
    if ntype == "function_call_expression"
      or ntype == "scoped_call_expression"
      or ntype == "method_call_expression"
      or ntype == "nullsafe_method_call_expression" then

      local fname = resolve_php_call_name(node, bufnr)
      if fname then
        if config.options.cost_overrides[fname] then
          return config.options.cost_overrides[fname]
        end
        if M.php_known_functions[fname] then
          return M.php_known_functions[fname]
        end
        if is_expensive_call(fname) then
          return EXPENSIVE_FALLBACK_COST
        end
      end
    end
  end

  -- Go call resolution
  if lang == "go" then
    if ntype == "call_expression" then
      local full_name, method_name = resolve_go_call_name(node, bufnr)
      if full_name then
        if config.options.cost_overrides[full_name] then
          return config.options.cost_overrides[full_name]
        end
        if M.go_known_functions[full_name] then
          return M.go_known_functions[full_name]
        end
        if method_name and M.go_known_functions[method_name] then
          return M.go_known_functions[method_name]
        end
        if is_expensive_call(full_name) then
          return EXPENSIVE_FALLBACK_COST
        end
        if method_name and is_expensive_call(method_name) then
          return EXPENSIVE_FALLBACK_COST
        end
      end
    end
  end

  -- Base cost lookup
  local cost_table = lang == "go" and M.go_costs or M.php_costs
  local base = cost_table[ntype]

  if base and base > 0 then
    return base
  end

  -- Recursive: cost = max child cost
  local max_cost = 1
  for child in node:iter_children() do
    local child_cost = M.score(child, bufnr, lang)
    if child_cost > max_cost then
      max_cost = child_cost
    end
  end

  return max_cost
end

return M
