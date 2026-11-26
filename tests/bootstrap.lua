-- End-to-end bootstrap tests with real Rex and Git, isolated config/data homes.
package.path = "./?.lua;./?/init.lua;" .. package.path
local git = require("plugin-rex.git")
local temporary = git.run({ "mktemp", "-d" })
local source = temporary .. "/source"
local bootstrap = assert(io.open("bootstrap.lua", "rb")):read("*a")
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

local function environment(name)
	local root = temporary .. "/" .. name
	return { XDG_DATA_HOME = root .. "/data space", XDG_CONFIG_HOME = root .. "/config space", REX_CONFIG = false }
end

local function install(env, input)
	local result, err = rex.exec(
		{ "rex", "do", "-", "source=" .. source },
		{ env = env, stdin = input or bootstrap, timeout = 30 }
	)
	assert(result, err)
	assert(result.ok, result.stderr)
	return result.stdout
end

local function check(env, path)
	local result, err = rex.exec({ "rex", "config", "check", path }, { env = env, timeout = 30 })
	assert(result, err)
	assert(result.ok and result.stdout:find("actions: 4", 1, true), result.stderr .. result.stdout)
end

local ok, err = pcall(function()
	git.run({ "mkdir", "-p", source .. "/plugin-rex" })
	for _, path in ipairs({ "plugin-rex.lua", "plugin-rex/spec.lua", "plugin-rex/git.lua" }) do
		git.run({ "cp", "--", path, source .. "/" .. path })
	end
	git.run({ "git", "init", "--initial-branch=main", source })
	git.run({ "git", "-C", source, "add", "." })
	git.run({
		"git",
		"-C",
		source,
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
		"Bootstrap fixture",
	})

	local fresh = environment("fresh")
	local config = fresh.XDG_CONFIG_HOME .. "/rex"
	test("stdin bootstrap installs the manager and creates a working fresh config", function()
		install(fresh)
		assert(read(config .. "/init.lua") == 'require("plugin-rex-setup")\n')
		assert(read(config .. "/plugin-rex-plugins.lua"):find("return {", 1, true))
		check(fresh, config .. "/init.lua")
	end)
	test("repeated bootstrap keeps plugin lists, loader, config and Git HEAD", function()
		local plugins = read(config .. "/plugin-rex-plugins.lua") .. "\n-- user's plugin choices\n"
		local loader = read(config .. "/plugin-rex-setup.lua") .. "\n-- user's options\n"
		write(config .. "/plugin-rex-plugins.lua", plugins)
		write(config .. "/plugin-rex-setup.lua", loader)
		local head = git.head({ dir = fresh.XDG_DATA_HOME .. "/rex/plugin-rex" })
		install(fresh)
		assert(read(config .. "/plugin-rex-plugins.lua") == plugins)
		assert(read(config .. "/plugin-rex-setup.lua") == loader)
		assert(git.head({ dir = fresh.XDG_DATA_HOME .. "/rex/plugin-rex" }) == head)
		check(fresh, config .. "/init.lua")
	end)
	test("existing init.lua stays byte-for-byte intact and gets connection instructions", function()
		local env = environment("existing")
		local directory = env.XDG_CONFIG_HOME .. "/rex"
		git.run({ "mkdir", "-p", directory })
		local original = '-- my existing settings\nrex.bind("cmd+d", "pane.split")\n'
		write(directory .. "/init.lua", original)
		local output = install(env)
		assert(read(directory .. "/init.lua") == original)
		assert(output:find('require("plugin-rex-setup")', 1, true))
		write(directory .. "/init.lua", original .. '\nrequire("plugin-rex-setup")\n')
		check(env, directory .. "/init.lua")
	end)
	test("REX_CONFIG scaffolds beside a custom configuration path", function()
		local env = environment("custom")
		env.REX_CONFIG = temporary .. "/custom init/settings.lua"
		install(env)
		assert(read(env.REX_CONFIG) == 'require("plugin-rex-setup")\n')
		assert(git.exists(temporary .. "/custom init/plugin-rex-plugins.lua"))
		assert(not git.exists(env.XDG_CONFIG_HOME .. "/rex/init.lua"))
		check(env, env.REX_CONFIG)
	end)
	test("a broken config symlink is retained instead of creating its missing target", function()
		local env = environment("symlink")
		local directory = env.XDG_CONFIG_HOME .. "/rex"
		local target = temporary .. "/do-not-create.lua"
		git.run({ "mkdir", "-p", directory })
		git.run({ "ln", "-s", target, directory .. "/init.lua" })
		install(env)
		assert(not git.exists(target))
		assert(git.run({ "readlink", directory .. "/init.lua" }) == target)
	end)
	test("an incomplete existing checkout fails before configuration is written", function()
		local env = environment("incomplete")
		git.run({ "mkdir", "-p", env.XDG_DATA_HOME .. "/rex/plugin-rex" })
		local result =
			assert(rex.exec({ "rex", "do", "-", "source=" .. source }, { env = env, stdin = bootstrap, timeout = 30 }))
		assert(not result.ok and result.stderr:find("Incomplete Plugin Rex checkout", 1, true))
		assert(not git.exists(env.XDG_CONFIG_HOME .. "/rex/init.lua"))
	end)
end)

git.run({ "rm", "-rf", "--", temporary })
if not ok then
	error(err, 0)
end
print("Passed " .. count.total .. " bootstrap tests")
