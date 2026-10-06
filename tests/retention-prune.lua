-- Retention removes only what no live context reads: an old message goes when it is at/before its
-- session's compaction point or when the whole session has been quiet past the cutoff. Debug sessions
-- are kept. Run: WA_SCRIPT=tests/retention-prune.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua")
memory.setup()
local old = host.now() - 30 * 86400
local function session(id, updated, summarized, mode)
  host.sql_exec("INSERT INTO sessions(id,started_at,updated_at,summarized_until,mode,user_id,node_id,title,summary) VALUES(?,?,?,?,?,'u','n','','')",
    require_json().encode({id, old, updated, summarized, mode}))
  for seq = 1, 4 do
    host.sql_exec("INSERT INTO messages(id,session_id,seq,role,content,created_at) VALUES(?,?,?,?,?,?)",
      require_json().encode({id .. "-" .. seq, id, seq, seq % 2 == 1 and "user" or "assistant", "m" .. seq, old}))
  end
end
function require_json() return dofile("lua/vendor/json.lua") end
session("active", host.now(), 2, "default")
session("stale", old, 0, "default")
session("debugged", old, 0, "debug")
session("long_uncompacted", host.now(), 0, "default")
local removed = memory.prune(7)
local json = require_json()
local function left(id) return json.decode(host.sql_query("SELECT COUNT(*) AS n FROM messages WHERE session_id=?", json.encode({id})))[1].n end
assert(left("active") == 2, "an active session keeps what follows its compaction point, got " .. left("active"))
assert(left("stale") == 0, "a session quiet past the cutoff is pruned")
assert(left("debugged") == 4, "debug sessions are kept")
assert(left("long_uncompacted") == 4, "an active, uncompacted session keeps its whole context")
assert(removed == 6, "removed " .. tostring(removed))
print("retention prune ok")
