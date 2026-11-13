-- Consistent, checked snapshots of every SQLite store the node keeps.
--
-- `scripts/backup-db.lua` copied memory.db alone and never checked the copy, and nothing took a backup
-- before an update migrated the schema (MEMORY.md asked the operator to remember). This finds every
-- store under the node's data and config directories (memory, graph, jobs, resource claims, the run
-- journal), snapshots each with `VACUUM INTO` through this connection (an attached store is vacuumed
-- by name, so the WAL is included and no store is copied mid-write), checks each copy with
-- `PRAGMA integrity_check`, and preserves every recoverable snapshot.
--
-- Retry instead of refuse (07/11). Three `wa update`s on two nodes refused with
-- `backup_failed: .../graph.db.d/graph.db: database disk image is malformed`, while the same file
-- passed `PRAGMA quick_check` immediately afterwards and the second `wa update` succeeded: the graph
-- component was writing the store and the copy read a state the writer was in the middle of. Two
-- failures matter here and they are different questions:
--
--   * the store is being written  -> retry, with a busy timeout and backoff, and do not refuse;
--   * the store is really damaged -> refuse the update, with SQLite's own verdict.
--
-- The source `quick_check` below is what tells them apart: it is asked before every retry, and a
-- verdict that is not contention (or contention that repeats on a second, independent read) is
-- damage. A copy is never reported without passing `integrity_check`, so a torn copy cannot pass as a
-- recovery source either. Knobs: `WA_BACKUP_ATTEMPTS`, `WA_BACKUP_BACKOFF_MS`,
-- `WA_BACKUP_BUSY_TIMEOUT_MS`.
--
-- The graph store is read under its OWNER's lock (13/11). The retry above treats a symptom: the graph
-- component writes its store from inside WASI, where SQLite has no POSIX locks and the journal mode
-- is `delete`, so a commit there is a page overwrite that excludes nobody - and this module's native
-- connection then reads the store mid-commit. Measured on `wa-desktop` 13/11: 3,653
-- `database disk image is malformed` reads and torn copies in 70 s of concurrent index + backup,
-- while the store passed `PRAGMA integrity_check` afterwards. Every `graph.db.malformed-*` copy the
-- operator found (77 on `work`, 30 on `openclaw`) came from that false verdict. So a graph store is
-- never attached here: `host.graph_snapshot` copies it under the same cross-process lock every graph
-- call holds (`rust/wa-capabilities/src/graph.rs`), and no guest can be running during the read. If
-- that still fails - a damaged store, or an index holding the lock past its wait - the store is
-- SKIPPED with a named warning and the update proceeds: the graph is derived state, rebuilt from the
-- tree, so it is never worth blocking a deploy. The ledger and every other store keep the rule above.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local M = {}

-- A store that a live writer holds needs SQLite to wait, not to answer "busy" on the first try.
local BUSY_TIMEOUT_MS = tonumber(host.getenv("WA_BACKUP_BUSY_TIMEOUT_MS") or "") or 15000
local ATTEMPTS = tonumber(host.getenv("WA_BACKUP_ATTEMPTS") or "") or 3
local BACKOFF_MS = tonumber(host.getenv("WA_BACKUP_BACKOFF_MS") or "") or 250
local SOURCE_ALIAS = "wa_backup_source"
local CHECK_ALIAS = "wa_backup_check"


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

local function list(dir)
  local ok, raw = pcall(host.list_dir, dir)
  if not ok then error('backup_inventory_failed: '..dir..': '..tostring(raw),0) end
  local value = type(raw) == "string" and json.decode(raw) or raw
  if type(value) ~= "table" or value.error then error('backup_inventory_failed: '..dir..': '..tostring(type(value)=='table' and value.error or raw),0) end
  return value.entries or value
end

-- Lock files are SQLite files that hold an exclusive transaction and no data: `*.lease.sqlite`,
-- `*-lease.sqlite` (run leases) and `*.transport.sqlite` (the binding transport lease). Attaching one that
-- a live process holds fails with "database is locked", so a missing pattern here made every bound node's
-- pre-update backup fail and `/update` refuse (04/11). scripts/test-backup-locks.lua derives the lock
-- names from the Rust sources so a new lock file cannot silently break backups again.
function M.is_store(name)
  name = tostring(name or "")
  if name:find("%.lease%.sqlite$") or name:find("%-lease%.sqlite$") or name:find("%.transport%.sqlite$")
    or name:find("%-journal$") or name:find("%-wal$") or name:find("%-shm$") then
    return false
  end
  return name:find("%.db$") ~= nil or name:find("%.sqlite$") ~= nil
