local cost   = require("condition-order.cost")
local config = require("condition-order.config")
local util   = require("condition-order.util")

local M = {}

-- Analysis cache: { [bufnr] = { changedtick, lang, diagnostics, fixes } }
local cache = {}

-- ══════════════════════════════════════════════
-- OPERATOR HELPERS
-- ══════════════════════════════════════════════

--- Extract the logical operator text from a binary_expression node.
--- Returns nil for comparison operators (!=, <, >, etc.).
---@param node TSNode
---@param bufnr integer
---@return string?
local function get_logical_op(node, bufnr)
  for i = 0, node:child_count() - 1 do
    local child = node:child(i)
    if child and not child:named() then
      local text = util.node_text(child, bufnr)
      if text == "&&" or text == "||" or text == "and" or text == "or" then
        return text
      end
    end
  end
  return nil
end

-- ══════════════════════════════════════════════
-- SAFETY CHECKS (Phase 1)
-- ══════════════════════════════════════════════

--- Return true if the node (or any descendant) contains an impure call expression.
--- A call is considered pure if it is in the known stdlib tables (and not on the
--- impure list) or listed in config.assume_pure.
---@param node TSNode
---@param bufnr integer
---@param lang string
---@return boolean
local function contains_impure_call(node, bufnr, lang)
  local ntype = node:type()

  -- Object creation is always potentially impure (constructor side effects).
  if ntype == "object_creation_expression" then
    return true
  end

  local is_php_call = lang == "php" and (
    ntype == "function_call_expression" or
    ntype == "scoped_call_expression"   or
    ntype == "method_call_expression"   or
    ntype == "nullsafe_method_call_expression"
  )
  local is_go_call = lang == "go" and ntype == "call_expression"

  if is_php_call or is_go_call then
    local fname = cost.resolve_call_name(node, bufnr, lang)
    if fname then
      -- User-declared pure functions take priority.
      for _, pure in ipairs(config.options.assume_pure) do
        if fname == pure then return false end
      end
      if cost.is_known_pure(fname, lang) then return false end
    end
    return true  -- Unknown call → assume impure
  end

  for child in node:iter_children() do
    if contains_impure_call(child, bufnr, lang) then return true end
  end
  return false
end

--- Return true if the node (or any named descendant) is a comment node.
---@param node TSNode
---@return boolean
local function has_comment_node(node)
  if node:type():find("comment") then return true end
  for child in node:iter_children() do
    if has_comment_node(child) then return true end
  end
  return false
end

-- ──────────────────────────────────────────────
-- Null-guard detection
-- ──────────────────────────────────────────────
-- Common patterns: `$x !== null`, `x != nil`, `isset($x)`.
-- If an operand guards variable X, no subsequent operand that accesses
-- X via member/index access must be placed before the guard.

--- Extract the null-guarded variable name from an operand's text.
--- Returns nil if this operand is not a null/nil/isset guard.
---@param text string  trimmed operand text
---@return string?
local function guarded_var(text)
  -- PHP: isset($var) or !isset($var)
  local v = text:match("^!?isset%s*%(%s*(%$[%w_]+)%s*%)")
  if v then return v end

  -- PHP: $var !==|!=|===|== null/NULL/false
  v = text:match("^(%$[%w_]+)%s*[!=][!=]=?%s*[nN][uU][lL][lL]")
   or text:match("^(%$[%w_]+)%s*[!=][!=]=?%s*[fF][aA][lL][sS][eE]")
  if v then return v end

  -- PHP (reversed): null !== $var
  v = text:match("^[nN][uU][lL][lL]%s*[!=][!=]=?%s*(%$[%w_]+)")
  if v then return v end

  -- Go: identifier != nil  /  identifier == nil  /  nil != identifier
  v = text:match("^([%a_][%w_]*)%s*[!=]=?%s*nil%f[%W]")
  if v and v ~= "nil" and v ~= "true" and v ~= "false" then return v end

  v = text:match("^nil%s*[!=]=?%s*([%a_][%w_]*)%f[%W]")
  if v and v ~= "nil" then return v end

  return nil
