-- Unit tests for the cost model.
-- Run via: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/unit/"

local config = require("condition-order.config")
local cost   = require("condition-order.cost")

config.setup({})  -- initialise defaults

describe("cost tables", function()
  it("PHP literals have cost 1", function()
    assert.are.equal(1, cost.php_costs["boolean"])
    assert.are.equal(1, cost.php_costs["null"])
    assert.are.equal(1, cost.php_costs["integer"])
  end)

  it("PHP method call is more expensive than variable", function()
    assert.is_true(cost.php_costs["method_call_expression"] > cost.php_costs["variable_name"])
  end)

  it("Go identifier is cheaper than call_expression", function()
    assert.is_true(cost.go_costs["identifier"] < cost.go_costs["call_expression"])
  end)
end)

describe("is_known_pure", function()
  it("PHP known functions are pure", function()
    assert.is_true(cost.is_known_pure("strlen",   "php"))
    assert.is_true(cost.is_known_pure("is_array", "php"))
    assert.is_true(cost.is_known_pure("isset",    "php"))
  end)

  it("PHP unknown functions are not pure", function()
    assert.is_false(cost.is_known_pure("myCustomFn", "php"))
  end)

  it("Go pure stdlib functions are pure", function()
    assert.is_true(cost.is_known_pure("len",             "go"))
    assert.is_true(cost.is_known_pure("strings.HasPrefix","go"))
    assert.is_true(cost.is_known_pure("errors.Is",       "go"))
  end)

  it("Go I/O functions are NOT pure", function()
    assert.is_false(cost.is_known_pure("os.Open",    "go"))
    assert.is_false(cost.is_known_pure("http.Get",   "go"))
    assert.is_false(cost.is_known_pure(".Query",     "go"))
    assert.is_false(cost.is_known_pure(".Lock",      "go"))
    assert.is_false(cost.is_known_pure("sort.Slice", "go"))
  end)
end)
