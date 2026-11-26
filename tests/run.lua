-- Real Rex Lua 5.1, real Git, isolated temporary repositories; no network.
package.path = "./?.lua;./?/init.lua;" .. package.path
local git = require("plugin-rex.git")
local spec = require("plugin-rex.spec")
local manager = require("plugin-rex")
local temporary = git.run({ "mktemp", "-d" })
local count = { total = 0 }

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = file:read("*a")
	file:close()
	return content
end

local function test(name, fn)
	local ok, err = pcall(fn)
	assert(ok, name .. ": " .. tostring(err))
	count.total = count.total + 1
	print("ok " .. count.total .. " - " .. name)
end

local function fails(fragment, fn)
	local ok, err = pcall(fn)
	assert(not ok and tostring(err):find(fragment, 1, true), "Expected '" .. fragment .. "', got " .. tostring(err))
end

local function commit(path)
	git.run({ "git", "-C", path, "add", "." })
	git.run({
		"git",
		"-C",
		path,
		"-c",
		"user.name=Plugin Rex Tests",
		"-c",
		"user.email=tests@example.invalid",
		"-c",
		"commit.gpgsign=false",
		"-c",
		"core.hooksPath=/dev/null",
		"commit",
		"-m",
		"fixture",
	})
	return git.run({ "git", "-C", path, "rev-parse", "HEAD" })
end

local function repository(name, content, layout)
	local path = temporary .. "/" .. name
	git.run({ "git", "init", "--initial-branch=main", path })
	git.run({ "mkdir", "-p", path .. (layout or "") })
	write(path .. (layout or "") .. "/" .. name .. ".lua", content)
	return path, commit(path)
end

