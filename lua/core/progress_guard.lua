-- The progress guard: a runaway loop is stopped; a long task is not.
--
-- The fixed 200-round ceiling this replaces stopped authorised work mid-mission (measured on
-- wasm_the_first, 10/11, session b8878ed2: `(runaway guard: 200 tool rounds without a final
-- answer)` cut a task the operator had asked for, and the continuation restarted cold). The
-- operator's rule is that the model is free - no turn budget, no round count, no nudge - so the
-- only thing worth stopping is a loop that is provably not making progress.
--
-- Two facts are enforceable without a budget, and they are the two this module decides on:
--
--   repeated calls  the same decision, by name and arguments, `repeat_limit` rounds in a row WITH NO
--                   NEW OBSERVATION. Re-issuing one call is not thinking; three identical decisions
--                   whose answers never moved is a loop (a stuck probe, a retry that cannot help).
--                   A call whose answer changes every round - an await on work still running, whose
--                   elapsed clock and output move - is waiting, not looping (19/11).
--   no progress     `idle_rounds` rounds in a row that changed nothing: no effectful call
--                   succeeded, no file changed, and the tool results were byte-identical to the
--                   round before. Reading twenty files is progress (the answers differ); asking
--                   the same question of a dead process twenty times is not.
--
-- An absolute ceiling still exists, but only when an operator sets `WASM_AGENT_MAX_TOOL_ROUNDS`:
-- the default is none (0), because a round count is exactly the budget the rule forbids.
--
-- Everything here is pure: `new()` holds the counters, `observe()` reads one round's facts and
-- answers a named reason to stop, or nil. The agent loop owns the effects (the notes checkpoint
-- and the failure record); this module owns the judgement, so `scripts/test-progress-guard.lua`
-- can pin it without a model, a node or a socket.
local M = {}

M.REPEAT_LIMIT_DEFAULT = 3
M.IDLE_ROUNDS_DEFAULT = 12

local function env_number(name, default)
  local raw = host.getenv(name)
  if raw == nil or raw == "" then return default end
  local value = tonumber(raw)
  if value == nil or value < 0 then return default end
  return math.floor(value)
end

-- Two identical decisions in a row is a retry; the third is a loop.
function M.repeat_limit()
  return math.max(2, env_number("WASM_AGENT_GUARD_REPEAT_LIMIT", M.REPEAT_LIMIT_DEFAULT))
end

-- No state change for this many rounds in a row is a loop. Configurable, never zero.
function M.idle_rounds()
  return math.max(3, env_number("WASM_AGENT_GUARD_IDLE_ROUNDS", M.IDLE_ROUNDS_DEFAULT))
end

-- 0 means "no ceiling". A value is honoured only because an operator asked for it.
function M.ceiling()
  return env_number("WASM_AGENT_MAX_TOOL_ROUNDS", 0)
end

