-- `wa --continue` after a reboot: it must go back to the thread that was being worked on, not to
-- the empty session the last `wa` window opened before anything was typed in it.
local memory = dofile("lua/core/memory.lua")
memory.setup()
local failed = 0
local function check(cond, label) if not cond then print("FAIL " .. label) failed = failed + 1 end end
local work = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "the work" })
memory.append_turn(work, { role = "user", content = "investigate the connector" })
local child = memory.start_session("", "subagent", { user_id = "master", node_id = "", title = "a helper" })
memory.append_turn(child, { role = "user", content = "helper turn" })
local empty = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "chat" })
check(memory.latest_session("master", "").id == empty, "latest_session still returns the newest row")
local thread = memory.latest_thread("master", "")
check(thread and thread.id == work,
  "latest_thread skips the empty window and the subagent: " .. tostring(thread and thread.title))
if failed > 0 then print("continue: " .. failed .. " failed") os.exit(1) end
print("continue ok")
