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
-- THE STUB REFUSES AN ID THIS CALLER DOES NOT OWN, like the real host does (rust/wa-capabilities/src/
-- operations.rs, owned()): an await for somebody else operation answers {error=...}, never a settled state.
-- A stub that answers every id hides exactly the defect review item 1 names.
local owned = {}
local function owned_await(req)
  return owned[tostring(req.id or "")] == true
end
-- THE STUB MIRRORS THE REAL HOST (review r2, B tests; operations.rs Caller::owns, :1219-1241).
--
-- Two rules it must enforce, because the code under test is exactly the code that got them wrong:
--   1. an await/read/cancel for an operation this caller does not own is REFUSED by name. The host
--      decides ownership by the OWNER the caller names (a sessionless caller owns the rows started under
--      its own owner), so an ownerless call is refused even for a child this very test started - which is
--      what every probe did before MUST 1.
--   2. it honours wait_ms and IGNORES wait_s (the host reads wait_ms, default 1 s, cap 10 s). A stub that
--      settled at once for any argument hid MUST 2: the old code sent wait_s and was answered in 1 s.
local REQUIRED_OWNER = "nodes-probe"
local function refuses(req, owner_of)
  return tostring(req.owner or "") ~= REQUIRED_OWNER or owner_of[tostring(req.id or "")] == nil
end
host.operation = function(action, request)
  local req = json.decode(request or "") or {}
  if action == "start" then
    starts = starts + 1
    owned["fixture-" .. starts] = true
    return json.encode({ operation_id = "fixture-" .. starts })
  elseif action == "await" then
    awaits = awaits + 1
    if refuses(req, owned) then return json.encode({ error = "operation_not_owned", id = req.id }) end
    if (tonumber(req.wait_ms) or 0) <= 0 then
      -- fewer than one millisecond is not a wait the host can honour; it answers unsettled.
      return json.encode({ settled = false, state = "running", operation_id = req.id })
    end
    return json.encode({ settled = true, state = "completed", operation_id = req.id })
  elseif action == "read" then
    reads = reads + 1
    -- A probe child prints ONE JSON line with its answer. The stub answers like one, because the joiner
    -- reads that answer out of the lease: a read that returned nothing would publish nothing.
    return json.encode({ content = json.encode({ node_id = "fixture", capabilities = { "bash" }, reason = "asked" }) .. "\n" })
  end
  return json.encode({ cancelled = true })
end
-- reset() clears the COUNTERS only: the in-flight registry is the thing case 5 measures, and wiping it
-- here made the second call look like a cold process (measured while writing this row: "6 then 6").
-- cold() is a process that has started nothing yet.
local function reset() starts, awaits, reads = 0, 0, 0 end
local function cold()
  reset()
  _G.WA_PROBE_INFLIGHT = nil
  -- The lease on disk is the bound that survives a fresh Lua state (growth E), so a COLD process is one
  -- with no lease either: leave it in place and the cases below would join children an earlier case started.
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if ok and type(paths) == "table" and type(paths.data) == "function" then
    -- CLEAR THE WHOLE LEASE DIRECTORY (review r2, B/MUST 4): the lease is one file PER PROCESS in
    -- <data>/nodes-probe-inflight, and each file that names a peer this row is about must go, or a later
    -- case joins children an earlier one left behind and "the first call started no child".
    -- There is no host.delete_file (measured: nil), so each file is OVERWRITTEN with an empty peer list;
    -- a file for a process that is gone drops out by its own deadline.
    -- BOTH SHAPES: the directory (this tree) and the legacy single file (the base this row must be red
    -- on). Clearing only the new one made the base fail for the WRONG reason - a stale lease from an
    -- earlier case, not the ownerless await - which is a red that proves nothing.
    pcall(host.write_file, paths.data() .. "/nodes-probe-inflight.json", json.encode({ peers = {} }))
    local dir = paths.data() .. "/nodes-probe-inflight"
    local listed = host.list_dir and host.list_dir(dir) or nil
    if type(listed) == "string" then listed = json.decode(listed) end
    for _, item in ipairs(type(listed) == "table" and (listed.entries or {}) or {}) do
      local name = tostring(type(item) == "table" and item.name or "")
      if name:match("%.json$") then
        pcall(host.write_file, dir .. "/" .. name, json.encode({ peers = {} }))
      end
    end
  end
end

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
local capped_starts = starts
assert(capped_starts <= 64, "500 peers started " .. capped_starts .. " children at once; the process cap is 64")
-- A peer that is over the cap is NAMED, never silently answered as if it had been asked.
local named = 0
for _, row in ipairs(capped) do
  if row.capabilities_reason == "probe_capacity" then named = named + 1 end
end
assert(named > 0, "the roster over the cap named no peer probe_capacity, so a capped peer would read as unknown")

-- 7. THE BOUND IS ASKED OF THE LEDGER, NOT ONLY OF THIS PROCESS (growth D): 554 live probe children,
--    ~92 per peer, came from ninety-two processes that could not see each other. probe_children_alive
--    must therefore consult the operation host, and must NAME why it could not when it cannot.
local asked = 0
local real_list = host.operation
host.operation = function(action, request)
  if action == "list" then asked = asked + 1; return json.encode({ operations = {} }) end
  return real_list(action, request)
