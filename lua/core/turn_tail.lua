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

return M

