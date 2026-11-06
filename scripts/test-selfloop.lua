-- The model's own controls for a long mission (docs/SELF-LOOP.md): notes, wakes and probes.
--
-- No model, provider, network or node: the run scheduler is a counted stub, the clock is a number the
-- test owns, and every probe path except the last (which uses the real QuickJS sandbox when this
-- binary carries it) is an injected function. The claims are the promises a model relies on:
--
--   * a time wake is not due early, is due at its time, and is claimed exactly once;
--   * an event wake is quiet until its topic is published, then carries the event identity and never
--     the event's text;
--   * a probe that says "unchanged" costs no model turn and re-arms as the model asked; changed and
--     broken probes do wake the model, with the result or the error;
--   * notes are per session, append/replace/compact keep the archive retrievable, and a new session
--     starts empty;
--   * a pending wake survives a new interpreter, and an interrupted dispatch is reported unknown, not
--     replayed.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()

local checks, skipped = 0, 0
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
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(label .. ": expected to find " .. tostring(needle) .. " in " .. tostring(text), 2)
  end
end
local function absent(text, needle, label)
  checks = checks + 1
  if type(text) == "string" and text:find(needle, 1, true) then
    error(label .. ": did not expect " .. tostring(needle) .. " in " .. tostring(text), 2)
  end
end
local function decode(raw)
  if type(raw) == "string" then return json.decode(raw) end
  return raw
end
local function rows(sql, params)
  return decode(host.sql_query(sql, json.encode(params or {})))
end

local T0 = 1700000000
-- `schedule` deliberately ignores a clock in its arguments; the test owns the clock through the
-- module's own test hook instead.
selfloop.set_test_clock(function() return T0 end)
local session = memory.start_session("local", "chat",
  { id = "selfloop-session", user_id = "master", node_id = "test-node", title = "self loop" })
local ctx = { user_id = "master", role = "master", session_id = session }

-- ---- the tool surface is wired to this module ------------------------------------------------
local tools = dofile("lua/core/tools.lua")
local names = {}
for _, item in ipairs(tools.all("master")) do names[item["function"].name] = true end
for _, name in ipairs({ "wake", "wake_list", "wake_cancel", "notes_read", "notes_write", "notes_append", "notes_compact" }) do
  check(names[name], "self-loop tool is advertised to the model: " .. name)
  check(tools.snippet(name) ~= nil, "self-loop tool has a prompt cue: " .. name)
end
check(tools.has_effect("wake"), "wake is an effect (a schedule is a write)")
check(not tools.has_effect("wake_list"), "wake_list is a read")
check(not tools.has_effect("notes_read"), "notes_read is a read")
check(tools.has_effect("notes_write"), "notes_write is an effect")

-- ---- a time wake: not early, due at its time, claimed once ----------------------------------
local dispatch = { count = 0, last = nil, receipt = { accepted = true, run_id = 1 } }
local function fake_dispatch(row)
  dispatch.count = dispatch.count + 1
  dispatch.last = row
  return dispatch.receipt
end

local first = selfloop.schedule({ in_seconds = 60, reason = "check the deploy", prompt = "look again", now = T0 }, ctx)
check(first.ok, "a time wake is accepted: " .. json.encode(first))
eq(first.wake.due_at, T0 + 60, "due at now + in_seconds")
eq(first.wake.status, "pending", "a new wake is pending")

local early = selfloop.tick({ now = T0 + 59, dispatch = fake_dispatch })
eq(early.dispatched, 0, "a wake is not dispatched before its time")
eq(dispatch.count, 0, "no dispatch receipt was asked for early")
local listed = selfloop.list({ now = T0 + 30 }, ctx)
eq(listed.count, 1, "the pending wake is listed")
eq(listed.wakes[1].in_seconds, 30, "the list says how long is left")
eq(listed.next_at, T0 + 60, "the list names the next due")
contains(selfloop.footer_text(session, { now = T0 + 30 }), "1 wake", "the footer counts the pending wake")
contains(selfloop.footer_text(session, { now = T0 + 30 }), "next", "the footer names the next due")

