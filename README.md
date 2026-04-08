# condition-order.nvim

A Neovim plugin that analyzes condition ordering in `if` statements and emits
diagnostics when a cheaper check should be evaluated before an expensive one,
enabling the short-circuit operator (`&&` / `||` / `and` / `or`) to skip work.

Supported languages: **PHP**, **Go**, **Python** — with a simple language-module
API for adding more.

## Requirements

- Neovim >= 0.9
- nvim-treesitter with parsers for the languages you use:
  - PHP: `:TSInstall php`
  - Go: `:TSInstall go`
  - Python: `:TSInstall python`

## Installation

### lazy.nvim
```lua
{
  "akyrey/condition-order.nvim",
  ft = { "php", "go", "python" },
  opts = {},
}
```

### packer.nvim
```lua
use {
  "akyrey/condition-order.nvim",
  config = function()
    require("condition-order").setup()
  end,
}
```

## Usage

The plugin runs automatically on `BufWritePost` and `BufReadPost` for supported
filetypes. Diagnostics appear inline (like any LSP warning).

### Commands

| Command                    | Description                                    |
|----------------------------|------------------------------------------------|
| `:ConditionOrderAnalyze`   | Run analysis on the current buffer             |
| `:ConditionOrderFix`       | Auto-fix all condition ordering in buffer      |
| `:ConditionOrderToggle`    | Enable/disable the plugin                      |
| `:ConditionOrderActions`   | Show code actions at cursor (standalone mode)  |

### Code Actions (Lightbulb Menu)

When you trigger `vim.lsp.buf.code_action()` (typically `<leader>ca`), condition-order
fixes appear alongside your LSP actions:

```
⚡ Reorder conditions on line 12 (cheapest first)
⚡ Reorder ALL conditions in buffer (3 fixes)
```

This works even without an LSP server via `:ConditionOrderActions`.

### Negation Awareness

The plugin correctly sees through negations. `!$user->isAdmin()` costs the same
as `$user->isAdmin()` — the `!` is free, the method call is what's expensive.

```php
// Before (plugin warns):
if (!$user->isAdmin() && $isEnabled) { ... }

// After (plugin suggests):
if ($isEnabled && !$user->isAdmin()) { ... }
```

Same in Go and Python (`not` is also treated as free):

```go
// Go — before:
if !user.IsAdmin() && enabled { ... }
// After:
if enabled && !user.IsAdmin() { ... }
```

```python
# Python — before:
if not re.match(r"admin", name) and is_enabled: ...
# After:
if is_enabled and not re.match(r"admin", name): ...
```

### Safety Guarantees

Auto-fixes are **blocked** (a diagnostic is still shown) when:

- An operand **contains a call with observable side effects** (e.g. `createUser()`,
  `open(...)`, `http.Get(...)`) — moving it earlier would change program behavior.
- A **null / nil / None guard** would be moved after an expression that depends on it
  (e.g. `$obj !== null && $obj->name` must not become `$obj->name && $obj !== null`).
- An operand **spans multiple lines** — the formatter would collapse them.
- An operand **contains a comment** — the comment would be lost.

You can opt a specific condition out with an inline comment:

```php
if ($user->isAdmin() && $isEnabled) { } // condition-order: ignore
```

```python
if expensive_check() and flag:  # condition-order: ignore
    pass
```

### Opt-out Per Buffer

```lua
vim.b.condition_order_disable = true  -- disables analysis for this buffer
```

### Statusline Integration

```lua
-- lualine example
require("lualine").setup({
  sections = {
    lualine_x = {
      function()
        local n = require("condition-order").count()
        return n > 0 and ("⚡ " .. n) or ""
      end,
    },
  },
})
```

## Cost Model

Each expression type is assigned a cost score (how many CPU cycles does this
burn before returning a boolean?). The principle is the same across languages.

### PHP

| Expression Type          | Cost | Rationale                          |
|--------------------------|------|------------------------------------|
| Literal / boolean / null | 1    | Essentially free                   |
| Variable                 | 2    | Single memory lookup               |
| isset / empty / is_*     | 3    | Language construct, very cheap     |
| Class::CONST             | 3    | Resolved at compile time           |
| Array access `$a['k']`   | 4    | Hash lookup                        |
| Property access `->prop` | 5    | Object dereference                 |
| Built-in function        | 6-8  | Function call overhead             |
| Method call              | 10   | Dispatch + function overhead       |
| Object creation          | 12   | Allocation + constructor           |
| DB / IO calls            | 20   | Network/disk bound                 |

### Go

| Expression Type              | Cost | Rationale                        |
|------------------------------|------|----------------------------------|
| Literal / true / false / nil | 1    | Essentially free                 |
| Identifier (variable)        | 2    | Register/stack lookup            |
| len() / cap()                | 2    | Compiler intrinsic               |
| errors.Is / errors.New       | 4-5  | Cheap stdlib                     |
| Field access `.Field`        | 4    | Pointer chase                    |
| strings.HasPrefix            | 4    | Simple comparison                |
| strings.Contains             | 5    | Linear scan                      |
| call_expression (generic)    | 8    | Function call overhead           |
| fmt.Sprintf                  | 8    | Allocates                        |
| regexp.MatchString           | 10   | Regex engine                     |
| json.Marshal / Unmarshal     | 12   | Reflection + allocation          |
| os.Stat                      | 15   | Syscall                          |
| os.Open / os.ReadFile        | 20   | Filesystem IO                    |
| http.Get / sql queries       | 20-25| Network bound                    |

