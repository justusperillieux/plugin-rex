-- All subprocesses use argument vectors through Rex; no shell or Lua C modules.
local M = {}

function M.run(argv, cwd)
	local result, err = rex.exec(argv, {
		cwd = cwd,
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
	local message = result.stderr ~= "" and result.stderr or result.stdout
	if message == "" then
		message = argv[1] .. " failed with exit code " .. tostring(result.code)
	end
	assert(result.ok, message .. (result.timed_out and " (command timed out)" or ""))
	return (result.stdout:gsub("\r?\n$", ""))
end

function M.exists(path)
	local result, err = rex.exec({ "test", "-e", path }, { timeout = 5 })
	assert(result, err)
	assert(result.code == 0 or result.code == 1, result.stderr)
	return result.ok
end

function M.command(plugin, args)
	local argv = { "git", "-c", "core.hooksPath=/dev/null", "-C", plugin.dir }
	for _, arg in ipairs(args) do
		argv[#argv + 1] = arg
	end
	return M.run(argv)
end

function M.head(plugin)
	return M.command(plugin, { "rev-parse", "--verify", "HEAD" })
end

function M.clean(plugin)
	assert(
		M.command(plugin, { "status", "--porcelain", "--untracked-files=all" }) == "",
		plugin.name .. " has local changes; keeping them intact"
	)
	assert(
		M.command(plugin, { "remote", "get-url", "origin" }) == plugin.url,
		plugin.name .. " has a different origin URL"
	)
end

local function resolve(plugin, revision)
	return M.command(plugin, { "rev-parse", "--verify", "--end-of-options", revision .. "^{commit}" })
end

local function target(plugin)
	if plugin.commit then
		return resolve(plugin, plugin.commit)
	end
	if plugin.tag then
		return resolve(plugin, "refs/tags/" .. plugin.tag)
	end
	if plugin.branch then
		return resolve(plugin, "refs/remotes/origin/" .. plugin.branch)
	end
	-- Refresh this symbolic ref so changes to the remote default branch are honored.
	M.command(plugin, { "remote", "set-head", "origin", "--auto" })
	return resolve(plugin, "refs/remotes/origin/HEAD")
end

function M.checkout(plugin, commit)
	M.command(plugin, { "checkout", "--detach", "--no-overwrite-ignore", commit, "--" })
end

function M.install(plugin, locked)
	if plugin.local_plugin then
		M.run({ "test", "-d", plugin.dir })
		return false
	end
	if M.exists(plugin.dir) then
		assert(
			M.command(plugin, { "rev-parse", "--show-prefix" }) == ""
				and M.command(plugin, { "rev-parse", "--is-inside-work-tree" }) == "true",
			"Plugin path is not its own Git repository: " .. plugin.dir
		)
		assert(
			M.command(plugin, { "remote", "get-url", "origin" }) == plugin.url,
			plugin.name .. " has a different origin URL"
		)
		return false
	end
	assert(not locked or locked.url == plugin.url, "Lockfile URL differs for " .. plugin.name .. "; run update")
	-- Clone to a sibling first: a failed clone never becomes an installed plugin.
	local staging = plugin.dir .. ".installing"
	assert(not M.exists(staging), "Unfinished install at " .. staging .. "; inspect and remove it before retrying")
	M.run({ "git", "-c", "core.hooksPath=/dev/null", "clone", "--no-checkout", "--", plugin.url, staging })
	local original = plugin.dir
	plugin.dir = staging
	local ok, err = pcall(function()
		M.checkout(plugin, locked and resolve(plugin, locked.commit) or target(plugin))
	end)
	plugin.dir = original
	if not ok then
		error(tostring(err) .. " (unfinished clone: " .. staging .. ")", 0)
	end
	assert(os.rename(staging, original))
	return true
end

function M.update(plugin, locked, restore)
	if plugin.local_plugin then
		return
	end
	if restore then
		assert(locked, "No lockfile entry for " .. plugin.name)
		assert(locked.url == plugin.url, "Lockfile URL differs for " .. plugin.name)
	end
	if M.install(plugin, restore and locked or nil) then
		return
	end
	if not restore and plugin.pin then
		return
	end
	M.clean(plugin)
	local commit
	if restore then
		local available, resolved = pcall(resolve, plugin, locked.commit)
		if available then
			commit = resolved
		end
	end
	if not commit then
		M.command(plugin, { "fetch", "--prune", "--tags", "origin" })
		commit = restore and resolve(plugin, locked.commit) or target(plugin)
	end
	-- A detached local commit cannot be silently discarded by an update.
	if not restore then
		local ancestor = pcall(M.command, plugin, { "merge-base", "--is-ancestor", M.head(plugin), commit })
		assert(
			ancestor,
			plugin.name .. " update would discard local commits or move backwards; use restore for a locked revision"
		)
	end
	M.checkout(plugin, commit)
end

return M
