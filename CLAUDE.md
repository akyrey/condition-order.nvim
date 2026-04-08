# condition-order.nvim — Claude Code Guide

## Project overview

A Neovim plugin that walks Treesitter ASTs, scores operands of `&&`/`||`/`and`/`or`
chains with a static cost model, and emits diagnostics + code actions when a cheaper
operand should be evaluated before an expensive one to maximize short-circuiting.

Supported languages: PHP, Go, Python. Others can be added via `cost.register_language`.

## Directory layout

```
lua/condition-order/
  init.lua          Entry point: setup(), commands, autocmds, debounce timers
  config.lua        Defaults + setup() merge
  util.lua          node_text(), display() helpers
  cost.lua          Language registry + scoring engine (dispatcher)
  analyzer.lua      AST walker, flatten_chain, safety checks, diagnostics
  actions.lua       LSP code-action handler override + standalone command
  languages/
    php.lua         PHP spec (costs, known_functions, impure_functions, AST hints)
    go.lua          Go spec
    python.lua      Python spec
plugin/
  condition-order.lua  Double-load guard + auto-setup via vim.schedule
tests/
  minimal_init.lua    Plenary test harness initialiser
  unit/
    cost_spec.lua     Registry + cost table + purity tests
    config_spec.lua   Config merge tests
    analyzer_spec.lua PHP / Go / Python integration tests (require TS parsers)
  fixtures/
    php/{reorder,safe}.php
    go/{reorder,safe}.go
    python/{reorder,safe}.py
doc/
  condition-order.txt  Vimdoc (:help condition-order)
```

## Language spec interface

Every language module (`languages/*.lua`) must return a table with:

| Field                      | Type                         | Purpose                                    |
|----------------------------|------------------------------|--------------------------------------------|
| `filetype`                 | string                       | Neovim filetype (e.g. `"python"`)          |
| `ts_lang`                  | string                       | Treesitter language name                   |
| `costs`                    | `table<string,integer>`      | node_type → base cost (0 = recurse)        |
| `known_functions`          | `table<string,integer>`      | function_name → cost (pure stdlib)         |
| `impure_functions`         | `table<string,boolean>`      | function_name → true (blocks auto-fix)     |
| `condition_starters`       | `table<string,boolean>`      | node types where `in_condition` → true     |
| `body_nodes`               | `table<string,boolean>`      | node types where `in_condition` → false    |
| `func_boundaries`          | `table<string,boolean>`      | node types that reset `in_condition`       |
| `call_node_types`          | `table<string,boolean>`      | node types treated as call expressions     |
| `logical_binary_node_types`| `table<string,boolean>`      | `binary_expression` (PHP/Go) or `boolean_operator` (Python) |
| `negation_node_types`      | `string[]`                   | Unary negation node type names             |
| `negation_ops`             | `string[]`                   | Negation operator texts (`"!"`, `"not"`)   |
| `resolve_call_name`        | `(node,bufnr)→(name?,suffix?)` | Extract function/method name from call node |

Register with: `require("condition-order.cost").register_language(name, spec)`

Bundled languages are auto-registered at `cost.lua` module-load time.

## Key design decisions

- **`cost.lua` is a pure dispatcher** — it holds no language data itself. All
  cost tables and AST knowledge live in `languages/*.lua`.
- **Single-pass AST walk** — `analyzer.lua`'s `walk()` carries an `in_condition`
  boolean top-down. No per-node parent-climbing.
- **Analysis cache** keyed by `(bufnr, changedtick)` — `analyze_buffer` and
  `get_fixes` share the same cache entry; re-walking on every code-action call
  is avoided.
- **Safety-first auto-fix** — fixes are blocked (diagnostic still shown) for:
  impure calls moving earlier, null-guard violations, multi-line operands,
  comment nodes inside operands.
- **PHP injection** — handled via `parser:for_each_tree` with `"php_only"` → `"php"` mapping.
- **Python uses `boolean_operator`** (not `binary_expression`) for `and`/`or` —
  all spec-driven node-type lookups go through `spec.logical_binary_node_types`.

## Running tests

```bash
# Requires nvim-treesitter + php, go, python parsers pre-installed
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "set rtp+=~/.local/share/nvim/lazy/plenary.nvim" \
  -c "set rtp+=~/.local/share/nvim/lazy/nvim-treesitter" \
  -c "PlenaryBustedDirectory tests/unit/ {minimal_init='tests/minimal_init.lua'}" \
  -c "qa!"
```

CI runs on Neovim v0.9.5, v0.10.3, and nightly (see `.github/workflows/ci.yml`).

## Adding a new language (checklist)

1. Create `lua/condition-order/languages/<name>.lua` implementing the spec interface above.
2. Add `M.register_language("<name>", require("condition-order.languages.<name>"))` to `cost.lua`.
3. Add `"<name>"` to the `filetypes` default in `config.lua`.
4. Add TS parser installation to `.github/workflows/ci.yml` (`TSInstallSync ... <name>`).
5. Add `tests/fixtures/<name>/reorder.<ext>` and `safe.<ext>`.
6. Add a `describe("<Name> analyzer", ...)` block in `tests/unit/analyzer_spec.lua`.
7. Update `README.md` cost table section and the `ft = { ... }` lazy.nvim snippet.

## Common gotchas

- `cost.score(node, bufnr, lang)` — `lang` is the **effective** treesitter language
  (e.g. `"php"` not `"php_only"`). Always use the mapped value from `for_each_tree`.
- `get_logical_op` looks for operator text among **unnamed** children. Works for
  PHP/Go `binary_expression` and Python `boolean_operator`.
- `flatten_chain` uses `spec.logical_binary_node_types` to detect chain nodes;
  all other nodes are treated as leaf operands.
- `analyze_binary` skips inner nodes of the same-operator chain by checking the
  parent node type against `spec.logical_binary_node_types`.
- The LSP code-action handler override in `actions.lua` is guarded by `_registered`
  to prevent double-wrapping on repeated `setup()` calls.
