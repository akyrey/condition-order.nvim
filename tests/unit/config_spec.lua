-- Unit tests for configuration merging.

local config = require("condition-order.config")

describe("config.setup", function()
	after_each(function()
		-- Reset to defaults between tests.
		config.setup({})
	end)

	it("defaults are applied when setup() called with no args", function()
		config.setup()
		assert.are.same({ "php", "go" }, config.options.filetypes)
		assert.are.equal(2, config.options.threshold)
		assert.are.equal(300, config.options.analyze_debounce_ms)
		assert.are.same({}, config.options.assume_pure)
		assert.are.equal("condition-order: ignore", config.options.ignore_comment)
	end)

	it("user options override defaults", function()
		config.setup({ threshold = 5, assume_pure = { "MyService::find" } })
		assert.are.equal(5, config.options.threshold)
		assert.are.same({ "MyService::find" }, config.options.assume_pure)
		-- other defaults preserved
		assert.are.same({ "php", "go" }, config.options.filetypes)
	end)

	it("calling setup() twice resets to defaults + new opts", function()
		config.setup({ threshold = 10 })
		config.setup({ threshold = 3 })
		assert.are.equal(3, config.options.threshold)
	end)

	it("cost_overrides deep-merged", function()
		config.setup({ cost_overrides = { ["DB::table"] = 25 } })
		assert.are.equal(25, config.options.cost_overrides["DB::table"])
	end)
end)
