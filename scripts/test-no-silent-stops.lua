-- No silent stops: a run that does not end with an answer says so, by name, once - in the ledger,
-- in the event stream, on the durable bus, and (when a rerun can finish it) in one wake.
--
-- Measured on wasm_the_first, 10/11:
--   * session a073ee85: after a 12-minute provider stall the provider timed out three times and the
--     run ended with an assistant row whose text was empty; no event, notice or wake left the
--     process, so "the provider stalled" and "the agent had nothing to say" looked identical;
--   * session b8878ed2: cut by `(runaway guard: 200 tool rounds without a final answer)`, work the
--     operator had asked for, and the continuation restarted cold;
--   * a deploy rewrote `wa`, the CLI re-execed, and the running turn was marked failed silently.
--
-- What this suite pins, level by level:
--   * the pure classifiers (failure name, guard decision, stall detection) - no host, no model;
--   * the whole loop through `host.http_stream`, so the wiring is under test and not a copy of it:
--     one named row per failed run, the event stream's failure, the durable bus fact firing a
--     subscriber's wake, and the guard's notes checkpoint written before the turn ends;
--   * `host.read_file`'s named second answer, and the `read` tool carrying it.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-no-silent-stops.lua wa --db /tmp/x.db
-- This suite stubs the transport and must not depend on an operator API key.
local real_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  -- A retry of a stall costs the same stall; the run-level naming is what this test measures.
  if key == 'WASM_AGENT_PROVIDER_RETRIES' then return '0' end
  if key == 'WASM_AGENT_PROVIDER_RESPONSE_TIMEOUT_RETRIES' then return '0' end
  return real_getenv(key)
end
-- Retry backoff is a real sleep; a test that sleeps is a test nobody runs.
host.sleep = function() end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
local provider = dofile("lua/core/provider.lua")
local selfloop = dofile("lua/core/selfloop.lua")
local progress_guard = dofile("lua/core/progress_guard.lua")
local run_failure = dofile("lua/core/run_failure.lua")
local file_tools = dofile("lua/core/file_tools.lua")
memory.setup()

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then error(string.format("%s: got %q, want %q", what, tostring(got), tostring(want))) end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(tostring(haystack), needle, 1, true) then
    error(string.format("%s: %q does not contain %q", what, tostring(haystack), needle))
  end
end
local function ok(condition, what)
  checks = checks + 1
  if not condition then error(what) end
end
local function skip(what, why) print("SKIP no-silent-stops " .. what .. ": " .. tostring(why)) end

-- --------------------------------------------------------------- the classifiers
-- Every ending gets a code a reader can grep, and the retryability is the provider's own judgement.
eq(run_failure.classify("provider_error: timeout: receive response").code, "provider_stalled",
  "a receive timeout is a stall")
eq(run_failure.classify("provider_error: timeout: receive response (provider_stalled: no response within 90s)").code,
  "provider_stalled", "the host's own marker wins, and it survives the provider_error prefix")
eq(run_failure.classify("provider_error: timeout: connect").code, "provider_stalled", "a connect timeout is a stall")
eq(run_failure.classify("provider_error: 500 server_error").code, "provider_error", "any other provider fault")
eq(run_failure.classify("provider_error: 401 unauthorized").retryable, true,
  "a provider fault is retryable as a class; the retry itself is the provider layer's decision")
eq(run_failure.classify("run_cancelled").code, "run_cancelled", "a cancel is named as one")
eq(run_failure.classify("guard_repeated_calls: x").code, "guard_repeated_calls", "the guard's code")
eq(run_failure.classify("guard_no_progress: x").code, "guard_no_progress", "the guard's other code")
eq(run_failure.classify("context_overflow: x").code, "context_overflow", "overflow")
eq(run_failure.classify("context_overflow: x").retryable, false, "a window that does not fit is not retryable")
eq(run_failure.classify("run_resource_refused: {}").code, "resource_refused", "a refused claim")
eq(run_failure.classify("run_interrupted: replaced").code, "run_interrupted", "a cut by a replacement")
eq(run_failure.classify("something nobody classified").code, "run_failed", "an unknown failure still gets a name")
local named = run_failure.classify("provider_error: timeout: receive response")
has(named.text, "run_failed: provider_stalled", "the durable sentence leads with the code")
has(named.text, "did not answer within its deadline", "and says what it means")

