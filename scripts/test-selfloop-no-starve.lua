-- A ROW THAT CANNOT BE DISPATCHED THIS TICK NEVER TAKES A SLOT (Fable 24/11 12:55Z).
--
-- MEASURED on the live node: no self-wake had been dispatched since 10:27Z, and a parked session
-- (icons 5f0fb651) had 13 overdue rows. The tick's plan is the 8 earliest-due pending rows
-- (rust/components/selfloop/src/logic.rs:31, DUE_LIMIT = 8) and the node then skipped every row of a held
-- session (lua/core/selfloop.lua:1607-1611, before this change), so every page of every tick was 8 rows of
-- one held session and nothing else on the node was ever reached. The proof was a canary: a wake of a FREE
-- session, due 12:39:04Z, was still pending an hour later.
--
-- The property, and the reason a wider page would not be enough: a row this tick cannot dispatch - a held
-- session, a deploy waiting or installing, a row deferred with a backoff that has not elapsed, a row another
-- process claimed - must never take a slot that a dispatchable row needs.
--
-- For each shape, 9 rows of that shape are seeded AHEAD of one free, due row (9 > DUE_LIMIT = 8, so before
-- the fix the page is made of nothing else), and one tick must dispatch exactly the free row:
--
--   * held    - a parked session's 9 overdue rows (kind='park' in self_wake_pauses): RED before the fix, on
--               both paths - this is the measured starvation;
--   * not-due - 9 rows whose due_at is still ahead: the due predicate already excludes them (a pin, green
--               before and after, so a future page cannot start reading rows it must not dispatch);
--   * claimed - 9 rows another process claimed (status='dispatching'): the status predicate already excludes
--               them (also a pin);
--   * deploy  - the gate is NOT a slot problem and this row does not pretend it is: while the installer's
--               real marker (<data>/deploy-pending.json) is there, the tick starts no turn at all (by design,
--               22/11), so the free row waits - bounded by the marker's own declared bound - and every row is
--               dispatched exactly once (SEED + 1 of them) on the ticks after the marker is removed;
--   * mix     - all three slot shapes at once, 9 each, ahead of one free row: one tick, one dispatch.
--
-- Both paths, because the plan's query is the component's and the row query is the native loop's: the native
-- instance is pinned (seam_override false), the component instance is pinned true, and the component half
-- fails the row if ANY call fell back to the native path - a fallback would compare the native path with
-- itself. With no reachable component the half is SKIPPED and says so (never counted as a pass), unless the
-- runner promised one (WA_SELFLOOP_COMPONENT_WASM), where a missing component is the runner's failure.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- The rule a test that writes a ledger must pass first (scripts/lib/test-home-guard.lua).
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local deploy_pause = dofile("lua/core/deploy_pause.lua")
local MARKER = deploy_pause.path()

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
local function decode(raw)
  if type(raw) == "string" then return json.decode(raw) end
  return raw
end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end
local function exec(sql, params) return decode(host.sql_exec(sql, json.encode(params or {}))) end

local T0 = 1700000000
local DUE_LIMIT = 8
local SEED = DUE_LIMIT + 1

