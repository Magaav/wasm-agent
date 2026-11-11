-- The probe that decides whether a kept binary can run a staged Lua tree (scripts/probe-lua-tree-mode.lua).
--
-- Why the probe exists: `deploy.sh` reuses the installed binary for a Lua-only change and installs
-- `lua-core/` beside it, and it used to decide that from the changed paths alone. The installed binary
-- must also *prefer* those bytes over its compiled-in copy, or the deploy's embedded check fails on the
-- first module that differs. Measured 10/11 on wasm_the_first: `a408c11b` verified a staged `67724745` tree
-- and then ran its own copy, so every attempt with a Lua change refused with
-- `stale embedded module: lua/core/server.lua` and the node stayed behind.
--
-- This pins the probe's decision, which is a table in and a decision out: no deploy, no binary, no network.
local root = assert(host.getenv('WASM_AGENT_LUA_ROOT'), 'run with a Lua root (the fast path sets one)')
local source = assert(host.read_file(root .. '/scripts/probe-lua-tree-mode.lua'), 'probe script')
local real = EMBEDDED
local function run() return load(source, '@probe-lua-tree-mode.lua')() end
local checks = 0
local function refusal(pattern, label)
  local ok, err = pcall(run)
  assert(not ok, label .. ': the probe must refuse')
  assert(tostring(err):find(pattern, 1, true), label .. ': got ' .. tostring(err))
  checks = checks + 1
end

-- A binary that runs the tree it is given: the marker the deploy put in the probe tree is what it reads.
EMBEDDED = { ['lua/vendor/json.lua'] = 'return {}\n-- wa-lua-tree-mode-probe\n' }
assert(pcall(run), 'a binary that runs the staged tree passes the probe')
checks = checks + 1

-- A binary that only verifies the tree and then runs its own copy: no marker, so no tree mode.
EMBEDDED = { ['lua/vendor/json.lua'] = 'return {}\n' }
refusal('lua tree mode absent', 'a binary that ignores the staged tree')

-- A runtime with no EMBEDDED table is not a node runtime at all.
EMBEDDED = nil
refusal('no EMBEDDED table', 'a runtime with no embedded table')

-- A binary that does not carry the probe module cannot be judged, and must not be trusted either.
EMBEDDED = {}
refusal('not in this binary', 'a binary without the probe module')

EMBEDDED = real
print('test-lua-tree-mode: ' .. checks .. ' checks passed')
