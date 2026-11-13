-- Interrupt and self-wakes in sync (operator, 13/11: "if we interrupt a session run while it has
-- scheduled wakes, we keep on getting recursive errors. interrupting a session should be in sync with
-- the schedule, once interrupted, it stops, once resumes, it resumes").
--
-- What was wrong, before this suite: an interrupt stopped the run and left the session's schedule
-- armed. `agent:run` fails the turn with `run_cancelled`, the wake was settled as a *failure*, a
-- repeating wake was re-armed for its cadence (`selfloop.finish`), and the CLI's own interrupt flag
-- stays set until the next submitted line (`rust/wa-capabilities/src/host.rs:428`, cleared only at
-- :3421) - so every wake claimed afterwards failed at once and re-armed again: one failed turn and one
-- error line per interval, for ever.
--
-- The claims here, on a fake clock and a counted scheduler stub (no model, no provider, no node):
--
--   * a cancel requested on the thread means the next claim starts no turn at all - that claim is the
--     CLI's recursive-error loop;
--   * a held session dispatches nothing: N minutes of fake clock, 0 runs, 0 errors;
--   * a hold loses nothing - the wakes keep their order and their targets, and an overdue one fires
--     exactly once after the resume, not once per missed interval;
--   * a wake whose turn the user stopped settles `cancelled`, is never retried and never re-arms;
--   * a user message (`selfloop.on_user_message`), and `wa resume --session <id>`, both re-arm the
--     schedule (`wa chat --resume` and `wa resume --session` call `selfloop.resume`).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()

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
local function rows(sql, params)
  return decode(host.sql_query(sql, json.encode(params or {})))
end
local function row_of(id)
  return rows("SELECT * FROM self_wakes WHERE id=?", { id })[1]
end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)

