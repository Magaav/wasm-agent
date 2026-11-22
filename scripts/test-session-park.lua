-- A session whose mission was stopped must stay stopped (Fable 22/11).
--
-- Measured 22/11: mission flaky-rel-native-poll was stopped on purpose (unit stopped 00:10Z, HOLD file
-- written) and its session kept working - 196 messages at the stop, 263 an hour later - because each
-- local install had written a "deploy pending: resume after the node swap" wake
-- (lua/core/deploy_pause.lua) and the node's tick performed it. A stopped unit and a HOLD file live
-- outside the node, so nothing in it knew the session was parked, and there was no verb that could
-- say so.
--
-- What this suite measures, on the REAL ledger of a scratch home (a real SQLite database, the real
-- `selfloop` tables, the real tick; no model, no provider, no network, no node):
--
--   * a due wake IS dispatched by the tick in this ledger (the control - so a later zero is the park
--     and not "nothing was due");
--   * parked, an overdue wake dispatches nothing, is counted held, keeps its id, its time, its reason
--     and its prompt, and the status verb says `parked` / `wakes held`;
--   * `selfloop.resume` - the one door `wa chat --resume`, `wa resume --session` and a user message go
--     through - lifts nothing, so coming back to the session cannot unstop it;
--   * release makes the same wake due, the tick runs it exactly ONCE (two ticks, one run);
--   * a release of something that is not parked is refused by name, and a hold an INTERRUPT put there
--     is not released by this verb; a park UPGRADES such a hold, keeping the moment it started.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- The rule a test that writes a ledger must pass before it runs (scripts/lib/test-home-guard.lua): the
-- home must sit under the suite's scratch root and carry none of a live node's own markers.
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
local park = dofile("lua/core/session_park.lua")
local RESUME_REASON = dofile("lua/core/deploy_pause.lua").RESUME_REASON

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
local function contains(text, needle, label)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(label .. ": expected to find " .. tostring(needle) .. " in: " .. tostring(text), 2)
  end
end
local function rows(sql, params)
  local raw = host.sql_query(sql, json.encode(params or {}))
  if type(raw) == "string" then return json.decode(raw) end
  return raw or {}
end
local function wake_of(id) return rows("SELECT * FROM self_wakes WHERE id=?", { id })[1] end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)

