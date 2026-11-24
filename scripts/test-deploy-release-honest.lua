-- A PAUSE WHOSE UPDATE DID NOT HAPPEN SAYS SO (r8c 1, Fable 24/11).
--
-- MEASURED (deploy-hold-never-fails-our-load/paused-evidence.log, 24/11): seven sessions sat 20-37 minutes after a
-- pause whose install never swapped anything - 16:48Z and 17:06Z were a TEST LEAK writing the node's real
-- deploy-pending.json, not an install - and their resume wakes (5ffa1bd2, d1cd45bc, 8117d28f) stayed pending even
-- through the real installs at 17:12-17:24.
--
-- What this row pins, on the real modules, the real marker file and the real tick:
--   * a marker PAST ITS BOUND releases the pause - one resume turn per session - because the installer that wrote
--     it is gone and a crashed (or leaked) marker must not hold a session for ever;
--   * the released turn CARRIES THE MACHINE'S OWN LINE, "[deploy] the update did not happen", so a model is not
--     left to invent what was installed;
--   * and a LIVE marker still holds: nothing is released and no turn is spent (the control, so a release that
--     happens always is not read as this fix).
-- The ledger, the marker file and the tick are the product's own; the scheduler is a counter, because a row must
-- never start a paid turn.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local pause = dofile("lua/core/deploy_pause.lua")
local data = dofile("lua/core/paths.lua").data()
local MARKER = data .. "/" .. pause.FILE

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)

local sent = { count = 0, ids = {} }
local function counted(row)
  sent.count = sent.count + 1
  sent.ids[#sent.ids + 1] = tostring(row.id)
  return { accepted = true, run_id = sent.count }
end
local function marker(since, bound)
  local ok = pcall(host.write_file, MARKER, json.encode({ to = "deadbeefcafe", state = "deploy_pending",
    since = since, bound_seconds = bound, by = "scripts/test-deploy-release-honest.lua" }))
  check(ok, "the installer's marker is written at " .. MARKER)
end
local function unpause(session)
  local answer = pause.at_boundary({ session_id = session, user_id = "master" }, "finish the request",
    { now = T0, no_record = true, notes = function() end,
      schedule = function(args) return selfloop.schedule(args, { session_id = session, user_id = "master" }) end })
  check(type(answer) == "table" and type(answer.wake) == "table", "the turn paused and armed one resume: " .. json.encode(answer))
  return answer.wake.id
end

-- ---- 1. a LIVE marker holds: no release, no turn -------------------------------------------------
local live_session = memory.start_session("local", "chat", { id = "r8c-live", user_id = "master", title = "live" })
marker(T0 - 60, 900)
local live_wake = unpause(live_session)
local before = rows("SELECT * FROM self_wakes WHERE id=?", { live_wake })[1]
sent = { count = 0, ids = {} }
local held = selfloop.tick({ now = T0 + 5, dispatch = counted })
eq(held.deploy_waiting, 1, "a live marker holds the tick (the gate)")
eq(sent.count, 0, "and spends no turn")
eq(tonumber(rows("SELECT due_at FROM self_wakes WHERE id=?", { live_wake })[1].due_at), tonumber(before.due_at),
  "the armed resume keeps its own time while the install is live")

-- ---- 2. the installer is gone (past its bound): ONE resume turn, and it says what happened ------
marker(T0 - 3600, 900)   -- since + bound is an hour in the past: an installer that never came back
sent = { count = 0, ids = {} }
local released = selfloop.tick({ now = T0 + 5, dispatch = counted })
eq(sent.count, 1, "exactly ONE resume turn is spent for the paused session")
eq(sent.ids[1], live_wake, "and it is the resume this pause armed, not another row")
eq(released.released, 1, "the tick reports the release (one row)")
local row = rows("SELECT * FROM self_wakes WHERE id=?", { live_wake })[1]
check(type(pause.NOT_HAPPENED) == "string" and pause.NOT_HAPPENED ~= "",
  "the module names the line a release carries (got " .. tostring(pause.NOT_HAPPENED) .. ")")
check((row.prompt or ""):find(pause.NOT_HAPPENED, 1, true) ~= nil,
  "the released turn carries the machine's own line (" .. pause.NOT_HAPPENED .. "): " .. tostring(row.prompt):sub(1, 160))
check((row.prompt or ""):find("finish the request", 1, true) ~= nil,
  "and the request the turn was continuing stays in it, below the line")
eq(row.status, "dispatching", "the row is claimed by the release and handed over once")

pcall(host.remove_file, MARKER)
print("deploy release ok (" .. checks .. " checks): a leaked or crashed marker releases ONE resume turn that says the update did not happen")
