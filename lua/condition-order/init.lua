local M = {}

local analyzer = require("condition-order.analyzer")
local config   = require("condition-order.config")

local NAMESPACE = vim.api.nvim_create_namespace("condition_order")

-- Use vim.uv (preferred in Neovim 0.10+) with fallback to vim.loop.
local uv = vim.uv or vim.loop

---@type boolean
M._enabled = true

-- Per-buffer debounce timers.
local _timers = {}

--- Cancel and discard any pending debounce timer for bufnr.
---@param bufnr integer
local function cancel_timer(bufnr)
  local t = _timers[bufnr]
  if t then
    t:stop()
    if not t:is_closing() then t:close() end
    _timers[bufnr] = nil
  end
end

-- ══════════════════════════════════════════════
-- CORE: analyze / fix / toggle
-- ══════════════════════════════════════════════

--- Run analysis on bufnr and publish diagnostics.
---@param bufnr? integer
function M.analyze(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M._enabled then
    vim.diagnostic.reset(NAMESPACE, bufnr)
    return
  end

  -- Per-buffer opt-out via `vim.b.condition_order_disable = true`.
  if vim.b[bufnr].condition_order_disable then
    vim.diagnostic.reset(NAMESPACE, bufnr)
    return
  end

  local ft = vim.bo[bufnr].filetype
  if not vim.tbl_contains(config.options.filetypes, ft) then return end

  local diagnostics = analyzer.analyze_buffer(bufnr, ft)
  vim.diagnostic.set(NAMESPACE, bufnr, diagnostics)
end

--- Auto-fix all condition-ordering issues in bufnr.
---@param bufnr? integer
function M.fix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype

  if not vim.tbl_contains(config.options.filetypes, ft) then
    vim.notify("condition-order: unsupported filetype: " .. ft, vim.log.levels.WARN)
    return
  end

  local fixes = analyzer.get_fixes(bufnr, ft)
  if #fixes == 0 then
    vim.notify("condition-order: no fixable issues found", vim.log.levels.INFO)
    return
  end

  -- Apply fixes bottom-up so earlier line numbers remain valid.
  table.sort(fixes, function(a, b) return a.range[1] > b.range[1] end)

  for _, fix in ipairs(fixes) do
    vim.api.nvim_buf_set_text(
      bufnr,
      fix.range[1], fix.range[2],
      fix.range[3], fix.range[4],
      vim.split(fix.replacement, "\n")
    )
  end

  vim.notify(
    string.format("condition-order: applied %d fix(es)", #fixes),
    vim.log.levels.INFO
  )

  M.analyze(bufnr)
end

--- Toggle the plugin globally on/off.
function M.toggle()
  M._enabled = not M._enabled
  if M._enabled then
    vim.notify("condition-order: enabled", vim.log.levels.INFO)
    M.analyze()
  else
    vim.notify("condition-order: disabled", vim.log.levels.INFO)
    vim.diagnostic.reset(NAMESPACE, vim.api.nvim_get_current_buf())
  end
end

--- Return the number of pending condition-order diagnostics in bufnr.
---@param bufnr? integer
---@return integer
function M.count(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return #vim.diagnostic.get(bufnr, { namespace = NAMESPACE })
end

--- Return the diagnostic namespace (useful for other plugins / statuslines).
---@return integer
function M.get_namespace()
  return NAMESPACE
end

-- ══════════════════════════════════════════════
-- DEBOUNCED AUTO-ANALYZE
-- ══════════════════════════════════════════════

--- Schedule a debounced analysis for bufnr.
---@param bufnr integer
local function schedule_analyze(bufnr)
  cancel_timer(bufnr)

  local delay = config.options.analyze_debounce_ms
  local t = uv.new_timer()
  _timers[bufnr] = t

  t:start(delay, 0, vim.schedule_wrap(function()
    _timers[bufnr] = nil
    if not t:is_closing() then t:close() end

    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    -- Size cap: skip huge buffers.
    local max_bytes = config.options.max_buffer_bytes
    if max_bytes then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local ok, size = pcall(vim.api.nvim_buf_get_offset, bufnr, line_count)
      if ok and size > max_bytes then return end
    end

    M.analyze(bufnr)
  end))
end

-- ══════════════════════════════════════════════
-- SETUP
-- ══════════════════════════════════════════════

---@param opts? table
function M.setup(opts)
  vim.g.condition_order_setup_called = true
  config.setup(opts)

  -- User commands.
  vim.api.nvim_create_user_command("ConditionOrderAnalyze", function()
    M.analyze()
  end, { desc = "Analyze condition ordering in current buffer" })

  vim.api.nvim_create_user_command("ConditionOrderFix", function()
    M.fix()
  end, { desc = "Auto-fix condition ordering in current buffer" })

  vim.api.nvim_create_user_command("ConditionOrderToggle", function()
    M.toggle()
  end, { desc = "Toggle condition-order analysis on/off" })

  -- Code action integration.
  if config.options.register_code_actions then
    local actions = require("condition-order.actions")
    actions.register()
    actions.register_standalone()
  end

  -- Autocommands for automatic analysis.
  if config.options.auto_analyze then
    local group = vim.api.nvim_create_augroup("ConditionOrder", { clear = true })

    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
      group    = group,
      pattern  = "*",
      callback = function(ev)
        -- Let Treesitter finish parsing before we walk the AST.
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            schedule_analyze(ev.buf)
          end
        end, 100)
      end,
    })

    -- Clean up timers on buffer delete.
    vim.api.nvim_create_autocmd("BufDelete", {
      group    = group,
      callback = function(ev) cancel_timer(ev.buf) end,
    })
  end
end

return M