-- The scheduler, counted. The tick's own loop hands it a row and reads the receipt; nothing here starts
-- a model, so "the wake ran" is exactly "the scheduler was given this row, once".
local dispatch = { count = 0, order = {} }
local function fake_dispatch(row)
  dispatch.count = dispatch.count + 1
  dispatch.order[#dispatch.order + 1] = row.id
  return { accepted = true, run_id = dispatch.count }
end
local function reset_dispatch() dispatch = { count = 0, order = {} } end

local function session(id)
  return memory.start_session("local", "chat", { id = id, user_id = "master", node_id = "test-node", title = id })
end

-- ---- the control: a due wake IS dispatched in this ledger --------------------------------------
-- Without this, a zero after the park could mean "the tick never dispatches anything here".
local ctl = session("park-control")
local control_wake = selfloop.schedule({ in_seconds = 10, reason = "the control" },
  { session_id = ctl, user_id = "master" })
check(control_wake.ok and control_wake.wake and control_wake.wake.id, "the control wake is scheduled")
reset_dispatch()
local ran = selfloop.tick({ now = T0 + 20, dispatch = fake_dispatch })
eq(tonumber(ran.dispatched) or 0, 1, "without a park the due wake is dispatched")
eq(dispatch.order[1], control_wake.wake.id, "and it is THIS wake the scheduler was given")

-- ---- parked: nothing runs, the wake is held and keeps everything -------------------------------
local sid = session("park-target")
local sched = selfloop.schedule({ in_seconds = 30, reason = RESUME_REASON, prompt = "continue the load test" },
  { session_id = sid, user_id = "master" })
check(sched.ok and sched.wake and sched.wake.id, "the session has a scheduled wake")
local wake_id = sched.wake.id
local before = wake_of(wake_id)
check(before and before.status == "pending", "it is pending before the park")

local parked = park.park({ wanted = sid, reason = "HOLD written: mission stopped" })
eq(parked.code, 0, "park answers with a success exit code")
eq(parked.parked, true, "park reports the session parked")
eq(parked.pending, 1, "and says one wake is being held")
contains(table.concat(parked.lines, "\n"), "no turn runs for this session", "the park says what it did")
contains(table.concat(parked.lines, "\n"), "wa session release " .. sid, "and names the release command")
eq(park.park({ wanted = sid, reason = "a second recipe" }).already, true, "parking twice is idempotent")

-- Past its time by an hour: the tick dispatches nothing and counts it held.
reset_dispatch()
local held_tick = selfloop.tick({ now = T0 + 3630, dispatch = fake_dispatch })
eq(tonumber(held_tick.dispatched) or 0, 0, "a parked session's due wake is not dispatched")
eq(dispatch.count, 0, "and the scheduler was given nothing")
check((tonumber(held_tick.paused) or 0) >= 1, "the tick reports the wake as held")
local after = wake_of(wake_id)
check(after ~= nil, "the wake is still in the ledger (nothing was dropped)")
eq(after.status, "pending", "it is still pending - a hold decides nothing")
eq(tonumber(after.due_at), tonumber(before.due_at), "its time was not moved")
eq(tostring(after.reason), tostring(before.reason), "nor its reason")
eq(tostring(after.prompt), tostring(before.prompt), "nor its prompt")
eq(memory.message_count(sid), 0, "and the session has no new message")

-- The status surface: the wake is held, and by a park and not by an interrupt.
local status = park.status({ wanted = sid })
eq(status.code, 0, "status answers for a parked session")
contains(table.concat(status.lines, "\n"), "parked since", "status says the session is parked")
contains(table.concat(status.lines, "\n"), "1 wake held", "status says the wake is held")
eq(status.parked, true, "status reports the park as a fact, not as a sentence only")
local all = park.status({})
check((tonumber(all.count) or 0) >= 1, "the whole-node listing finds the parked session")
contains(table.concat(all.lines, "\n"), sid, "and names it")
contains(selfloop.footer_text(sid), "wake held (session parked)", "the footer says held, not paused")

-- ---- coming back is not the release ------------------------------------------------------------
local resumed = selfloop.resume(sid)
eq(resumed.resumed, false, "a resume does not lift a park")
eq(resumed.parked, true, "it says why")
contains(tostring(resumed.note or ""), "wa session release", "and names the command that does")
selfloop.on_user_message(sid, { user_id = "master" })
reset_dispatch()
eq(tonumber(selfloop.tick({ now = T0 + 3635, dispatch = fake_dispatch }).dispatched) or 0, 0,
  "a user message in the session does not unstop it either")
eq(park.park({ wanted = sid }).parked, true, "and the hold is still there afterwards")
eq(selfloop.hold(sid) ~= nil and selfloop.hold(sid).kind, "park", "with its kind intact")

-- ---- release: the same wake, due again, ONCE ---------------------------------------------------
local released = park.release({ wanted = sid })
eq(released.code, 0, "release answers with a success exit code")
eq(released.released, true, "release reports the park lifted")
eq(released.pending, 1, "and one wake pending again")
eq(released.overdue, 1, "counted as already due")
eq(selfloop.hold(sid), nil, "the hold row is gone")
reset_dispatch()
local run = selfloop.tick({ now = T0 + 3640, dispatch = fake_dispatch })
eq(tonumber(run.dispatched) or 0, 1, "the released wake runs")
eq(dispatch.count, 1, "once")
eq(dispatch.order[1], wake_id, "and it is the same wake, not a new one")
reset_dispatch()
eq(tonumber(selfloop.tick({ now = T0 + 3700, dispatch = fake_dispatch }).dispatched) or 0, 0, "a second tick runs nothing")
eq(dispatch.count, 0, "so the wake ran exactly once")

-- A second release has nothing to do, and says so instead of claiming an effect.
local again = park.release({ wanted = sid })
eq(again.code, 1, "releasing a session that is not parked is a refusal")
eq(again.released, nil, "and it does not claim to have released anything")
contains(table.concat(again.lines, "\n"), "is not parked", "the refusal says so")

-- ---- an interrupt hold is not this verb's ------------------------------------------------------
-- The schedule follows the run (13/11): an interrupted run holds it and coming back re-arms it. The
-- release verb must not lift THAT hold - it would re-arm a schedule the user stopped with Esc - and a
-- park over it must not move the moment the schedule stopped.
local held_by_interrupt = session("park-interrupt")
selfloop.schedule({ in_seconds = 10, reason = "after the interrupt" }, { session_id = held_by_interrupt, user_id = "master" })
selfloop.pause(held_by_interrupt, "master", "run_cancelled", { now = T0 })
local refused = park.release({ wanted = held_by_interrupt })
eq(refused.code, 1, "releasing an interrupted session is refused")
eq(refused.error, "session_held_by_interrupt", "by name")
contains(table.concat(refused.lines, "\n"), "wa chat --resume " .. held_by_interrupt, "with the command that does it")
check(selfloop.paused(held_by_interrupt) ~= nil, "and the interrupt hold is untouched")
local upgraded = park.park({ wanted = held_by_interrupt, reason = "HOLD written" })
eq(upgraded.parked, true, "parking an already-held session parks it")
eq(upgraded.upgraded, true, "by upgrading the hold rather than replacing it")
eq(selfloop.hold(held_by_interrupt).since, T0, "the moment the schedule stopped is not moved by the park")
eq(resumed ~= nil and selfloop.resume(held_by_interrupt).resumed, false, "and that hold is a park now: a resume lifts nothing")
park.release({ wanted = held_by_interrupt })

-- ---- naming: a full id, a unique prefix, an ambiguous one, and nowhere at all --------------------
local a1, a2 = session("park-prefix-1"), session("park-prefix-2")
local by_prefix = park.park({ wanted = "park-prefix-1" })
eq(by_prefix.session_id, a1, "an exact id parks that session")
park.release({ wanted = a1 })
local ambiguous = park.park({ wanted = "park-prefix-" })
eq(ambiguous.code, 2, "a prefix that names two sessions is refused")
eq(ambiguous.error, "ambiguous_session", "by name")
contains(table.concat(ambiguous.lines, "\n"), "wa session park <id>", "and it asks for the full id")
eq(selfloop.hold(a1), nil, "and it parked neither of them")
eq(selfloop.hold(a2), nil, "")
local missing = park.park({ wanted = "no-such-session-anywhere" })
eq(missing.code, 2, "an id no session has is refused")
eq(missing.error, "no_such_session", "by name")
contains(table.concat(missing.lines, "\n"), "list them with: wa sessions", "with the way to find one")
eq(park.park({}).code, 2, "parking nothing is a usage refusal, not a park of anything")

-- The park of a session that has no wake is a park with nothing held: an honest zero, not an error.
local quiet = session("park-quiet")
local quiet_park = park.park({ wanted = quiet })
eq(quiet_park.parked, true, "a session with no wake can be parked")
eq(quiet_park.pending, 0, "and it says nothing is held")
eq(park.status({ wanted = quiet }).pending, 0, "status agrees")
contains(selfloop.footer_text(quiet), "", "a parked session with no wake says nothing in the footer")
park.release({ wanted = quiet })

-- Which half answered the wake queries here: the `selfloop` component when this home has it provisioned,
-- else the built-in. NOT a check - both are correct and the park is kernel state either way - but a log
-- that does not say it would let a green row hide that the seam was never reached.
local seam_active = (select(1, dofile("lua/core/features.lua").seam("selfloop")) and true) or false
print("session park: selfloop seam " .. (seam_active and "active (component)" or "native"))
print("session park ok (" .. checks .. " checks)")
