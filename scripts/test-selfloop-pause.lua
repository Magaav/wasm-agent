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

-- ---- a wake the node REFUSED for a waiting build is put back, not consumed (23/11) --------------
-- MEASURED (avell, ~14:2xZ): the pause ended two workers rc=1 with `run_resource_refused ... resource_busy`
-- while a build waited. The same race reaches a WAKE: the request arrives between run_wake's own gate and the
-- run's session claim, the run does not start, and the row must keep its place instead of being settled by its
-- own refusal. The two halves are asserted here: the one test for the sentences, and the deferral itself.
local pause_mod = dofile("lua/core/deploy_pause.lua")
check(pause_mod.is_refusal("deploy_waiting: waiting for the install of 8082b42e1111"),
  "a pre-run-gate refusal is recognised")
check(pause_mod.is_refusal("deploy waiting: waiting for the install of 8082b42e1111; this turn paused after its step"),
  "and so is a paused turn's own sentence")
check(not pause_mod.is_refusal("provider_failed"), "a provider failure is not a refusal for a build")
check(not pause_mod.is_refusal(nil), "and neither is nothing at all")
local refused_session = memory.start_session("local", "chat",
  { id = "wakes-pause-refused", user_id = "master", node_id = "test-node", title = "refused for a build" })
local fctx = { user_id = "master", role = "master", session_id = refused_session }
local refused_wake = selfloop.schedule({ in_seconds = 5, reason = "resume after the swap" }, fctx)
check(refused_wake.ok, "the wake is scheduled: " .. json.encode(refused_wake))
local claimed_refused = selfloop.claim_due(refused_session, "master", { now = T0 + 10 })
check(claimed_refused and claimed_refused.id == refused_wake.wake.id, "and claimed for its turn")
local refusal = "deploy_waiting: waiting for the install of 8082b42e1111 (deploy request 1-2, asked 2s ago)"
local put_back = selfloop.defer_refused(claimed_refused, refusal, { now = T0 + 10 })
check(put_back.deferred == true, "the refused wake is put back: " .. json.encode(put_back))
local refused_row = row_of(refused_wake.wake.id)
eq(refused_row.status, "pending", "the row is pending again, not delivered")
check(tonumber(refused_row.due_at) > T0 + 10, "with a time ahead, so it is looked at again")
check(tostring(refused_row.last_error):find("deploy_waiting", 1, true) ~= nil,
  "and the refusal is on the row: " .. tostring(refused_row.last_error))
eq(selfloop.defer_refused({ id = "no-such-wake", attempts = 0 }, refusal, { now = T0 + 10 }).error, "wake_not_pending",
  "a row that is not pending is refused by name, never guessed at")

-- THE SWEEP ON A LIVE-SHAPED TICK, THROUGH THE REAL HOST (r5, 24/11). The r4 sweep asked for `host.delete_file`,
-- which does not exist (the capability is `host.remove_file`), so it closed nothing on the live node for nine minutes
-- and the unit test did not notice because it INJECTED the remover - the fixture replaced exactly the thing that was
-- wrong. Here nothing is injected: real files in `<data>/deploy-paused`, and `selfloop.tick` with no options.
--
-- The oldest record must go, the young one and the half-written one must stay, and the sweep must say it ran.
local data_dir = dofile("lua/core/paths.lua").data()
local paused = data_dir .. "/deploy-paused"
local now_s = os.time()
local function write_record(name, body)
  pcall(host.write_file, paused .. "/" .. name, body)
  return paused .. "/" .. name
end
local function exists(path)
  local ok, text = pcall(host.read_file, path)
  return ok and type(text) == "string"
end
dofile("lua/core/deploy_pause.lua").paused_dir = function() return paused end
local old_path = write_record("old-record.json", json.encode({ session = "sess-old", since = now_s - 7 * 3600 }))
-- A REAL session, because the sweep closes a record whose session is gone - a made-up id would be "positively
-- gone" and the case would prove the opposite of what it says.
local live_session = memory.start_session("local", "chat",
  { user_id = "master", node_id = "test-node", title = "a live pause record" })
