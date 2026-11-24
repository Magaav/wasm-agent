-- The two sessions and their wakes for scripts/test-placement-defer.sh, written through the real modules so the
-- rows are exactly the rows a live node would have. Run once, before the node is started: a session, a resume wake
-- for A (`selfloop.schedule`, the same row a paused resume writes), and a time wake for B.
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local now = tonumber(host.now())
local a = memory.start_session("local", "chat", { id = "placement-a", user_id = "master", node_id = "n", title = "A attended" })
local b = memory.start_session("local", "chat", { id = "placement-b", user_id = "master", node_id = "n", title = "B waiting" })
local wake_a = selfloop.schedule({ in_seconds = 0, reason = "resume after the node sw", prompt = "resume", now = now },
  { session_id = a, user_id = "master" })
local wake_b = selfloop.schedule({ in_seconds = 0, reason = "B's own work", prompt = "do B's thing", now = now },
  { session_id = b, user_id = "master" })
print("wake_a=" .. tostring(wake_a and wake_a.wake and wake_a.wake.id))
print("wake_b=" .. tostring(wake_b and wake_b.wake and wake_b.wake.id))
print("ready")
