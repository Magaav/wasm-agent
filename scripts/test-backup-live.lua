-- The pre-update backup against a real SQLite store, and against a store that is being written.
--
-- 07/11: three `wa update`s on two nodes refused with
-- `backup_failed: .../graph.db.d/graph.db: database disk image is malformed`, the same file passed
-- `PRAGMA quick_check` right after, and the second `wa update` succeeded. The backup read a store a
-- component was writing and treated the torn read as corruption. `lua/core/backup.lua` now reads every
-- store through SQLite (`VACUUM INTO`, never a byte copy) under a busy timeout, retries contention with
-- backoff, and asks the SOURCE whether it is damaged before it retries. This test holds that line:
--
--   * a real store -- including rows that only exist in its -wal -- is copied, checked, and the copy is
--     a working database (`wa_snapshot` has the fifty-snapshot concurrency test, in Rust, because that
--     needs a writer thread);
--   * a store that is really damaged is refused with SQLite's own verdict, immediately;
--   * a store that only answers "locked"/"malformed" while its source passes `quick_check` is retried
--     with backoff, and refused only when the retry budget is spent;
--   * a copy that fails `integrity_check` is never reported as a snapshot.
--
-- The retry cases are driven through a stub host, because one Lua interpreter has exactly one SQLite
-- connection: it cannot hold a lock against itself. The Rust crate covers the same rules with real
-- concurrency (cargo test -p wa-snapshot).
--
--   WA_SCRIPT=scripts/test-backup-live.lua wa --db /tmp/wa-backup-live/ledger.db
--
-- Prints `backup live ok`; every check raises on failure, so the gate reads a verdict.

local json = dofile("lua/vendor/json.lua")
local real_backup = dofile("lua/core/backup.lua")
local paths = dofile("lua/core/paths.lua")