local young_path = write_record("young-record.json", json.encode({ session = live_session, since = now_s - 60 }))
local half_path = write_record("half-record.json", "{\"session\":\"sess-half\"")
selfloop.tick({ now = now_s })
check(not exists(old_path), "a record older than the window is closed on a live tick (the capability's real name)")
check(exists(young_path), "a young record whose session is live is kept")
check(exists(half_path), "a half-written YOUNG record is kept: unreadable is not dead")
for _, path in ipairs({ old_path, young_path, half_path }) do pcall(host.remove_file, path) end
-- THE RECLAIM AGAINST THE REAL RESOURCES STORE (r5d, Fable, 24/11). The two live defects were that the claim was
-- looked for in the wrong store (the ledger has no claims table: they are in `<data>/resources/claims.sqlite`,
-- `resources.rs:354-361`) and compared against the wrong boot (`claims.boot` is the uuid `Store::open` mints, not
-- `runtime_info().boot_id`). So this test uses NO injection at all: a real claim through lua/core/resources.lua, the
-- real store the node reads for this HOME, and the module's own `claim_state`.
--
-- HOW THIS PROVES IT IS THE NODE'S OWN STORE: `host.resource("list")` is the store this process opened, `paths.data()`
-- is the directory the whole run is using, and the test asserts the claim it just took is in the inventory it just
-- asked for under that data root - the same root `deploy-pause`, `sentinel` and the ledger live in.
-- A DEPLOY THAT IS WAITING WOULD RETURN THE RECLAIM EARLY and make this block pass for the wrong reason, so the
-- fixture proves nothing waits first: no installer marker, no request in the sentinel box of THIS home.
pcall(host.remove_file, dofile("lua/core/paths.lua").data() .. "/deploy-pending.json")
do
  local box = dofile("lua/core/paths.lua").data() .. "/sentinel/requests"
  local listing = host.list_dir(box)
  local decoded = listing and json.decode(listing) or nil
  for _, entry in ipairs((decoded and decoded.entries) or {}) do
    pcall(host.remove_file, box .. "/" .. tostring(entry.name or ""))
  end
end
local resources = dofile("lua/core/resources.lua")
local pause_mod = dofile("lua/core/deploy_pause.lua")
local pause_data = dofile("lua/core/paths.lua").data()
local claim_session = memory.start_session("local", "chat",
  { user_id = "master", node_id = "test-node", title = "a session with a run claim" })
local ctx = { user_id = "master", session_id = claim_session, run_id = "run-r5d" }
check(pause_mod.waiting(os.time()) == nil, "nothing is waiting for a deploy in this fixture (the reclaim runs)")
local taken = resources.claim(ctx, { "session:" .. claim_session })
check(taken and taken.ok, "a real session claim is taken through the resources capability: " .. json.encode(taken))
local inventory = json.decode(host.resource("list", "{}") or "{}") or {}
local liveness, found_at = nil, nil
for _, entry in ipairs(inventory.claims or {}) do
  if tostring(entry.key or "") == "session:" .. claim_session then liveness = entry.liveness end
end
check(liveness == "held", "the inventory answers `held` for a claim THIS process holds: " .. tostring(liveness))
check(type(pause_data) == "string" and pause_data ~= "", "the data root is the one this run uses: " .. tostring(pause_data))
local store = pause_data .. "/resources/claims.sqlite"
local store_ok, store_text = pcall(host.read_file, store)
check(store_ok and type(store_text) == "string" and #store_text > 0,
  "the store exists where the node reads it, under the same data root: " .. store)

-- A dispatching resume row is written the way the tick writes one, then the reclaim is asked to judge it.
local wake = selfloop.schedule({ in_seconds = 60, reason = selfloop.RESUME_REASON or "deploy pending: resume after the node swap",
  prompt = "resume" }, { session_id = claim_session, user_id = "master" })
check(wake and wake.ok, "a resume row exists for that session")
local old_at = os.time() - 400
-- ONE CLOCK, WALL: `selfloop.schedule` stamps `created_at` with THIS FILE's clock (T0), and a row carrying T0 while
-- the calls here use `os.time()` satisfies neither the 6 h window nor the 300 s bound - measured: `stale: n=0` at
-- `now=1700000400` for a row stamped `updated_at=1795486042`, so the reclaim and the re-arm were never reached.
host.sql_exec([[UPDATE self_wakes SET status='dispatching', created_at=?, updated_at=? WHERE id=?]],
  json.encode({ old_at, old_at, wake.wake.id }))