end

--- Return true if op_text accesses var_name as the base of a member/index expression.
---@param op_text string
---@param var_name string
---@return boolean
local function accesses_var_as_base(op_text, var_name)
  local t = vim.trim(op_text)
  local e = vim.pesc(var_name)
  return t:match("^" .. e .. "%->") ~= nil  -- PHP property/method
      or t:match("^" .. e .. "%[")  ~= nil  -- PHP/Go index
      or t:match("^" .. e .. "%.")  ~= nil  -- Go field/method
end

-- ══════════════════════════════════════════════
-- CHAIN FLATTENING
-- ══════════════════════════════════════════════

---@class ConditionOperand
---@field node TSNode
---@field cost integer
---@field text string

--- Flatten a chain of same-operator binary expressions into a flat list.
---@param node TSNode
---@param operator string
---@param bufnr integer
---@param lang string
---@param operands ConditionOperand[]
local function flatten_chain(node, operator, bufnr, lang, operands)
  if node:type() ~= "binary_expression" then
    table.insert(operands, {
      node = node,
      cost = cost.score(node, bufnr, lang),
      text = util.node_text(node, bufnr),
    })
    return
  end

  local op = get_logical_op(node, bufnr)
  if op ~= operator then
    -- Different operator — treat entire subtree as one leaf operand.
    table.insert(operands, {
      node = node,
      cost = cost.score(node, bufnr, lang),
      text = util.node_text(node, bufnr),
    })
    return
  end

  local left  = node:named_child(0)
  local right = node:named_child(1)
  if left  then flatten_chain(left,  operator, bufnr, lang, operands) end
  if right then flatten_chain(right, operator, bufnr, lang, operands) end
end

-- ══════════════════════════════════════════════
-- CORE ANALYSIS
-- ══════════════════════════════════════════════

---@class ConditionFix
---@field range integer[]  {start_row, start_col, end_row, end_col}
---@field replacement string

