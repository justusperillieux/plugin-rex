-- Standalone Lua 5.1 installer: curl .../bootstrap.lua | rex do -
-- Runs locally through Rex; never reloads or overwrites an existing configuration.
local function run(argv)
	local result, err = rex.exec(argv, {
		timeout = 120,
		env = {
			GIT_TERMINAL_PROMPT = "0",
			GIT_DIR = false,
			GIT_COMMON_DIR = false,
			GIT_WORK_TREE = false,
			GIT_INDEX_FILE = false,
		},
	})
	assert(result, err)
	assert(
		result.ok,
		result.stderr ~= "" and result.stderr
			or (result.stdout ~= "" and result.stdout or "Command failed: " .. argv[1])
	)
	return result.stdout
end

local function exists(path)
	for _, flag in ipairs({ "-e", "-L" }) do
		local result, err = rex.exec({ "test", flag, path }, { timeout = 5 })
		assert(result, err)
		assert(result.code == 0 or result.code == 1, result.stderr)
		if result.ok then
			return true
		end
	end
	return false
end

local function absolute(path)
	assert(
		type(path) == "string" and path:sub(1, 1) == "/" and not path:find("[;?%z\r\n]"),
		"Use an absolute path without Lua search-path delimiters: " .. tostring(path)
	)
	return path:gsub("/+$", "")
end

local function write_new(path, content)
	if exists(path) then
		print("Kept " .. path)
		return false
	end
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
	print("Created " .. path)
	return true
end

local home = os.getenv("HOME")
local data = absolute(os.getenv("XDG_DATA_HOME") or (assert(home, "HOME is unset") .. "/.local/share"))
local config = absolute(os.getenv("XDG_CONFIG_HOME") or (assert(home, "HOME is unset") .. "/.config"))
local init = absolute(os.getenv("REX_CONFIG") or (config .. "/rex/init.lua"))
local config_dir = assert(init:match("^(.+)/[^/]+$"), "REX_CONFIG must name a file in a directory")
local manager = data .. "/rex/plugin-rex"
local source = (rex.args or {}).source or "https://github.com/justusperillieux/plugin-rex.git"
assert(
	type(source) == "string" and source ~= "" and not source:find("%z"),
	"source must be a Git URL or repository path"
)

run({ "mkdir", "-p", "--", data .. "/rex" })
if not exists(manager) then
	run({ "git", "-c", "core.hooksPath=/dev/null", "clone", "--", source, manager })
else
	print("Kept existing checkout " .. manager)
end

-- Don't scaffold configuration for a wrong or incomplete checkout.
for _, relative in ipairs({ "plugin-rex.lua", "plugin-rex/spec.lua", "plugin-rex/git.lua" }) do
	local file = assert(
		io.open(manager .. "/" .. relative, "rb"),
		"Incomplete Plugin Rex checkout at " .. manager .. "; inspect it before retrying"
	)
	file:close()
end
run({ "mkdir", "-p", "--", config_dir })
write_new(
	config_dir .. "/plugin-rex-plugins.lua",
	[[-- Add plugins here, then run `rex config check` and `rex config reload`.
return {
  -- { "justusperillieux/treerex", opts = {} },
  -- {
  --   "justusperillieux/tmplrex",
  --   opts = { projects = { { name = "Work", cwd = "~/Developer/work" } } },
  -- },
}
]]
)
write_new(
	config_dir .. "/plugin-rex-setup.lua",
	[[local data = os.getenv("XDG_DATA_HOME") or (assert(os.getenv("HOME"), "HOME is unset") .. "/.local/share")
local manager = data .. "/rex/plugin-rex"
package.path = manager .. "/?.lua;" .. manager .. "/?/init.lua;" .. package.path
require("plugin-rex").setup(require("plugin-rex-plugins"))
]]
)
local created = write_new(init, 'require("plugin-rex-setup")\n')
if not created then
	print("\nAdd this once to " .. init .. ':\n\n  require("plugin-rex-setup")\n')
end
print("\nEdit " .. config_dir .. "/plugin-rex-plugins.lua to choose your plugins.")
print("Then run: rex config check && rex config reload")
print("The existing configuration has not been reloaded.")
