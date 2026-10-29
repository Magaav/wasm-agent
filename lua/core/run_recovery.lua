-- Automatic recovery of a run that stopped without an answer (29/10).
--
-- A CLI killed mid-run (container restart, crash, a terminal closed) leaves its thread with no
-- recorded answer; `memory.session_state` derives that from the transcript tail ("unfinished"), and
-- `agent:note_interruption` already tells the model so - but only once the reader types again. This
-- module decides whether the CLI should re-drive that thread by itself when it opens it.
--
-- It re-drives the MODEL TURN, never an effect: the run starts from the recorded transcript plus the
-- recovery notice (agent.lua), and a tool call whose result is missing is re-decided by the model
-- after it re-checks the machine - it is never re-executed from the ledger. Liveness is the host's:
-- `resources.begin` refuses a session whose owner process is still alive, so a second terminal on a
-- live thread is refused rather than doubled.
--
-- Bounded: one automatic attempt per interruption (a tail that is our own recovery prompt is left for
-- the reader), only for a recent tail, and WASM_AGENT_AUTO_RECOVER=0 turns it off.
local memory = dofile("lua/core/memory.lua")
local json = dofile("lua/vendor/json.lua")

local M = {}

M.MARK = "[Automatic recovery]"

local function setting(name, default)
  local value = tonumber(host.getenv(name) or "")
  if value == nil then return default end
  return value
end

-- A failed tail is a landed outcome, except where the failure is the transport's and not the turn's:
-- a stream the provider cut, or a link that dropped. Those are what a restart should finish.
local RECOVERABLE_FAILURE = { "provider_incomplete_stream", "connection", "network appears down", "timed out" }

-- Pure on its inputs: `state` is memory.session_state, `last_user` the newest user row (or nil).
-- Returns the reason to recover, or nil and why not.
function M.decide(state, last_user, now, opts)
  opts = opts or {}
  if opts.enabled == false then return nil, "disabled" end
  if not state then return nil, "no session" end
  local recoverable = state.state == "unfinished"
  if state.state == "failed" then
    local detail = tostring(state.detail or ""):lower()
    for _, needle in ipairs(RECOVERABLE_FAILURE) do
      if detail:find(needle, 1, true) then recoverable = true break end
    end
  end
  if not recoverable then return nil, "tail is " .. tostring(state.state) end
  local max_age = opts.max_age or 6 * 3600
  if state.at and now - state.at > max_age then return nil, "tail older than " .. max_age .. "s" end
  -- The interruption already had its automatic attempt: the newest question is our own prompt.
  if last_user and tostring(last_user.content or ""):sub(1, #M.MARK) == M.MARK then
    return nil, "already re-driven once"
  end
  return state.detail ~= "" and state.detail or state.state
end

function M.prompt(reason)
  return M.MARK .. " The previous run in this thread stopped before it recorded an answer ("
    .. tostring(reason) .. "), most likely a restart, crash or provider cut. This is an automated "
    .. "continuation, not a new request. Re-establish the real state from the machine first (files, "
    .. "`git status`, processes, the ledger); a step whose result is not recorded may or may not have "
    .. "run, so check its effect before repeating it, and never repeat an outward action (a message, "
    .. "a push, a deploy) without proof it did not happen. Then finish the task the user last asked "
    .. "for and say plainly what had already been done."
end

-- The CLI's entry: the prompt to run now, or nil.
function M.due(session_id)
  local enabled = tostring(host.getenv("WASM_AGENT_AUTO_RECOVER") or "") ~= "0"
  local state = memory.session_state(session_id)
  local raw = host.sql_query("SELECT content FROM messages WHERE session_id=? AND role='user' AND phase<>'bash' "
    .. "ORDER BY seq DESC LIMIT 1", json.encode({ session_id }))
  local rows = type(raw) == "string" and json.decode(raw) or raw
  local last_user = type(rows) == "table" and rows[1] or nil
  local reason = M.decide(state, last_user, host.now(),
    { enabled = enabled, max_age = setting("WASM_AGENT_AUTO_RECOVER_MAX_AGE_SECONDS", 6 * 3600) })
  if not reason then return nil end
  return { reason = reason, prompt = M.prompt(reason) }
end

return M