local before = host.sql_query([[SELECT COUNT(*) AS n FROM messages WHERE session_id=? AND created_at>=?]],
  json.encode({ claim_session, old_at }))
local before_rows = json.decode(before or "[]") or {}
check(tonumber(before_rows[1] and before_rows[1].n or 1) == 0, "the session has written nothing since the dispatch")
pause_mod.ensure_resumes(os.time(), { stale_seconds = 300 })
local held_row = host.sql_query([[SELECT status FROM self_wakes WHERE id=?]], json.encode({ wake.wake.id }))
local held_status = (json.decode(held_row or "[]") or {})[1]
check(held_status and held_status.status == "dispatching",
  "a claim held by the LIVE store keeps the row (no duplicate turn): " .. json.encode(held_status))

-- THE ACCEPTANCE CASE, live-shaped and with NO seam: a dispatching resume row 400 s past its dispatch, its claim
-- RELEASED (`resources.finish`, what a finished run does), the session quiet - and the NODE must reclaim it and
-- re-arm it, which is ae2a9231's shape at install #1. Then a second pass must add nothing.
--
-- ONE CLOCK: this file installs one (`created_at = 1700000000`), so the call is given the ROW's own clock. Passing
-- wall time made the row look 6 h+ old, the migration retired it as `too old to resume`, and the reclaim and re-arm
-- were never reached - a fixture bug that hid the acceptance for three rounds.
local released_answer = resources.finish(ctx)
local inventory_after = host.resource("list", "{}") or ""
print("FINISH=" .. json.encode(released_answer))
print("INV=" .. tostring(inventory_after):sub(1, 400))
-- A DEPLOY THAT IS WAITING AT THIS INSTANT WOULD SKIP THE RE-ARM (step 4 sits behind that gate, rightly), and the
-- earlier blocks of this file leave requests and markers behind: the fixture says out loud that nothing waits.
pcall(host.remove_file, pause_data .. "/deploy-pending.json")
do
  local box = pause_data .. "/sentinel/requests"
  local listing = host.list_dir(box)
  local decoded = listing and json.decode(listing) or nil
  for _, entry in ipairs((decoded and decoded.entries) or {}) do
    pcall(host.remove_file, box .. "/" .. tostring(entry.name or ""))
  end
end
local clock_now = old_at + 400
check(pause_mod.waiting(clock_now) == nil, "nothing waits for a deploy at the moment the reclaim runs")
local verdict = pause_mod.ensure_resumes(clock_now, { stale_seconds = 300 })
check((tonumber(verdict and verdict.reclaimed) or 0) == 1,
  "the released claim lets the row be reclaimed in ONE call: " .. json.encode(verdict))
local rows_json = host.sql_query([[SELECT id, status, reason, resume_chain FROM self_wakes WHERE session_id=?]],
  json.encode({ claim_session }))