local due = selfloop.tick({ now = T0 + 60, dispatch = fake_dispatch })
eq(due.dispatched, 1, "a due wake is dispatched")
eq(dispatch.count, 1, "the scheduler was asked once")
eq(dispatch.last.id, first.wake.id, "the receipt names the wake")
eq(dispatch.last.reason, "check the deploy", "the receipt carries the model's reason")
local again = selfloop.tick({ now = T0 + 61, dispatch = fake_dispatch })
eq(again.dispatched, 0, "a claimed wake is not dispatched a second time")
eq(dispatch.count, 1, "the second tick asked the scheduler nothing")

-- The scheduler's run settled it: a one-shot wake is done, a repeating one re-arms.
local one = selfloop.list({ all = true, now = T0 + 61 }, ctx).wakes[1]
eq(one.status, "dispatching", "the row is in flight until its run settles")
selfloop.finish({ id = one.id, every_seconds = nil }, true, nil, { now = T0 + 62 })
one = selfloop.list({ all = true, now = T0 + 62 }, ctx).wakes[1]
eq(one.status, "delivered", "a settled one-shot wake is delivered")
eq(selfloop.list({ now = T0 + 62 }, ctx).count, 0, "a delivered wake is no longer pending")

-- ---- cancel ---------------------------------------------------------------------------------
local cancel_me = selfloop.schedule({ in_seconds = 30, reason = "cancel me", now = T0 }, ctx)
local cancelled = selfloop.cancel({ id = cancel_me.wake.id, now = T0 + 1 }, ctx)
check(cancelled.ok, "a pending wake cancels")
eq(selfloop.list({ now = T0 + 1 }, ctx).count, 0, "a cancelled wake is no longer pending")
eq(selfloop.tick({ now = T0 + 100, dispatch = fake_dispatch }).dispatched, 0, "a cancelled wake never fires")
eq(dispatch.count, 1, "cancelling dispatched nothing")
eq(selfloop.cancel({ id = "nope", now = T0 }, ctx).error, "unknown_wake", "an id this session never had is refused")

-- ---- refusals: a bad wake fails loudly, before any row exists -------------------------------
local function refused(args, label)
  local result = selfloop.schedule(args, ctx)
  check(result.error ~= nil, label .. " is refused: " .. json.encode(result))
end
refused({ reason = "x", in_seconds = 10, on = { "deploy.done" }, now = T0 }, "a time wake and an event wake together")
refused({ reason = "x", in_seconds = 10, at = T0 + 100, now = T0 }, "in_seconds and at together")
refused({ reason = "x", at = T0 - 1, now = T0 }, "a time in the past")
refused({ reason = "", in_seconds = 10, now = T0 }, "an empty reason")
refused({ reason = "x", now = T0 }, "a wake with neither a time nor an event")
refused({ reason = "x", on = {}, now = T0 }, "an empty event list")
refused({ reason = "x", in_seconds = 10, every_seconds = 1, now = T0 }, "a cadence below the documented floor")
refused({ reason = "x", in_seconds = 10, probe = "return {changed=false}", now = T0 },
  "a probe on a time wake with no recheck cadence")
refused({ reason = "x", on = { "deploy.done" }, every_seconds = 30, now = T0 },
  "an event wake with a time argument")
check(selfloop.schedule({ reason = "x", in_seconds = 10, now = T0 },
  { user_id = "master", role = "master", session_id = "missing-session" }).error ~= nil,
  "a session that does not exist is refused")

-- A child session cannot keep waking itself: its route back is the parent's completion notice.
local child = memory.start_session("local", "subagent",
  { id = "selfloop-child", user_id = "master", node_id = "test-node", parent_session_id = session })
local child_wake = selfloop.schedule({ in_seconds = 10, reason = "child loop", now = T0 },
  { user_id = "master", role = "master", session_id = child })
eq(child_wake.error, "wake_not_for_subagent", "a subagent session cannot schedule a self-wake")

-- Another owner's session is not ours to wake.
local guest = memory.start_session("local", "chat",
  { id = "selfloop-guest", user_id = "guest", node_id = "test-node", title = "guest" })