--- Analyse a single binary_expression that is the top of a logical chain.
---@param node TSNode
---@param bufnr integer
---@param lang string
---@param diagnostics vim.Diagnostic[]
---@param fixes ConditionFix[]
local function analyze_binary(node, bufnr, lang, diagnostics, fixes)
  local operator = get_logical_op(node, bufnr)
  if not operator then return end

  -- Skip inner nodes of the same-operator chain (parent handles the full chain).
  local parent = node:parent()
  if parent and parent:type() == "binary_expression" then
    if get_logical_op(parent, bufnr) == operator then return end
  end

  -- Optional per-line ignore comment.
  local ignore = config.options.ignore_comment
  if ignore and ignore ~= "" then
    local sr0, _, er0, _ = node:range()
    local lines = vim.api.nvim_buf_get_lines(bufnr, sr0, er0 + 1, false)
    for _, line in ipairs(lines) do
      if line:find(ignore, 1, true) then return end
    end
  end

  -- Flatten the chain.
  local operands = {}
  flatten_chain(node, operator, bufnr, lang, operands)
  if #operands < 2 then return end

  -- Cheapest-first sort (stable: equal-cost items preserve original order).
  local sorted = {}
  for i, op in ipairs(operands) do
    sorted[i] = { idx = i, op = op }
  end
  table.sort(sorted, function(a, b)
    if a.op.cost ~= b.op.cost then return a.op.cost < b.op.cost end
    return a.idx < b.idx  -- preserve original order for ties
  end)
  local sorted_ops = {}
  for _, s in ipairs(sorted) do sorted_ops[#sorted_ops + 1] = s.op end

  -- Determine if the sorted order is meaningfully different from the original.
  local needs_reorder = false
  for i, s in ipairs(sorted) do
    if s.idx ~= i then
      if math.abs(operands[i].cost - s.op.cost) >= config.options.threshold then
        needs_reorder = true
        break
      end
    end
  end
  if not needs_reorder then return end

  -- ── Safety checks (Phase 1) ──────────────────

  local fix_blocked = false
  local fix_reason  = nil

  -- Check 1: multi-line operands (reconstruction would collapse formatting).
  for _, op in ipairs(operands) do
    local r0, _, r1, _ = op.node:range()
    if r0 ~= r1 then
      fix_blocked = true
      fix_reason  = "multi-line operand"
      break
    end
  end

  -- Check 2: comment nodes inside operands.
  if not fix_blocked then
    for _, op in ipairs(operands) do
      if has_comment_node(op.node) then
        fix_blocked = true
        fix_reason  = "comment inside operand"
        break
      end
    end
  end

  -- Check 3: purity — don't move impure calls to earlier positions.
  -- Moving calls LATER is fine (short-circuit may suppress them).
  -- Moving calls EARLIER can reorder side effects.
  if not fix_blocked then
    for new_pos, s in ipairs(sorted) do
      if s.idx > new_pos then  -- moving to an earlier position
        if contains_impure_call(s.op.node, bufnr, lang) then
          fix_blocked = true
          fix_reason  = "operand may have side effects"
          break
        end
      end
    end
  end

  -- Check 4: null-guard constraints.
  -- If operand[i] guards variable X, any operand[j>i] that accesses X must
  -- remain after the guard in the sorted output.
  if not fix_blocked then
    for guard_orig_idx, guard_op in ipairs(operands) do
      local gvar = guarded_var(guard_op.text)
      if gvar then
        -- Find guard's position in sorted_ops.
        local guard_sorted_pos = nil
        for si, sop in ipairs(sorted_ops) do
          if sop.node == guard_op.node then
            guard_sorted_pos = si
            break
          end
        end
        -- Check dependents.
        for dep_orig_idx = guard_orig_idx + 1, #operands do
          local dep_op = operands[dep_orig_idx]
          if accesses_var_as_base(dep_op.text, gvar) then
            for si, sop in ipairs(sorted_ops) do
              if sop.node == dep_op.node then
                if guard_sorted_pos and si < guard_sorted_pos then
                  fix_blocked = true
                  fix_reason  = "null-guard constraint on " .. gvar
                end
                break
              end
            end
          end
          if fix_blocked then break end
        end
      end
      if fix_blocked then break end
    end
  end

  -- ── Build diagnostic ───────────────────────

  local sr, sc, er, ec = node:range()

  -- For ||: note that "cheapest first" is a fallback heuristic; ideal is
  -- "most likely true first" which requires runtime profiling.
  local op_hint = (operator == "||" or operator == "or")
    and operator .. " (cheapest-first fallback; ideal: most-likely-true first)"
    or operator

  local msg
  if fix_blocked then
    msg = string.format(
      "Conditions out of order for faster %s — manual fix needed (%s)",
      op_hint, fix_reason
    )
  else
    local cur_first  = util.display(operands[1].text)
    local best_first = util.display(sorted_ops[1].text)
    msg = string.format(
      "Reorder for faster %s: move `%s` (cost %d) before `%s` (cost %d)",
      operator,
      best_first, sorted_ops[1].cost,
      cur_first,  operands[1].cost
    )
  end

  table.insert(diagnostics, {
    lnum     = sr,
    col      = sc,
    end_lnum = er,
    end_col  = ec,
    message  = msg,
    severity = config.options.severity,
    source   = "condition-order",
  })

  if not fix_blocked then
    local sep   = " " .. operator .. " "
    local texts = {}
    for _, op in ipairs(sorted_ops) do texts[#texts + 1] = op.text end
    table.insert(fixes, {
      range       = { sr, sc, er, ec },
      replacement = table.concat(texts, sep),
    })
  end
end

-- ══════════════════════════════════════════════
-- TOP-DOWN AST WALKER  (Phase 3: no per-node parent-climb)
-- ══════════════════════════════════════════════

-- Entering these nodes puts us inside a condition context.
local CONDITION_STARTERS = {
  if_statement             = true,
  elseif_clause            = true,
  while_statement          = true,
  do_statement             = true,
  conditional_expression   = true,  -- PHP ternary
  for_statement            = true,  -- Go
  expression_switch_statement = true, -- Go switch
}

-- Entering these nodes ends the condition context (they are body blocks).
local BODY_NODES = {
  compound_statement = true,  -- PHP { ... }
  declaration_list   = true,  -- Go block (some parsers)
  block              = true,  -- Go { ... }
}

-- Entering these nodes resets in_condition (function / class boundaries).
local FUNC_BOUNDARIES = {
  function_definition  = true,  -- PHP
  method_declaration   = true,  -- PHP + Go
  class_declaration    = true,  -- PHP
  function_declaration = true,  -- Go
  func_literal         = true,  -- Go closure
  program              = true,  -- PHP root
  source_file          = true,  -- Go root
}

---@param node TSNode
---@param bufnr integer
---@param lang string
---@param diagnostics vim.Diagnostic[]
---@param fixes ConditionFix[]
---@param in_condition boolean
local function walk(node, bufnr, lang, diagnostics, fixes, in_condition)
  local ntype = node:type()
  local next_cond = in_condition

  if FUNC_BOUNDARIES[ntype] then
    next_cond = false
  elseif CONDITION_STARTERS[ntype] then
    next_cond = true
  elseif BODY_NODES[ntype] then
    next_cond = false
  end

  if ntype == "binary_expression" and in_condition then
    analyze_binary(node, bufnr, lang, diagnostics, fixes)
  end

  for child in node:iter_children() do
    walk(child, bufnr, lang, diagnostics, fixes, next_cond)
  end
end

-- ══════════════════════════════════════════════
-- CACHE MANAGEMENT
-- ══════════════════════════════════════════════

-- Purge cache entry when a buffer is deleted.
vim.api.nvim_create_autocmd("BufDelete", {
  group = vim.api.nvim_create_augroup("ConditionOrderCache", { clear = true }),
  callback = function(ev) cache[ev.buf] = nil end,
})

--- Run (or return cached) analysis for a buffer.
---@param bufnr integer
---@param lang string
---@return vim.Diagnostic[], ConditionFix[]
local function run_analysis(bufnr, lang)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = cache[bufnr]
  if entry and entry.changedtick == tick and entry.lang == lang then
    return entry.diagnostics, entry.fixes
  end

  local diagnostics = {}
  local fixes       = {}

  -- Use for_each_tree to handle PHP injections (php_only) and other embedded langs.
  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then
    return diagnostics, fixes
  end

  parser:parse()

  parser:for_each_tree(function(tree, lang_tree)
    local tree_lang = lang_tree:lang()
    -- Map "php_only" (injected PHP inside HTML) to "php" for cost tables.
    local effective = (tree_lang == "php_only") and "php" or tree_lang
    -- Only analyse languages in our filetypes list.
    if not vim.tbl_contains(config.options.filetypes, effective) then return end

    local root = tree:root()
    walk(root, bufnr, effective, diagnostics, fixes, false)
  end)

  cache[bufnr] = {
    changedtick  = tick,
    lang         = lang,
    diagnostics  = diagnostics,
    fixes        = fixes,
  }
  return diagnostics, fixes
end

-- ══════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════

--- Analyse a buffer and return diagnostics.
---@param bufnr integer
---@param lang string
---@return vim.Diagnostic[]
function M.analyze_buffer(bufnr, lang)
  local diags, _ = run_analysis(bufnr, lang)
  return diags
end

--- Return fixable issues for a buffer (reuses cached analysis when possible).
---@param bufnr integer
---@param lang string
---@return ConditionFix[]
function M.get_fixes(bufnr, lang)
  local _, fixes = run_analysis(bufnr, lang)
  return fixes
end

return M
