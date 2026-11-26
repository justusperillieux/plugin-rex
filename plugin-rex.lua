-- Pure Lua 5.1 plugin management for Rex.
local spec = require("plugin-rex.spec")
local git = require("plugin-rex.git")
local M = {}
local state

local function configured()
	return assert(state, "Call require('plugin-rex').setup first")
end

local function mkdir(path)
	git.run({ "mkdir", "-p", "--", path })
end

local function read_lock()
	if not git.exists(state.lockfile) then
		return { version = 1, plugins = {} }
	end
	local file = assert(io.open(state.lockfile, "rb"))
	local content = file:read("*a")
	file:close()
	local lock, err = rex.json.decode(content)
	assert(lock, "Invalid lockfile: " .. tostring(err))
	assert(type(lock) == "table" and lock.version == 1 and type(lock.plugins) == "table", "Unsupported lockfile format")
	for name, entry in pairs(lock.plugins) do
		assert(
			type(name) == "string"
				and type(entry) == "table"
				and type(entry.url) == "string"
				and type(entry.commit) == "string"
				and #entry.commit == 40
				and entry.commit:match("^%x+$"),
			"Invalid lockfile entry: " .. tostring(name)
		)
	end
	return lock
end

local function write_lock(lock)
	mkdir(state.lockfile:match("^(.+)/[^/]+$"))
	local encoded, err = rex.json.encode(lock, { indent = true })
	assert(encoded, err)
	local temporary = state.lockfile .. ".tmp"
	local file = assert(io.open(temporary, "wb"))
	local ok, write_err = file:write(encoded .. "\n")
	local closed, close_err = file:close()
	assert(ok, write_err)
	assert(closed, close_err)
	assert(os.rename(temporary, state.lockfile))
end