eq(selfloop.schedule({ in_seconds = 10, reason = "x", now = T0 },
  { user_id = "master", role = "master", session_id = guest }).error,
  "selfloop_forbidden_session", "a session another owner owns is refused")

-- ---- an event wake: quiet until published, then identity without payload text ----------------
local event_wake = selfloop.schedule({ on = { "deploy.done", "message" }, reason = "deploy finished", now = T0 }, ctx)
check(event_wake.ok, "an event wake is accepted")
eq(event_wake.wake.due_at, nil, "an event wake is not on a clock")
eq(selfloop.tick({ now = T0 + 999, dispatch = fake_dispatch }).dispatched, 0, "an event wake does not fire on time")

local payload_text = "THE OWNER'S PRIVATE MESSAGE TEXT"
local published = selfloop.publish("deploy.done", { id = "evt-1", text = payload_text }, { now = T0 + 5 })
eq(published.matched, 1, "the published topic matched the subscription")
local stored_event = rows("SELECT event_json FROM self_wakes WHERE id=?", { event_wake.wake.id })[1].event_json
contains(stored_event, "deploy.done", "the stored event names its topic")
contains(stored_event, "evt-1", "the stored event keeps its identity")
absent(stored_event, payload_text, "the stored event never keeps the payload text")
local event_due = selfloop.tick({ now = T0 + 5, dispatch = fake_dispatch })
eq(event_due.dispatched, 1, "a published event makes its wake due")
eq(dispatch.last.id, event_wake.wake.id, "the event wake is the one dispatched")
selfloop.finish({ id = event_wake.wake.id }, true, nil, { now = T0 + 6 })

-- A job id (no dot) is a subscription to `job.<id>`, and "message" is a new user message here only.
local job_wake = selfloop.schedule({ on = { "received-message" }, reason = "a job finished", now = T0 }, ctx)
eq(selfloop.publish("job.received-message", { id = "d1" }, { now = T0 + 7 }).matched, 1,
  "a job id matches the job.<id> topic")
selfloop.finish({ id = job_wake.wake.id }, true, nil, { now = T0 + 8 })

local message_wake = selfloop.schedule({ on = { "message" }, reason = "someone wrote", now = T0 }, ctx)
eq(selfloop.on_user_message("some-other-session", { now = T0 + 9 }).matched, 0,
  "a message in another session does not wake this one")
eq(selfloop.on_user_message(session, { now = T0 + 9 }).matched, 1,
  "a real user message in this session wakes it")
selfloop.finish({ id = message_wake.wake.id }, true, nil, { now = T0 + 10 })

-- ---- a pending wake survives a new interpreter; an interrupted dispatch is not replayed -------
local survivor = selfloop.schedule({ in_seconds = 3600, reason = "later", now = T0 }, ctx)
local reloaded = dofile("lua/core/selfloop.lua")
reloaded.setup()
local after_restart = reloaded.list({ now = T0 + 1 }, ctx)
eq(after_restart.count, 1, "a new interpreter still sees the pending wake")
eq(after_restart.wakes[1].id, survivor.wake.id, "it is the same wake")

local inflight = selfloop.schedule({ in_seconds = 1, reason = "in flight", now = T0 }, ctx)
eq(selfloop.tick({ now = T0 + 1, dispatch = fake_dispatch }).dispatched, 1, "the wake is handed over")
local claimed = selfloop.list({ all = true, now = T0 + 1 }, ctx).wakes[1]
local reconciled = selfloop.tick({ now = T0 + 1 + 120, dispatch = fake_dispatch, stale_seconds = 60 })
eq(reconciled.reconciled, 1, "a dispatch older than the stale window is reconciled")
local unknown = selfloop.list({ all = true, now = T0 + 200 }, ctx)
local found
for _, wake in ipairs(unknown.wakes) do if wake.id == inflight.wake.id then found = wake end end
eq(found and found.status, "unknown", "an interrupted dispatch is unknown, never replayed")
eq(selfloop.tick({ now = T0 + 200, dispatch = fake_dispatch }).dispatched, 0, "an unknown wake is not dispatched again")

