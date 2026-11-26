# Plugin Rex

[![CI](https://github.com/justusperillieux/plugin-rex/actions/workflows/ci.yml/badge.svg)](https://github.com/justusperillieux/plugin-rex/actions/workflows/ci.yml)

<p><img src="assets/plugin-rex-logo-v2.png" alt="Plugin Rex — a T-rex with a large electrical plug for a tail on Rex's colorful gradient background" width="320"></p>

**Plug more into Rex.**

A pure Lua plugin manager for [Rex](https://www.superlogical.com/rex), inspired by
[lazy.nvim](https://github.com/folke/lazy.nvim) and its
[declarative plugin specs](https://lazy.folke.io/spec). Declare plugins in Lua,
install them from Git, load their dependencies, and save exact versions in a
lockfile. Manage everything from Rex's native command palette or CLI.

All manager and bootstrap code targets Lua 5.1 and runs through Rex. Git and a
few standard system tools handle subprocess work; there is no compiled manager
component, Neovim dependency, or LuaRocks requirement.

## Requirements

- macOS or Linux.
- Rex on your `PATH`, with `rex.exec`, `rex.json`, Lua actions, and native
  `rex.ui` prompts. Tested with Rex 0.1.0-preview.23, control API revision 19.
- Git 2.28+ and standard POSIX tools: `test`, `mkdir`, and `rmdir`.
- Access to the manager and plugins' Git repositories. For a private GitHub
  repository, use an authenticated [GitHub CLI](https://cli.github.com/) session.
  Public bootstrap downloads can use `curl` instead.

Run installation and management commands on the machine running the Rex server.
Use the same `HOME`, `XDG_DATA_HOME`, and `XDG_CONFIG_HOME` values as that server.
`rex do` scripts execute locally, even when connected to a remote Rex server.

## Quick start

### 1. Bootstrap

For this private repository, authenticate with `gh auth login` if needed, then:

```sh
gh auth setup-git
gh api repos/justusperillieux/plugin-rex/contents/bootstrap.lua \
  --header 'Accept: application/vnd.github.raw+json' | rex do -
```

`gh auth setup-git` lets Git use your GitHub CLI credentials to clone the private
repository. Neither the installer nor the manager stores your credentials.

If the repository is public, the equivalent command needs only `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/justusperillieux/plugin-rex/main/bootstrap.lua | rex do -
```

These commands download and run the [Lua bootstrap script](bootstrap.lua). It:

- Clones Plugin Rex into `~/.local/share/rex/plugin-rex`.
- Creates `plugin-rex-plugins.lua` for your plugin list and `plugin-rex-setup.lua`
  to load the manager, beside your Rex `init.lua`.
- Creates `init.lua` if it is missing. If it already exists, keeps it intact and
  prints the one line to add:

```lua
require("plugin-rex-setup")
```

Existing files, plugin choices, and manager checkouts are retained on repeated
runs. The bootstrap does not update an existing checkout or reload Rex. You can
also download `bootstrap.lua`, inspect it, and run `rex do ./bootstrap.lua`.

### 2. Choose your plugins

Edit `~/.config/rex/plugin-rex-plugins.lua`. For example:

```lua
return {
  { "justusperillieux/treerex", opts = {} },
  {
    "justusperillieux/tmplrex",
    opts = {
      projects = {
        { name = "Work", cwd = "~/Developer/work" },
      },
    },
  },
}
```

The bootstrap starts with an empty list, so it does not install any plugins
until you choose them. `opts = {}` calls the plugin's `setup` function even when
you have no custom options. Use `main` if its module name differs from the
repository name.

When moving a plugin from an existing configuration, remove its old
`require(...).setup(...)` call so it is configured once. Old modules already
cached by Lua take precedence; remove obsolete configuration-directory module
links if you want the managed checkout to provide them.

### 3. Check and reload

```sh
rex config check && rex config reload
```

Missing plugins are installed while the configuration loads, including during
`rex config check`. Open Rex's command palette and look for **Plugin Rex** to
install, update, restore, or inspect plugins.

## Files and configuration

With default paths, bootstrap creates this layout:

```text
~/.config/rex/
  init.lua                 # calls require("plugin-rex-setup")
  plugin-rex-setup.lua      # manager loading and setup options
  plugin-rex-plugins.lua    # your plugin specs
  plugin-rex-lock.json      # saved Git commits, created on install/update

~/.local/share/rex/
  plugin-rex/              # the manager itself
  plugins/                 # managed plugin checkouts
```

`XDG_CONFIG_HOME` replaces `~/.config`; `XDG_DATA_HOME` replaces `~/.local/share`.
If `REX_CONFIG` names a custom configuration file, bootstrap creates its loader
and plugin list beside that file. The manager's default lockfile still uses
`XDG_CONFIG_HOME/rex/plugin-rex-lock.json`; override it explicitly when needed.

To change manager options, edit the final call in `plugin-rex-setup.lua`:

```lua
require("plugin-rex").setup(require("plugin-rex-plugins"), {
  install_missing = false,
  -- root = "~/my-rex-plugins",
  -- lockfile = "~/dotfiles/rex/plugin-rex-lock.json",
})
```

With `install_missing = false`, eager plugins whose checkouts or dependencies
are missing remain unloaded. Use **Install Plugins**, then reload configuration.
Paths must be absolute or start with `~/`. Call `setup` once per Lua runtime.
Plugins execute with the same privileges as your Rex configuration.

### Manual installation

To manage installation yourself, clone the repository:

```sh
git clone https://github.com/justusperillieux/plugin-rex.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/rex/plugin-rex"
```

Then add this to your existing `init.lua`, filling in the plugin list:

```lua
local data = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
local manager = data .. "/rex/plugin-rex"
package.path = manager .. "/?.lua;" .. manager .. "/?/init.lua;" .. package.path

require("plugin-rex").setup({
  { "justusperillieux/treerex", opts = {} },
})
```

For a development checkout, substitute its absolute path for `manager`.
For bootstrap from a committed local Git repository, run
`rex do ./bootstrap.lua source=/absolute/path/to/plugin-rex`.

## Plugin specs

```lua
require("plugin-rex").setup({
  -- GitHub shorthand; adds the repository to Lua's module search path.
  "someone/lua-library",

  -- A local development checkout, never cloned, updated, or locked.
  {
    dir = "~/Developer/my-plugin",
    main = "my_plugin",
    opts = { greeting = "hello" },
  },

  -- A custom Git URL and an explicitly named entry module.
  {
    url = "https://git.example.org/team/useful-plugin.git",
    name = "useful-plugin",
    branch = "main",
    main = "useful",
    dependencies = {
      { "someone/helper", opts = {} },
      "lua-library", -- references a spec declared elsewhere
    },
    init = function(plugin)
      -- Runs at startup, even for lazy plugins, before any configuration.
    end,
    opts = function(plugin, opts)
      opts.enabled = true -- mutate opts, or return a replacement table
    end,
    config = function(plugin, opts)
      require("useful").setup(opts)
    end,
  },
}, {
  root = "~/.local/share/rex/plugins",
  lockfile = "~/.config/rex/plugin-rex-lock.json",
  install_missing = true,
})
```

The default root uses `$XDG_DATA_HOME/rex/plugins`, falling back to
`~/.local/share/rex/plugins`. The default lockfile uses
`$XDG_CONFIG_HOME/rex/plugin-rex-lock.json`, falling back to the path above.
Paths must be absolute or begin with `~/`. `REX_CONFIG` does not change these
defaults; set `lockfile` explicitly for a separate configuration.

| Field | Behavior |
| --- | --- |
| `[1]`, `url`, `dir` | GitHub `owner/repo`, a Git URL, or a local directory. |
| `name` | Unique install directory name; defaults to the repository basename. |
| `main` | Entry module; defaults to the name with a trailing `.lua` removed. |
| `opts` | Table or `function(plugin, opts)`; implies `require(main).setup(opts)`. |
| `config` | `function(plugin, opts)` replaces automatic setup; `true` enables it. |
| `init` | `function(plugin)` called for every enabled plugin before eager loading. |
| `dependencies` | Nested specs or bare names referencing declared specs; loaded first. |
| `enabled` | Boolean or zero-argument function; `false` excludes the spec. |
| `lazy` | Load on `require` or `load(name)`; defaults to false for top-level specs. |
| `priority` | Higher numbers load earlier among eager plugins; default 50. |
| `branch`, `tag`, `commit` | Track a branch or tag, or select a full 40-character commit SHA. |
| `pin` | Skip updates for an installed plugin; restore still honors the lockfile. |
| `event` | Event name or list; makes the plugin lazy by default; scripts only. |

Dependencies declared inline default to lazy. A referenced top-level dependency
keeps its own loading policy. Declare each plugin once; duplicate names, missing
dependencies, dependency cycles, and unknown spec fields are errors. Dependencies
take precedence over priority; equal priorities are ordered by name.

Modules can live at the repository root or under `lua/`, using either
`module.lua` or `module/init.lua`. There is no implicit execution of Neovim
`plugin/` files. Without `opts` or `config`, loading only adds module search paths.

## Lazy loading and Rex's execution model

```lua
{ "someone/helper", lazy = true, opts = {} }
-- Later, require("helper") loads dependencies and runs setup exactly once.
-- Explicit loading also works:
require("plugin-rex").load("helper")
```

Rex requires actions, modes, settings, and named key bindings to be declared
while `init.lua` loads. Keep plugins that declare these eager, including
Treerex and Tmplrex. Use lazy loading for modules that can initialize later,
or require them during the initial configuration load. An `init` callback can
declare an action whose `run` callback later requires a lazy helper module.

Rex sends events only to scripts run with `rex do`. An `event` spec in
`init.lua` is rejected before installing anything. In a script it works:

```lua
-- watch.lua, after adding Plugin Rex to package.path:
require("plugin-rex").setup({
  { "someone/notifications", event = "terminal.bell", opts = {} },
})
```

```sh
rex do ./watch.lua --all
```

The first matching event initializes the plugin. Later events do not repeat
setup. Plugins needing persistent event handlers should register them at the
script's top level; Rex disallows registering handlers from another handler.
Scripts execute on the machine running `rex do`; keep it on the server machine
for these filesystem operations.

## Manage plugins

Open Rex's command palette:

- **Plugin Rex: Install Plugins** installs missing plugins at their locked commits,
  or the configured Git revision if they have no lock entry.
- **Plugin Rex: Update Plugins** fetches upstream changes, advances clean unpinned
  checkouts, and records their new commits.
- **Plugin Rex: Restore Plugins** checks out the exact saved commits, including
  pinned plugins, without changing the lockfile.
- **Plugin Rex: Plugin Status…** shows installed, loaded, lazy, local, pinned,
  and failed states.

The same operations are available as `install()`, `update()`, `restore()`, and
`status()` on `require("plugin-rex")`. After reloading the configuration, actions
can also be invoked from the CLI:

```sh
rex do plugin_rex_install
rex do plugin_rex_update
rex do plugin_rex_restore
rex do plugin_rex_status json=true --json
rex config reload
```

Reload configuration after changing installed versions. Existing loaded Lua
modules retain their old code until reload; live hot reload is not attempted.

To remove a plugin, delete its spec from your plugin list and reload. Its checkout
and lock entry are retained; Plugin Rex does not automatically delete files.

### Update the manager

Plugin updates do not update Plugin Rex itself. Update its checkout separately:

```sh
git -C "${XDG_DATA_HOME:-$HOME/.local/share}/rex/plugin-rex" pull --ff-only
rex config check && rex config reload
```

## Lockfile and recovery

Commit the JSON lockfile with your Rex configuration. Install preserves existing
checkouts and existing lock entries; use Restore to reconcile a changed checkout
with the saved version. If a spec's source or revision changes, Update applies it
where a safe forward move is possible; a different origin requires moving the old
managed checkout aside first. To move backwards intentionally, change the saved
lockfile commit and use Restore.

Updates and restores refuse working trees with tracked or untracked changes.
Updates also refuse to discard local commits or move to unrelated history.
Restore intentionally changes the checked-out commit to the lockfile revision;
save any local commits you need before restoring. Git hooks are disabled for
manager operations. Git authentication uses your existing Git/SSH configuration;
terminal password prompts are disabled.
Restore uses local commit objects when available, so an existing checkout can
be restored offline.

Operations run serially under an exclusive `<root>.lock` directory. The lockfile
is replaced atomically after the whole install/update succeeds. If an operation
fails partway, earlier checkouts may have changed; the old lockfile remains
available for Restore. After a process crash, inspect any `<plugin>.installing`
directory and the empty `<root>.lock` directory before removing them and retrying.

This first version supports the fields documented above. It does not implement
spec merging/imports, semantic version ranges, build hooks, automatic removal,
submodules, command/key triggers, or a custom management panel. Removing a spec
leaves its checkout and lock entry intact.

Rex's [Lua API reference](https://www.superlogical.com/rex/docs/reference/lua)
and [event documentation](https://www.superlogical.com/rex/docs/automate/lua-events)
describe the runtime constraints.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| No Plugin Rex actions in the palette | Add `require("plugin-rex-setup")` to `init.lua`, then check and reload configuration. |
| `module 'plugin-rex' not found` | Check that the manager is installed and the loader uses the same data directory as bootstrap. |
| A plugin cannot be required | Check its `main` module name, whether it is installed, and that it exports `setup` when using `opts`. |
| A plugin is missing after bootstrap | Add its spec to `plugin-rex-plugins.lua`, then check and reload; bootstrap starts with no plugins. |
| An update reports local changes or commits | Save your work before retrying. Updates do not reset or discard it. |
| Git authentication fails | Confirm the URL and your normal Git/SSH authentication on the server machine; terminal password prompts are disabled. |
| An operation reports an existing `.lock` directory | Wait for the running operation. After a crash, inspect the empty lock directory before removing it. |
| Event loading fails in `init.lua` | Events are available only to `rex do` scripts; keep action-declaring plugins eager. |

## Develop

GitHub Actions runs Lua 5.1 formatting checks with StyLua 2.6.0 and the full
manager/bootstrap test suite against Rex 0.1.0-preview.23 on Ubuntu 24.04.
The Rex download and GitHub Actions dependencies are pinned; no repository
secrets are needed beyond GitHub's built-in token.

```sh
make check # validates manager actions and an eager plugin in real Rex config
make test  # manager and bootstrap tests with temporary Git repositories; no network
```

Run these from the repository root. Tests leave your live configuration and Rex
sessions unchanged. All source targets Lua 5.1; formatting uses
`stylua --syntax Lua51 bootstrap.lua plugin-rex.lua plugin-rex examples tests`.
