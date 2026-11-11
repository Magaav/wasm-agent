-- Does the binary running this script USE the Lua tree it was given, or only verify it?
--
-- `deploy.sh` keeps the installed binary for a Lua-only change and installs `lua-core/` beside it, and it
-- decides that from the *paths* the change touched. That is not enough (measured 10/11 on wasm_the_first):
-- the installed binary `a408c11b` verified a staged `67724745` tree with `--lua-tree` and then ran its own
-- compiled-in copy, so the deploy's embedded check - which compares `EMBEDDED` against the tree - failed on
-- the first module that differed (`lua/core/server.lua`) and the fast path could never install a Lua change
-- on that node. The bytes being verifiable is not the property the fast path needs; the runtime *preferring*
-- them is.
--
-- The probe tree carries one marker line in `lua/vendor/json.lua`, and the binary exposes `EMBEDDED` from
-- whichever copy it actually runs. A binary with the tree mode reports the marker; one without does not.
-- Read-only: no connector, no model, no network, and nothing is written.
assert(EMBEDDED ~= nil, 'no EMBEDDED table: not a wa node runtime')
local source = EMBEDDED['lua/vendor/json.lua']
assert(type(source) == 'string', 'the probe module is not in this binary')
assert(source:find('wa%-lua%-tree%-mode%-probe') ~= nil,
  'lua tree mode absent: EMBEDDED did not follow WA_LUA_TREE (this binary predates the tree mode)')
print('lua tree mode ok')
