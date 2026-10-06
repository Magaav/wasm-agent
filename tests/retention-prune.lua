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
local removed, problem = memory.prune(7)
assert(removed==nil and problem=='retention_evidence_admission_required')
local pruned,why=memory.prune_journal(7)
assert(pruned==nil and why=='retention_evidence_admission_required')
local json = require_json()
local function left(id) return json.decode(host.sql_query("SELECT COUNT(*) AS n FROM messages WHERE session_id=?", json.encode({id})))[1].n end
assert(left("active") == 4, "compaction does not retire original evidence")
assert(left("stale") == 4, "a quiet session retains original evidence")
assert(left("debugged") == 4, "debug sessions are kept")
assert(left("long_uncompacted") == 4, "an active, uncompacted session keeps its whole context")
print("retention preservation ok (6 checks, 0 skipped)")
