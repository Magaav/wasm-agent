-- The two halves of scripts/test-session-park.sh that need the real store: the fixture that starts a
-- session with a scheduled wake, and the reader that runs the node's own tick one time and prints what
-- it did. `wa session park` / `release` / `status` and `wa chat --resume` are run as SEPARATE
-- processes by that script, which is the point: the park has to hold ACROSS processes, written by the
-- verb and read by the tick (22/11 - the session kept working because nothing in the node knew).
--
-- PARK_MODE=fixture  start the two sessions and schedule the wakes; print their ids
-- PARK_MODE=tick     tick once with a counted scheduler stub; print dispatched/held/runs/messages
-- PARK_MODE=read     print the ledger facts for the session, and nothing else
local json = dofile("lua/vendor/json.lua")
local mode = host.getenv("PARK_MODE") or ""
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()

-- 36 characters of [0-9a-f-]: that is what a mission record may carry (`mission.session_id_ok`),
-- and a mission directory is one of the two ways this verb is called.
local LEADER, NAMED = "park-e2e", "aaaabbbb-cccc-dddd-eeee-ffff00001111"

if mode == "fixture" then
  local leader = memory.start_session("local", "chat",
    { id = LEADER, user_id = "master", node_id = "e2e", title = "park e2e" })
  -- The wake the incident was made of: the "deploy pending: resume after the node swap" row every local
  -- install wrote (lua/core/deploy_pause.lua), one second out so "it is due" is a fact about the
  -- ledger and not about how long this script took.
  local wake = selfloop.schedule({ in_seconds = 1, reason = dofile("lua/core/deploy_pause.lua").RESUME_REASON,
    prompt = "continue the 64-wide load test" }, { session_id = leader, user_id = "master" })
  if not (wake and wake.ok and wake.wake and wake.wake.id) then
    error("the fixture could not schedule a wake: " .. json.encode(wake))
  end
  local named = memory.start_session("local", "chat",
    { id = NAMED, user_id = "master", node_id = "e2e", title = "park named by a mission" })
  local second = selfloop.schedule({ in_seconds = 1, reason = "the mission's own wake" },
    { session_id = named, user_id = "master" })
  if not (second and second.ok and second.wake and second.wake.id) then
    error("the fixture could not schedule the mission's wake: " .. json.encode(second))
  end
  print(string.format("fixture ok leader=%s mission=%s wake=%s", leader, named, wake.wake.id))
  return
end

if mode == "tick" then
  -- The scheduler, counted: an accepted receipt and nothing started. A wake that "ran" is a wake the
  -- node's own tick handed to the scheduler, so nothing here needs a model to see it.
  local runs = 0
  local out = selfloop.tick({ now = os.time(), dispatch = function(row)
    runs = runs + 1
    return { accepted = true, run_id = runs }
  end })
  local summary = selfloop.summary(LEADER) or {}
  print(string.format("tick dispatched=%d held=%d runs=%d pending=%d messages=%d messages_mission=%d",
    tonumber(out.dispatched) or 0, tonumber(out.paused) or 0, runs, tonumber(summary.pending) or 0,
    memory.message_count(LEADER), memory.message_count(NAMED)))
  return
end

if mode == "solo" then
  -- The thread `wa chat --continue` finds: a message in it, and the node id a chat session carries
  -- (`chat.lua`'s NODE is ""), because `memory.latest_thread` filters on both. Parked, --continue must
  -- be refused for the same reason --resume is: it opens a thread the reader is coming back to.
  local solo = memory.start_session("local", "chat",
    { id = "park-solo", user_id = "master", node_id = "", title = "park solo" })
  memory.append_turn(solo, { role = "user", content = "start the load test" })
  selfloop.schedule({ in_seconds = 60, reason = "the solo wake" }, { session_id = solo, user_id = "master" })
  local held = selfloop.park(solo, "master", "HOLD written: mission stopped")
  if not (held and held.parked) then error("the fixture could not park: " .. json.encode(held)) end
  print("solo ok " .. solo)
  return
end

if mode == "read" then
  local hold = selfloop.hold(LEADER)
  local summary = selfloop.summary(LEADER) or {}
  print(string.format("read parked=%s kind=%s pending=%d held=%d messages=%d",
    tostring(hold ~= nil and hold.kind == "park"), tostring(hold and hold.kind or "-"),
    tonumber(summary.pending) or 0, tonumber(summary.paused and 1 or 0), memory.message_count(LEADER)))
  return
end

error("session-park fixture: unknown PARK_MODE " .. tostring(mode))
