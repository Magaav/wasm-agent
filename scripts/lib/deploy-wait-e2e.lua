-- The two halves of scripts/test-deploy-wait.sh that need the real ledger: what the node recorded, and what
-- its own tick does with the schedule.
--
-- Run as its own process, against the scratch node's ledger and home, because the point of the test is that
-- the state crosses processes: two `wa chat --once` workers, a served node turn, the installer's marker and the
-- node's tick are five different processes reading and writing one home.
--
--   DW_MODE=count  print the ledger and the schedule as numbers: sessions, messages, pending resume wakes
--   DW_MODE=tick   run the node's own tick once with a counted scheduler stub, print what it did
local json = dofile("lua/vendor/json.lua")
local mode = host.getenv("DW_MODE") or ""
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local pause = dofile("lua/core/deploy_pause.lua")

-- Every session in this home, and the messages each one holds. A wait that writes nothing leaves both numbers
-- where they were; that is what "nothing was lost, and nothing was half-written" looks like from outside.
local function ledger()
  local sessions, messages = 0, 0
  for _, row in ipairs(memory.list_sessions(nil, 500) or {}) do
    sessions = sessions + 1
    messages = messages + (tonumber(memory.message_count(row.id)) or 0)
  end
  return sessions, messages
end

-- The one ledger read this file needs, through the same seam `lua/core/memory.lua` uses (`host.sql_rows`, with
-- the JSON answer of an older host accepted too).
local function rows(sql, params)
  if type(host.sql_rows) == "function" then
    local answer = host.sql_rows(sql, json.encode(params or {}))
    if answer == nil then error("sql_rows refused: " .. sql, 2) end
    return answer
  end
  return json.decode(host.sql_query(sql, json.encode(params or {}))) or {}
end

if mode == "count" then
  local sessions, messages = ledger()
  local found = rows("SELECT count(*) AS n FROM self_wakes WHERE status='pending' AND reason=?", { pause.RESUME_REASON })
  local pending = tonumber(type(found) == "table" and found[1] and found[1].n) or 0
  print(string.format("sessions=%d messages=%d resume_wakes=%d", sessions, messages, pending))
  return
end

-- A REAL turn, in its own process, against the stub model the harness started: the same agent, the same run
-- loop, the same provider protocol a `wa chat` uses. It prints the session it ran in and the reply, so the
-- harness can hold the session's own state and read the pause the turn decided for itself.
if mode == "turn" then
  local agentlib = dofile("lua/core/agent.lua")
  local id = memory.start_session("local", "chat",
    { user_id = "master", node_id = "", title = "deploy wait: a turn in flight" })
  local events = 0
  local bot = agentlib.new(id, function() events = events + 1 end, "master", "master", "")
  local reply = bot.run(bot, host.getenv("DW_TURN_PROMPT") or "say something")
  print("session=" .. tostring(id))
  print("events=" .. events)
  print("reply=" .. tostring(reply or ""))
  return
end

-- A wake of a session that is NOT paused and that is due NOW: the tick must hold this one too (the loop that
-- kept the node busy on 22/11 was exactly this - a worker's own wake firing during the wait). The row keeps its
-- time, so it fires as soon as the deploy ends; nothing is dropped.
if mode == "due" then
  local id = memory.start_session("local", "chat",
    { id = "deploy-wait-worker", user_id = "master", node_id = "", title = "the worker's own loop" })
  local wake = selfloop.schedule({ in_seconds = 1, reason = "the worker's own wake", prompt = "carry on" },
    { session_id = id, user_id = "master" })
  if not (wake and wake.ok and wake.wake and wake.wake.id) then
    error("the fixture could not schedule the worker's wake: " .. json.encode(wake))
  end
  print("due ok " .. tostring(wake.wake.id))
  return
end

if mode == "tick" then
  local runs = 0
  local out = selfloop.tick({ now = os.time(), dispatch = function(row)
    runs = runs + 1
    return { accepted = true, run_id = runs }
  end })
  print(string.format("dispatched=%d runs=%d deploy_waiting=%d deploy_wait_due=%d released=%d",
    tonumber(out.dispatched) or 0, runs, tonumber(out.deploy_waiting) or 0, tonumber(out.deploy_wait_due) or 0,
    tonumber(out.released) or 0))
  return
end

error("deploy-wait fixture: unknown DW_MODE " .. tostring(mode))