end

local function main_db()
  for _, row in ipairs(query("PRAGMA database_list")) do
    if row.name == "main" then return tostring(row.file or "") end
  end
  return ""
end

-- Every store file one level down from the data/config roots (stores live in the root or in one
-- subdirectory such as resources/ or jobs/), never inside a previous backup.
function M.stores()
  local found, seen = {}, {}
  for _, root in ipairs({ paths.data(), paths.config() }) do
    local function scan(dir, depth)
      for _, entry in ipairs(list(dir)) do
        local name = tostring(entry.name or "")
        local path = dir .. "/" .. name
        if entry.kind == "dir" and depth == 0 and name ~= "backups" and name ~= "changes" and name ~= "bin" then
          scan(path, 1)
        elseif entry.kind == "file" and M.is_store(name) and not seen[path] then
          seen[path] = true
          found[#found + 1] = path
        end
      end
    end
    scan(root, 0)
  end
  -- The live database can be anywhere (`wa --db PATH`); it is always included.
  local main = main_db()
  if main ~= "" and not seen[main] then found[#found + 1] = main end
  table.sort(found)
  return found
end

-- The two ways a store answers "I cannot be read right now". They are classified, never guessed from
-- the caller: contention is retried, damage is refused.
local function busy(answer)
  local text = tostring(answer):lower()
  return text:find("busy", 1, true) ~= nil or text:find("locked", 1, true) ~= nil
end

-- `database disk image is malformed` is what a read of a store another writer holds looked like on
-- 07/11, and it is also what a damaged b-tree says. It is retried, because the source `quick_check`
-- is the authority on which of the two it is; it is never trusted as a verdict on its own.
local function torn(answer)
  local text = tostring(answer):lower()
  return text:find("malformed", 1, true) ~= nil or text:find("not a database", 1, true) ~= nil
    or text:find("corrupt", 1, true) ~= nil
end

local function retryable(answer)
  return busy(answer) or torn(answer)
end

-- The first row of an `integrity_check`/`quick_check`: "ok", or the first problem SQLite names.
local function verdict_of(rows)
  local first = type(rows) == "table" and rows[1] or nil
  if type(first) ~= "table" then return "unknown" end
  if first.quick_check ~= nil then return tostring(first.quick_check) end
  if first.integrity_check ~= nil then return tostring(first.integrity_check) end
  return tostring(first[1])
end

-- One `PRAGMA quick_check`/`integrity_check` of a store, through this interpreter's own connection --
-- the only SQLite handle Lua has. `main` needs no attachment; every other store is attached for the
-- check and detached again, because a store left bound cannot be attached twice on the next attempt.
local function check_store(path, pragma, is_main)
  if is_main then return verdict_of(query("PRAGMA " .. pragma)) end
  sql("ATTACH DATABASE ? AS " .. CHECK_ALIAS, { path })
  local ok, rows = pcall(query, "PRAGMA " .. CHECK_ALIAS .. "." .. pragma)
  pcall(sql, "DETACH DATABASE " .. CHECK_ALIAS)
  if not ok then error(tostring(rows), 0) end
  return verdict_of(rows)
end

-- One read of the source: "verdict" (nothing stopped the read, `value` is SQLite's answer) or
-- "error" (`value` is why the read could not run).
local function source_read(path, is_main)
  local ok, value = pcall(check_store, path, "quick_check", is_main)
  if ok then return "verdict", tostring(value) end
  return "error", tostring(value)
end

-- Is the SOURCE damaged? Two independent reads have to agree, because one failed read is exactly what
-- a store with a writer in it looks like. Returns the verdict that says it is damaged, or nil when the
-- store is sound or too busy to tell (a busy store is retried by the caller, never called corrupt).
local function damaged(path, is_main)
  local kind, value = source_read(path, is_main)
  if kind == "verdict" and value == "ok" then return nil end
  if kind == "error" and busy(value) then return nil end
  host.sleep(BACKOFF_MS)
  local again_kind, again = source_read(path, is_main)
  if again_kind == "verdict" and again == "ok" then return nil end
  if torn(value) or torn(again) then return torn(value) and value or again end
  if again_kind == "error" and busy(again) then
    -- The second read could not run at all; the first one's answer stands, and a busy answer is not
    -- evidence of damage.
    if kind == "verdict" then return value ~= "ok" and value or nil end
    return nil
  end
  return kind == "verdict" and value or again
end

-- One copy of one store into `copy`. `VACUUM INTO` is the read: it goes through SQLite, so a
-- committed page in the WAL is included and the file is never copied byte for byte. Measured 07/11: a
-- `VACUUM INTO` that fails leaves an empty destination file, which the next attempt accepts, and a
-- destination that holds a non-empty invalid file is refused with "file is not a database" -- a
-- visible failure, never a false success.
local function copy_store(source, copy, is_main)
  if is_main then
    sql("VACUUM INTO ?", { copy })
    return
  end
  -- An attempt that failed mid-ATTACH can leave the alias bound, and a second ATTACH of the same
  -- alias is an error rather than a retry.
  pcall(sql, "DETACH DATABASE " .. SOURCE_ALIAS)
  sql("ATTACH DATABASE ? AS " .. SOURCE_ALIAS, { source })
  local ok, failure = pcall(sql, "VACUUM " .. SOURCE_ALIAS .. " INTO ?", { copy })
  pcall(sql, "DETACH DATABASE " .. SOURCE_ALIAS)
  if not ok then error(tostring(failure), 0) end
end

-- Snapshot one store: copy, check the copy, and retry contention with backoff. Raises
-- `backup_failed: <source>: <reason>` when the store is damaged or stays unreadable.
local function snapshot(source, copy, is_main)
  local problem, attempts = "no attempt was made", 0
  for attempt = 1, ATTEMPTS do
    attempts = attempt
    local retry = false
    -- A retry must not meet the copy the previous attempt left behind. `VACUUM INTO` refuses a
    -- destination that exists and is not empty ("output file already exists"), and an attempt that
    -- copied a store but then failed the copy's `integrity_check` leaves exactly that - a written,
    -- unsound destination. Before this, the retry reported SQLite's "output file already exists" as
    -- the failure and the real cause was never seen: measured 2026-11-11, `wa update openclaw` and
    -- `wa update work` both refused with `backup_failed: .../graph.db.d/graph.db: output file already
    -- exists`, so neither peer could be installed. The path is inside the directory this run just
    -- created and the only file that can be there is this module's own copy, so emptying it is what
    -- SQLite accepts - the same reason an empty destination from a failed VACUUM is accepted.
    if attempt > 1 and host.write_file then pcall(host.write_file, copy, "") end
    local copied, failure = pcall(copy_store, source, copy, is_main)
    if copied then
      local checked, check = pcall(check_store, copy, "integrity_check", false)
      if checked and check == "ok" then
        return { source = source, copy = copy, check = "ok", attempts = attempt }
      end
      failure = "the copy did not pass integrity_check: " .. tostring(checked and check or check)
      -- The copy was written but is not sound. That is what a read torn by a writer leaves behind, so
      -- it is retried; the source `quick_check` below is what says whether it was the writer's doing.
      retry = true
    else
      -- A store that is not contention and not a torn image (no space, no permission, a bad path) is
      -- not going to get better by asking again.
      retry = retryable(failure)
    end
    problem = tostring(failure)
    if not retry then error("backup_failed: " .. source .. ": " .. problem, 0) end
    local broken = damaged(source, is_main)
    if broken then error("backup_failed: " .. source .. ": " .. broken, 0) end
    if attempt < ATTEMPTS then host.sleep(BACKOFF_MS * attempt) end
  end
  error("backup_failed: " .. source .. ": " .. problem .. " (after " .. attempts
    .. " attempts; the source still passes quick_check, so it is being written)", 0)
end

-- Snapshot every store into <config>/backups/<stamp>/ and check each copy. Returns
-- {ok, dir, stores = {{source, copy, check, attempts}}} or raises with the first failure.
--
-- The busy timeout is set for the duration of the snapshot and put back afterwards: it is what makes a
-- store a writer holds a wait instead of an error, and it is not this module's business whether some
-- other caller wanted the interpreter's default.
local function with_busy_timeout(work)
  local previous = 0
  local ok, rows = pcall(query, "PRAGMA busy_timeout")
  if ok and type(rows) == "table" and type(rows[1]) == "table" then
    previous = tonumber(rows[1].timeout or rows[1].busy_timeout or rows[1][1]) or 0
  end
  sql("PRAGMA busy_timeout = " .. BUSY_TIMEOUT_MS)
  local returned = table.pack(pcall(work))
  pcall(sql, "PRAGMA busy_timeout = " .. tostring(previous))
  if not returned[1] then error(returned[2], 0) end
  return table.unpack(returned, 2, returned.n)
end

-- Is this store the code graph's? `rust/wa-capabilities/src/graph.rs` keeps it in `P.d/graph.db`
-- (one directory per logical database, so a second root's store is `graph.db.roots/<sha>.db`), and
-- the graph component is the only process that may write it. Named by path, because the same module
-- snapshots stores this rule must not touch.
function M.is_graph_store(path)
  local parent, name = tostring(path or ""):gsub("\\", "/"):match("^(.*)/([^/]+)$")
  if not parent then return false end
  local directory = parent:match("([^/]+)$") or ""
  if directory == "graph.db.d" then return name == "graph.db" end
  -- A second indexed root gets its own store in `graph.db.roots/`, keyed by the root's digest.
  if directory == "graph.db.roots" then return name:match("%.db$") ~= nil end
  return false
end

-- One snapshot of a graph store, taken by its owner's lock (`host.graph_snapshot`). Returns
-- `record, nil` on success and `nil, reason` when the store cannot be copied right now; the caller
-- records a skip, never a refusal.
local function graph_snapshot(source, copy)
  if type(host.graph_snapshot) ~= "function" then
    return nil, "this host has no graph_snapshot capability, so a graph store cannot be copied safely; rebuilt from source"
  end
  local ok, raw = pcall(host.graph_snapshot, json.encode({ db = source, copy = copy, wait_ms = BUSY_TIMEOUT_MS }))
  if not ok then return nil, tostring(raw) end
  local answer = type(raw) == "string" and json.decode(raw) or raw
  if type(answer) ~= "table" then return nil, "graph_snapshot answered " .. tostring(raw) end
  if answer.error then return nil, tostring(answer.error) end
  if answer.check ~= "ok" then return nil, "the copy did not pass integrity_check: " .. tostring(answer.check) end
  return { source = source, copy = copy, check = "ok", attempts = tonumber(answer.attempts) or 1,
    locked = "graph_store", pages = answer.pages }, nil
end

function M.run(label)
  local stamp = os.date("!%Y%m%dT%H%M%SZ") .. '-' .. host.uuid() .. (label and label ~= "" and ("-" .. label:gsub("[^%w_-]", "")) or "")
  local dir = paths.config() .. "/backups/" .. stamp
  assert(host.write_file(dir .. "/.keep", ""),'backup_directory_write_failed')
  return with_busy_timeout(function()
    local results, skipped, main = {}, {}, main_db()
    for index, source in ipairs(M.stores()) do
      local copy = dir .. "/" .. source:gsub("^.*[/\\\\]", ""):gsub("^(.*)$", function(name) return index .. "-" .. name end)
      if M.is_graph_store(source) then
        -- Never ATTACH a store its component may be writing: the copy is taken under the store's own
        -- lock, and a store that cannot be copied is skipped with one named line.
        local record, reason = graph_snapshot(source, copy)
        if record then
          results[#results + 1] = record
        else
          local line = "backup_skipped: " .. source .. ": " .. tostring(reason)
            .. " (derived: the code graph is rebuilt from its sources, so this backup steps over it)"
          skipped[#skipped + 1] = { source = source, reason = tostring(reason), line = line }
          print(line)
        end
      else
        results[#results + 1] = snapshot(source, copy, source == main)
      end
    end
    M.prune()
    return { ok = true, dir = dir, stores = results, skipped = skipped }
  end)
end

-- Starting 11/11 this module preserves every snapshot and the *retention* belongs to the automatic
-- reclaim pass: `scripts/reclaim-disk.mjs` keeps the newest 3 `*-pre-update` snapshots plus any a pending
-- rollback names, and removes the rest. Two owners of one rule is how 48 snapshots (6.8 GB) accumulated
-- on openclaw while each side believed the other was bounding them, so the rule lives there and this
-- function keeps saying what it does: nothing.
function M.prune()
  return { skipped = 'retention_is_the_reclaim_pass' }
end

return M
