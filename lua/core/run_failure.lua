-- A run that does not end with an answer says so, by name, once - in the transcript, in the
-- event stream and in a waking fact.
--
-- Measured on wasm_the_first, 10/11 (session a073ee85): after a 12-minute provider stall the
-- provider timed out three times and the run ended with an assistant row whose text was empty;
-- nothing woke anyone and nothing streamed a failure, so "the provider stalled" and "the agent
-- had nothing to say" looked exactly alike. Session b8878ed2 was cut by the runaway guard the
-- same way. The row was there either way - its trace held the reason - but a reason in a trace
-- nobody reads is a silent stop.
--
-- So every non-answer ending goes through here:
--
--   * classify: one named code per failure, the sentence a reader needs, and whether a rerun
--     could plausibly finish it. Pure.
--   * record: ONE durable assistant row, ok=false, whose *content* is the named failure. The
--     ledger's own `classify()` already calls such a tail `failed`, and evidence.failure() reads
--     the span, so the state, the session list and the reader agree.
--   * announce: the same fact on the event stream the window reads, on the durable bus event
--     (`run.failed`, which hooks and wakes can subscribe to), and - for a failure a retry can
--     plausibly finish - one self-wake that re-drives the thread. The wake is a *notice*, not a
--     budget: it is scheduled once per run, it carries the named reason, and a wake that itself
--     failed does not schedule another (M.loop_broken).
--
-- Nothing here counts turns or limits the model. A run ends because the work is done, the run was
-- cancelled, or something failed; this module only makes the last case visible.

local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")

local M = {}

-- The bus topic and the durable event name. One fact, two readers: `host.bus_publish` is the live
-- fan-out used by the update banner, and `selfloop.publish` is the durable one that wakes and hooks
-- already understand (docs/SELF-LOOP.md, docs/HOOKS.md).
M.TOPIC = "wa.run.failed"
M.EVENT = "run.failed"

-- The prefix makes the row greppable and marks it as a harness fact, not prose from the model.
M.PREFIX = "run_failed: "

-- Order matters: the first match wins, and the most specific evidence is checked first. Each class
-- names the sentence a reader needs, because "provider_error: timeout: receive response" alone does
-- not say whether to wait, retry or look at the node.
local CLASSES = {
  { code = "provider_stalled", retryable = true,
    why = "the provider did not answer within its deadline",
    match = { "provider_stalled", "timeout: receive response", "timeout: connect", "connect: timeout" } },
  { code = "provider_empty", retryable = true,
    why = "the provider answered with nothing",
    match = { "empty_reply", "returned nothing" } },
  { code = "provider_error", retryable = true,
    why = "the provider call failed",
    match = { "provider_error:" } },
  { code = "run_cancelled", retryable = true,
    why = "the run was cancelled before it answered",
    match = { "run_cancelled" } },
  { code = "guard_repeated_calls", retryable = true,
    why = "the progress guard stopped the turn after the same call repeated",
    match = { "guard_repeated_calls" } },
  { code = "guard_no_progress", retryable = true,
    why = "the progress guard stopped the turn after rounds that changed no state",
    match = { "guard_no_progress" } },
  { code = "runaway_guard", retryable = true,
    why = "the configured round ceiling stopped the turn",
    match = { "runaway_guard" } },
  { code = "context_overflow", retryable = false,
    why = "the request no longer fits the model's window",
    match = { "context_overflow" } },
  { code = "resource_refused", retryable = false,
    why = "the session's run claim was held by another live run",
    match = { "run_resource_refused", "resource_busy" } },
  { code = "resource_release_failed", retryable = false,
    why = "the run ended but its claim could not be released",
    match = { "resource_release_failed" } },
  { code = "run_interrupted", retryable = true,
    why = "the process running the turn was replaced or stopped",
    match = { "run_interrupted", "binary_replaced" } },
}

local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

-- A Lua error carries its origin: `C:\\...\\agent.lua:2187: ...\\provider.lua:1218: provider_error: ...`.
-- A reader (and the 192-byte excerpt the session detail shows) needs the failure, not three paths it
-- already knows. The paths are not deleted from the trace; only the sentence the name is built from
-- is cleaned, and only of leading locations.
local function strip_locations(text)
  local cleaned = text
  for _ = 1, 8 do
    local next_text = cleaned:gsub("^[%w%._%-/\\:]+%.lua:%d+: ", "", 1)
    if next_text == cleaned then break end
    cleaned = next_text
  end
  return cleaned
end
M.strip_locations = strip_locations