-- --------------------------------------------------------------- the progress guard
-- A runaway loop is stopped; a long task is not. No count is a budget.
eq(progress_guard.repeat_limit(), 3, "three identical decisions in a row is the default limit")
eq(progress_guard.idle_rounds(), 12, "twelve changed-nothing rounds is the default")
if real_getenv("WASM_AGENT_MAX_TOOL_ROUNDS") == nil or real_getenv("WASM_AGENT_MAX_TOOL_ROUNDS") == "" then
  eq(progress_guard.ceiling(), 0, "there is no round ceiling unless an operator asks for one")
else
  skip("ceiling default", "WASM_AGENT_MAX_TOOL_ROUNDS is set in this environment")
end
eq(progress_guard.fingerprint({ { ["function"] = { name = "read", arguments = '{"path":"a"}' } } }),
  'read({"path":"a"})', "a decision is its name and arguments")

local same = { signature = "read(a)", results = "digest-1", effects = 0, changes = "c1" }
local g = progress_guard.new({ repeat_limit = 3, idle_rounds = 12, ceiling = 0 })
eq(progress_guard.observe(g, same), nil, "the first identical round is a retry")
eq(progress_guard.observe(g, same), nil, "the second is still a retry")
local stopped = progress_guard.observe(g, same)
has(stopped, "guard_repeated_calls", "the third identical decision is a loop")
has(stopped, "read(a)", "the reason names the call")

local idle = progress_guard.new({ repeat_limit = 10, idle_rounds = 4, ceiling = 0 })
eq(progress_guard.observe(idle, { signature = "read(a)", results = "same", effects = 0, changes = "c" }), nil,
  "the first round is the baseline, never counted against the model")
eq(progress_guard.observe(idle, { signature = "read(b)", results = "same", effects = 0, changes = "c" }), nil, "one")
eq(progress_guard.observe(idle, { signature = "read(c)", results = "same", effects = 0, changes = "c" }), nil, "two")
eq(progress_guard.observe(idle, { signature = "read(d)", results = "same", effects = 0, changes = "c" }), nil, "three")
local flat = progress_guard.observe(idle, { signature = "read(e)", results = "same", effects = 0, changes = "c" })
has(flat, "guard_no_progress", "four rounds that changed nothing are a loop")
has(flat, "4 rounds", "the reason counts them")

local busy = progress_guard.new({ repeat_limit = 10, idle_rounds = 3, ceiling = 0 })
eq(progress_guard.observe(busy, { signature = "a", results = "r1", effects = 0, changes = "c" }), nil, "round one")
eq(progress_guard.observe(busy, { signature = "b", results = "r2", effects = 0, changes = "c" }), nil,
  "new results are progress, so reads are never a loop")
eq(progress_guard.observe(busy, { signature = "c", results = "r3", effects = 1, changes = "c" }), nil,
  "an effect is progress")

local capped = progress_guard.new({ repeat_limit = 10, idle_rounds = 10, ceiling = 2 })
eq(progress_guard.observe(capped, { signature = "a", results = "r1", effects = 1, changes = "c" }), nil, "round one")
has(progress_guard.observe(capped, { signature = "b", results = "r2", effects = 1, changes = "c" }),
  "runaway_guard", "an operator's ceiling is honoured when it is set")

