-- Every SQLite store is snapshotted and checked, the live database wherever it is, and only the newest
-- recoverable backups are kept. Run: WA_SCRIPT=tests/backup-all-stores.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua"); memory.setup()
memory.remember("backup probe", "global")
local paths = dofile("lua/core/paths.lua")
local json = dofile("lua/vendor/json.lua")
local function sql(s,p)
  local r=json.decode(host.sql_exec(s,json.encode(p or {})));assert(not r.error,r.error);return r
end
sql("ATTACH DATABASE ? AS g", {paths.data() .. '/graph.db'})
sql("CREATE TABLE IF NOT EXISTS g.t(x)");sql("INSERT INTO g.t VALUES(1)");sql("DETACH DATABASE g")
assert(host.write_file(paths.data()..'/fixture.run-lease.sqlite',''), 'lease fixture file')
local backup = dofile("lua/core/backup.lua")
for _,p in ipairs(backup.stores()) do assert(not p:find('fixture.run%-lease%.sqlite$'),'an exclusive OS lease is not a data snapshot') end
for i = 1, 7 do backup.run("t" .. i) end
local result = backup.run("final")
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
for _,e in ipairs(json.decode(host.list_dir(paths.config() .. '/backups')).entries) do
  if e.kind=='dir' then kept=kept+1 end
end
assert(kept == 8, "all recoverable snapshots are kept, got " .. kept)
print("backup all stores ok")