-- Pure: the problem text (an error, a refusal, a guard sentence) to one named failure.
-- Returns { code, why, detail, retryable, text }.
function M.classify(problem)
  local detail = tostring(problem or "")
  detail = redact.text(strip_locations(detail:gsub("%s+$", "")))
  if detail == "" then detail = "the run stopped without an answer and recorded no reason" end
  local lower = detail:lower()
  for _, class in ipairs(CLASSES) do
    for _, needle in ipairs(class.match) do
      if contains(lower, needle) then
        return { code = class.code, why = class.why, detail = detail, retryable = class.retryable,
          text = M.PREFIX .. class.code .. " - " .. class.why .. ": " .. detail }
      end
    end
  end
  return { code = "run_failed", why = "the run stopped without an answer", detail = detail,
    retryable = false, text = M.PREFIX .. "run_failed - the run stopped without an answer: " .. detail }
end

-- A run the reader stopped (Esc, Ctrl-C) is not a failure, and it is not retried.
--
-- Victor, 13/11: interrupting a self-wake run printed three lines - `⏰ self-wake: run failed:
-- run_cancelled`, `! run_failed: run_cancelled - the run was cancelled before it answered:
-- run_cancelled`, and `⎿ Interrupted by user`. The first two were this module treating the reader's
-- own choice as a failure: it wrote a failure row, announced an error on the stream and the bus, and
-- scheduled a rerun of a run the reader had just cancelled. The screen now says one line
-- (`lua/core/cli_view.lua`'s `failed`), and the record says the same sentence once.
M.CANCEL_CODE = "run_cancelled"
M.CANCEL_TEXT = "Interrupted by user"

-- Whether a classified failure is really the reader stopping the run.
function M.cancelled(info)
  return type(info) == "table" and tostring(info.code or "") == M.CANCEL_CODE
end

-- The durable row's text for a classified failure. Kept beside classify so a caller that already
-- has the fields does not rebuild the sentence differently.
function M.text(info)
  return info.text or M.PREFIX .. tostring(info.code or "run_failed") .. " - "
    .. tostring(info.why or "the run stopped without an answer") .. ": " .. tostring(info.detail or "")
end

-- The one fact every announcement carries. Ids, a code and a bounded excerpt - never the whole
-- error, never model text, so a bus subscriber cannot accidentally depend on either.
function M.fact(info, opts)
  opts = opts or {}
  local detail = tostring(info.detail or "")
  if #detail > 400 then detail = detail:sub(1, 400) .. " (truncated)" end
  return {
    schema = M.TOPIC,
    schema_version = 1,
    code = tostring(info.code or "run_failed"),
    retryable = info.retryable == true,
    detail = detail,
    detail_bytes = #tostring(info.detail or ""),
    session_id = opts.session_id,
    run_id = opts.run_id,
    message_id = opts.message_id,
    user_id = opts.user_id,
    round = opts.round,
    attempts = opts.attempts,
    at = opts.at or math.floor(host.now() * 1000),
  }
end

-- One durable row, and only one. The trace keeps the model/tool spans the run had reached, then
-- adds the run's own failed span, so evidence.failure() - which scans for the last failed span -
-- reads the named reason rather than an empty message.
function M.record(info, opts)
  opts = opts or {}
  local session_id = opts.session_id
  if not session_id then return nil, "run_failure_requires_session" end
  local memory = opts.memory or dofile("lua/core/memory.lua")
  local trace = {}
  for _, span in ipairs(opts.trace or {}) do trace[#trace + 1] = span end
  trace[#trace + 1] = { kind = "run", ok = false, code = info.code, error = info.detail,
    ms = opts.ms, round = opts.round, attempts = opts.attempts, retryable = info.retryable }
  local id = opts.message_id or host.uuid()
  local turn = {
    id = id, role = "assistant", content = M.text(info), ok = false,
    trace = trace, debug = opts.debug,
    ms = opts.ms,
  }
  -- The agent's own recorder when it is given: it appends the run's counts snapshot to the row, and
  -- a failed run's context growth is exactly the kind of fact a reader must still be able to see
  -- (`scripts/test-context-growth.lua` asserts it). Without a recorder (a restart notice from outside
  -- the loop) the plain append is the right write.
  if type(opts.record) == "function" then
    return { id = id, seq = opts.record(turn) }
  end
  local seq = memory.append_turn(session_id, turn)
  return { id = id, seq = seq }
end

-- Publish + emit. Best effort on every channel: a failure to announce must never replace the
-- failure being announced. Returns what actually happened, so a caller/test can tell the two apart.
function M.announce(info, opts)
  opts = opts or {}
  local fact = M.fact(info, opts)
  local out = { published = false, event = false, emitted = false, wake = nil }
  -- `opts.quiet`: the fact still goes to the bus and the durable event (a subscriber must learn that the
  -- run ended), but nothing is written on the reader's stream - a cancellation is already said there, once.
  if type(opts.emit) == "function" and not opts.quiet then
    local ok = pcall(opts.emit, { type = "failure", code = fact.code, retryable = fact.retryable,
      error = fact.detail, session_id = fact.session_id, run_id = fact.run_id,
      message_id = fact.message_id, text = M.text(info) })
    out.emitted = ok
    -- The window's existing error channel too: a client that only knows `error` must not miss it.
    pcall(opts.emit, { type = "error", error = M.text(info), code = fact.code, run_id = fact.run_id })
  end
  if host.bus_publish then
    local ok, answer = pcall(host.bus_publish, M.TOPIC, json.encode(fact))
    out.published = ok and answer ~= false and answer ~= nil
  end
  local ok, answer = pcall(function()
    return dofile("lua/core/selfloop.lua").publish(M.EVENT, fact,
      { session_id = fact.session_id, user_id = fact.user_id })
  end)
  out.event = ok and type(answer) == "table" and answer.ok == true
  if out.event then out.matched = answer.matched end
  return out
end

-- A failure a rerun can plausibly finish is handed back to the thread once, as a wake.
--
-- `opts.last_user` is the newest user row's content. A wake this module already scheduled starts
-- with M.WAKE_MARK, and a run that fails while answering one must not schedule another: that is
-- the only loop this could create, and it is closed by the mark, not by a count.
M.WAKE_MARK = "[run failure]"
M.WAKE_SECONDS = 60

function M.wake_seconds()
  local value = tonumber(host.getenv("WASM_AGENT_RUN_FAILURE_WAKE_SECONDS") or "")
  if value == nil then return M.WAKE_SECONDS end
  if value <= 0 then return nil end
  return value
end

function M.wake_prompt(info)
  return M.WAKE_MARK .. " The previous run in this thread stopped before it answered (" ..
    M.text(info) .. "). This is an automated continuation, not a new request. Re-establish the " ..
    "real state from the machine first (files, `git status`, processes) - a step whose result is " ..
    "not recorded may or may not have run - then finish the task the user last asked for and say " ..
    "plainly what had already been done."
end

function M.loop_broken(last_user)
  local text = tostring(last_user or "")
  return text:sub(1, #M.WAKE_MARK) == M.WAKE_MARK
end

-- Schedule that one wake. Returns the wake id, or nil and why not. Every refusal is a fact, not an
-- exception: a failure to schedule is reported, never substituted for the failure itself.
function M.wake(info, opts)
  opts = opts or {}
  local seconds = M.wake_seconds()
  if seconds == nil then return nil, "wake_disabled" end
  if info.retryable ~= true then return nil, "not_retryable" end
  -- A run the reader stopped is not one to rerun by itself: the reader ended it on purpose.
  if M.cancelled(info) then return nil, "cancelled" end
  if opts.subagent then return nil, "not_for_subagent" end
  if M.loop_broken(opts.last_user) then return nil, "already_woken" end
  local ok, answer = pcall(function()
    return dofile("lua/core/selfloop.lua").schedule({
      session_id = opts.session_id,
      owner = opts.user_id,
      reason = "run failed: " .. tostring(info.code),
      prompt = M.wake_prompt(info),
      in_seconds = seconds,
    }, { session_id = opts.session_id, user_id = opts.user_id })
  end)
  if not ok then return nil, "wake_failed: " .. tostring(answer) end
  if type(answer) ~= "table" or not answer.ok then
    return nil, "wake_refused: " .. tostring(answer and (answer.error or json.encode(answer)) or "no answer")
  end
  return answer.wake and answer.wake.id or "scheduled", nil
end

-- The whole ending, in the order that keeps the record ahead of the announcement: classify, write
-- the one row, then announce (stream, bus, wake). Returns the classification plus what happened.
function M.handle(problem, opts)
  opts = opts or {}
  local info = M.classify(problem)
  -- A user interrupt (Esc, Ctrl-C) is not a failure: no `run_failed` row, no error on the stream, and no
  -- wake - a cancelled run must not silently start itself again. One row, one sentence, once.
  if M.cancelled(info) then
    local cancelled = { code = M.CANCEL_CODE, why = M.CANCEL_TEXT, detail = info.detail,
      retryable = false, cancelled = true,
      text = M.CANCEL_TEXT .. (opts.self_wake and " (self-wake)" or "") }
    local recorded, record_error = M.record(cancelled, opts)
    local announced = M.announce(cancelled, { quiet = true, session_id = opts.session_id,
      user_id = opts.user_id, run_id = opts.run_id, message_id = recorded and recorded.id or nil,
      round = opts.round, attempts = opts.attempts })
    return { info = cancelled, cancelled = true,
      message_id = recorded and recorded.id or nil, seq = recorded and recorded.seq or nil,
      record_error = record_error, announced = announced, wake_id = nil, wake_reason = "cancelled" }
  end
  local recorded, record_error = M.record(info, opts)
  if recorded then opts.message_id = recorded.id end
  local announced = M.announce(info, opts)
  local wake_id, wake_reason = M.wake(info, opts)
  return { info = info, message_id = recorded and recorded.id or nil,
    seq = recorded and recorded.seq or nil, record_error = record_error,
    announced = announced, wake_id = wake_id, wake_reason = wake_reason }
end

return M