### Python

| Expression Type              | Cost | Rationale                        |
|------------------------------|------|----------------------------------|
| Literal / True / False / None| 1    | Essentially free                 |
| Identifier (variable)        | 2    | Name lookup                      |
| len() / bool() / id()        | 2-3  | Builtin, minimal overhead        |
| isinstance() / hasattr()     | 3-4  | Type introspection               |
| Attribute access `obj.attr`  | 4    | Pointer chase + descriptor       |
| Subscript `obj[key]`         | 5    | `__getitem__` call               |
| any() / all() / min() / max()| 5    | Iteration                        |
| call (generic)               | 8    | Function call overhead           |
| re.match / re.search         | 8    | Regex engine                     |
| os.path.exists               | 8    | Syscall                          |
| requests.get / .post         | ∞    | Network I/O — also blocks fix    |
| open / subprocess.run        | ∞    | I/O — also blocks fix            |

## Configuration

```lua
require("condition-order").setup({
  -- Filetypes to analyze (default: php, go, python)
  filetypes = { "php", "go", "python" },

  -- Minimum cost difference to trigger a warning
  threshold = 2,

  -- Auto-analyze on save / open
  auto_analyze = true,

  -- Milliseconds to debounce autocmd-triggered analysis
  analyze_debounce_ms = 300,

  -- Skip analysis when buffer exceeds this many bytes (nil = no limit)
  max_buffer_bytes = nil,

  -- Diagnostic severity (HINT, INFO, WARN, ERROR)
  severity = vim.diagnostic.severity.HINT,

  -- Register as code action source (lightbulb menu)
  register_code_actions = true,

  -- Custom cost overrides (function name -> cost)
  cost_overrides = {
    -- PHP examples
    ["DB::table"]     = 20,
    ["Cache::get"]    = 15,
    -- Go examples
    ["mydb.Query"]    = 20,
    ["cache.Get"]     = 12,
    -- Python examples
    ["my_app.db.query"] = 20,
  },

  -- Patterns considered "IO/expensive" (matched against function names)
  expensive_patterns = {
    "query", "fetch", "find", "load",
    "file_get_contents", "curl",
    "Http::get", "Http::post", "DB::table",
    "ReadFile", "WriteFile", "ReadAll", "ReadDir",
    "ListenAndServe", ".Scan", ".Next",
  },

  -- Function names to treat as side-effect-free even if not in the stdlib list.
  -- Useful for your application's pure helper functions.
  assume_pure = {
    -- PHP: "Cache::get", "myhelper.IsPending"
    -- Python: "myapp.utils.is_valid"
  },

  -- Comment text that suppresses a diagnostic on the same line(s).
  -- Set to "" to disable.
  ignore_comment = "condition-order: ignore",
})
```

## Architecture

```
condition-order.nvim/
├── plugin/
│   └── condition-order.lua        # Loader guard + auto-setup
└── lua/condition-order/
    ├── init.lua                   # Setup, commands, autocommands
    ├── config.lua                 # User options with defaults
    ├── util.lua                   # Shared helpers (node_text, display)
    ├── cost.lua                   # Language registry + scoring engine
    ├── analyzer.lua               # AST walker, chain flattening, diagnostics
    ├── actions.lua                # Code action provider (lightbulb integration)
    └── languages/
        ├── php.lua                # PHP cost table + AST hints + call resolver
        ├── go.lua                 # Go cost table + AST hints + call resolver
        └── python.lua             # Python cost table + AST hints + call resolver
```

Data flow: **Treesitter AST → analyzer flattens chains → cost engine scores each
operand → diagnostics emitted → actions offer fixes**.

## Extending — Adding a New Language

Create `lua/condition-order/languages/<name>.lua` returning a spec table, then
register it before or during `setup()`:

```lua
-- lua/condition-order/languages/ruby.lua
local M = {}

M.filetype = "ruby"
M.ts_lang  = "ruby"

M.costs = {
  ["integer"] = 1, ["identifier"] = 2,
  ["call"] = 8, ["method_call"] = 10,
  -- ...
}
M.known_functions    = { ["nil?"] = 2, ["is_a?"] = 3 }
M.impure_functions   = { ["puts"] = true, ["system"] = true }
M.condition_starters = { if_node = true, while_modifier = true }
M.body_nodes         = { then_node = true, do_block = true }
M.func_boundaries    = { method_definition = true, program = true }
M.call_node_types    = { call = true, method_call = true }
M.logical_binary_node_types = { binary = true }
M.negation_node_types = { "unary" }
M.negation_ops        = { "!" }

function M.resolve_call_name(node, bufnr)
  -- ... language-specific call name extraction
  return vim.treesitter.get_node_text(node:named_child(0), bufnr), nil
end

return M
```

```lua
-- In your Neovim config, before or inside condition-order setup:
local cost = require("condition-order.cost")
cost.register_language("ruby", require("path.to.languages.ruby"))

require("condition-order").setup({
  filetypes = { "php", "go", "python", "ruby" },
})
```

### Custom cost overrides for your codebase

```lua
require("condition-order").setup({
  cost_overrides = {
    ["ElasticSearch::search"] = 25,
    ["Redis::pipeline"]       = 12,
    ["elasticsearch.Search"]  = 25,
  },
})
```