local checks = 0
local function ok(value, label, detail)
  checks = checks + 1
  if not value then error("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""), 2) end
  print("  ok: " .. label)
end

local function sql(statement, params)
  local raw = host.sql_exec(statement, json.encode(params or {}))
  local result = type(raw) == "string" and json.decode(raw) or raw
  if type(result) == "table" and result.error then error(tostring(result.error), 0) end
  return result
end

local function query(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  local rows = type(raw) == "string" and json.decode(raw) or raw
  if type(rows) == "table" and rows.error then error(tostring(rows.error), 0) end
  return rows or {}
end

local function have(path)
  return host.path_kind(path) == "file"
end

-- ---- 1. real stores, real SQLite -------------------------------------------------------------

local data, config = paths.data(), paths.config()
assert(host.write_file(data .. "/.keep", "") and host.write_file(config .. "/.keep", ""), "the fixture needs writable roots")

-- A second store, the shape the graph component keeps: rows committed but not checkpointed, so they
-- exist only in the -wal. A byte copy would lose them; a torn read would refuse them.
sql("ATTACH DATABASE ? AS g", { data .. "/graph.db" })
query("PRAGMA g.journal_mode=WAL")
sql("CREATE TABLE IF NOT EXISTS g.t(x TEXT)")
sql("DELETE FROM g.t")
sql("INSERT INTO g.t VALUES('first'),('second'),('third')")
sql("DETACH DATABASE g")
-- And a store in the config root, so the walk finds one under each root.
sql("ATTACH DATABASE ? AS c", { config .. "/jobs.db" })
sql("CREATE TABLE IF NOT EXISTS c.job(id TEXT)")
sql("INSERT INTO c.job VALUES('one')")
sql("DETACH DATABASE c")

local first = real_backup.run("live")
ok(first.ok == true and type(first.dir) == "string", "the pre-update backup runs over real stores")
ok(#first.stores >= 3, "the ledger, the graph store and the jobs store are all snapshotted", #first.stores)
local copied = {}
for _, store in ipairs(first.stores) do
  ok(store.check == "ok", "every copy passes integrity_check: " .. store.source, store.check)
  ok(store.attempts == 1, "an uncontended store is copied on the first attempt", store.attempts)
  ok(have(store.copy), "and the copy is on disk: " .. store.copy)
  copied[store.source] = store.copy
end
ok(copied[data .. "/graph.db"] ~= nil, "the graph store is in the snapshot")
ok(copied[config .. "/jobs.db"] ~= nil, "so is the store under the config root")

-- The copy of the WAL store is a working database that holds the committed rows.
sql("ATTACH DATABASE ? AS cp", { copied[data .. "/graph.db"] })
local rows = query("SELECT x FROM cp.t ORDER BY x")
sql("DETACH DATABASE cp")
ok(#rows == 3, "the copy of the WAL store holds every committed row", #rows)

-- ---- 1b. the graph store is copied by its owner's lock, and a store that cannot be copied is skipped
--
-- The graph component writes its store from inside WASI, where SQLite has no POSIX locks (measured
-- 13/11 on `wa-desktop`: 3,653 torn reads in 70 s of concurrent index + backup, on a store that
-- passed `integrity_check` afterwards). So the backup never attaches it: it asks `host.graph_snapshot`,
-- which takes the same cross-process lock every graph call holds. And when even that cannot copy the
-- store, the store is SKIPPED with a named line - the graph is rebuilt from the tree, so it must never
-- refuse a deploy. It runs before section 2, which seeds a `broken.db` that would make every later
-- `run` refuse (the walk is sorted).

ok(real_backup.is_graph_store(data .. "/graph.db.d/graph.db"), "the component's own store is recognised")
ok(real_backup.is_graph_store(data .. "/graph.db.roots/ab12.db"), "and a second root's cache")
ok(not real_backup.is_graph_store(data .. "/graph.db"), "a store merely named graph.db is not the component's")
ok(not real_backup.is_graph_store(config .. "/jobs.db"), "and neither is another store")

local graph_dir = data .. "/graph.db.d"
ok(host.write_file(graph_dir .. "/.keep", ""), "the component's directory exists")
sql("ATTACH DATABASE ? AS g", { graph_dir .. "/graph.db" })
sql("CREATE TABLE IF NOT EXISTS g.def(name TEXT)")
sql("INSERT INTO g.def VALUES('index_snapshot_probe')")
sql("DETACH DATABASE g")

local snapshotted = real_backup.run("graph-live")
ok(snapshotted.ok == true and #snapshotted.skipped == 0, "the graph store was snapshotted, not skipped")
local graph_copy
for _, store in ipairs(snapshotted.stores) do
  if store.source == graph_dir .. "/graph.db" then graph_copy = store end
end
ok(graph_copy ~= nil, "the graph store is in the snapshot")
ok(graph_copy and graph_copy.locked == "graph_store", "it was copied under the store's own lock, never attached")
ok(graph_copy and graph_copy.check == "ok", "and the copy passes integrity_check")
sql("ATTACH DATABASE ? AS gc", { graph_copy.copy })
local defs = query("SELECT name FROM gc.def")
sql("DETACH DATABASE gc")
ok(#defs == 1 and defs[1].name == "index_snapshot_probe", "the copy holds the committed row")

-- A graph store that cannot be copied at all: the deploy still proceeds, with one named line.
host.write_file(graph_dir .. "/graph.db", string.rep("a torn page, not a database. ", 128))
local damaged_graph = real_backup.run("graph-damaged")
ok(damaged_graph.ok == true, "a graph store that cannot be copied does not refuse the backup")
ok(#damaged_graph.skipped == 1, "it is recorded as skipped, one entry", #damaged_graph.skipped)
local skip = damaged_graph.skipped[1] or {}
ok(skip.source == graph_dir .. "/graph.db", "the skipped store is named, got: " .. tostring(skip.source))
ok(tostring(skip.line):find("backup_skipped", 1, true) ~= nil, "the warning is a backup_skipped line, got: " .. tostring(skip.line))
ok(tostring(skip.line):find("graph.db", 1, true) ~= nil, "and it names the store, got: " .. tostring(skip.line))
ok(tostring(skip.line):find("derived", 1, true) ~= nil, "and says why it is safe to step over, got: " .. tostring(skip.line))
ok(tostring(skip.reason) ~= "" and tostring(skip.reason) ~= "nil", "the reason is carried, got: " .. tostring(skip.reason))
local newest_damaged = nil
for _, entry in ipairs(json.decode(host.list_dir(config .. "/backups")).entries) do
  if entry.kind == "dir" and (newest_damaged == nil or entry.name > newest_damaged) then newest_damaged = entry.name end
end
local leaked_skip = false
for _, entry in ipairs(json.decode(host.list_dir(config .. "/backups/" .. newest_damaged)).entries) do
  if tostring(entry.name):find("graph.db", 1, true) then leaked_skip = true end
end
ok(leaked_skip == false, "a skipped store publishes no copy, not even an empty one")


-- ---- 2. a store that is really damaged is refused --------------------------------------------

-- Garbage where a database should be: SQLite answers "file is not a database", and no retry can make
-- that better.
host.write_file(data .. "/broken.db", string.rep("this is not a sqlite database; it is a torn file. ", 64))
local refused, message = pcall(real_backup.run, "broken")
ok(refused == false, "a damaged store refuses the backup")
message = tostring(message)
ok(message:find("backup_failed", 1, true) ~= nil, "the refusal is a backup_failed, got: " .. message)
ok(message:find("broken.db", 1, true) ~= nil, "and it names the store, got: " .. message)
local newest = nil
for _, entry in ipairs(json.decode(host.list_dir(config .. "/backups")).entries) do
  if entry.kind == "dir" and (newest == nil or entry.name > newest) then newest = entry.name end
end
local published = newest and json.decode(host.list_dir(config .. "/backups/" .. newest)).entries or {}
local leaked = false
for _, entry in ipairs(published) do
  if tostring(entry.name):find("broken.db", 1, true) then leaked = true end
end
ok(leaked == false, "a refused store publishes no copy")

-- ---- 3. contention is retried, damage is refused, a bad copy is never a snapshot ---------------
--
-- One Lua interpreter has one SQLite connection, so the store cannot be locked against itself; a stub
-- host scripts the answers instead. The module reads its knobs from `host.getenv`, so it is loaded
-- again under the stub.

local real_host = host
local scenario, vacuums, integrity_reads, sleeps, busy_timeouts = nil, 0, 0, {}, {}
host = {
  paths = function()
    return { home = data, config = config, data = data, cache = data .. "/cache", temp = data .. "/tmp" }
  end,
  getenv = function(name)
    if name == "WA_BACKUP_ATTEMPTS" then return "3" end
    if name == "WA_BACKUP_BACKOFF_MS" then return "250" end
    if name == "WA_BACKUP_BUSY_TIMEOUT_MS" then return "15000" end
    return os.getenv(name)
  end,
  write_file = function(path, text) return true end,
  -- No stores from the walk: these cases are about the live database.
  list_dir = function() return json.encode({ entries = {} }) end,
  uuid = function() return "fixture" end,
  sleep = function(ms) sleeps[#sleeps + 1] = ms end,
  sql_exec = function(statement, params)
    local values = json.decode(params or "[]")
    if statement:find("^PRAGMA busy_timeout") then
      busy_timeouts[#busy_timeouts + 1] = tonumber(statement:match("=(%s*%d+)") or "") or 0
      return json.encode({ ok = true, changes = 0 })
    end
    if statement:find("^ATTACH") or statement:find("^DETACH") then return json.encode({ ok = true, changes = 0 }) end
    if statement:find("^VACUUM") then
      vacuums = vacuums + 1
      return json.encode(scenario.vacuum(vacuums, values[1]))
    end
    return json.encode({ error = "the stub scripts no answer for: " .. statement })
  end,
  sql_query = function(statement)
    if statement == "PRAGMA busy_timeout" then return json.encode({ { timeout = 0 } }) end
    if statement == "PRAGMA database_list" then
      return json.encode({ { name = "main", file = data .. "/ledger.db" } })
    end
    if statement:find("quick_check") then return json.encode(scenario.quick_check()) end
    if statement:find("integrity_check") then
      integrity_reads = integrity_reads + 1
      return json.encode(scenario.integrity_check())
    end
    return json.encode({ error = "the stub scripts no answer for: " .. statement })
  end,
}
setmetatable(host, { __index = function(_, key) return real_host[key] end })

local function reset(next_scenario)
  scenario = next_scenario
  vacuums, integrity_reads, sleeps, busy_timeouts = 0, 0, {}, {}
end

local busy = { error = "database is locked" }
local torn = { error = "database disk image is malformed" }
local sound = { { quick_check = "ok" } }
local checked = { { integrity_check = "ok" } }

-- 3a. The 07/11 case: the store answers "malformed" while it is being written, the SOURCE passes
-- quick_check, and the third attempt is a complete copy. No refusal, backoff between attempts.
reset({
  vacuum = function(n) return n < 3 and torn or { ok = true, changes = 0 } end,
  quick_check = function() return sound end,
  integrity_check = function() return checked end,
})
local backup = dofile("lua/core/backup.lua")
local retried = backup.run("contended")
ok(retried.ok == true, "a store being written does not refuse the backup")
ok(retried.stores[1].attempts == 3, "the torn reads were retried until one was complete", retried.stores[1].attempts)
ok(retried.stores[1].check == "ok", "and the copy that was kept passed integrity_check")
ok(#sleeps == 2 and sleeps[1] < sleeps[2], "the retries back off: " .. json.encode(sleeps))
ok(busy_timeouts[1] == 15000 and busy_timeouts[#busy_timeouts] == 0,
  "the busy timeout is set for the snapshot and put back afterwards: " .. json.encode(busy_timeouts))

-- 3b. Real damage: the source itself says the image is malformed, twice. Refused at once, with
-- SQLite's verdict, and not retried into a false pass.
reset({
  vacuum = function() return torn end,
  quick_check = function() return torn end,
  integrity_check = function() return checked end,
})
local damaged, why = pcall(backup.run, "damaged")
ok(damaged == false, "a store whose source is malformed refuses the backup")
ok(tostring(why):find("backup_failed", 1, true) ~= nil and tostring(why):find("malformed", 1, true) ~= nil,
  "with SQLite's verdict, got: " .. tostring(why))
ok(vacuums == 1, "damage is not retried: one read of the store", vacuums)
ok(#sleeps == 1, "the second source check is the confirmation, not another attempt", #sleeps)

-- 3c. Contention that never ends, with a sound source: refused as busy after the budget, and the
-- message says the store is being written rather than that it is corrupt.
reset({
  vacuum = function() return busy end,
  quick_check = function() return sound end,
  integrity_check = function() return checked end,
})
local held, busy_message = pcall(backup.run, "busy")
ok(held == false, "a store that stays locked refuses the backup after the retry budget")
ok(tostring(busy_message):find("after 3 attempts", 1, true) ~= nil
  and tostring(busy_message):find("quick_check", 1, true) ~= nil,
  "and the refusal says the source is sound and being written, got: " .. tostring(busy_message))
ok(vacuums == 3, "the whole budget was used", vacuums)

-- 3d. A copy that fails its own check is never a snapshot.
reset({
  vacuum = function() return { ok = true, changes = 0 } end,
  quick_check = function() return sound end,
  integrity_check = function() return { { integrity_check = "Tree 0 page 5: broken" } } end,
})
local badcopy, copy_message = pcall(backup.run, "badcopy")
ok(badcopy == false, "a copy that fails integrity_check is refused")
ok(tostring(copy_message):find("integrity_check", 1, true) ~= nil,
  "and the refusal names the check, got: " .. tostring(copy_message))
ok(integrity_reads == 3, "each attempt's copy was checked", integrity_reads)

-- 3e. The retry lands on the destination the failed attempt left behind. A copy that passes its own
-- `integrity_check` only on the second read is the case the retry exists for, and until 2026-11-11 it
-- could never succeed: `VACUUM INTO` refuses a destination that exists and is not empty, so attempt 2
-- reported `output file already exists` instead of copying again. That is the exact refusal that
-- blocked `wa update openclaw` and `wa update work` on both peers, so the emptying is asserted here.
reset({
  vacuum = function() return { ok = true, changes = 0 } end,
  quick_check = function() return sound end,
  -- The first copy is unsound, the second is good: what a store with a live writer produces.
  integrity_check = function() return integrity_reads == 1 and { { integrity_check = "Tree 0 page 5: broken" } } or checked end,
})
local emptied = {}
host.write_file = function(path, text)
  if text == "" and tostring(path):find("ledger.db", 1, true) then emptied[#emptied + 1] = path end
  return true
end
local replaced = backup.run("replaced-copy")
ok(replaced.ok == true, "a copy that is unsound once and sound on the next attempt is snapshotted")
ok(replaced.stores[1].attempts == 2, "the second attempt is what kept it", replaced.stores[1].attempts)
ok(replaced.stores[1].check == "ok", "and the kept copy passed integrity_check")
ok(#emptied == 1 and emptied[1]:find("ledger.db", 1, true) ~= nil,
  "the destination the failed attempt left was emptied first: " .. json.encode(emptied))

host = real_host

print("backup live ok (" .. checks .. " checks)")