-- ---- probes: unchanged costs no turn, changed wakes with the result, a failure wakes ----------
local probes = {
  { value = { changed = false, note = "nothing new" } },
  { value = { changed = true, seen = 7 } },
  { why = "probe_script_failed: boom" },
}
local function probe_fn()
  local next = table.remove(probes, 1)
  return function() return next.value, next.why end
end

local quiet = selfloop.schedule({ in_seconds = 10, every_seconds = 30, probe = "return {changed=false}", reason = "poll", now = T0 }, ctx)
local skipped_tick = selfloop.tick({ now = T0 + 10, dispatch = fake_dispatch, probe = probe_fn() })
eq(skipped_tick.skipped, 1, "an unchanged probe skips the model turn")
eq(skipped_tick.dispatched, 0, "an unchanged probe dispatched nothing")
local rearmed = selfloop.list({ now = T0 + 10 }, ctx).wakes[1]
eq(rearmed.id, quiet.wake.id, "the skipped wake is still the same wake")
eq(rearmed.in_seconds, 30, "an unchanged probe re-arms at the cadence the model asked for")

local changed_tick = selfloop.tick({ now = T0 + 40, dispatch = fake_dispatch, probe = probe_fn() })
eq(changed_tick.dispatched, 1, "a changed probe wakes the model")
local changed_row = rows("SELECT probe_result FROM self_wakes WHERE id=?", { quiet.wake.id })[1]
contains(changed_row.probe_result, "seen", "the changed probe's result travels with the wake")
selfloop.finish({ id = quiet.wake.id, every_seconds = 30 }, true, nil, { now = T0 + 41 })
local repeating = selfloop.list({ now = T0 + 41 }, ctx).wakes[1]
eq(repeating.status, "pending", "a repeating wake is still pending after its turn")
eq(repeating.in_seconds, 30, "the repeating wake re-arms after the turn")

local broken_tick = selfloop.tick({ now = T0 + 71, dispatch = fake_dispatch, probe = probe_fn() })
eq(broken_tick.dispatched, 1, "a probe that fails wakes the model to decide")
local broken_row = rows("SELECT probe_result FROM self_wakes WHERE id=?", { quiet.wake.id })[1]
contains(broken_row.probe_result, "boom", "the probe failure is handed to the model")
selfloop.finish({ id = quiet.wake.id }, true, nil, { now = T0 + 72 })

-- The wake turn's shape: the model's own prompt, a visible marker, its notes, the probe/event facts,
-- and a trace a reader can recognise as a self-wake.
selfloop.notes_write({ text = "goal: ship the change\nnext: run the tests", now = T0 }, ctx)
local shaped = {
  id = "shaped", session_id = session, owner = "master", reason = "check tests", prompt = "run the gate",
  event_json = json.encode({ topic = "job.ci" }), probe_result = json.encode({ changed = true, seen = 7 }),
}
local content, trace = selfloop.turn_content(shaped, { now = T0 })
contains(content, "[self-wake", "the wake turn is marked in the transcript")
contains(content, "run the gate", "the model's own prompt is the user-side text")
contains(content, "goal: ship the change", "the notes are offered at the start of the wake turn")
contains(content, "seen", "the probe result is offered with the wake")
contains(content, "job.ci", "the event identity is offered with the wake")
eq(type(trace), "table", "the trace is a list, like every stored turn trace")
eq(trace[1] and trace[1].kind, "self_wake", "the trace marks the turn as a self-wake")
eq(trace[1] and trace[1].id, "shaped", "the trace names the wake")

-- ---- notes: the model owns the document; compact/archive loses nothing ------------------------
local fresh = memory.start_session("local", "chat",
  { id = "selfloop-notes", user_id = "master", node_id = "test-node", title = "notes" })
local notes_ctx = { user_id = "master", role = "master", session_id = fresh }
eq(selfloop.notes_read({}, notes_ctx).empty, true, "a new session starts with empty notes")