-- The installer's marker, as upgrade.sh writes it: a real file in <data>, read by the tick's own gate with no
-- injection. `since` is the fake clock's, because the tick judges the marker's bound against the clock it is
-- given.
local function marker_absent(label)
  local ok, text = pcall(host.read_file, MARKER)
  check(not (ok and type(text) == "string" and #text > 0), label .. ": " .. tostring(MARKER))
end
local function write_marker(since)
  local body = json.encode({ to = "dead0000beef1111", state = "deploy_pending", since = since,
    bound_seconds = 900, by = "scripts/test-selfloop-no-starve.lua" })
  local ok = pcall(host.write_file, MARKER, body)
  check(ok, "the installer's marker is written at " .. tostring(MARKER))
end
local function remove_marker() pcall(host.remove_file, MARKER) end

-------------------------------------------------------------------------- one path
local function runner(module, tag)
  local base = "nostarve-" .. tag .. "-" .. tostring(host.uuid()):sub(1, 8)
  local state = { ids = {}, count = 0 }
  local function dispatch(row)
    state.count = state.count + 1
    state.ids[#state.ids + 1] = row.id
    return { accepted = true, run_id = state.count }
  end
  local function reset()
    exec("DELETE FROM self_wakes WHERE session_id LIKE ?", { base .. "%" })
    exec("DELETE FROM self_wake_pauses WHERE session_id LIKE ?", { base .. "%" })
    state.ids, state.count = {}, 0
  end
  local function session(name)
    local sid = memory.start_session("local", "chat", { id = base .. "-" .. name, user_id = "master",
      node_id = "test-node", title = "no-starve " .. name })
    return sid, { user_id = "master", role = "master", session_id = sid }
  end
  local function schedule(ctx, seconds, reason)
    local answer = module.schedule({ in_seconds = seconds, reason = reason }, ctx)
    check(answer and answer.ok and answer.wake and answer.wake.id,
      "a wake is scheduled (" .. tostring(reason) .. "): " .. json.encode(answer))
    return answer.wake.id
  end
  local function row_of(id) return rows("SELECT * FROM self_wakes WHERE id=?", { id })[1] end
  local function still_pending(ids, label)
    for _, id in ipairs(ids) do
      local row = row_of(id)
      check(row ~= nil, label .. ": the row " .. tostring(id) .. " still exists")
      eq(row.status, "pending", label .. ": the row " .. tostring(id) .. " is still pending")
    end
  end
  return { base = base, state = state, dispatch = dispatch, reset = reset, session = session,
    schedule = schedule, row_of = row_of, still_pending = still_pending }
end

local function run_all(module, tag)
  local r = runner(module, tag)
  local dispatched

  -- ---- held: a parked session's overdue rows, ahead of one free row ----------------------------
  r.reset()
  local held_sid, held_ctx = r.session("held")
  local held_ids = {}
  for i = 1, SEED do held_ids[#held_ids + 1] = r.schedule(held_ctx, 10, "held " .. i) end
  local parked = module.park(held_sid, "master", "session was stopped", { now = T0 })
  check(parked and parked.ok, "the session is parked (a real self_wake_pauses row): " .. json.encode(parked))
  local free_sid, free_ctx = r.session("free")
  local free_id = r.schedule(free_ctx, 20, "the free row")
  dispatched = module.tick({ now = T0 + 60, dispatch = r.dispatch })
  eq(dispatched.dispatched, 1, "held: one tick dispatches the free row")
  eq(#r.state.ids, 1, "held: exactly one row was handed to the scheduler")
  eq(r.state.ids[1], free_id, "held: and it is the free row, not a row of the parked session")
  eq(dispatched.paused, SEED, "held: the tick reports the parked session's overdue rows as held")
  r.still_pending(held_ids, "held")
  for _, id in ipairs(held_ids) do
    eq(tonumber(r.row_of(id).due_at), T0 + 10, "held: a held row keeps its own time")
  end
  check(r.row_of(free_id).status ~= "pending", "held: the dispatched row is claimed, not left pending")

  -- ---- not-due: a backoff that has not elapsed (a pin) -----------------------------------------
  r.reset()
  local future_sid, future_ctx = r.session("future")
  local future_ids = {}
  for i = 1, SEED do future_ids[#future_ids + 1] = r.schedule(future_ctx, 300, "not due yet " .. i) end
  local _, free2_ctx = r.session("free2")
  local free2 = r.schedule(free2_ctx, 20, "the free row among not-due rows")
  dispatched = module.tick({ now = T0 + 60, dispatch = r.dispatch })
  eq(dispatched.dispatched, 1, "not-due: one tick dispatches the free row")
  eq(r.state.ids[1], free2, "not-due: and it is the free row")
  r.still_pending(future_ids, "not-due")
  for _, id in ipairs(future_ids) do
    eq(tonumber(r.row_of(id).due_at), T0 + 300, "not-due: a row whose backoff has not elapsed keeps its time")
  end

  -- ---- claimed: another process has the row (a pin) --------------------------------------------
  r.reset()
  local busy_sid, busy_ctx = r.session("busy")
  local busy_ids = {}
  for i = 1, SEED do busy_ids[#busy_ids + 1] = r.schedule(busy_ctx, 10, "claimed " .. i) end
  local claimed = 0
  for _ = 1, SEED do
    if module.claim_due(busy_sid, "master", { now = T0 + 20 }) then claimed = claimed + 1 end
  end
  eq(claimed, SEED, "claimed: every seeded row is claimed the way another process claims it")
  local _, free3_ctx = r.session("free3")
  local free3 = r.schedule(free3_ctx, 20, "the free row among claimed rows")
  dispatched = module.tick({ now = T0 + 60, dispatch = r.dispatch })
  eq(dispatched.dispatched, 1, "claimed: one tick dispatches the free row")
  eq(r.state.ids[1], free3, "claimed: and it is the free row")
  eq(dispatched.reconciled, 0, "claimed: a fresh claim is not reconciled as an interrupted dispatch")
  for _, id in ipairs(busy_ids) do
    eq(r.row_of(id).status, "dispatching", "claimed: the other process's row is untouched")
  end

  -- ---- deploy: the gate, and the promise that nothing is stranded by it ------------------------
  r.reset()
  marker_absent("deploy: the fixture starts with no installer marker")
  local dep_sid, dep_ctx = r.session("deploy")
  local dep_ids = {}
  for i = 1, SEED do dep_ids[#dep_ids + 1] = r.schedule(dep_ctx, 10, "waiting " .. i) end
  local _, free4_ctx = r.session("free4")
  local free4 = r.schedule(free4_ctx, 20, "the free row behind the gate")
  write_marker(T0 - 60)
  dispatched = module.tick({ now = T0 + 60 })
  eq(dispatched.dispatched, 0, "deploy: no turn starts while the installer's marker is there")
  eq(dispatched.deploy_waiting, 1, "deploy: and the tick says so, by name")
  eq(#r.state.ids, 0, "deploy: nothing reached the scheduler")
  r.still_pending(dep_ids, "deploy")
  eq(r.row_of(free4).status, "pending", "deploy: the free row was not consumed by the gate")
  remove_marker()
  marker_absent("deploy: the marker is gone")
  for _ = 1, 3 do module.tick({ now = T0 + 60, dispatch = r.dispatch }) end
  eq(#r.state.ids, SEED + 1, "deploy: after the gate lifts every row is dispatched exactly once")
  local saw_free = false
  for _, id in ipairs(r.state.ids) do if id == free4 then saw_free = true end end
  check(saw_free, "deploy: the free row is among them")

  -- ---- mix: every slot shape at once, 9 each, ahead of one free row -----------------------------
  r.reset()
  local mixheld, mixheld_ctx = r.session("mixheld")
  for i = 1, SEED do r.schedule(mixheld_ctx, 10, "mix held " .. i) end
  check(module.park(mixheld, "master", "session was stopped", { now = T0 }).ok, "mix: the session is parked")
  local mixbusy, mixbusy_ctx = r.session("mixbusy")
  for i = 1, SEED do r.schedule(mixbusy_ctx, 10, "mix claimed " .. i) end
  for _ = 1, SEED do module.claim_due(mixbusy, "master", { now = T0 + 20 }) end
  local _, mixfuture_ctx = r.session("mixfuture")
  for i = 1, SEED do r.schedule(mixfuture_ctx, 500, "mix not due " .. i) end
  local _, mixfree_ctx = r.session("mixfree")
  local mixfree = r.schedule(mixfree_ctx, 400, "the one free row")
  dispatched = module.tick({ now = T0 + 400, dispatch = r.dispatch })
  eq(dispatched.dispatched, 1, "mix: one tick dispatches the single free row, whatever is in front of it")
  eq(r.state.ids[1], mixfree, "mix: and it is that row")
  eq(dispatched.paused, SEED, "mix: the parked session's rows are counted held")
  r.reset()
end

-------------------------------------------------------------------------- the two paths
-- Two instances of the module in one process, each pinned: the switch is the `selfloop` feature, which on a
-- machine with the component installed would route BOTH (scripts/test-selfloop-component.lua measured that).
local function instance(seam)
  local module = dofile("lua/core/selfloop.lua")
  module.setup()
  module.seam_override = seam and function() return true, "active_component" end
    or function() return false, "seam_disabled" end
  module.set_test_clock(function() return T0 end)
  return module
end

local native = instance(false)
run_all(native, "native")
print("selfloop no-starve: the native path ok (" .. checks .. " checks)")

local reachable = nil
if type(host.selfloop) == "function" then
  local probe = decode(host.selfloop(json.encode({ op = "summary", session_id = "", now = 0 })))
  reachable = type(probe) == "table" and probe.ok == true
  if not reachable then
    print("note: the selfloop component did not answer: " .. tostring(type(probe) == "table" and probe.error or probe))
  end
end

if reachable then
  local logged, real_log = {}, host.log
  host.log = function(line) logged[#logged + 1] = tostring(line) end
  local called, failure = pcall(function() run_all(instance(true), "component") end)
  host.log = real_log
  if not called then error(failure, 0) end
  local fell_back = {}
  for _, line in ipairs(logged) do
    if tostring(line):find("served natively", 1, true) then fell_back[#fell_back + 1] = tostring(line) end
  end
  check(#fell_back == 0, "the component answered every call (no native fallback): " .. tostring(fell_back[1]))
elseif (os.getenv("WA_SELFLOOP_COMPONENT_WASM") or "") ~= "" then
  error("the runner promised the selfloop component (WA_SELFLOOP_COMPONENT_WASM="
    .. tostring(os.getenv("WA_SELFLOOP_COMPONENT_WASM")) .. ") and it did not answer")
else
  print("SKIP selfloop no-starve: the component half (no selfloop component reachable in this process)")
end

print("selfloop no-starve ok: " .. checks .. " checks, native"
  .. (reachable and " + component" or " (component SKIPPED)"))