end
cold()
B.list({ peers = peers, live_capabilities = true })
assert(asked > 0, "the ledger was never asked how many probe children are alive, so only one process is bounded")
-- And when the host cannot answer, the reason is named rather than the bound being silently skipped.
host.operation = function(action, request)
  if action == "list" then error("no list on this host") end
  if action == "start" then starts = starts + 1; return json.encode({ operation_id = "fixture-" .. starts }) end
  if action == "await" then return json.encode({ settled = true }) end
  if action == "read" then return json.encode({ content = "" }) end
  return json.encode({})
end
cold()
B.list({ peers = peers, live_capabilities = true })
assert(_G.WA_PROBE_SHARED_BOUND == "operation_list_unavailable",
  "a host that cannot list operations left the shared bound unnamed (saw " .. tostring(_G.WA_PROBE_SHARED_BOUND) .. ")")
-- 8. THE LEASE SURVIVES A FRESH LUA STATE (growth E). A codemode run gets a brand-new state, so both
--    _G tables are empty in it. The lease on disk is what it must find, or one row with ninety-two
--    sandboxed scripts starts ninety-two sets of children - the 554 processes measured at row 37.
host.operation = function(action, request)
  local req = json.decode(request or "") or {}
  if action == "start" then
    starts = starts + 1; owned["fixture-" .. starts] = true
    return json.encode({ operation_id = "fixture-" .. starts })
  end
  if action == "await" then
    if not owned[tostring(req.id or "")] then return json.encode({ error = "operation_not_owned", id = req.id }) end
    return json.encode({ settled = true })
  end
  if action == "read" then
    return json.encode({ content = json.encode({ node_id = "fixture", capabilities = { "bash" }, reason = "asked" }) .. "\n" })
  end
  return json.encode({})
end
cold()
_G.WA_IN_PROBE_CHILD = nil
A._in_probe_child = nil
B.list({ peers = peers, live_capabilities = true })
local first_set = starts
assert(first_set > 0, "the first call in a cold state started no child, so the lease below proves nothing")
-- THE FRESH STATE: every in-memory fact forgotten, the disk untouched.
reset()
_G.WA_IN_PROBE_INFLIGHT = nil
local D = dofile("lua/core/nodes.lua")
local joined = D.list({ peers = peers, live_capabilities = true })
assert(starts == 0, "a fresh Lua state started " .. starts .. " MORE children for peers a previous state had"
  .. " already leased (" .. first_set .. " then " .. starts .. ") - that is the 554-process fan-out")
-- AND IT MUST GET THE ANSWER (review item 1). A joiner that starts nothing but answers probe_timeout or
-- probe_leaseholder_pending has traded a fork storm for a 20-second wait on every peer: the lease carries
-- the holder RESULT precisely so a joiner reads it instead of awaiting an id it does not own.
local answered, pending = 0, 0
for _, row in ipairs(joined) do
  if row.local_node then
    -- the host itself; not a peer we ask
  elseif type(row.capabilities) == "table" and #row.capabilities > 0 then
    answered = answered + 1
  elseif row.capabilities_reason == "probe_timeout" or row.capabilities_reason == "probe_leaseholder_pending" then
    pending = pending + 1
  end
end
assert(answered > 0, "a fresh state that JOINED a leased child got no answer at all (" .. pending
  .. " peers reported a wait, 0 answered) - that is the refused-await defect item 1 names")
assert(pending == 0, pending .. " joined peers were left waiting for an answer that was already published")
-- 9. THE REQUEST ITSELF (review r2, B/MUST 1 and MUST 2). Every other case can pass while the wire is
--    wrong, and it did: the row was green on a tree that sent no owner and a wait_s the host ignores.
local seen = {}
host.operation = function(action, request)
  local req = json.decode(request or "") or {}
  if action == "start" then
    starts = starts + 1
    owned["fixture-" .. starts] = true
    return json.encode({ operation_id = "fixture-" .. starts })
  elseif action == "await" then
    seen[#seen + 1] = { owner = req.owner, wait_ms = req.wait_ms, wait_s = req.wait_s }
    return json.encode({ settled = true, state = "completed", operation_id = req.id })
  elseif action == "read" then
    return json.encode({ content = json.encode({ node_id = "fixture", capabilities = { "bash" }, reason = "asked" }) .. "\n" })
  end
  return json.encode({ cancelled = true })
end
cold()
_G.WA_IN_PROBE_CHILD = nil
A._in_probe_child = nil
B.list({ peers = peers, live_capabilities = true })
assert(#seen > 0, "no await reached the stub, so the request shape below proves nothing")
for _, one in ipairs(seen) do
  assert(one.owner == "nodes-probe", "an await carried owner=" .. tostring(one.owner)
    .. "; the host refuses an ownerless caller, so every peer would answer probe_leaseholder_pending")
  assert(tonumber(one.wait_ms) and tonumber(one.wait_ms) > 0, "an await carried no wait_ms; the host reads wait_ms only")
  assert(one.wait_s == nil, "an await still carried wait_s=" .. tostring(one.wait_s)
    .. "; the host ignores it, so the deadline was a 1 s look followed by a cancel")
  assert(tonumber(one.wait_ms) <= 10000, "an await asked for " .. tostring(one.wait_ms) .. " ms; the host caps it at 10 s")
end
local why = "the ledger is asked (" .. asked .. " list call(s)) and a host that cannot answer says why"

print("nodes probe instances ok: two real instances (" .. unmasked .. " children when unmarked), the marked one "
  .. "starts none, an instance loaded after the mark starts none, a repeated call starts none ("
  .. first .. " then 0, no accumulation), 500 peers are capped at " .. capped_starts
  .. ", and the child environment is named (" .. A.PROBE_CHILD_ENV .. "; " .. why)
