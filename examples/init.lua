-- Run `rex config check examples/init.lua` from this checkout.
-- This empty spec validates the API without downloading anything.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("plugin-rex").setup({}, { install_missing = false })

-- In your own init.lua, after bootstrapping Plugin Rex:
-- require("plugin-rex").setup({
--   { "justusperillieux/treerex", opts = {} },
--   {
--     "justusperillieux/tmplrex",
--     opts = { projects = { { name = "Work", cwd = "~/Developer/work" } } },
--   },
-- })
