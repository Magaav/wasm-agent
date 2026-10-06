-- Every SQLite store is snapshotted and checked, the live database wherever it is, and only the newest
-- five backups are kept. Run: WA_SCRIPT=tests/backup-all-stores.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua"); memory.setup()
memory.remember("backup probe", "global")
local paths = dofile("lua/core/paths.lua")
host.sql_exec("ATTACH DATABASE ? AS g", '["' .. paths.data() .. '/graph.db"]')
host.sql_exec("CREATE TABLE IF NOT EXISTS g.t(x)", "[]"); host.sql_exec("INSERT INTO g.t VALUES(1)", "[]"); host.sql_exec("DETACH DATABASE g", "[]")
local backup = dofile("lua/core/backup.lua")
for i = 1, 7 do backup.run("t" .. i) end
local result = backup.run("final")
local json = dofile("lua/vendor/json.lua")
local live = ""
for _, row in ipairs(json.decode(host.sql_query("PRAGMA database_list", "[]"))) do
  if row.name == "main" then live = row.file end
end
local copied = {}
for _, store in ipairs(result.stores) do
  assert(store.check == "ok", store.source .. " copy failed its integrity check")
  copied[store.source] = true
end
assert(copied[live], "the live database is copied wherever it is: " .. live)
assert(copied[paths.data() .. "/graph.db"], "and a second store is copied too")
local kept = 0
for _ in io.popen("ls " .. paths.config() .. "/backups"):lines() do kept = kept + 1 end
assert(kept == 5, "the newest five backups are kept, got " .. kept)
print("backup all stores ok")
