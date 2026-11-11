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
--   repeated calls  the same decision, by name and arguments, `repeat_limit` rounds in a row.
--                   Re-issuing one call is not thinking; three identical decisions with no new
--                   observation between them is a loop (a stuck probe, a retry that cannot help).
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
-- Returns nil to continue, or a named reason string to stop. The reason is the durable code, so a
-- reader can grep it and M.classify can name it.
function M.observe(state, obs)
  obs = obs or {}
  state.round = state.round + 1

  local changed = (obs.effects or 0) > 0
    or (obs.changes ~= nil and obs.changes ~= state.changes)
    or (obs.results ~= nil and obs.results ~= state.last_results)
  state.changes = obs.changes ~= nil and obs.changes or state.changes
  state.last_results = obs.results

  local signature = tostring(obs.signature or "")
  if signature ~= "" and signature == state.last_call then
    state.repeats = state.repeats + 1
  else
    state.repeats = signature ~= "" and 1 or 0
    state.last_call = signature ~= "" and signature or nil
  end
  if changed then state.idle = 0 else state.idle = state.idle + 1 end

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