local function manage(operation)
	configured()
	assert(not state.busy, "A plugin operation is already running")
	mkdir(state.root)
	-- Coordinates separate config checks, scripts, and palette actions.
	local guard = state.root .. ".lock"
	local acquired, acquire_err = rex.exec({ "mkdir", "--", guard }, { timeout = 5 })
	assert(
		acquired and acquired.ok,
		"Cannot acquire "
			.. guard
			.. "; another manager may be running. If it crashed, remove this empty directory. "
			.. tostring(acquire_err or "")
	)
	state.busy = true
	local ok, result = pcall(function()
		local lock, results = read_lock(), {}
		for _, plugin in ipairs(state.plugins) do
			local entry = lock.plugins[plugin.name]
			if operation == "install" then
				git.install(plugin, entry)
			else
				git.update(plugin, entry, operation == "restore")
			end
			if not plugin.local_plugin and operation ~= "restore" then
				if operation == "update" or not entry then
					lock.plugins[plugin.name] = { url = plugin.url, commit = git.head(plugin) }
				end
			end
			results[#results + 1] = plugin.name
		end
		if operation ~= "restore" then
			write_lock(lock)
		end
		return results
	end)
	state.busy = false
	local released, release_err = rex.exec({ "rmdir", "--", guard }, { timeout = 5 })
	if not ok then
		error(result, 0)
	end
	assert(released and released.ok, release_err or "Cannot release " .. guard)
	return result
end

function M.install()
	return manage("install")
end
function M.update()
	return manage("update")
end
function M.restore()
	return manage("restore")
end

local function module_file(plugin, name)
	local relative = name:gsub("%.", "/")
	for _, pattern in ipairs({ "/?.lua", "/?/init.lua", "/lua/?.lua", "/lua/?/init.lua" }) do
		local path = plugin.dir .. pattern:gsub("%?", function()
			return relative
		end)
		local file = io.open(path, "rb")
		if file then
			file:close()
			return path
		end
	end
end

function M.load(name)
	local plugin = assert(configured().by_name[name], "Unknown plugin: " .. tostring(name))
	if plugin.loaded then
		return plugin
	end
	assert(not plugin.loading, "Recursive plugin load: " .. name)
	assert(
		not plugin.error,
		"Previous load failed for " .. name .. "; reload configuration: " .. tostring(plugin.error)
	)
	assert(
		git.exists(plugin.dir),
		"Plugin is not installed: " .. name .. "; run plugin_rex_install and reload configuration"
	)
	plugin.loading = true
	local ok, err = pcall(function()
		for _, dependency in ipairs(plugin.dependencies) do
			M.load(dependency)
		end
		package.path = plugin.dir
			.. "/?.lua;"
			.. plugin.dir
			.. "/?/init.lua;"
			.. plugin.dir
			.. "/lua/?.lua;"
			.. plugin.dir
			.. "/lua/?/init.lua;"
			.. package.path
		local opts = plugin.opts
		if type(opts) == "function" then
			local defaults = {}
			opts = opts(plugin, defaults) or defaults
		end
		opts = opts or {}
		assert(type(opts) == "table", "opts must return a table for " .. name)
		if type(plugin.config) == "function" then
			plugin.config(plugin, opts)
		elseif plugin.opts ~= nil or plugin.config == true then
			local module = require(plugin.main)
			assert(
				type(module) == "table" and type(module.setup) == "function",
				plugin.main .. " must export setup(opts)"
			)
			module.setup(opts)
		end
	end)
	plugin.loading = false
	if not ok then
		plugin.error = tostring(err)
		error("Loading " .. name .. ": " .. tostring(err), 0)
	end
	plugin.loaded = true
	return plugin
end

function M.status()
	configured()
	local results = {}
	for _, plugin in ipairs(state.plugins) do
		results[#results + 1] = {
			name = plugin.name,
			dir = plugin.dir,
			installed = git.exists(plugin.dir),
			loaded = plugin.loaded == true,
			local_plugin = plugin.local_plugin,
			pin = plugin.pin == true,
			error = plugin.error,
		}
	end
	return results
end

local function actions()
	for _, operation in ipairs({ "install", "update", "restore" }) do
		local method = operation
		rex.action({
			name = "plugin_rex_" .. method,
			title = "Plugin Rex: " .. method:sub(1, 1):upper() .. method:sub(2) .. " Plugins",
			category = "Plugin Rex",
			description = "Run " .. method .. "; reload Rex configuration afterward.",
			run = function()
				return { plugins = M[method](), message = "Reload Rex configuration to use installed versions." }
			end,
		})
	end
	rex.action({
		name = "plugin_rex_status",
		title = "Plugin Rex: Plugin Status…",
		category = "Plugin Rex",
		run = function(_, args)
			local status = M.status()
			if args and args.json then
				return status
			end
			local items = {}
			for _, item in ipairs(status) do
				items[#items + 1] = {
					id = item.name,
					title = item.name,
					subtitle = (
						item.error or (not item.installed and "Missing" or (item.loaded and "Loaded" or "Lazy"))
					)
						.. (item.local_plugin and " · local" or "")
						.. (item.pin and " · pinned" or "")
						.. " · "
						.. item.dir,
				}
			end
			if #items > 0 then
				rex.ui.pick({ title = "Plugin Rex", items = items })
			end
			return status
		end,
		args = { json = "boolean?" },
	})
end

function M.setup(specs, options)
	assert(not state, "Plugin Rex is already configured in this Lua runtime")
	options = options or {}
	assert(type(options) == "table", "Options must be a table")
	for key in pairs(options) do
		assert(key == "root" or key == "lockfile" or key == "install_missing", "Unsupported option: " .. tostring(key))
	end
	assert(
		options.install_missing == nil or type(options.install_missing) == "boolean",
		"install_missing must be a boolean"
	)
	local home = os.getenv("HOME")
	local data = os.getenv("XDG_DATA_HOME") or (assert(home, "HOME is unset") .. "/.local/share")
	local config = os.getenv("XDG_CONFIG_HOME") or (assert(home, "HOME is unset") .. "/.config")
	local root = spec.path(options.root or (data .. "/rex/plugins"))
	assert(root ~= "/", "Plugin root cannot be /")
	local lockfile = spec.path(options.lockfile or (config .. "/rex/plugin-rex-lock.json"))
	local plugins, by_name = spec.normalize(specs, root)
	for _, plugin in ipairs(plugins) do
		assert(
			#plugin.event == 0 or type(rex.args) == "table",
			"event lazy loading only works in rex do scripts; init.lua receives no events"
		)
	end
	state = { root = root, lockfile = lockfile, plugins = plugins, by_name = by_name }
	-- No plugins become require-able before their dependencies and config run.
	table.insert(package.loaders, 2, function(name)
		-- Let Lua resolve modules already exposed by a loaded/loading plugin.
		-- An unloaded plugin exporting the same name must not intercept them.
		for _, plugin in ipairs(plugins) do
			if (plugin.loaded or plugin.loading) and module_file(plugin, name) then
				return "\n\tmodule is already on Plugin Rex's search path"
			end
		end
		for _, plugin in ipairs(plugins) do
			if not plugin.loaded and not plugin.loading and module_file(plugin, name) then
				M.load(plugin.name)
				-- During configuration require(main) may already have loaded this module.
				-- Capture it before require installs its in-progress sentinel.
				local loaded = package.loaded[name]
				return function()
					if loaded ~= nil then
						return loaded
					end
					local chunk, err = loadfile(assert(module_file(plugin, name)))
					assert(chunk, err)
					return chunk(name)
				end
			end
		end
		return "\n\tno unloaded Plugin Rex plugin provides '" .. name .. "'"
	end)
	actions()
	if options.install_missing ~= false then
		M.install()
	end
	-- Every init runs before any plugin's configuration, including lazy plugins.
	for _, plugin in ipairs(plugins) do
		if plugin.init then
			plugin.init(plugin)
		end
	end
	local eager = {}
	for _, plugin in ipairs(plugins) do
		if not plugin.lazy then
			eager[#eager + 1] = plugin
		end
		for _, event in ipairs(plugin.event) do
			local name = plugin.name
			rex.on(event, function()
				M.load(name)
			end)
		end
	end
	table.sort(eager, function(a, b)
		if (a.priority or 50) == (b.priority or 50) then
			return a.name < b.name
		end
		return (a.priority or 50) > (b.priority or 50)
	end)
	local function available(plugin)
		if not git.exists(plugin.dir) then
			return false
		end
		for _, name in ipairs(plugin.dependencies) do
			if not available(by_name[name]) then
				return false
			end
		end
		return true
	end
	for _, plugin in ipairs(eager) do
		if options.install_missing ~= false or available(plugin) then
			M.load(plugin.name)
		end
	end
	return M
end

return M