local ok, err = pcall(function()
	test("normalizes GitHub shorthand and local paths", function()
		local plugins = spec.normalize({ "owner/tool", { dir = "~/plugin", name = "local-plugin" } }, temporary)
		assert(plugins[1].url == "https://github.com/owner/tool.git")
		assert(plugins[2].local_plugin and plugins[2].dir:sub(1, 1) == "/")
		assert(spec.normalize({ "owner/tool.git" }, temporary)[1].url == "https://github.com/owner/tool.git")
	end)
	test("rejects duplicate names, unsafe paths and unsupported fields", function()
		fails("Duplicate", function()
			spec.normalize({ "a/tool", "b/tool" }, temporary)
		end)
		fails("Invalid plugin name", function()
			spec.normalize({ { "a/tool", name = ".." } }, temporary)
		end)
		fails("Unsupported", function()
			spec.normalize({ { "a/tool", build = "make" } }, temporary)
		end)
		fails("delimiter", function()
			spec.path("/tmp/a;b")
		end)
	end)
	test("validates dependency references and cycles", function()
		fails("Unknown", function()
			spec.normalize({ { "a/tool", dependencies = { "absent" } } }, temporary)
		end)
		fails("Dependency cycle", function()
			spec.normalize({ { "a/one", dependencies = { "two" } }, { "a/two", dependencies = { "one" } } }, temporary)
		end)
		local cyclic = { "a/loop" }
		cyclic.dependencies = { cyclic }
		fails("Cyclic dependency", function()
			spec.normalize({ cyclic }, temporary)
		end)
	end)
	test("disabled specs do not introduce dependencies", function()
		local plugins = spec.normalize({
			{
				"a/tool",
				enabled = function()
					return false
				end,
				dependencies = { "missing" },
			},
		}, temporary)
		assert(#plugins == 0)
	end)

	local eager, initial = repository(
		"fixture_eager",
		[[
local M = {}
function M.setup(opts)
  assert(_G.plugin_rex_initialized == 4)
  assert(_G.plugin_rex_dependency)
  _G.plugin_rex_value = opts.value
end
return M
]]
	)
	local dependency =
		repository("fixture_dependency", "return { setup = function() _G.plugin_rex_dependency = true end }")
	local lazy = repository(
		"fixture_lazy",
		[[
return { setup = function(opts)
  _G.plugin_rex_lazy = (_G.plugin_rex_lazy or 0) + 1
  assert(opts.value == 7)
end }
]],
		"/lua"
	)
	local event = repository("fixture_event", "return { setup = function() _G.plugin_rex_event = true end }")
	local library = temporary .. "/local library"
	git.run({ "mkdir", "-p", library .. "/lua/fixture_library" })
	write(library .. "/lua/fixture_library/init.lua", "return { value = 13 }")
	local root, lockfile = temporary .. "/plugins", temporary .. "/config/lock.json"
	local handlers = {}
	local original_on = rex.on
	rex.on = function(name, callback)
		handlers[name] = callback
	end
	local function init()
		_G.plugin_rex_initialized = (_G.plugin_rex_initialized or 0) + 1
	end

	test("installs plugins, runs all init hooks, then dependencies and config", function()
		manager.setup({
			{
				url = eager,
				opts = { value = 42 },
				init = init,
				dependencies = {
					{ url = dependency, opts = {}, init = init },
				},
			},
			{
				url = lazy,
				lazy = true,
				opts = function(_, opts)
					opts.value = 7
				end,
				init = init,
				pin = true,
			},
			{ url = event, event = "terminal.bell", opts = {}, init = init },
			{ dir = library, name = "fixture_library", lazy = true },
		}, { root = root, lockfile = lockfile })
		rex.on = original_on
		assert(_G.plugin_rex_value == 42)
		assert(not _G.plugin_rex_lazy and not _G.plugin_rex_event)
		local lock = assert(rex.json.decode(read(lockfile)))
		assert(lock.plugins.fixture_eager.commit == initial)
		assert(lock.plugins.fixture_lazy and lock.version == 1)
	end)
	test("require loads and configures a lazy plugin exactly once", function()
		local module = require("fixture_lazy")
		assert(type(module.setup) == "function" and _G.plugin_rex_lazy == 1)
		assert(require("fixture_lazy") == module)
		manager.load("fixture_lazy")
		assert(_G.plugin_rex_lazy == 1)
	end)
	test("status reports eager, dependency and lazy state", function()
		local status = manager.status()
		assert(#status == 5 and status[1].loaded and status[2].loaded and status[3].loaded)
		assert(status[3].pin and not status[4].loaded)
		assert(status[5].local_plugin and not status[5].loaded)
	end)
	test("palette actions return operation results without prompts", function()
		local result, invoke_err = rex.invoke("plugin_rex_status", { json = true })
		assert(result and #result == 5, invoke_err)
	end)
	test("event callbacks load their plugin exactly once", function()
		assert(not _G.plugin_rex_event)
		handlers["terminal.bell"]({}, {})
		assert(_G.plugin_rex_event and manager.status()[4].loaded)
		handlers["terminal.bell"]({}, {})
	end)
	test("require loads local libraries with lua/module/init.lua and no setup", function()
		local module = require("fixture_library")
		assert(module.value == 13 and manager.status()[5].loaded)
		assert(require("fixture_library") == module)
	end)
	test("rejects a second setup", function()
		fails("already configured", function()
			manager.setup({})
		end)
	end)
	test("coordinates writers with an exclusive filesystem lock", function()
		git.run({ "mkdir", root .. ".lock" })
		fails("Cannot acquire", manager.install)
		git.run({ "rmdir", root .. ".lock" })
	end)

	write(eager .. "/new.txt", "next version")
	local updated = commit(eager)
	write(lazy .. "/new.txt", "pinned remote update")
	commit(lazy)
	local original_lock = read(lockfile)
	test("update advances clean plugins and preserves pinned commits", function()
		local before = git.head({ dir = root .. "/fixture_lazy" })
		manager.update()
		assert(git.head({ dir = root .. "/fixture_eager" }) == updated)
		assert(git.head({ dir = root .. "/fixture_lazy" }) == before)
	end)
	test("restore checks out the saved commit without rewriting the lockfile", function()
		write(lockfile, original_lock)
		manager.restore()
		assert(git.head({ dir = root .. "/fixture_eager" }) == initial)
		assert(read(lockfile) == original_lock)
	end)
	test("restore uses local objects without contacting the remote", function()
		git.checkout({ dir = root .. "/fixture_eager" }, updated)
		local source_hidden = eager .. "-offline"
		assert(os.rename(eager, source_hidden))
		local restored, restore_err = pcall(manager.restore)
		assert(os.rename(source_hidden, eager))
		assert(restored, restore_err)
		assert(git.head({ dir = root .. "/fixture_eager" }) == initial)
	end)
	test("install does not silently replace saved commits with current HEAD", function()
		git.checkout({ dir = root .. "/fixture_eager" }, updated)
		manager.install()
		assert(rex.json.decode(read(lockfile)).plugins.fixture_eager.commit == initial)
	end)
	test("dirty plugin updates preserve files and release the operation lock", function()
		write(root .. "/fixture_eager/dirty.txt", "keep me")
		fails("local changes", manager.update)
		assert(read(root .. "/fixture_eager/dirty.txt") == "keep me")
		assert(not git.exists(root .. ".lock"))
		assert(read(lockfile) == original_lock)
		assert(os.remove(root .. "/fixture_eager/dirty.txt"))
	end)
	test("local commits cannot be silently discarded by update", function()
		write(root .. "/fixture_eager/local.txt", "local commit")
		local local_commit = commit(root .. "/fixture_eager")
		fails("discard local commits", manager.update)
		assert(git.head({ dir = root .. "/fixture_eager" }) == local_commit)
		manager.restore()
		assert(git.head({ dir = root .. "/fixture_eager" }) == initial)
	end)
	test("fresh install uses locked versions", function()
		local plugin = { name = "fresh", url = eager, dir = temporary .. "/fresh" }
		git.install(plugin, { url = eager, commit = initial })
		assert(git.head(plugin) == initial)
	end)
	test("branch, tag and commit selectors resolve exact revisions", function()
		git.run({ "git", "-C", eager, "tag", "v1", initial })
		for key, value in pairs({ branch = "main", tag = "v1", commit = initial }) do
			local plugin = { name = key, url = eager, dir = temporary .. "/selector-" .. key, [key] = value }
			git.install(plugin)
			assert(git.head(plugin) == (key == "branch" and updated or initial))
		end
	end)
	test("local plugins remain outside Git management", function()
		local path = temporary .. "/local without git"
		git.run({ "mkdir", path })
		local plugin = { local_plugin = true, name = "local", dir = path }
		assert(git.install(plugin) == false)
		git.update(plugin)
		assert(not git.exists(path .. "/.git"))
	end)
	test("malformed lockfiles fail without overwriting them", function()
		write(lockfile, "not json")
		fails("Invalid lockfile", manager.install)
		assert(read(lockfile) == "not json" and not git.exists(root .. ".lock"))
		write(lockfile, original_lock)
	end)
	test("changed remote URLs are rejected", function()
		git.run({ "git", "-C", root .. "/fixture_eager", "remote", "set-url", "origin", dependency })
		fails("different origin", manager.update)
	end)
end)

git.run({ "rm", "-rf", "--", temporary })
if not ok then
	error(err, 0)
end
print("Passed " .. count.total .. " tests")