selfloop.notes_write({ text = "goal\nstep 1\nstep 2", now = T0 }, notes_ctx)
eq(selfloop.notes_read({}, notes_ctx).text, "goal\nstep 1\nstep 2", "notes_write replaces the document")
selfloop.notes_append({ text = "step 3", now = T0 + 1 }, notes_ctx)
eq(selfloop.notes_read({}, notes_ctx).text, "goal\nstep 1\nstep 2\nstep 3", "notes_append adds a line")
local compacted = selfloop.notes_compact({ keep_lines = 2, now = T0 + 2 }, notes_ctx)
check(compacted.ok and compacted.archived, "notes_compact archives the previous document")
eq(selfloop.notes_read({}, notes_ctx).text, "step 2\nstep 3", "notes_compact keeps the last lines")
local archived = selfloop.notes_read({ version = compacted.archived }, notes_ctx)
contains(archived.text, "goal", "the archived version is retrievable")
contains(archived.text, "step 1", "the archived version kept what compaction dropped")
local versions = selfloop.notes_read({ versions = true }, notes_ctx)
check(versions.count >= 1, "archived versions are listed")
selfloop.notes_write({ text = "rewritten", now = T0 + 3 }, notes_ctx)
eq(selfloop.notes_read({}, notes_ctx).text, "rewritten", "notes_write replaces the compacted text")
local after_rewrite = selfloop.notes_read({ versions = true }, notes_ctx)
check(after_rewrite.count >= 2, "a replace archives the version it replaced")
local other = memory.start_session("local", "chat",
  { id = "selfloop-notes-other", user_id = "master", node_id = "test-node", title = "other notes" })
eq(selfloop.notes_read({}, { user_id = "master", role = "master", session_id = other }).empty, true,
  "notes are per session, not per owner")
local big = string.rep("x", 65537)
eq(selfloop.notes_append({ text = big, now = T0 }, notes_ctx).error, "notes_too_large",
  "an append past the document bound is refused, not truncated")

-- ---- the tool arms reach the module (the model calls these, not the CLI) ---------------------
local via_tool = tools.dispatch(memory, "wake", { in_seconds = 30, reason = "via the tool", now = T0 + 500 }, "master", ctx)
check(via_tool.ok, "the wake tool dispatches: " .. json.encode(via_tool))
local via_list = tools.dispatch(memory, "wake_list", { now = T0 + 500 }, "master", ctx)
check(via_list.count >= 1, "the wake_list tool dispatches")
eq(tools.dispatch(memory, "notes_write", { text = "tool notes", now = T0 }, "guest",
  { user_id = "guest", role = "guest", session_id = notes_ctx.session_id }).error,
  "selfloop_forbidden_session", "a guest cannot write notes into a master session")
check(tools.dispatch(memory, "notes_write", { text = "tool notes", now = T0 }, "master", notes_ctx).ok,
  "notes_write through the tool arm works")

-- ---- the real probe sandbox: read-only tools, a shaped answer, an effect refused -------------
local embed = false
if type(host.quickjs) == "function" then
  local ok, info = pcall(host.quickjs, "info", "{}")
  local decoded = ok and decode(info) or nil
  embed = type(decoded) == "table" and decoded.embedded_assets == true
end
if not embed then
  skipped = skipped + 1
else
  local probe_row = { id = "real-probe", owner = "master", session_id = fresh }
  local value, why = selfloop.run_probe("return {changed:false, note:'nothing moved'}", probe_row, { role = "master" })
  check(value and value.changed == false and value.note == "nothing moved",
    "the real probe sandbox answers a shaped unchanged value: " .. tostring(why))
  local value2, why2 = selfloop.run_probe(
    "const n = await tools.notes_read({}); return {changed:true, bytes:n.bytes}", probe_row, { role = "master" })
  check(value2 and value2.changed == true and type(value2.bytes) == "number",
    "the real probe sandbox can call a read-only tool: " .. tostring(why2))
  local _, why3 = selfloop.run_probe("await tools.notes_write({text:'x'}); return {changed:true}", probe_row,
    { role = "master" })
  check(why3 ~= nil, "an effectful tool call is impossible in a probe (not declared)")
  local _, why4 = selfloop.run_probe("return {changed:'yes'}", probe_row, { role = "master" })
  contains(why4, "probe_changed_must_be_a_boolean", "a malformed probe answer is a probe failure, not a guess")
  -- The documented example shape: a read-only `read` result is under `content`, and the probe decides.
  local probe_file = dofile("lua/core/paths.lua").data() .. "/selfloop-probe.txt"
  host.write_file(probe_file, "STATUS: FAIL\n")
  local read_probe = "const r = await tools.read({path:" .. json.encode(probe_file)
    .. "}); return {changed: r.content.includes('FAIL')}"
  local value5, why5 = selfloop.run_probe(read_probe, probe_row, { role = "master" })
  check(value5 and value5.changed == true, "a probe can read a file and decide from it: " .. tostring(why5))