-- --------------------------------------------------------------- a failed provider call
local function turn(title, user)
  local session_id = memory.ensure_session(user, "local", title)
  local events = {}
  local agent = agentlib.new(session_id, function(event) events[#events + 1] = event end,
    "master", user, "local")
  agent.stream = true
  return agent, session_id, events
end

local function assistant_rows(session_id)
  local rows = {}
  for _, row in ipairs(memory.session_messages(session_id) or {}) do
    if row.role == "assistant" then rows[#rows + 1] = row end
  end
  return rows
end

local user = "no-silent-stops"
local agent, session_id, events = turn("provider stall", user)
-- A durable subscriber: a wake on the run.failed topic. If the announcement is real, this fires.
local watched = selfloop.schedule({ session_id = session_id, owner = user, reason = "watch run failures",
  prompt = "report the failure", on = { "run.failed" } }, { session_id = session_id, user_id = user })
ok(watched and watched.ok, "the watching wake is scheduled: " .. json.encode(watched or {}))

host.http_stream = function()
  return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local run_ok, run_error = pcall(agent.run, agent, "do the thing nobody will answer")
ok(not run_ok, "a provider stall fails the run")
has(run_error, "provider_error", "the caller still gets the transport's own words")

local rows = assistant_rows(session_id)
eq(#rows, 1, "one failed run writes exactly one assistant row (never an empty one, never two)")
has(rows[1].content, "run_failed: provider_stalled", "the row itself names the failure")
eq(rows[1].ok, 0, "and is recorded as failed")
local trace = json.encode(rows[1].trace or {})
has(trace, "provider_stalled", "the trace carries the name")
has(trace, "model_call", "the model call that failed is still in the trace")

local state = memory.session_state(session_id) or {}
eq(state.state, "failed", "the session's tail reads as failed")
has(state.detail, "provider_stalled", "and the detail names it")

local announced, errored = false, false
for _, event in ipairs(events) do
  if event.type == "failure" and event.code == "provider_stalled" then announced = true end
  if event.type == "error" and tostring(event.error):find("provider_stalled", 1, true) then errored = true end
end
ok(announced, "the failure is announced on the stream as a failure event")
ok(errored, "and on the error channel every client already reads")

local wakes = selfloop.list({ session_id = session_id }, { session_id = session_id, user_id = user })
local fired = nil
for _, wake in ipairs((wakes and wakes.wakes) or {}) do
  if wake.reason == "watch run failures" then fired = wake end
end
ok(fired and fired.due_at, "the durable run.failed fact fired the subscriber's wake")
local retry = nil
for _, wake in ipairs((wakes and wakes.wakes) or {}) do
  if tostring(wake.reason or ""):find("run failed:", 1, true) then retry = wake end
end
ok(retry, "a retryable failure schedules one wake that re-drives the thread")
has(retry.prompt, run_failure.WAKE_MARK, "the wake is marked, so its own failure cannot schedule another")
has(retry.prompt, "provider_stalled", "and carries the named reason")
ok(run_failure.loop_broken(run_failure.WAKE_MARK .. " x"), "the mark is what closes the wake loop")
eq(run_failure.loop_broken("an ordinary request"), false, "an ordinary request does not close it")

-- --------------------------------------------------------------- a guard stop is not a cut
local agent2, session2, events2 = turn("guard stop", user .. "-guard")
local rounds = 0
host.http_stream = function()
  rounds = rounds + 1
  return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
    tool_calls = { { id = "call-" .. rounds, type = "function",
      ["function"] = { name = "read", arguments = '{"path":"AGENTS.md","limit":2}' } } } })
end
local guard_ok, guard_error = pcall(agent2.run, agent2, "keep reading the same thing")
ok(not guard_ok, "the guard stops the turn")
has(guard_error, "guard_repeated_calls", "and the stop names itself")
eq(rounds, 3, "three identical decisions, no more")

local notes = selfloop.notes_text(session2)
has(notes, "Guard checkpoint", "the checkpoint is written before the turn ends")
has(notes, "guard_repeated_calls", "it names why the turn stopped")
has(notes, "keep reading the same thing", "and keeps the goal the next turn continues")

local guard_rows = assistant_rows(session2)
local failed_rows, empty_failed = 0, 0
for _, row in ipairs(guard_rows) do
  if row.ok == 0 then
    failed_rows = failed_rows + 1
    if tostring(row.content or "") == "" then empty_failed = empty_failed + 1 end
  end
end
eq(failed_rows, 1, "a guard stop writes one failed row, not one per round")
eq(empty_failed, 0, "and never an empty one")
local last_guard = guard_rows[#guard_rows]
has(last_guard.content, "guard_repeated_calls", "the durable row names the guard")
ok(#guard_rows > 1, "the tool rounds before it are still in the transcript (they are the evidence)")

-- --------------------------------------------------------------- presence: a process, not a row
-- The liveness signal the landing queue reads (scripts/lib/landing-queue.mjs): a row written by the
-- process serving the session, heartbeated while it works, deleted when it lets go - and never able
-- to close a session another live process is serving.
--
-- The table ships in lua/core/schema.sql. A binary built before this tree carries an older embedded
-- schema, so the whole section is reported as SKIPPED against one rather than silently passing.
local presence_table = false
do
  local found = host.sql_query("SELECT name FROM sqlite_master WHERE type='table' AND name='session_presence'",
    json.encode({}))
  local rows = type(found) == "string" and json.decode(found) or found
  presence_table = type(rows) == "table" and rows[1] ~= nil
end
if not presence_table then
  skip("session presence", "this wa binary embeds a schema without session_presence (the Rust and queue halves are pinned by test-session-liveness.mjs and resources.rs)")
else
local presence_user = "no-silent-stops-presence"
local presence_session = memory.ensure_session(presence_user, "local", "presence")
local who = memory.process_identity()
ok(who.pid > 0, "this process knows its own pid")
local began = memory.presence_begin(presence_session, { role = "master" })
ok(began and began.pid == who.pid, "presence_begin records this process")
local row = memory.presence(presence_session)
ok(row and tonumber(row.pid) == who.pid, "the row names the pid")
local before_beat = tonumber(row.heartbeat_at) or 0
host.sleep(1100)
memory.presence_beat(presence_session)
local beaten = memory.presence(presence_session)
ok(tonumber(beaten.heartbeat_at) > before_beat, "a beat moves the heartbeat")
ok(memory.presence_live(presence_session, 900) ~= nil, "a fresh heartbeat is live")
ok(memory.presence_live(presence_session, 0) == nil, "a zero tolerance reports it stale instead")
-- Another live process serving the same session must not be closed by this one.
host.sql_exec("UPDATE session_presence SET pid=? WHERE session_id=?",
  json.encode({ who.pid + 1000, presence_session }))
local ended, why = memory.finish_session(presence_session)
eq(ended, false, "a session another process is serving is not ended by this one")
has(why, "session_live_in_process", "and the refusal names the process")
host.sql_exec("UPDATE session_presence SET pid=? WHERE session_id=?",
  json.encode({ who.pid, presence_session }))
eq(memory.finish_session(presence_session), true, "this process may end the session it serves")
memory.presence_begin(presence_session, { role = "master" })
memory.presence_end(presence_session)
eq(memory.presence(presence_session), nil, "presence_end removes the row")
eq(memory.presence_live(presence_session, 900) == nil, true, "and nothing is live afterwards")
end

-- --------------------------------------------------------------- read_file says why
local text = host.read_file("AGENTS.md")
ok(type(text) == "string" and #text > 0, "a readable file still answers its text")
local missing, why = host.read_file("no/such/file/for/this/test.txt")
eq(missing, nil, "a missing file is nil")
if type(why) == "string" then
  has(why, "read_file_missing", "and the second answer names why")
  local answer = file_tools.read({ path = "no/such/file/for/this/test.txt" })
  eq(answer.error, "read_file_missing", "the read tool carries the host's name to the model")
  local directory, directory_why = host.read_file("lua")
  eq(directory, nil, "a directory is nil")
  has(tostring(directory_why), "read_file_is_a_directory", "and says it is a directory, not missing")
else
  skip("read_file named answers", "this wa binary answers a bare nil (the Lua side is pinned above)")
end

print(string.format("ok no-silent-stops: %d checks", checks))
