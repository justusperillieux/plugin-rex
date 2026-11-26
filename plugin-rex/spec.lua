-- Normalize the supported lazy.nvim-style spec subset before doing any I/O.
local M = {}

local fields = {
	name = true,
	url = true,
	dir = true,
	main = true,
	dependencies = true,
	enabled = true,
	lazy = true,
	priority = true,
	init = true,
	config = true,
	opts = true,
	branch = true,
	tag = true,
	commit = true,
	pin = true,
	event = true,
}

local function text(value, label)
	assert(type(value) == "string" and value ~= "" and not value:find("%z"), label .. " must be a non-empty string")
	return value
end

function M.path(value)
	text(value, "Path")
	if value == "~" or value:sub(1, 2) == "~/" then
		value = assert(os.getenv("HOME"), "HOME is unset") .. value:sub(2)
	end
	assert(value:sub(1, 1) == "/", "Use an absolute path or ~/path: " .. value)
	assert(not value:find("[;?\n\r]"), "Path contains a Lua search-path delimiter: " .. value)
	return value:gsub("/+$", "") .. (value == "/" and "/" or "")
end

function M.normalize(specs, root)
	assert(type(specs) == "table", "setup expects a list of plugin specs")
	local ordered, by_name, visiting = {}, {}, {}
	local function add(raw, dependency)
		if type(raw) == "string" then
			raw = { raw }
		end
		assert(type(raw) == "table", "A plugin spec must be a string or table")
		for key in pairs(raw) do
			assert(key == 1 or fields[key], "Unsupported plugin spec field: " .. tostring(key))
		end
		local enabled = raw.enabled
		if type(enabled) == "function" then
			enabled = enabled()
		end
		assert(enabled == nil or type(enabled) == "boolean", "enabled must be a boolean or return one")
		if enabled == false then
			return
		end
		assert(not visiting[raw], "Cyclic dependency spec")
		local source = raw.url or raw[1]
		assert(not (raw.dir and raw.url), "Use dir or url, not both")
		if source then
			text(source, "Plugin source")
		end
		if raw.dir ~= nil then
			text(raw.dir, "dir")
		end
		assert(source or raw.dir, "A plugin needs owner/repo, url, or dir")
		local url = source
		if source and not raw.url and source:match("^[%w_.-]+/[%w_.-]+$") then
			url = "https://github.com/" .. source:gsub("%.git$", "") .. ".git"
		end
		local basename = (raw.dir or source):gsub("/+$", ""):match("([^/:]+)$") or ""
		local name = raw.name or basename:gsub("%.git$", "")
		text(name, "Plugin name")
		assert(name:match("^[%w_.-]+$") and name ~= "." and name ~= "..", "Invalid plugin name: " .. name)
		assert(not by_name[name], "Duplicate plugin name: " .. name .. "; declare each plugin once")
		local plugin = {}
		for key, value in pairs(raw) do
			plugin[key] = value
		end
		plugin.name, plugin.url = name, raw.dir and nil or url
		plugin.dir = raw.dir and M.path(raw.dir) or root .. "/" .. name
		plugin.local_plugin = raw.dir ~= nil
		plugin.main = raw.main or name:gsub("%.lua$", "")
		text(plugin.main, "main")
		assert(plugin.main:match("^[%w_.-]+$"), "Invalid main module: " .. plugin.main)
		for _, key in ipairs({ "lazy", "pin" }) do
			assert(raw[key] == nil or type(raw[key]) == "boolean", key .. " must be a boolean")
		end
		assert(raw.priority == nil or type(raw.priority) == "number", "priority must be a number")
		assert(raw.init == nil or type(raw.init) == "function", "init must be a function")
		assert(
			raw.config == nil or raw.config == true or type(raw.config) == "function",
			"config must be true or a function"
		)
		assert(
			raw.opts == nil or type(raw.opts) == "table" or type(raw.opts) == "function",
			"opts must be a table or function"
		)
		assert(not (raw.tag and raw.commit), "Use tag or commit, not both")
		for _, key in ipairs({ "branch", "tag", "commit" }) do
			if raw[key] ~= nil then
				text(raw[key], key)
			end
		end
		if raw.commit then
			assert(raw.commit:match("^%x+$") and #raw.commit == 40, "commit must be a full 40-character SHA")
		end
		local events = raw.event or {}
		if type(events) == "string" then
			events = { events }
		end
		assert(type(events) == "table", "event must be a string or list")
		plugin.event = {}
		for _, event in ipairs(events) do
			plugin.event[#plugin.event + 1] = text(event, "event")
		end
		plugin.lazy = raw.lazy
		if plugin.lazy == nil then
			plugin.lazy = dependency or #plugin.event > 0
		end
		plugin.dependencies = {}
		by_name[name], ordered[#ordered + 1], visiting[raw] = plugin, plugin, true
		assert(raw.dependencies == nil or type(raw.dependencies) == "table", "dependencies must be a list")
		for _, dep in ipairs(raw.dependencies or {}) do
			-- Bare names reference a spec declared elsewhere; owner/repo strings are specs.
			if type(dep) == "string" and not dep:find("/", 1, true) then
				plugin.dependencies[#plugin.dependencies + 1] = dep
			else
				local child = add(dep, true)
				if child then
					plugin.dependencies[#plugin.dependencies + 1] = child.name
				end
			end
		end
		visiting[raw] = nil
		return plugin
	end
	for _, raw in ipairs(specs) do
		add(raw, false)
	end
	local done, active = {}, {}
	local function visit(plugin)
		assert(not active[plugin.name], "Dependency cycle at " .. plugin.name)
		if done[plugin.name] then
			return
		end
		active[plugin.name] = true
		for _, name in ipairs(plugin.dependencies) do
			assert(by_name[name], "Unknown or disabled dependency: " .. name)
			visit(by_name[name])
		end
		active[plugin.name], done[plugin.name] = nil, true
	end
	for _, plugin in ipairs(ordered) do
		visit(plugin)
	end
	return ordered, by_name
end

return M
