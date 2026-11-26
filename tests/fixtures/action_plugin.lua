local M = {}

function M.setup(opts)
	assert(opts.message == "configured")
	rex.action({
		name = "plugin_rex_fixture",
		title = "Plugin Rex Fixture",
		run = function()
			return opts.message
		end,
	})
end

return M
