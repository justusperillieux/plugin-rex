-- Check eager plugins can register real Rex actions while configuration loads.
package.path = "./?.lua;./?/init.lua;" .. package.path
local result = assert(rex.exec({ "pwd", "-P" }, { timeout = 5 }))
assert(result.ok, result.stderr)
local cwd = result.stdout:gsub("\n$", "")
local manager = require("plugin-rex")
local ok, event_err = pcall(manager.setup, {
	{ dir = cwd .. "/tests/fixtures", event = "terminal.bell" },
}, { install_missing = false })
assert(not ok and tostring(event_err):find("init.lua receives no events", 1, true))
manager.setup({
	{ dir = cwd .. "/tests/fixtures", main = "action_plugin", opts = { message = "configured" } },
	{ url = "https://example.invalid/missing.git", opts = {} },
	{
		dir = cwd .. "/tests/fixtures",
		name = "waiting-for-dependency",
		dependencies = { "missing" },
		config = function()
			error("A plugin with a missing dependency must remain unloaded")
		end,
	},
}, { root = cwd .. "/tests/not-installed", install_missing = false })
assert(not manager.status()[2].installed and not manager.status()[2].loaded)
assert(manager.status()[3].installed and not manager.status()[3].loaded)
