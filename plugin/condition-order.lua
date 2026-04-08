-- Guard against double-loading.
if vim.g.loaded_condition_order then
  return
end
vim.g.loaded_condition_order = true

-- Track whether the user has called setup() explicitly.
-- When lazy.nvim loads the plugin with `opts = {}`, it calls setup() for us.
-- When loaded manually without opts, we auto-setup with defaults here.
vim.schedule(function()
  -- `vim.g.condition_order_setup_called` is set in init.lua's setup().
  if not vim.g.condition_order_setup_called then
    require("condition-order").setup()
  end
end)