-- One round's decision, as a string: the calls in order, each name with its arguments. Two rounds
-- with the same fingerprint asked the model the same question and got the same plan back.
function M.fingerprint(calls)
  local parts = {}
  for _, call in ipairs(calls or {}) do
    local function_ = call["function"] or call
    parts[#parts + 1] = tostring(function_.name or "?") .. "(" .. tostring(function_.arguments or "") .. ")"
  end
  return table.concat(parts, "\n")
end

-- A wait on supervised work is RECOGNISED BY ITS ANSWER, never by the calling tool's name.
--
-- Measured 19/11 on rel-native (out.log ~16590-16610): the call the guard killed was
-- `codemode({code: "const a = await tools.operation({action:'await', id:'op-...', wait_s:900})"})`,
-- repeated three rounds while the operation it waited on was still pending behind another mission's
-- suite lock. The answer said `{"state":"pending",...}` - and a check that looked for the `operation`
-- tool by name could not see it, because the call the model made was codemode. The answer is the one
-- fact both shapes share, so the answer is what this reads.
--
-- A wait on SETTLED work is not this: it hands back the same bytes again, so it is still a repeat and
-- still stops. And an answer with no wait evidence is not evidence of waiting - unknown is not yes.
local WAIT_STATES = { pending = true, running = true, queued = true, accepted = true, draining = true }

-- One record that says supervised work is still running. `pending` is codemode's own documented meaning
-- for a call that outlived its wait (`{state:"pending", op}`), so it needs an id to count; a live
-- operation state carries its id or its own clock.
-- The fields that say a record is a WAIT rather than a finished answer. A codemode pending answer is
-- the MEASURED shape (rel-native out.log ~16590-16610): the script returned `{state:"pending",
-- log:"..."}`, which names no op and no operation_id, so a predicate demanding those missed the very
-- call the guard killed. `log`, `bytes`, `output_bytes`, `progress`, `promoted` and `shell_exited` are
-- the facts a running call reports; any of them beside a live state is evidence of supervised work.
local WAIT_EVIDENCE = { op = true, operation_id = true, elapsed_ms = true, name = true,
  log = true, bytes = true, output_bytes = true, progress = true, promoted = true,
  shell_exited = true, waiting_for = true }

local function live_wait(record)
  if type(record) ~= "table" or record.settled == true then return false end
  -- 202 IS THE DOCUMENTED "accepted, still running or queued" (lua/core/status.lua:296,309-313), and it
  -- is the shape a nested call ACTUALLY reports: the measured codemode answer carries
  -- {name:"operation", ok:true, status:202}, a NUMBER, not a state string. A predicate that only read
  -- state strings missed the very call the guard killed.
  if tonumber(record.status) == 202 or tonumber(record.code) == 202 then return true end
  local state = tostring(type(record.state) == "string" and record.state
    or (type(record.status) == "string" and record.status) or "")
  if not WAIT_STATES[state] then return false end
  for field in pairs(WAIT_EVIDENCE) do
    if record[field] ~= nil then return true end
  end
  return false
end

--- Does this answer carry evidence of supervised work still running? Reads the answer itself, then the
--- rest of a script's result (`calls`, `value`), so a nested await and a direct one are the same fact.
function M.waiting(answer)
  if type(answer) ~= "table" then return false end
  if live_wait(answer) then return true end
  if type(answer.value) == "table" and live_wait(answer.value) then return true end
  for _, key in ipairs({ "calls", "call", "results" }) do
    local list = answer[key]
    if type(list) == "table" then
      for _, record in pairs(list) do
        if live_wait(record) then return true end
      end
    end
  end
  return false
end
-- The clock-shaped facts a tool answer carries. They move every second the work runs, so a digest over
-- them changes with no work done - which is what made a `wait_ms:0` poll look like progress forever
-- (review r2, item 6). `elapsed_ms`, `remaining_ms`, `ms` and a `log` line that is mostly a timer are
-- removed before the digest is taken; every other field is kept, so real output still shows up.
-- A CLOCK FIELD IS RECOGNISED BY ITS SHAPE, not by a list that is always one field behind.
-- Review r3, B6: the list missed the whole `timing` block (execution_ms, total_ms, setup_ms,
-- spawn_ms, measured_ms, ...), so the digest of a running operation moved every round with no work
-- done and a wait_s:0 poll looked like progress forever. Every fact this module compares is either an
-- answer or a clock, and every clock on this node ends in _ms or is named below.
local CLOCK_NAMES = { ms = true, elapsed = true, remaining = true, timing = true, waited = true }
local function clock_field(key)
  local name = tostring(key)
  return CLOCK_NAMES[name] == true or name:sub(-3) == '_ms'
end

--- A digest of what an answer SAYS, with the clock fields removed. Two answers that differ only by a
--- passing second answer the same string, so a poll that learned nothing is visible as a repeat.
function M.stable(answer)
  local function strip(value, depth)
    if type(value) ~= "table" or depth > 6 then return value end
    local copy = {}
    for key, item in pairs(value) do
      if not clock_field(key) then copy[key] = strip(item, depth + 1) end
    end
    return copy
  end
  return strip(answer, 0)
end

-- WHAT THE WAIT ITSELF LEARNED: the operation-progress fields of an answer, and nothing else.
--
-- Review r3, B6. Three attempts to digest a whole answer failed for one reason: a codemode answer is
-- mostly bookkeeping - arguments, evidence pointers, timing, attempts - and every part of it can move
-- while the operation does nothing. Clock-stripping fixed one field at a time and the digest still
-- drifted, so a wait_s:0 poll looked like progress forever.
--
-- The fix is to digest only the facts that mean WORK ADVANCED: the operation's state, whether it
-- settled, how many output bytes it has, whether it was promoted, and whether it exited. Those are the
-- fields the node itself uses to say a pending call is making progress (codemode_pending's own
-- PROGRESS_FIELDS). The evidence pointers are FOLLOWED, because that is where a nested call's real
-- state lives, and the fields are COLLECTED from every record in the answer.
local PROGRESS_FIELDS = { state = true, status = true, settled = true, ok = true,
  output_bytes = true, bytes_written = true, promoted = true, shell_exited = true,
  output_streams_closed = true, operation_id = true, op = true }

local function collect(value, into, read, seen, depth)
  if type(value) ~= 'table' or depth > 6 then return into end
  for key, item in pairs(value) do
    local name = tostring(key)
    if PROGRESS_FIELDS[name] and type(item) ~= 'table' then
      into[#into + 1] = name .. '=' .. tostring(item)
    elseif type(item) == 'table' then
      if type(item.path) == 'string' and type(read) == 'function' and not seen[item.path] then
        -- An evidence pointer: the raw answer behind it is what the call actually said.
        seen[item.path] = true
        local ok, raw = pcall(read, item.path)
        if ok and type(raw) == 'string' and raw ~= '' then
          local parsed_ok, parsed = pcall(dofile('lua/vendor/json.lua').decode, raw)
          if parsed_ok and type(parsed) == 'table' then collect(parsed, into, read, seen, depth + 1) end
        end
      end
      collect(item, into, read, seen, depth + 1)
    end
  end
  return into
end

--- What a wait learned: the operation-progress facts of an answer, in a stable order.
function M.said(answer, read)
  local into = collect(answer, {}, read, {}, 0)
  table.sort(into)
  return table.concat(into, '\n')
end

function M.new(opts)
  opts = opts or {}
  return {
    repeat_limit = opts.repeat_limit or M.repeat_limit(),
    idle_rounds = opts.idle_rounds or M.idle_rounds(),
    ceiling = opts.ceiling or M.ceiling(),
    round = 0,
    last_call = nil,
    repeats = 0,
    last_results = nil,
    last_say = nil,
    idle = 0,
    changes = opts.changes,
    stopped = nil,
  }
end

-- One round: `obs` is
--   signature  the round's call fingerprint (M.fingerprint)
--   results    a digest of the tool results this round produced (nil when none ran)
--   effects    how many effectful calls ran successfully
--   changes    a digest of the run's changed files (nil when the run changes none)
--   label      a short, human name for the repeated call ("read AGENTS.md"), for the reason text
--   waiting    every call this round was a wait on work still running (M.waiting)
--   wait_spent_ms / wait_budget_ms  what the wait actually cost, against what it asked for, so a
--              wait that SPENT time is progress and a `wait_ms:0` poll that spent none is not
--   say        a digest of what the calls SAID, clocks stripped and evidence pointers followed
--              (M.said); a wait is progress only when this MOVES - effects never exempt a wait
-- Returns nil to continue, or a named reason string to stop. The reason is the durable code, so a
-- reader can grep it and M.classify can name it.
function M.observe(state, obs)
  obs = obs or {}
  state.round = state.round + 1

  -- A CHANGE CAUSED ONLY BY A CLOCK IS NOT PROGRESS (review r2, item 6). The measured pending answer
  -- carries `log` text that is mostly elapsed time (`"0\n48:06\n15:04"`); a digest over it changes
  -- every round even when the operation did nothing at all, which would make a `wait_ms:0` poll look
  -- like work forever. So the round reports a digest with the clock fields REMOVED (obs.results_stable,
  -- built by M.stable), and `changed` compares that when it is present. A real byte of output still
  -- changes it; a second passing does not.
  local results_digest = obs.results_stable ~= nil and obs.results_stable or obs.results
  local changed = (obs.effects or 0) > 0
    or (obs.changes ~= nil and obs.changes ~= state.changes)
    or (results_digest ~= nil and results_digest ~= state.last_results)
  state.changes = obs.changes ~= nil and obs.changes or state.changes
  state.last_results = results_digest

  -- A repeat is the same decision with NO NEW OBSERVATION - the module's own contract, which this line
  -- did not honour: it counted every identical call whatever the round had learned. Measured 19/11 on
  -- rel-native (out.log ~16590-16610): three `codemode({code: ... await operation ...})` rounds were
  -- killed as guard_repeated_calls while their answers were plainly moving
  -- (`log":"0\n42:50\n09:48...` then `48:06\n15:04...` - the operation was spending real time behind
  -- another mission's suite lock). The blocked build was legitimate work, ended by a counter that
  -- ignored the evidence in front of it.
  --
  -- A round whose results are byte-identical is still a loop: ten `wait_ms:0` calls that answer at once
  -- with the same bytes are ten identical decisions, which is exactly what this must stop.
  local signature = tostring(obs.signature or "")
  if signature ~= "" and signature == state.last_call then
    state.repeats = state.repeats + 1
  else
    state.repeats = signature ~= "" and 1 or 0
    state.last_call = signature ~= "" and signature or nil
  end
  if changed then state.idle = 0 else state.idle = state.idle + 1 end

  -- A round that waited on work still running is progress ONLY when the wait itself learned
  -- something or actually waited. Measured 19/11 on rel-native: the killed waits each spent a full
  -- 900 s budget behind another mission's suite lock, and their answers plainly moved
  -- (log bytes 42:50 -> 48:06). The hole this closes is the other shape: `wait_s:0` / `wait_ms:0`
  -- answers AT ONCE, so ten identical immediate answers are ten identical decisions with no new
  -- observation - a hot loop, not a wait. So a live wait is exempt when its answer MOVED or when it
  -- spent the budget it asked for; a poll that spent nothing stays a repeat, and a wait that spent
  -- real time is progress even when its answer is byte-identical.
  -- A LONG WAIT IS JUDGED BY THE TIME THE CALL SPENT, not by a budget the call may not report.
  -- codemode_pending strips wait_s before dispatching, so the answer carries no budget at all and a
  -- budget test could never fire (review r3, B6). The rule is: a wait that spent at least a second, or
  -- its own full budget when one is known, is progress - so an await that blocked five minutes and
  -- answered the same pending is progress, while a wait_s:0 poll that returned at once is not.
  local budget = math.max(1000, obs.wait_budget_ms or 0)
  local waited_long = (obs.wait_spent_ms or 0) >= budget
  -- AND NEVER ON EFFECTS. A codemode call that merely awaited counted as an effect, which made
  -- `changed` true every round; the exemption reads only what the call SAID (obs.say) or how long it
  -- waited, never the effect count.
  local said_more = obs.say ~= nil and obs.say ~= state.last_say
  if obs.say ~= nil then state.last_say = obs.say end
  if obs.waiting == true and (said_more or waited_long) then
    state.repeats = math.min(state.repeats, 1)
    state.idle = 0
  end

  if signature ~= "" and state.repeats >= state.repeat_limit then
    state.stopped = string.format("guard_repeated_calls: the same call was made %d rounds in a row "
      .. "with no new observation (%s); the turn stopped where a continuation can pick it up",
      state.repeats, tostring(obs.label or signature:gsub("%s+", " "):sub(1, 160)))
    return state.stopped
  end
  if state.idle >= state.idle_rounds then
    state.stopped = string.format("guard_no_progress: %d rounds in a row changed nothing - no "
      .. "successful effect, no changed file and the same tool results; the turn stopped where a "
      .. "continuation can pick it up", state.idle)
    return state.stopped
  end
  if state.ceiling > 0 and state.round >= state.ceiling then
    state.stopped = string.format("runaway_guard: the operator's WASM_AGENT_MAX_TOOL_ROUNDS ceiling "
      .. "(%d rounds) was reached", state.ceiling)
    return state.stopped
  end
  return nil
end

return M
