-- A turn the NODE runs (a wake, a completion) is not connected to the terminal: the CLI polled the
-- ledger's MESSAGES and drew the finished turn as history (`chat.lua` catch_up, the "added to this
-- session elsewhere" line). The turn's FACTS are already written the moment they happen
-- (`telemetry.lua:272`, one INSERT per fact) and `telemetry.events` is a cursor reader over them, so the
-- CLI can ATTACH to the turn by cursor and draw it with the live blocks instead of waiting for it to end
-- (mission turn-survives-a-provider-stall, item 3 / C2).
--
-- What this module does NOT do: it is not a run. No timer, no deltas, no spinner - those belong to the
-- process running the turn, and inventing them here would draw a second run box for one turn. It draws
-- the two things a reader watching a node-run turn needs and cannot otherwise see: that the provider has
-- paused (with the wait and the attempt), and that a model call is under way again.
local json = dofile("lua/vendor/json.lua")
local json_encode = json.encode
local decode_json = json.decode

local M = {}

-- The one line a pause becomes, in the words the live loop uses for it (agent.lua's waiting row):
-- "paused 2s: the provider has not answered (1/2)".
function M.pause_line(payload)
  payload = payload or {}
  local seconds = math.floor((tonumber(payload.wait_ms) or 0) / 1000)
  local attempt = tostring(payload.attempt or 1)
  local limit = payload.limit == nil and "?" or tostring(payload.limit)
  return string.format("paused %ds: the provider has not answered (%s/%s)", seconds, attempt, limit)
end

-- Poll the session's facts after `state.cursor` and draw what a reader would otherwise miss. Returns the
-- state, so a caller keeps one cursor per attached session. A ledger that cannot be read answers
-- `available=false`, and that is not "nothing happened": the cursor is left alone and nothing is drawn.
function M.poll(view, session_id, state)
  state = state or { cursor = 0 }
  local telemetry = dofile("lua/core/telemetry.lua")
  local batch = telemetry.events(session_id, state.cursor or 0, 200)
  if not batch.available then return state end
  for _, row in ipairs(batch.events or {}) do
    local seq = tonumber(row.seq) or 0
    if seq > (state.cursor or 0) then state.cursor = seq end
    local kind = tostring(row.kind or "")
    local phase = tostring(row.phase or "")
    local payload = row.payload or {}
    -- The run the fact names: a pause and a model call are facts OF a run, so the tail can stop it by id
    -- later (`cancel_on_interrupt`). A row with no run id leaves the last one standing.
    local run_id = tonumber(payload.run_id) or tonumber(row.run_id)
    if run_id then state.run_id = run_id end
    if kind == "provider_retry" then
      state.pauses = (state.pauses or 0) + 1
      if view and view.event then view:event({ type = "status", text = M.pause_line(payload) }) end
    elseif kind == "model_call" and phase == "start" then
      state.calls = (state.calls or 0) + 1
      if view and view.event then view:event({ type = "status", text = "model" }) end
    end
  end
  return state
end


-- STOPPING A TURN THE NODE OWNS (item 3 / C2b). `host.run_cancelled` is process-local and the scheduler's
-- cancel is in-process memory, so the only door to a run owned by a SERVED node is that node's own route:
-- `POST /runs` with an `action` body (`serve.rs:2931`, dispatched at `:2453`), authenticated with the
-- session credential the window already sends (`X-WA-Session`, `ui/app.js:230-233`). The base is the
-- node's documented port: 8799 by default (`docs/INSTANCES.md:18`, `--port`), passed in by a caller that
-- knows better.
-- Literal loopback only - `docs/BINDING.md:24` permits HTTP exactly there.
local DEFAULT_PORT = 8799

-- The URL the request goes to, so a row can pin it and a reader can see the contract in one line. The port is
-- the documented default unless a caller names one: nothing here reads the environment - a node on another
-- port passes it in.
function M.cancel_url(port)
  return string.format("http://127.0.0.1:%d/runs", tonumber(port) or DEFAULT_PORT)
end

-- Ask the node that owns `run_id` to stop it. The answer is `{ok=true, ...}` when the request was
-- accepted, and a refusal by name otherwise: nothing here guesses that a cancel landed.
function M.cancel(session_id, run_id, opts)
  opts = opts or {}
  local request = {
    action = "cancel",
    owner = opts.owner or "master",
    conversation = opts.conversation or session_id,
  }
  if run_id ~= nil then request.run_id = run_id end
  local headers = { ["X-WA-Session"] = tostring(session_id or "") }
  local ok, answer = pcall(host.http, "POST", M.cancel_url(opts.port), headers, json_encode(request))
  if not ok then return { ok = false, error = "cancel_unreachable", detail = tostring(answer) } end
  local decoded_ok, decoded = pcall(decode_json, tostring(answer))
  if not decoded_ok or type(decoded) ~= "table" then
    return { ok = false, error = "cancel_answer_unreadable" }
  end
  return decoded
end

-- ESC WHILE ATTACHED (item 3 / C2b's last step). The reader thread's Esc already means "interrupt the
-- run" (`keymap.rs` console row), but `host.run_cancelled` is process-local, so for a turn ANOTHER process
-- owns the key used to do nothing. Here the same key becomes the door above:
--   * nothing happens unless this tail has a run id (a local turn keeps its own Esc, untouched),
--   * the interrupt is CONSUMED once per key (cli_input:interrupt), so the same Esc is not also left in
--     the draft and one key never stops two things,
--   * the reader is told what happened in one line, and a node that did not answer is said so by name.
-- Returns true when it asked the node to stop a turn.
function M.cancel_on_interrupt(view, session_id, state, input, opts)
  if not (state and state.run_id) then return false end
  if not (input and input.interrupt) then return false end
  local _, at = input:interrupt()
  if not at then return false end
  if state.stopped_at == at then return false end
  state.stopped_at = at
  local answer = M.cancel(session_id, state.run_id, opts)
  if view and view.line then
    local text = (answer and answer.ok)
      and "  asked the node to stop this turn"
      or ("  the node did not answer the stop request (" .. tostring(answer and answer.error or "no answer") .. ")")
    pcall(view.line, view, text, "dim", view.live)
  end
  return true
end

return M

