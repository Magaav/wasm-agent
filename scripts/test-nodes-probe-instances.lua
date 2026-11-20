-- A PROBE CHILD NEVER PROBES AGAIN - ACROSS MODULE INSTANCES (item 0, the 19/11 OOM).
--
-- MEASURED 19/11 on avell: the fast path took the node from 6 GB to 23 GB and killed wa-serve. The
-- crowd was 1,653 "wa ... nodes probe <id>" processes of ~14 MB each, still appearing after the run
-- that started them ended. The parent chain of a sampled child was another probe child
-- (t=4s: "nodes probe aaaa" -> "nodes probe bbbb", 49 children; t=5s: 378).
--
-- WHY THE FIRST GUARD WAS NOT ENOUGH: lua/core/nodes.lua is dofile()d by fifteen callers (init, server,
-- tools, subagents, fleet, federation, ...) and EVERY dofile builds its own M table. The guard was
-- "M._in_probe_child" - INSTANCE state. M.probe set it on the instance it ran in; every other instance
-- in the same process still fanned out, and each child repeated that, so the tree was unbounded.
--
-- This row builds two real instances and asks the second one. host.operation is counted, never started,
-- so the row itself forks nothing. Red on the base: the marked instance still started one child per
-- peer. Green now: zero, for an instance marked directly and for one loaded after the mark.
local A = dofile("lua/core/nodes.lua")
local B = dofile("lua/core/nodes.lua")
assert(A ~= B, "the two dofile calls returned the SAME table, so this row would prove nothing")

local peers = {}
for i = 1, 80 do peers[i] = { node_id = string.rep(string.char(97 + (i % 6)), 32), name = "peer" .. i } end

-- A counted host.operation: a fan-out is a number here, and THIS ROW STARTS NO PROCESS.
local started = 0
host.operation = function()
  started = started + 1
  return '{"operation_id":"fixture-' .. started .. '"}'
end

-- 1. UNMARKED: an instance fans out, so the row can tell a guard from a wall that always says no.
_G.WA_IN_PROBE_CHILD = nil
A._in_probe_child = nil
started = 0
B.list({ peers = peers, live_capabilities = true })
local unmasked = started
assert(unmasked > 0, "an unmarked instance started no child per peer, so the guard below proves nothing")

-- 2. MARKED BY M.probe (the state every probe child is in): the SAME instance starts NOTHING.
_G.WA_IN_PROBE_CHILD = true
A._in_probe_child = true
started = 0
local rows = B.list({ peers = peers, live_capabilities = true })
assert(started == 0, "a probe-marked process still started " .. started .. " probe children of " .. unmasked
  .. " (the 19/11 recursion)")
assert(#rows >= 1, "the guard swallowed the roster too: list returned no rows")

-- 3. THE ORDER THAT BROKE IT: an instance loaded AFTER the mark must not fan out either.
local C = dofile("lua/core/nodes.lua")
started = 0
C.list({ peers = peers, live_capabilities = true })
assert(started == 0, "an instance loaded after the mark started " .. started .. " probe children")

-- 4. A child is told by its ENVIRONMENT before its first line, without any instance state at all.
assert(type(A.PROBE_CHILD_ENV) == "string" and A.PROBE_CHILD_ENV ~= "",
  "the module names no environment for a probe child, so a child cannot be marked before it runs")

print("nodes probe instances ok: two real instances (" .. unmasked .. " children when unmarked), the marked one "
  .. "starts none, an instance loaded after the mark starts none, and the child environment is named ("
  .. A.PROBE_CHILD_ENV .. ")")
