# condition-order.nvim

A Neovim plugin that analyzes condition ordering in `if` statements for **PHP** and **Go**,
suggesting reorderings that short-circuit faster.

Think of it like a performance linter: put cheap checks before expensive ones,
and likely-to-fail checks before unlikely ones.

## Requirements

- Neovim >= 0.9
- Treesitter with parsers installed:
  - PHP: `:TSInstall php`
  - Go: `:TSInstall go`

## Installation

### lazy.nvim
```lua
{
  "akyrey/condition-order.nvim",
  ft = { "php", "go" },
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
⚡ Reorder conditions (cheapest first)
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

Same in Go:

```go
// Before:
if !user.IsAdmin() && enabled { ... }

// After:
if enabled && !user.IsAdmin() { ... }
```

### Cost Model

Each expression type is assigned a cost score. The principle is the same across
languages — how many CPU cycles does this burn before returning a boolean?

#### PHP Costs

| Expression Type          | Cost | Rationale                          |
|--------------------------|------|------------------------------------|
| Literal / boolean / null | 1    | Essentially free                   |
| Variable                 | 2    | Single memory lookup               |
| isset / empty / is_*     | 3    | Language construct, very cheap      |
| Class::CONST             | 3    | Resolved at compile time           |
| Array access `$a['k']`   | 4    | Hash lookup                        |
| Property access `->prop` | 5    | Object dereference                 |
| Built-in function        | 6-8  | Function call overhead             |
| Method call              | 10   | Dispatch + function overhead       |
| Object creation          | 12   | Allocation + constructor           |
| DB / IO calls            | 20   | Network/disk bound                 |

#### Go Costs

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

## Configuration

```lua
require("condition-order").setup({
  -- Filetypes to analyze
  filetypes = { "php", "go" },

  -- Minimum cost difference to trigger a warning
  threshold = 2,

  -- Auto-analyze on save
  auto_analyze = true,

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
  },

  -- Patterns considered "IO/expensive" (matched against function names)
  expensive_patterns = {
    -- PHP
    "query", "fetch", "find", "load",
    "file_get_contents", "curl",
    "Http::get", "Http::post",
    "DB::table", "DB::select",
    -- Go
    "ReadFile", "WriteFile", "ReadAll", "ReadDir",
    "ListenAndServe", "Dial", "LookupHost",
    ".Scan", ".Next",
  },
})
```

## Architecture

```
condition-order.nvim/
├── plugin/
│   └── condition-order.vim    # VimL loader (guards double-load)
└── lua/condition-order/
    ├── init.lua               # Setup, commands, autocommands
    ├── config.lua             # User options with defaults
    ├── cost.lua               # Cost model (PHP + Go tables, scoring engine)
    ├── analyzer.lua           # AST walker, chain flattening, diagnostics
    └── actions.lua            # Code action provider (lightbulb integration)
```

The data flow is: **Treesitter AST → analyzer flattens chains → cost scores each operand → diagnostics emitted → actions offer fixes**.

## Extending

### Adding a new language

1. Add a cost table in `cost.lua` (e.g., `M.python_costs`)
2. Add known function costs (e.g., `M.python_known_functions`)
3. Add the language's condition-context node types in `analyzer.lua`'s walker
4. Add function name resolution for the language's call expression shape
5. Add the filetype to your config

### Custom cost overrides for your codebase

If your project has specific expensive functions, add them via `cost_overrides`:

```lua
require("condition-order").setup({
  cost_overrides = {
    -- Your app's heavy hitters
    ["ElasticSearch::search"] = 25,
    ["Redis::pipeline"]       = 12,
    ["elasticsearch.Search"]  = 25,
  },
})
```