-- The scheduler, counted: an accepted receipt, and the order of what it was given.
local dispatch = { count = 0, order = {} }
local function fake_dispatch(row)
  dispatch.count = dispatch.count + 1
  dispatch.order[#dispatch.order + 1] = row.id
  return { accepted = true, run_id = dispatch.count }
end
local function reset_dispatch() dispatch = { count = 0, order = {} } end

-- ---- a cancel requested on this thread holds the schedule at the claim -----------------------
-- The CLI's loop, first: Esc leaves `CLI_INTERRUPT` set until the next submitted line is submitted, so
-- the claim made at the idle prompt must not start a turn. Before the fix it did - the turn failed
-- `run_cancelled` at once (`lua/core/agent.lua`, the round check) and a repeating wake re-armed.
local cancel_session = memory.start_session("local", "chat",
  { id = "wakes-pause-cancel", user_id = "master", node_id = "test-node", title = "cancelled claim" })
local cctx = { user_id = "master", role = "master", session_id = cancel_session }

-- The control, on a session of its own: with no cancel requested, a due wake IS claimable - so the
-- check below fails on a build where the claim ignores the cancel, and not because nothing is due.
local control_session = memory.start_session("local", "chat",
  { id = "wakes-pause-control", user_id = "master", node_id = "test-node", title = "control" })
local ctl = { user_id = "master", role = "master", session_id = control_session }
local control_wake = selfloop.schedule({ in_seconds = 10, reason = "the control" }, ctl)
local real_cancel = host.run_cancelled
host.run_cancelled = function() return json.encode({ cancelled = false, run_cancel = false, subagent_cancel = false }) end
local claimable = selfloop.claim_due(control_session, "master", { now = T0 + 20 })
check(claimable and claimable.id == control_wake.wake.id, "without a cancel request the wake is claimable")

local due_wake = selfloop.schedule({ in_seconds = 10, reason = "after the interrupt" }, cctx)
check(due_wake.ok, "a due wake is scheduled on the cancelled session")
host.run_cancelled = function() return json.encode({ cancelled = true, run_cancel = true, subagent_cancel = false }) end
local not_claimed = selfloop.claim_due(cancel_session, "master", { now = T0 + 20 })
check(not_claimed == nil, "a cancel requested on the thread means the wake is NOT claimed")
check(selfloop.paused(cancel_session) ~= nil, "and the schedule is held by that same observation")
reset_dispatch()
eq(selfloop.tick({ now = T0 + 90, dispatch = fake_dispatch }).dispatched, 0,
  "so the tick starts no run, and no turn can fail run_cancelled")
eq(dispatch.count, 0, "no run was started under the cancel")
host.run_cancelled = real_cancel
local still_there = row_of(due_wake.wake.id)
eq(still_there.status, "pending", "the wake that was not claimed is still pending, not lost")
check(tonumber(still_there.due_at) == T0 + 10, "and keeps its own time")

-- Put this session's row away so the counts below belong to the sessions they name: resume it, claim
-- the wake once, and settle it as the cancelled turn it would have been.
selfloop.resume(cancel_session, "master", { now = T0 + 91 })
local after_resume = selfloop.claim_due(cancel_session, "master", { now = T0 + 91 })
check(after_resume and after_resume.id == due_wake.wake.id, "the held wake is claimed once after the resume")
selfloop.settle_interrupted(after_resume, { now = T0 + 91 })

-- ---- one interrupt, two wakes: nothing fires, nothing errors --------------------------------
local session = memory.start_session("local", "chat",
  { id = "wakes-pause-session", user_id = "master", node_id = "test-node", title = "wakes and pauses" })
local ctx = { user_id = "master", role = "master", session_id = session }
local first = selfloop.schedule({ in_seconds = 60, reason = "first wake" }, ctx)
local second = selfloop.schedule({ in_seconds = 120, reason = "second wake" }, ctx)
check(first.ok and second.ok, "two wakes are scheduled: " .. json.encode(first))

-- The appending half of the fix, called exactly as `agent.lua` calls it the moment a run observes the
-- user's cancel (`note_interrupt`, lua/core/agent.lua).
local held = selfloop.pause(session, "master", "run_cancelled", { now = T0 })
check(held.ok and held.paused, "the interrupt holds the session's schedule: " .. json.encode(held))
check(selfloop.pause(session, "master", "run_cancelled", { now = T0 + 5 }).already,
  "a second observation of the same interrupt does not move the hold")

reset_dispatch()
for _, at in ipairs({ 60, 61, 90, 120, 121, 180, 240, 300, 420, 600 }) do
  local out = selfloop.tick({ now = T0 + at, dispatch = fake_dispatch })
  eq(out.dispatched, 0, "no wake is dispatched while the session is held (at +" .. at .. "s)")
  eq(out.paused, (at >= 120 and 2 or 1), "the tick reports the held rows (at +" .. at .. "s)")
  local claimed = selfloop.claim_due(session, "master", { now = T0 + at })
  check(claimed == nil, "the CLI cannot claim a wake while the session is held (at +" .. at .. "s)")
end
eq(dispatch.count, 0, "N minutes of fake clock started no run at all")
local failed = rows("SELECT COUNT(*) AS n FROM self_wakes WHERE session_id=? AND (status='failed' OR last_error<>'')",
  { session })[1]
eq(tonumber(failed.n), 0, "no wake was recorded as an error while the session was held")

-- The hold is the *only* reason nothing fired: the same rows fire once it is gone.
local summary = selfloop.summary(session)
eq(summary.paused, true, "the session reads as held")
eq(summary.pending, 2, "both wakes are still pending, not lost")
eq(selfloop.footer_text(session), "\226\143\176 2 wakes paused",
  "the footer fact says the count is paused, not a next time")
local listed = selfloop.list({}, ctx)
eq(listed.paused, true, "wake_list says the schedule is held")
eq(#listed.wakes, 2, "wake_list still shows both wakes")

-- ---- resume: each overdue wake fires once, in order -----------------------------------------
local resumed = selfloop.resume(session, "master", { now = T0 + 600 })
check(resumed.resumed, "the resume lifts the hold: " .. json.encode(resumed))
eq(resumed.pending, 2, "the resume reports the wakes it re-armed")
eq(tonumber(resumed.overdue), 2, "both were overdue during the hold")
check(not selfloop.summary(session).paused, "the session is not held any more")

reset_dispatch()
local after = selfloop.tick({ now = T0 + 600, dispatch = fake_dispatch })
eq(after.dispatched, 2, "both overdue wakes fire on the first tick after the resume")
eq(dispatch.count, 2, "the scheduler was asked once per wake, not once per missed interval")
eq(dispatch.order[1], first.wake.id, "they fire in their own order (earliest first)")
eq(dispatch.order[2], second.wake.id, "and in their own order (second)")
eq(selfloop.tick({ now = T0 + 601, dispatch = fake_dispatch }).dispatched, 0,
  "a claimed wake is not dispatched again")
eq(selfloop.claim_due(session, "master", { now = T0 + 601 }), nil, "and nothing is left to claim")

-- ---- an overdue repeating wake fires exactly once, not once per interval ---------------------
local repeat_session = memory.start_session("local", "chat",
  { id = "wakes-pause-repeat", user_id = "master", node_id = "test-node", title = "repeating" })
local rctx = { user_id = "master", role = "master", session_id = repeat_session }
local repeater = selfloop.schedule({ in_seconds = 30, every_seconds = 300, reason = "poll the build" }, rctx)
check(repeater.ok, "the repeating wake is scheduled: " .. json.encode(repeater))
selfloop.pause(repeat_session, "master", "run_cancelled", { now = T0 })
reset_dispatch()
for _, at in ipairs({ 30, 330, 630, 930, 1230, 1500 }) do
  eq(selfloop.tick({ now = T0 + at, dispatch = fake_dispatch }).dispatched, 0,
    "a held repeating wake does not fire (at +" .. at .. "s)")
end
selfloop.resume(repeat_session, "master", { now = T0 + 1500 })
local claimed_once = selfloop.claim_due(repeat_session, "master", { now = T0 + 1500 })
check(claimed_once and claimed_once.id == repeater.wake.id, "the overdue wake is claimed once after the resume")
eq(selfloop.claim_due(repeat_session, "master", { now = T0 + 1500 }), nil,
  "and it is not claimed five times for the five intervals that passed")

-- ---- a run cancelled by the user is never retried, and never schedules another wake ----------
local retry_session = memory.start_session("local", "chat",
  { id = "wakes-pause-retry", user_id = "master", node_id = "test-node", title = "no retry" })
local tctx = { user_id = "master", role = "master", session_id = retry_session }
local repeating = selfloop.schedule({ in_seconds = 5, every_seconds = 60, reason = "keep watching" }, tctx)
check(repeating.ok, "the repeating wake is scheduled: " .. json.encode(repeating))
local running = selfloop.claim_due(retry_session, "master", { now = T0 + 10 })
check(running and running.id == repeating.wake.id, "the wake is claimed for its turn")
-- What `selfloop.run_wake` does when the turn it started stops with `run_cancelled`:
-- `if not ok and M.cancelled_stop(result) then M.settle_interrupted(row, ...)`.
check(selfloop.cancelled_stop("run_cancelled"), "a cancelled turn is recognised by its own error")
check(selfloop.cancelled_stop("lua/core/agent.lua:2132: run_cancelled"),
  "and when the error carries its location")
check(not selfloop.cancelled_stop("provider_failed"), "a provider failure is not a cancellation")
eq(selfloop.settle_interrupted(running, { now = T0 + 10 }).status, "cancelled",
  "the cancelled wake settles cancelled")
local settled = row_of(repeating.wake.id)
eq(settled.status, "cancelled", "and the row says cancelled")
eq(tonumber(settled.due_at), nil, "with no next time: it never schedules another wake")
reset_dispatch()
for _, at in ipairs({ 70, 130, 600, 3600 }) do
  eq(selfloop.tick({ now = T0 + at, dispatch = fake_dispatch }).dispatched, 0,
    "a cancelled wake is not retried by the scheduler (at +" .. at .. "s)")
end
eq(dispatch.count, 0, "the cancelled wake started no further run")

-- ---- the user coming back: a message, and `wa resume` ---------------------------------------
local back_session = memory.start_session("local", "chat",
  { id = "wakes-pause-message", user_id = "master", node_id = "test-node", title = "back" })
local bctx = { user_id = "master", role = "master", session_id = back_session }
local waiting = selfloop.schedule({ in_seconds = 30, reason = "waiting for the reader" }, bctx)
check(waiting.ok, "a wake is scheduled before the interrupt")
selfloop.pause(back_session, "master", "run_cancelled", { now = T0 })
eq(selfloop.tick({ now = T0 + 40, dispatch = fake_dispatch }).dispatched, 0, "held, so it does not fire")
-- `agent:run` calls this after it records a user turn (`lua/core/agent.lua`, `on_user_message`).
local answered = selfloop.on_user_message(back_session, { user_id = "master", message_id = "m1" })
check(answered and answered.resumed, "a real user message re-arms the held schedule: " .. json.encode(answered))
reset_dispatch()
eq(selfloop.tick({ now = T0 + 41, dispatch = fake_dispatch }).dispatched, 1,
  "and the wake that came due while it was held fires once")
eq(selfloop.tick({ now = T0 + 42, dispatch = fake_dispatch }).dispatched, 0, "exactly once")

-- The event half: an `on:[...]` wake that arrives while the session is held is kept, not dropped.
local event_session = memory.start_session("local", "chat",
  { id = "wakes-pause-event", user_id = "master", node_id = "test-node", title = "events" })
local ectx = { user_id = "master", role = "master", session_id = event_session }
local subscription = selfloop.schedule({ on = { "job.77" }, reason = "the job finished" }, ectx)
check(subscription.ok, "an event wake is scheduled: " .. json.encode(subscription))
selfloop.pause(event_session, "master", "run_cancelled", { now = T0 })
selfloop.publish("job.77", { id = "job-77" }, { session_id = event_session, user_id = "master", now = T0 })
eq(selfloop.tick({ now = T0 + 5, dispatch = fake_dispatch }).dispatched, 0,
  "the job finishing while the session is held starts no turn")
eq(row_of(subscription.wake.id).status, "pending", "the event wake is still there")
selfloop.resume(event_session, "master", { now = T0 + 6 })
eq(selfloop.tick({ now = T0 + 6, dispatch = fake_dispatch }).dispatched, 1,
  "and it fires once when the session comes back")

-- ---- what the reader is told ----------------------------------------------------------------
local quiet_session = memory.start_session("local", "chat",
  { id = "wakes-pause-footer", user_id = "master", node_id = "test-node", title = "footer" })
local fctx = { user_id = "master", role = "master", session_id = quiet_session }
eq(selfloop.footer_text(quiet_session), "", "a session with nothing pending has no footer fact")
selfloop.schedule({ in_seconds = 120, reason = "footer" }, fctx)
check(selfloop.footer_text(quiet_session):find("1 wake", 1, true) ~= nil,
  "one pending wake reads as one wake: " .. selfloop.footer_text(quiet_session))
selfloop.pause(quiet_session, "master", "run_cancelled", { now = T0 })
eq(selfloop.footer_text(quiet_session), "\226\143\176 1 wake paused", "a held session says paused")
selfloop.resume(quiet_session, "master", { now = T0 + 1 })
check(selfloop.footer_text(quiet_session):find("paused", 1, true) == nil,
  "and the resume takes the word back: " .. selfloop.footer_text(quiet_session))

-- The resume is the operator's door too: `wa resume --session <id>` calls `selfloop.resume` and prints
-- what came back (`lua/core/init.lua`), so a hold is never invisible to the person who has to lift it.
check(type(selfloop.resume(quiet_session, "master", { now = T0 + 2 }).resumed) == "boolean",
  "resuming a session that is not held answers plainly")

for _, name in ipairs({ "pause", "resume", "paused", "cancel_requested", "cancelled_stop", "settle_interrupted" }) do
  check(type(selfloop[name]) == "function", "the module exposes " .. name)
end

print(string.format("self-loop pause: %d checks passed", checks))
