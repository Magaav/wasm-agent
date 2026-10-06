-- Replication keeps what it does not carry, keeps NULLs, replicates deletes, and a stale row cannot win.
-- Run: WA_SCRIPT=tests/memory-replication.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua")
local json = dofile("lua/vendor/json.lua")
memory.setup()
local function row(id) return json.decode(host.sql_query("SELECT * FROM sessions WHERE id=?", json.encode({id})))[1] end
local now = host.now()
-- an open local session with an interruption mark
host.sql_exec("INSERT INTO sessions(id,started_at,updated_at,user_id,node_id,title,mode,summary,interrupted_seq,interrupted_reason) VALUES('s1',?,?,'u','n','t','default','',7,'crash')",
  json.encode({now, now}))
local before = row("s1")
assert(before.ended_at == nil, "a new session is open")
-- a newer replica of the same session (no ended_at, no parent)
local ok = memory.apply_entry({ kind = "session", payload = { id = "s1", title = "renamed", updated_at = now + 5, started_at = now } })
local after = row("s1")
assert(ok and after.title == "renamed", "the newer replica applies")
assert(after.ended_at == nil, "an open session stays open (ended_at NULL, not 0)")
assert(after.parent_session_id == nil, "no parent stays NULL")
assert(tonumber(after.interrupted_seq) == 7 and after.interrupted_reason == "crash", "columns the replica does not carry are kept")
-- The bug: last used 100 s ago, worktree changed just now (which does not bump updated_at), then a
-- replica written 50 s ago arrives. By updated_at alone it looked newer and erased the change.
host.sql_exec("INSERT INTO sessions(id,started_at,updated_at,user_id,node_id,title,mode,summary) VALUES('s2',?,?,'u','n','t','default','')",
  json.encode({now - 100, now - 100}))
memory.set_session_worktree("s2", "/work/tree")
memory.apply_entry({ kind = "session", payload = { id = "s2", title = "stale", worktree = "", updated_at = now - 50, started_at = now - 100 } })
assert(row("s2").worktree == "/work/tree", "a stale replica cannot undo a newer local change")
-- deletes replicate
local id = memory.remember("replicated fact", "global")
memory.apply_entry({ kind = "memory", op = "delete", payload = { id = id, deleted_at = now } })
assert(#memory.recall("replicated fact") == 0, "a replicated delete removes the memory")
local journal = memory.journal_since(0, 1000)
local deletes = 0
memory.forget(memory.remember("to forget", "global"))
for _, e in ipairs(memory.journal_since(0, 1000)) do if e.op == "delete" then deletes = deletes + 1 end end
assert(deletes == 1, "forget is journalled as a delete")
print("memory replication ok")
