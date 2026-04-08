-- Unit tests for the cost model.
-- Run via: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/unit/"

local config = require("condition-order.config")
local cost = require("condition-order.cost")

config.setup({}) -- initialise defaults

-- ── Language spec accessors ──────────────────────────────────────────────────

local php = cost.get_language("php")
local go = cost.get_language("go")
local python = cost.get_language("python")

describe("language registry", function()
	it("php spec is registered", function()
		assert.is_not_nil(php)
	end)

	it("go spec is registered", function()
		assert.is_not_nil(go)
	end)

	it("python spec is registered", function()
		assert.is_not_nil(python)
	end)

	it("register_language accepts a custom spec", function()
		cost.register_language("test_lang", {
			filetype = "test_lang",
			ts_lang = "test_lang",
			costs = { ["identifier"] = 5 },
			known_functions = {},
			impure_functions = {},
			condition_starters = {},
			body_nodes = {},
			func_boundaries = {},
			call_node_types = {},
			logical_binary_node_types = { binary_expression = true },
			negation_node_types = {},
			negation_ops = {},
			resolve_call_name = function()
				return nil, nil
			end,
		})
		assert.is_not_nil(cost.get_language("test_lang"))
	end)
end)

describe("cost tables", function()
	it("PHP literals have cost 1", function()
		assert.are.equal(1, php.costs["boolean"])
		assert.are.equal(1, php.costs["null"])
		assert.are.equal(1, php.costs["integer"])
	end)

	it("PHP method call is more expensive than variable", function()
		assert.is_true(php.costs["method_call_expression"] > php.costs["variable_name"])
	end)

	it("Go identifier is cheaper than call_expression", function()
		assert.is_true(go.costs["identifier"] < go.costs["call_expression"])
	end)

	it("Python call is more expensive than identifier", function()
		assert.is_true(python.costs["call"] > python.costs["identifier"])
	end)
end)

describe("is_known_pure", function()
	it("PHP known functions are pure", function()
		assert.is_true(cost.is_known_pure("strlen", "php"))
		assert.is_true(cost.is_known_pure("is_array", "php"))
		assert.is_true(cost.is_known_pure("isset", "php"))
	end)

	it("PHP unknown functions are not pure", function()
		assert.is_false(cost.is_known_pure("myCustomFn", "php"))
	end)

	it("Go pure stdlib functions are pure", function()
		assert.is_true(cost.is_known_pure("len", "go"))
		assert.is_true(cost.is_known_pure("strings.HasPrefix", "go"))
		assert.is_true(cost.is_known_pure("errors.Is", "go"))
	end)

	it("Go I/O functions are NOT pure", function()
		assert.is_false(cost.is_known_pure("os.Open", "go"))
		assert.is_false(cost.is_known_pure("http.Get", "go"))
		assert.is_false(cost.is_known_pure(".Query", "go"))
		assert.is_false(cost.is_known_pure(".Lock", "go"))
		assert.is_false(cost.is_known_pure("sort.Slice", "go"))
	end)

	it("Python pure builtins are pure", function()
		assert.is_true(cost.is_known_pure("len", "python"))
		assert.is_true(cost.is_known_pure("isinstance", "python"))
		assert.is_true(cost.is_known_pure("any", "python"))
	end)

	it("Python I/O and mutation functions are NOT pure", function()
		assert.is_false(cost.is_known_pure("open", "python"))
		assert.is_false(cost.is_known_pure("requests.get", "python"))
		assert.is_false(cost.is_known_pure("random.shuffle", "python"))
		assert.is_false(cost.is_known_pure(".sort", "python"))
		assert.is_false(cost.is_known_pure("subprocess.run", "python"))
	end)

	it("unknown language returns false", function()
		assert.is_false(cost.is_known_pure("len", "cobol"))
	end)
end)

describe("language spec shape", function()
	it("PHP has expected AST node sets", function()
		assert.is_true(php.condition_starters["if_statement"])
		assert.is_true(php.body_nodes["compound_statement"])
		assert.is_true(php.func_boundaries["function_definition"])
		assert.is_true(php.call_node_types["function_call_expression"])
		assert.is_true(php.logical_binary_node_types["binary_expression"])
	end)

	it("Go has expected AST node sets", function()
		assert.is_true(go.condition_starters["if_statement"])
		assert.is_true(go.condition_starters["for_statement"])
		assert.is_true(go.body_nodes["block"])
		assert.is_true(go.call_node_types["call_expression"])
	end)

	it("Python uses boolean_operator for logical binary", function()
		assert.is_true(python.logical_binary_node_types["boolean_operator"])
		assert.is_nil(python.logical_binary_node_types["binary_expression"])
	end)

	it("Python uses not_operator for negation", function()
		assert.are.equal("not_operator", python.negation_node_types[1])
		assert.are.equal("not", python.negation_ops[1])
	end)
end)
