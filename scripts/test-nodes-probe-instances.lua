-- A PROBE CHILD NEVER PROBES AGAIN, AND ONE PROCESS NEVER ACCUMULATES THEM (item 0, the 19/11 OOM).
--
-- MEASURED 19/11 on avell: the fast path took this node from 6 GB to 23 GB and killed wa-serve. Two
-- separate growths, both measured on this node while writing this row:
--
--   A. A PROBE CHILD PROBED AGAIN. lua/core/nodes.lua is dofile()d by fifteen callers (init, server,
--      tools, subagents, fleet, federation, ...) and EVERY dofile builds its own M table. The guard was
--      "M._in_probe_child" - INSTANCE state - so M.probe marked one instance and the other fourteen in
--      the same process still fanned out. A sampled child's own parent was a probe child
--      ("nodes probe aaaa" -> "nodes probe bbbb": 49 children at t=4s, 378 at t=5s).
--   B. CHILDREN ACCUMULATED ACROSS CALLS. A child lives up to PROBE_DEADLINE_S (20 s) and every M.list()
--      started a fresh one per peer, so a row calling list() a few times in one turn left 125 live
--      "wa nodes probe" processes for a 6-peer roster (measured in scripts/test-remote-refusals.lua).
--
-- This row builds REAL instances and counts host.operation starts. It starts no process: the stub
-- answers start/await/read/cancel itself, so the row cannot fork anything it then has to reap.
-- RED on the base (48ca92de^): case 2 fails with "a probe-marked process still started N probe
-- children" - the recursion - and case 5 fails with one new child per peer on the second call.
local json = dofile("lua/vendor/json.lua") -- a script has no `json` global; the modules carry their own
local A = dofile("lua/core/nodes.lua")
local B = dofile("lua/core/nodes.lua")
assert(A ~= B, "the two dofile calls returned the SAME table, so this row would prove nothing")

local peers = {}
for i = 1, 80 do peers[i] = { node_id = string.rep(string.char(97 + (i % 6)), 32), name = "peer" .. i } end

-- A counted host.operation. Only "start" is a child; await/read/cancel are the bookkeeping around it and
-- are counted separately so the numbers below name exactly one thing each.
local starts, awaits, reads = 0, 0, 0
host.operation = function(action, request)
  local req = json.decode(request or "") or {}
  if action == "start" then
    starts = starts + 1
    return json.encode({ operation_id = "fixture-" .. starts })
  elseif action == "await" then
    awaits = awaits + 1
    return json.encode({ settled = true, state = "completed", operation_id = req.id })
  elseif action == "read" then
    reads = reads + 1
    return json.encode({ content = json.encode({ node_id = "fixture", capabilities = { "bash" }, reason = "asked" }) })
  end
  return json.encode({ cancelled = true })
end
-- reset() clears the COUNTERS only: the in-flight registry is the thing case 5 measures, and wiping it
-- here made the second call look like a cold process (measured while writing this row: "6 then 6").
-- cold() is a process that has started nothing yet.
local function reset() starts, awaits, reads = 0, 0, 0 end
local function cold() reset(); _G.WA_PROBE_INFLIGHT = nil end

-- 1. UNMARKED: an instance fans out, so the row can tell a guard from a wall that always says no.
_G.WA_IN_PROBE_CHILD = nil
A._in_probe_child = nil
cold()
B.list({ peers = peers, live_capabilities = true })
local unmasked = starts
assert(unmasked > 0, "an unmarked instance started no child per peer, so the guard below proves nothing")

-- 2. MARKED BY M.probe (the state every probe child is in): the SAME instance starts NOTHING.
_G.WA_IN_PROBE_CHILD = true
A._in_probe_child = true
cold()
local rows = B.list({ peers = peers, live_capabilities = true })
assert(starts == 0, "a probe-marked process still started " .. starts .. " probe children of " .. unmasked
  .. " (the 19/11 recursion)")
assert(#rows >= 1, "the guard swallowed the roster too: list returned no rows")

-- 3. THE ORDER THAT BROKE IT: an instance loaded AFTER the mark must not fan out either.
local C = dofile("lua/core/nodes.lua")
cold()
C.list({ peers = peers, live_capabilities = true })
assert(starts == 0, "an instance loaded after the mark started " .. starts .. " probe children")

-- 4. A child is told by its ENVIRONMENT before its first line, without any instance state at all.
assert(type(A.PROBE_CHILD_ENV) == "string" and A.PROBE_CHILD_ENV ~= "",
  "the module names no environment for a probe child, so a child cannot be marked before it runs")

-- 5. NO ACCUMULATION (growth B): with the mark cleared, the FIRST unmarked call starts one child per
--    peer and the SECOND call, inside the same deadline, starts NONE - it joins the children already
--    running. This is the 125-live-processes measurement as an assertion.
_G.WA_IN_PROBE_CHILD = nil
A._in_probe_child = nil
cold()
B.list({ peers = peers, live_capabilities = true })
local first = starts
assert(first > 0, "the first unmarked call started no child, so the reuse below proves nothing")
reset()
B.list({ peers = peers, live_capabilities = true })
assert(starts == 0, "a second list() inside the deadline started " .. starts .. " MORE children for peers that"
  .. " already have one running (the accumulation: " .. first .. " then " .. starts .. ")")

-- 6. THE CAP (an allowance, not a hope): a roster larger than the process cap starts at most the cap,
--    and the child that is over it is named by the caller's own reason rather than forked.
cold()
local many = {}
for i = 1, 500 do many[i] = { node_id = string.format("%064x", i), name = "big" .. i } end
local capped = B.list({ peers = many, live_capabilities = true })
assert(starts <= 64, "500 peers started " .. starts .. " children at once; the process cap is 64")
-- A peer that is over the cap is NAMED, never silently answered as if it had been asked.
local named = 0
for _, row in ipairs(capped) do
  if row.capabilities_reason == "probe_capacity" then named = named + 1 end
end
assert(named > 0, "the roster over the cap named no peer probe_capacity, so a capped peer would read as unknown")

print("nodes probe instances ok: two real instances (" .. unmasked .. " children when unmarked), the marked one "
  .. "starts none, an instance loaded after the mark starts none, a repeated call starts none ("
  .. first .. " then 0, no accumulation), 500 peers are capped at " .. starts
  .. ", and the child environment is named (" .. A.PROBE_CHILD_ENV .. ")")