end

-- ---- the scheduler's run half: a claimed wake re-enters the transcript as a marked turn ----------
-- The fast path has no provider and must make no network call: the LLM environment is hidden for this
-- section, so the run takes the existing local fallback. If a provider still reports configured (a
-- route this stub cannot hide), the section is reported SKIPPED rather than making a model call.
local provider_module = dofile("lua/core/provider.lua")
local real_getenv = host.getenv
host.getenv = function(name)
  if name == "WASM_AGENT_LLM_API_KEY" or name == "WASM_AGENT_LLM_BASE_URL" or name == "WASM_AGENT_LLM_MODEL" then
    return nil
  end
  return real_getenv(name)
end
if provider_module.configured() then
  host.getenv = real_getenv
  skipped = skipped + 1
else
  selfloop.notes_write({ text = "plan: continue the mission", now = T0 }, ctx)
  local end_to_end = selfloop.schedule({ in_seconds = 0, reason = "e2e", prompt = "continue the mission", now = T0 }, ctx)
  check(end_to_end.ok, "the end-to-end wake is scheduled")
  local captured
  local handed = selfloop.tick({ now = T0, dispatch = function(row) captured = row; return { accepted = true } end })
  eq(handed.dispatched, 1, "the end-to-end wake is handed to the scheduler")
  check(captured ~= nil, "the scheduler receipt carries the row")
  local ran = selfloop.run_wake({ id = captured.id, owner = "master", session_id = session, cancelled = false })
  check(ran.ok, "the run half executes the wake turn: " .. json.encode(ran))
  local tail = rows("SELECT role,content,trace FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 2", { session })
  local wake_message
  for _, row in ipairs(tail) do if row.role == "user" then wake_message = row end end
  check(wake_message ~= nil, "the wake turn wrote a user-side message")
  contains(wake_message.content, "[self-wake", "the transcript marks the turn as a self-wake")
  contains(wake_message.content, "continue the mission", "the user-side text is the model's own prompt")
  contains(wake_message.content, "plan: continue the mission", "the notes are offered on the wake turn")
  contains(wake_message.trace, "self_wake", "the stored trace records a self-wake")
  local delivered
  for _, wake in ipairs(selfloop.list({ all = true, now = T0 }, ctx).wakes) do
    if wake.id == end_to_end.wake.id then delivered = wake end
  end
  eq(delivered and delivered.status, "delivered", "the settled wake is no longer pending")
  host.getenv = real_getenv
end

-- A wake cancelled before its turn runs is recorded as cancelled, and a settled row is not admitted
-- again: the admission half of the run, without a model either way.
local cancel_before = selfloop.schedule({ in_seconds = 0, reason = "cancel before run", now = T0 }, ctx)
local claim_row
selfloop.tick({ now = T0, dispatch = function(row) claim_row = row; return { accepted = true } end })
local cancelled_run = selfloop.run_wake({ id = claim_row.id, owner = "master", session_id = session, cancelled = true })
check(cancelled_run.cancelled == true, "a wake cancelled before execution is recorded, not run")
eq(selfloop.run_wake({ id = claim_row.id, owner = "master", session_id = session }).error,
  "self_wake_not_dispatching", "a settled wake is not admitted twice")
eq(selfloop.run_wake({ id = "never-allocated", owner = "master", session_id = session }).error,
  "self_wake_not_admitted", "an id this session never had is refused by the run half")

print(json.encode({ ok = true, checks = checks, skipped = skipped }))