local rows = json.decode(rows_json or "[]") or {}
local owed, seen_rows = 0, {}
for _, row in ipairs(rows) do
  seen_rows[#seen_rows + 1] = tostring(row.status) .. "/chain=" .. tostring(row.resume_chain)
  if tostring(row.id) ~= tostring(wake.wake.id) and row.status == "pending"
    and tostring(row.reason) == tostring(pause_mod.RESUME_REASON) then
    owed = owed + 1
    check(tonumber(row.resume_chain) == 1, "the re-armed row carries chain 1: " .. tostring(row.resume_chain))
  end
end
check(owed == 1, "and exactly ONE new pending resume row, with no seam: " .. tostring(owed)
  .. " rows: " .. table.concat(seen_rows, ", "))
local again = pause_mod.ensure_resumes(clock_now, { stale_seconds = 300 })
local rows2 = json.decode(host.sql_query([[SELECT status FROM self_wakes WHERE session_id=?]],
  json.encode({ claim_session })) or "[]") or {}
local pending2 = 0
for _, row in ipairs(rows2) do if row.status == "pending" then pending2 = pending2 + 1 end end
check((tonumber(again and again.rearmed) or 0) == 0 and pending2 == 1,
  "a second pass adds nothing: " .. json.encode(again) .. " pending=" .. tostring(pending2))

-- r6, THE THREE TESTS (24/11). All of them through the product's own setup and stores - `selfloop.setup`, the real
-- resources store via `lua/core/resources.lua`, host capabilities by their real names, params as JSON text, and ONE
-- clock taken from the row itself; nothing injected.
local pause_mod = dofile("lua/core/deploy_pause.lua")
local r6_data = dofile("lua/core/paths.lua").data()
local r6_now = os.time()

-- (1) THE SWEEP RUNS BEFORE THE WAITING GATE: a record older than the window closes whatever is installing, and the
-- daily stamp is written - the live node closed none for hours because the gate returns before the sweep.
local paused_dir = pause_mod.paused_dir()
local function put_record(name, body) pcall(host.write_file, paused_dir .. "/" .. name, body) return paused_dir .. "/" .. name end
local function there(path) local ok, text = pcall(host.read_file, path) return ok and type(text) == "string" end
local old_record = put_record("r6-old.json", json.encode({ session = "r6-old-session", since = r6_now - 7 * 3600 }))
local live_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 live" })
local young_record = put_record("r6-young.json", json.encode({ session = live_session, since = r6_now - 60 }))
local marker = pause_mod.path and pause_mod.path() or (r6_data .. "/deploy-pending.json")
pcall(host.write_file, marker, json.encode({ state = "deploy_pending", since = r6_now - 5, bound_seconds = 1800,
  to = "e832e152", by = "installer" }))
check(pause_mod.waiting(r6_now) ~= nil, "a deploy is installing in this fixture (the gate is up)")
selfloop.tick({ now = r6_now })
check(not there(old_record), "the sweep closed the expired record WHILE an install was waiting")
check(there(young_record), "and kept the young record of a live session")
check(there(r6_data .. "/pause-sweep.last"), "and said it ran: <data>/pause-sweep.last exists")
pcall(host.remove_file, marker)
pcall(host.remove_file, young_record)

-- (2) A RESUME THAT MEETS AN INSTALL ALREADY WAITING SPENDS NOTHING: no model call, no message, row back to pending.
local r6_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 wake" })
local r6_wake = selfloop.schedule({ in_seconds = 0, reason = pause_mod.RESUME_REASON, prompt = "resume after the deploy" },
  { session_id = r6_session, user_id = "master" })
check(r6_wake and r6_wake.ok, "a resume row is due now: " .. json.encode(r6_wake))
local claimed = selfloop.claim_due(r6_session, "master", { now = r6_now })
check(claimed and claimed.id == r6_wake.wake.id, "and the node claimed it for its turn")
pcall(host.write_file, marker, json.encode({ state = "deploy_pending", since = r6_now - 2, bound_seconds = 1800,
  to = "e832e152", by = "installer" }))
local messages_before = tonumber((json.decode(host.sql_query([[SELECT COUNT(*) AS n FROM messages WHERE session_id=?]],
  json.encode({ r6_session })) or "[]") or {})[1].n) or 0
local deferred = selfloop.run_wake({ id = r6_wake.wake.id, owner = "master", session_id = r6_session })
check(type(deferred) == "table" and deferred.deferred == true, "the run defers instead of starting: " .. json.encode(deferred))
check(tostring(deferred.deploy_waiting):find("deploy_waiting", 1, true) ~= nil,
  "with the sentence every other refusal uses (no new text): " .. tostring(deferred.deploy_waiting):sub(1, 60))
local messages_after = tonumber((json.decode(host.sql_query([[SELECT COUNT(*) AS n FROM messages WHERE session_id=?]],
  json.encode({ r6_session })) or "[]") or {})[1].n) or 0
check(messages_after == messages_before, "and writes NOTHING into the session: " .. tostring(messages_before)
  .. " -> " .. tostring(messages_after))
local back = (json.decode(host.sql_query([[SELECT status FROM self_wakes WHERE id=?]],
  json.encode({ r6_wake.wake.id })) or "[]") or {})[1] or {}
check(tostring(back.status) == "pending", "the row is pending again, not failed: " .. json.encode(back))
pcall(host.remove_file, marker)

-- (4) NO STATEMENT OF THE REPAIR TOUCHES A ROW THAT IS NOT A DEPLOY RESUME (24/11, the defect that put main red):
-- `test-deploy-resume.lua`'s unrelated wake must keep its status, its time and its prompt through every pass - the
-- migration, the reclaim, the pending retire and the re-arm all carry reason = the resume reason in their WHERE.
local foreign_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 foreign" })
local foreign = {}
for _, spec in ipairs({ { "foreign-dispatching", "check the deploy" }, { "foreign-unknown", "look again" } }) do
  local armed = selfloop.schedule({ in_seconds = 60, reason = spec[2], prompt = "unrelated" },
    { session_id = foreign_session, user_id = "master" })
  check(armed and armed.ok, "an unrelated wake is armed: " .. tostring(spec[1]))
  foreign[#foreign + 1] = armed.wake.id
end
-- one of them dispatched-and-dead, the other merely overdue: both are exactly what the repair looks for by STATUS
host.sql_exec([[UPDATE self_wakes SET status='dispatching', created_at=?, updated_at=? WHERE id=?]],
  json.encode({ r6_now - 7200, r6_now - 7200, foreign[1] }))
host.sql_exec([[UPDATE self_wakes SET created_at=?, due_at=? WHERE id=?]],
  json.encode({ r6_now - 7200, r6_now - 7200, foreign[2] }))
local function snapshot(id)
  local row = (json.decode(host.sql_query([[SELECT status, prompt, due_at, created_at, resume_chain FROM self_wakes WHERE id=?]],
    json.encode({ id })) or "[]") or {})[1] or {}
  return table.concat({ tostring(row.status), tostring(row.prompt), tostring(row.due_at), tostring(row.created_at),
    tostring(row.resume_chain) }, "|")
end
local before_foreign = { snapshot(foreign[1]), snapshot(foreign[2]) }
pause_mod.ensure_resumes(r6_now, { stale_seconds = 300 })
pause_mod.ensure_resumes(r6_now, { stale_seconds = 300 })
check(snapshot(foreign[1]) == before_foreign[1],
  "an unrelated DISPATCHING wake is untouched by the repair: " .. before_foreign[1] .. " -> " .. snapshot(foreign[1]))
check(snapshot(foreign[2]) == before_foreign[2],
  "and so is an unrelated OVERDUE one: " .. before_foreign[2] .. " -> " .. snapshot(foreign[2]))
-- UNCHANGED, not "none pending": one of them was armed pending on purpose, and the repair must leave that one
-- pending and the other exactly as it was.
local foreign_pending = 0
for _, id in ipairs(foreign) do
  local row = (json.decode(host.sql_query([[SELECT status FROM self_wakes WHERE id=?]], json.encode({ id })) or "[]") or {})[1] or {}
  if tostring(row.status) == "pending" then foreign_pending = foreign_pending + 1 end
end
check(foreign_pending == 1, "and nothing re-arms them: one was pending before, one after - " .. tostring(foreign_pending) .. " of 2")
-- (3) AT MOST ONE PENDING RESUME PER SESSION, seeded from c67c0609's real shape (two resume rows for one session):
-- arming B while A is pending REPLACES it - one row, the OLDEST created_at, the LARGEST chain.
-- (3b) A RESUMED TURN THAT PAUSES AGAIN: its own row is `dispatching` (the turn running now), the pause arms a NEW
-- resume, and when that turn ends `finish` must not land on the new row. MEASURED shape of the back-to-back installs:
-- replacing the dispatching row let `finish` write `delivered` over the new resume and lose it.
local paused_run_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 resumed" })
local row_x = selfloop.schedule({ in_seconds = 0, reason = pause_mod.RESUME_REASON, prompt = "resume X" },
  { session_id = paused_run_session, user_id = "master" })
check(row_x and row_x.ok, "row X is armed")
host.sql_exec([[UPDATE self_wakes SET created_at=?, resume_chain=1 WHERE id=?]],
  json.encode({ r6_now - 7200, row_x.wake.id }))
local claimed_x = selfloop.claim_due(paused_run_session, "master", { now = r6_now })
check(claimed_x and claimed_x.id == row_x.wake.id, "and the node claimed it: X is `dispatching`, the turn is running")
-- the turn pauses again, so deploy_pause arms a resume for the NEXT install, the way at_boundary does
local armed_on_pause = selfloop.schedule({ in_seconds = 60, reason = pause_mod.RESUME_REASON, prompt = "resume Y" },
  { session_id = paused_run_session, user_id = "master", resume_chain = 1 })
check(armed_on_pause and armed_on_pause.ok, "the pause armed a second resume")
check(armed_on_pause.replaced ~= true and tostring(armed_on_pause.wake.id) ~= tostring(row_x.wake.id),
  "a DISPATCHING row is not replaced: the new resume is its own row")
check(tonumber((json.decode(host.sql_query([[SELECT created_at FROM self_wakes WHERE id=?]],
  json.encode({ armed_on_pause.wake.id })) or "[]") or {})[1].created_at) == r6_now - 7200,
  "and it INHERITS the chain's oldest created_at, so re-arming cannot extend the window")
-- now the running turn ends the way a finished run does
selfloop.finish(claimed_x, true, "turn finished", { now = r6_now })
local after_rows = json.decode(host.sql_query([[SELECT id, status, created_at, resume_chain FROM self_wakes
  WHERE session_id=? AND reason=?]], json.encode({ paused_run_session, pause_mod.RESUME_REASON })) or "[]") or {}
local pending_after = 0
for _, row in ipairs(after_rows) do if row.status == "pending" then pending_after = pending_after + 1 end end
check(pending_after == 1, "after the turn ends there is exactly ONE pending resume: " .. json.encode(after_rows))
for _, row in ipairs(after_rows) do
  if tostring(row.id) == tostring(armed_on_pause.wake.id) then
    check(row.status == "pending", "and it is the NEW row, not overwritten by the finish: " .. json.encode(row))
    check(tonumber(row.resume_chain) == 1, "with the chain carried over: " .. tostring(row.resume_chain))
  end
end

-- (3c) THE BELT: a row that someone re-armed WHILE the turn ran is never overwritten by that turn's ending - `finish`
-- writes only where the row is still `dispatching`.
local belt_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 belt" })
local belt_row = selfloop.schedule({ in_seconds = 0, reason = pause_mod.RESUME_REASON, prompt = "belt" },
  { session_id = belt_session, user_id = "master" })
local belt_claimed = selfloop.claim_due(belt_session, "master", { now = r6_now })
check(belt_claimed and belt_claimed.id == belt_row.wake.id, "the belt row is claimed")
host.sql_exec([[UPDATE self_wakes SET status='pending' WHERE id=?]], json.encode({ belt_row.wake.id }))
selfloop.finish(belt_claimed, true, "turn finished", { now = r6_now })
local belt_after = (json.decode(host.sql_query([[SELECT status FROM self_wakes WHERE id=?]],
  json.encode({ belt_row.wake.id })) or "[]") or {})[1] or {}
check(tostring(belt_after.status) == "pending",
  "finish does NOT overwrite a row that was re-armed meanwhile: " .. json.encode(belt_after))
local one_session = memory.start_session("local", "chat", { user_id = "master", node_id = "n", title = "r6 one" })
local first = selfloop.schedule({ in_seconds = 60, reason = pause_mod.RESUME_REASON, prompt = "A" },
  { session_id = one_session, user_id = "master" })
check(first and first.ok, "row A is armed")
host.sql_exec([[UPDATE self_wakes SET created_at=?, resume_chain=2 WHERE id=?]], json.encode({ r6_now - 3600, first.wake.id }))
local second = selfloop.schedule({ in_seconds = 120, reason = pause_mod.RESUME_REASON, prompt = "B", resume_chain = 1 },
  { session_id = one_session, user_id = "master" })
check(second and second.ok and second.replaced == true, "arming B REPLACES A instead of adding a row: " .. json.encode(second))
local rows = json.decode(host.sql_query([[SELECT id, status, created_at, resume_chain, prompt FROM self_wakes
  WHERE session_id=? AND reason=?]], json.encode({ one_session, pause_mod.RESUME_REASON })) or "[]") or {}
check(#rows == 1, "exactly ONE resume row for the session: " .. json.encode(rows))
check(tostring(rows[1].id) == tostring(first.wake.id), "and it is the row that was already owed")
check(tonumber(rows[1].created_at) == r6_now - 3600, "keeping the OLDEST created_at for the window: " .. tostring(rows[1].created_at))
check(tonumber(rows[1].resume_chain) == 2, "and the LARGEST chain: " .. tostring(rows[1].resume_chain))
check(tostring(rows[1].status) == "pending", "pending again, with B's prompt: " .. tostring(rows[1].prompt))
for _, name in ipairs({ "pause", "resume", "paused", "cancel_requested", "cancelled_stop", "settle_interrupted", "defer_refused" }) do
  check(type(selfloop[name]) == "function", "the module exposes " .. name)
end

print(string.format("self-loop pause: %d checks passed", checks))
