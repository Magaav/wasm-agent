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

-- Is this store the code graph's? `rust/wa-capabilities/src/graph.rs` keeps every store the `graph`
-- component writes as `graph.db` inside a per-store directory - `graph.db.d/` for the configured
-- database, `graph.db.roots/<digest>.db.d/` for another indexed root - and an explicit `db` option may
-- name the file directly (`scripts/check-graph-component.lua` does, in `<data>/deploy-graph-check/`).
-- The NAME is therefore what identifies it, and a store that merely happens to be called `graph.db`
-- and belongs to something else is still skipped *visibly*: it gets its `backup_skipped` line with the
-- reason, and is never attached. Attaching a store a component may be writing is the defect this rule
-- exists for (`docs/RELEASE-UPDATE.md`, "The graph store is copied by its owner's lock").
function M.is_graph_store(path)
  local _, name = tostring(path or ""):gsub("\\", "/"):match("^(.*)/([^/]+)$")
  return name == "graph.db"
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

-- Assigned below (write_manifest): M.run writes the manifest as it goes, so every snapshot this
-- module takes is restorable and not only the periodic one.
local write_manifest

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
    -- The manifest is written for EVERY snapshot this module takes, not only the periodic one: a
    -- pre-update snapshot nobody can name is the same unusable directory the restore refuses.
    local manifest = write_manifest(dir, label, stamp, results, skipped)
    return { ok = true, dir = dir, stores = results, skipped = skipped, manifest = manifest }
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

-- ---- the manifest: what a snapshot holds, and which source each copy came from ------------------------
-- A snapshot without a manifest is a directory of files called '3-memory.db': a reader can check those
-- bytes, but nothing says which store each one belongs to, so a restore would have to guess a
-- destination. Unknown is not yes, and a guess is how one store's copy overwrites another's ledger. So
-- every snapshot this module takes writes manifest.json as it is taken, and 'wa restore --from' reads
-- THAT file: a directory without one, or a copy whose bytes no longer match it, is refused by name.
local MANIFEST = 'manifest.json'

-- Is 'path' the directory 'root' or somewhere under it?
local function inside(path, root)
  path, root = tostring(path or ''), tostring(root or ''):gsub('/+$', '')
  if root == '' or path == '' then return false end
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

local function basename(path)
  local _, name = tostring(path or ''):gsub('\\', '/'):match('^(.*)/([^/]+)$')
  return name or tostring(path or '')
end

-- The manifest of one snapshot directory: its table, or nil plus the named reason it cannot be used.
function M.manifest(dir)
  local ok, text = pcall(host.read_file, tostring(dir or ''):gsub('/+$', '') .. '/' .. MANIFEST)
  if not ok or type(text) ~= 'string' then return nil, 'restore_manifest_missing' end
  local decoded, value = pcall(json.decode, text)
  if not decoded or type(value) ~= 'table' or type(value.stores) ~= 'table' or #value.stores == 0 then
    return nil, 'restore_manifest_unreadable'
  end
  return value
end

-- Every snapshot under <config>/backups that carries a manifest, newest first. A directory without one is
-- listed with manifest=false and its reason: it is visible, not silently skipped, and restore refuses it.
function M.list()
  local root = paths.config() .. '/backups'
  local ok, raw = pcall(host.list_dir, root)
  if not ok then return {} end
  local value = type(raw) == 'string' and json.decode(raw) or raw
  local entries = (type(value) == 'table' and value.entries) or value or {}
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.kind == 'dir' then
      local dir = root .. '/' .. tostring(entry.name)
      local manifest, why = M.manifest(dir)
      out[#out + 1] = { dir = dir, name = tostring(entry.name), label = manifest and manifest.label or nil,
        stamp = manifest and manifest.stamp or nil, taken_utc = manifest and manifest.taken_utc or nil,
        stores = manifest and #manifest.stores or 0, manifest = manifest ~= nil, reason = why }
    end
  end
  table.sort(out, function(a, b)
    local as, bs = tostring(a.stamp or ''), tostring(b.stamp or '')
    if as ~= bs then if as == '' then return false elseif bs == '' then return true end return as > bs end
    return a.name > b.name
  end)
  return out
end

-- Write the manifest for one snapshot, after its copies exist: every store with the bytes it has now.
-- A copy whose hash cannot be read is recorded as sha256='unknown' rather than left out, and restore
-- refuses it - a snapshot that does not know what it holds cannot be put back.
write_manifest = function(dir, label, stamp, results, skipped)
  local stores, steps = {}, {}
  for _, record in ipairs(results or {}) do
    local sha = nil
    if host.file_sha256 then
      local ok, value = pcall(host.file_sha256, record.copy)
      if ok and type(value) == 'string' and value ~= '' then sha = value end
    end
    stores[#stores + 1] = { source = record.source, copy = basename(record.copy), check = record.check,
      attempts = record.attempts, sha256 = sha or 'unknown', locked = record.locked }
  end
  for _, record in ipairs(skipped or {}) do
    steps[#steps + 1] = { source = record.source, reason = record.reason }
  end
  local identity = ''
  if host.node_identity then
    local ok, value = pcall(host.node_identity)
    if ok and type(value) == 'table' then identity = tostring(value.node_id or '') end
  end
  local manifest = { version = 1, label = tostring(label or ''), stamp = stamp,
    taken_utc = os.date('!%Y-%m-%dT%H:%M:%SZ'), node_id = identity, stores = stores, skipped = steps }
  assert(host.write_file(dir .. '/' .. MANIFEST, json.encode(manifest)), 'backup_manifest_write_failed')
  return manifest
end

-- Put one snapshot back: every store to the source path its manifest names.
--
-- The order of the checks is the point, and each refusal names the one thing that is wrong:
--   1. the directory must hold a readable manifest (unknown is not yes);
--   2. every copy must still hash to what the manifest recorded and pass integrity_check - a torn or
--      edited backup is refused BEFORE anything of the node's is touched;
--   3. every destination must be inside this node's own data/config directories or be the live ledger,
--      so a hand-edited manifest cannot write outside the node;
--   4. only then is the current file moved aside (.pre-restore-<stamp>) and the copy put in place, so a
--      failure halfway leaves the old file recoverable rather than gone.
-- ---- who holds a store, and the one command that stops it (item 2 of the node-ops round, 19/11) --------
--
-- MEASURED before this: 'wa restore --from <dir>' replaced the bytes of the ledger while
-- 'wa-serve.service' was serving it. The file on disk said the snapshot's rows; the node answered from
-- its own open connection and from the -wal that belonged to the OLD file. Replacing a store under a
-- live SQLite connection is not a copy problem - a new file inherits a journal that describes the old
-- one - and a restore that reports ok while the node serves something else is the 'it worked' nobody
-- can use.
--
-- The evidence on POSIX is /proc: a process with the store (or its -wal/-shm) open. This process is
-- excluded by its own id - it is the caller, and it opened the ledger to read it. A platform with no
-- readable /proc answers 'unavailable', and the restore REFUSES rather than proceeding blind: unknown
-- is not yes, and the caller can run the restore from a node that can answer the question.
local function shell_quote_arg(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function self_process_id()
  local ok, raw = pcall(host.runtime_info)
  if not ok then return '' end
  local info = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
  if type(info) ~= 'table' then return '' end
  return tostring(info.process_id or '')
end

local function process_holders(path)
  local self_pid = (self_process_id()):gsub('[^%w]', '')
  local script = table.concat({
    'p=' .. shell_quote_arg(path),
    "self='" .. self_pid .. "'",
    -- The exec shell is a child of the process running this restore, so its parent is that process
    -- even when runtime_info could not answer: the caller is excluded by two independent facts.
    'ppid=$PPID',
    'if [ ! -d /proc ] || [ ! -r /proc/self/fd ]; then echo "$(printf %s unavailable)"; exit 0; fi',
    'found=0',
    'for d in /proc/[0-9]*; do',
    '  pid=${d#/proc/}',
    '  [ -n "$self" ] && [ "$pid" = "$self" ] && continue',
    '  [ -n "$ppid" ] && [ "$pid" = "$ppid" ] && continue',
    '  held=0',
    '  for f in "$d"/fd/*; do',
    '    t=$(readlink "$f" 2>/dev/null) || continue',
    '    case "$t" in "$p"|"$p-wal"|"$p-shm") held=1; break ;; esac',
    '  done',
    '  [ "$held" = 1 ] || continue',
    '  comm=$(tr "\\000" " " < "$d/cmdline" 2>/dev/null | cut -c1-120)',
    '  [ -n "$comm" ] || comm=$(cat "$d/comm" 2>/dev/null)',
    '  unit=$(sed -n "s|.*/\\([^/]*\\.service\\)$|\\1|p" "$d/cgroup" 2>/dev/null | head -1)',
    '  printf "%s\\t%s\\t%s\\n" "$pid" "$comm" "$unit"',
    '  found=1',
    'done',
    '[ "$found" = 1 ] || echo "$(printf %s none)"',
    'exit 0',
  }, '\n')
  local ran, raw = pcall(host.exec, script, '', 60)
  if not ran then return nil, 'the holder scan could not run: ' .. tostring(raw) end
  local answer = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
  if type(answer) ~= 'table' or tonumber(answer.code) ~= 0 then
    local why = type(answer) == 'table' and tostring(answer.stderr or answer.code) or tostring(raw)
    return nil, 'the holder scan did not answer: ' .. why
  end
  local text = tostring(answer.stdout or '')
  local holders = {}
  for line in text:gmatch('[^\r\n]+') do
    local pid, comm, unit = line:match('^(%d+)\t(.*)\t(.*)$')
    if pid then holders[#holders + 1] = { pid = tonumber(pid), command = comm, unit = unit } end
  end
  if #holders == 0 and not text:find('none', 1, true) then
    return nil, 'the holder scan answered nothing it could read (' .. tostring(text):gsub('%s+', ' '):sub(1, 120) .. ')'
  end
  return holders
end

-- The ONE command that stops the holder this scan found: its own systemd unit when the process runs
-- under one (read from /proc/<pid>/cgroup), and its pid otherwise. Never a guess: when neither is
-- readable the answer says so instead of printing a command that would not work.
local function stop_command(holder)
  local unit = tostring(holder.unit or '')
  if unit ~= '' then return 'systemctl --user stop ' .. unit end
  if holder.pid then return 'kill ' .. tostring(holder.pid) .. '  # pid ' .. tostring(holder.pid) .. ' (' .. (holder.command ~= '' and holder.command or 'unknown command') .. ')' end
  return '(this process could not be named)'
end

local function describe_holders(holders)
  local parts = {}
  for _, holder in ipairs(holders) do
    parts[#parts + 1] = string.format('pid %s (%s)', tostring(holder.pid), holder.command ~= '' and holder.command or 'unknown command')
  end
  return table.concat(parts, ', ')
end

function M.restore(dir, opts)
  opts = opts or {}
  local stamp = tostring(opts.stamp or (os.date('!%Y%m%dT%H%M%SZ') .. '-' .. host.uuid()))
  dir = tostring(dir or ''):gsub('/+$', '')
  if dir == '' then return { ok = false, error = 'restore_dir_required' } end
  local manifest, why = M.manifest(dir)
  if not manifest then
    return { ok = false, error = why, detail = dir .. ' holds no usable ' .. MANIFEST .. ': a snapshot this cannot name is not restored, and nothing was changed' }
  end
  local data, config = paths.data(), paths.config()
  local live = main_db()
  local plan = {}
  for _, store in ipairs(manifest.stores) do
    local source, copy = tostring(store.source or ''), dir .. '/' .. tostring(store.copy or '')
    if source == '' or store.copy == nil then
      return { ok = false, error = 'restore_manifest_incomplete', detail = 'a store row names no source or no copy; nothing was changed' }
    end
    local kind = 'unknown'
    if host.path_kind then
      local ok, value = pcall(host.path_kind, copy)
      if ok then kind = tostring(value) end
    end
    if kind == 'missing' then
      return { ok = false, error = 'restore_copy_missing', detail = copy .. ' is named by the manifest and is not there; nothing was changed' }
    end
    if kind ~= 'file' then
      return { ok = false, error = 'restore_copy_unreadable', detail = copy .. ' could not be read as a file (' .. kind .. '); nothing was changed' }
    end
    if store.sha256 == nil or store.sha256 == 'unknown' then
      return { ok = false, error = 'restore_copy_unhashed', detail = copy .. ' has no recorded sha256, so its bytes cannot be shown to be the ones this snapshot took; nothing was changed' }
    end
    local current = nil
    if host.file_sha256 then local ok, value = pcall(host.file_sha256, copy); if ok then current = value end end
    if type(current) ~= 'string' or current ~= store.sha256 then
      return { ok = false, error = 'restore_copy_changed', detail = copy .. ' no longer hashes to the manifest (recorded ' .. tostring(store.sha256) .. ', now ' .. tostring(current) .. '); a copy that changed is not this snapshot, and nothing was changed' }
    end
    local ok_check, verdict = pcall(check_store, copy, 'integrity_check', false)
    if not ok_check or verdict ~= 'ok' then
      return { ok = false, error = 'restore_copy_unverified', detail = copy .. ' does not pass integrity_check (' .. tostring(verdict) .. '); nothing was changed' }
    end
    if not (inside(source, data) or inside(source, config) or (live ~= '' and source == live)) then
      return { ok = false, error = 'restore_source_outside_node', detail = source .. ' is not under ' .. data .. ' or ' .. config .. ' (nor the ledger this process opened), so this manifest would write outside the node; nothing was changed' }
    end
    plan[#plan + 1] = { source = source, copy = copy, sha256 = store.sha256 }
  end
  -- ---- THE HOLDER CHECK, before anything of the node's is touched ----------------------------------
  -- A store a live process has open cannot be replaced under it: the node keeps serving its own pages and
  -- the -wal that belongs to the old file. Refused by name, with the process and the ONE command that
  -- stops it - never a restore that reports ok while the node answers from somewhere else.
  local held = {}
  for _, item in ipairs(plan) do
    local holders, why = process_holders(item.source)
    if not holders then
      return { ok = false, error = 'restore_holder_check_unavailable', detail = item.source .. ': ' .. tostring(why) .. '; nothing was changed' }
    end
    for _, holder in ipairs(holders) do held[#held + 1] = { source = item.source, holder = holder } end
  end
  if #held > 0 then
    local lines, commands = {}, {}
    for _, entry in ipairs(held) do
      lines[#lines + 1] = string.format('%s is held by pid %s (%s)', entry.source, tostring(entry.holder.pid),
        entry.holder.command ~= '' and entry.holder.command or 'unknown command')
      -- The unit (the service that owns the process) AND the pid: a process can sit in a unit this
      -- restore should not stop on its own (the caller own unit), and a reader told only the unit
      -- would stop more than the holder. Both facts, so the choice is the operator.
      commands[#commands + 1] = stop_command(entry.holder)
      commands[#commands + 1] = "kill " .. tostring(entry.holder.pid)
    end
    local seen, unique = {}, {}
    for _, command in ipairs(commands) do if not seen[command] then seen[command] = true; unique[#unique + 1] = command end end
    return { ok = false, error = 'restore_store_held',
      detail = table.concat(lines, '; ') .. '. Stop it first, then restore again: ' .. table.concat(unique, ' && '),
      held = held, stop = unique }
  end
  if opts.dry_run then return { ok = true, dry_run = true, dir = dir, would_restore = plan } end
  local function quote(path) return "'" .. tostring(path):gsub("'", "'\\''") .. "'" end
  -- A command's real verdict: exit 0, or the reason it was not. Every move in this function goes through
  -- it, so no step can fail silently and no report can claim a file was kept that was not.
  local function run(command, seconds)
    local ran, raw = pcall(host.exec, command, '', seconds or 120)
    if not ran then return false, tostring(raw) end
    local answer = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
    if type(answer) ~= 'table' then return false, tostring(raw) end
    local code = tonumber(answer.code) or 0
    if code ~= 0 then
      local why = tostring(answer.stderr or ''):gsub('%s+$', ''):sub(1, 200)
      if why == '' then why = 'exit ' .. tostring(code) end
      return false, why
    end
    return true, answer
  end
  local restored = {}
  for _, item in ipairs(plan) do
    local dir_of_source = item.source:match('^(.*)/[^/]+$') or '.'
    local aside = item.source .. '.pre-restore-' .. stamp
    local staged = dir_of_source .. '/.' .. basename(item.source) .. '.restoring-' .. stamp
    -- 1. The verified copy is written BESIDE its destination, not over it: a failure here leaves the
    --    store exactly as it was, and the last step can then be a rename.
    local ok_stage, stage_why = run('cp -p ' .. quote(item.copy) .. ' ' .. quote(staged))
    if not ok_stage then
      return { ok = false, error = 'restore_stage_failed', detail = item.source .. ': the checked copy could not be staged (' .. tostring(stage_why) .. '); the current file is untouched', restored = restored }
    end
    -- The staged bytes are the manifest's bytes: verified again HERE, because the copy was checked at
    -- plan time and nothing this function has done since may be assumed.
    local staged_sha = nil
    if host.file_sha256 then local ok, value = pcall(host.file_sha256, staged); if ok then staged_sha = value end end
    if type(staged_sha) ~= 'string' or staged_sha ~= item.sha256 then
      pcall(run, 'rm -f ' .. quote(staged), 60)
      return { ok = false, error = 'restore_stage_changed', detail = item.source .. ': the staged copy does not hash to the manifest (recorded ' .. tostring(item.sha256) .. ', staged ' .. tostring(staged_sha) .. '); the current file is untouched', restored = restored }
    end
    -- 2. The current file is moved aside by RENAME (atomic within its directory), and the move's result is
    --    checked: `previous` is set only when this really happened, so a report can never print a way back
    --    that does not exist.
    local had_current = false
    if host.path_kind then local ok, value = pcall(host.path_kind, item.source); had_current = ok and value == 'file' end
    if had_current then
      local ok_aside, aside_why = run('mv -f ' .. quote(item.source) .. ' ' .. quote(aside))
      if not ok_aside then
        pcall(run, 'rm -f ' .. quote(staged), 60)
        return { ok = false, error = 'restore_aside_failed', detail = item.source .. ': the current file could not be moved aside (' .. tostring(aside_why) .. '); the store is untouched and the staged copy was removed', restored = restored }
      end
      if host.path_kind then
        local ok, value = pcall(host.path_kind, aside)
        if not ok or value ~= 'file' then
          return { ok = false, error = 'restore_aside_unverified', detail = item.source .. ': the move aside reported success but ' .. aside .. ' is not a file (' .. tostring(value) .. '); the store is not where it was and needs an operator', restored = restored }
        end
      end
    end
    -- 3. The store takes its place by RENAME: the swap is atomic, and a half-written ledger cannot be read
    --    by a node that opens it between the two steps.
    local ok_place, place_why = run('mv -f ' .. quote(staged) .. ' ' .. quote(item.source))
    if not ok_place then
      local rolled_back = false
      if had_current then
        local ok_back = run('mv -f ' .. quote(aside) .. ' ' .. quote(item.source))
        rolled_back = ok_back and true or false
      end
      pcall(run, 'rm -f ' .. quote(staged), 60)
      return { ok = false, error = 'restore_place_failed',
        detail = item.source .. ': the staged copy could not be renamed into place (' .. tostring(place_why) .. '); '
          .. (had_current and (rolled_back and ('the previous file was put back from ' .. aside) or ('the previous file is at ' .. aside .. ' and could NOT be put back'))
            or 'there was no previous file'),
        restored = restored }
    end
    -- 4. The journal files that belonged to the OLD file go: a -wal that survives the swap describes pages
    --    of a database that is no longer there, and SQLite would replay it into the restored one. Removed
    --    or refused by name - never left behind silently.
    local journal_notes = {}
    for _, suffix in ipairs({ '-wal', '-shm' }) do
      local path = item.source .. suffix
      local kind = 'missing'
      if host.path_kind then local ok, value = pcall(host.path_kind, path); if ok then kind = tostring(value) end end
      if kind == 'file' then
        local ok_rm, rm_why = run('rm -f ' .. quote(path), 60)
        if ok_rm then
          journal_notes[#journal_notes + 1] = 'removed the stale ' .. suffix
        else
          return { ok = false, error = 'restore_journal_removal_failed',
            detail = item.source .. ': the restored store is in place but the old ' .. suffix .. ' could not be removed (' .. tostring(rm_why) .. '); SQLite would replay it into the new file, so this store must be repaired by hand',
            restored = restored }
        end
      end
    end
    local is_live = (live ~= '' and item.source == live)
    restored[#restored + 1] = { source = item.source, copy = item.copy, previous = had_current and aside or nil,
      sha256 = item.sha256, live = is_live, journal = journal_notes }
  end
  local reopens = {}
  for _, item in ipairs(restored) do if item.live then reopens[#reopens + 1] = item.source end end
  return { ok = true, dir = dir, restored = restored, stamp = stamp, label = manifest.label,
    reopen_required = #reopens > 0, reopen = reopens }
end

-- Retention for the snapshots THIS module takes periodically, and only those.
--
-- M.prune above keeps saying that pre-update snapshots belong to the reclaim pass, and that rule is not
-- changed here: two owners of one rule is the defect that let 48 snapshots accumulate. What is new is a
-- periodic snapshot nobody asked for, and an unbounded set of those is the same defect pointing the
-- other way - so the newest WA_BACKUP_KEEP (default 7) 'periodic' snapshots are kept and older ones are
-- removed, each removal printed. A snapshot with a pending rollback is not 'periodic', so it is not in
-- this list at all and is never touched.
local function prune_periodic(keep)
  keep = tonumber(keep) or 7
  local removed, kept = 0, 0
  for _, snapshot in ipairs(M.list()) do
    if snapshot.label == 'periodic' then
      kept = kept + 1
      if kept > keep then
        local ok, raw = pcall(host.exec, "rm -rf '" .. tostring(snapshot.dir):gsub("'", "'\\''") .. "'", '', 120)
        local answer = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
        if ok and not (type(answer) == 'table' and (tonumber(answer.code) or 0) ~= 0) then removed = removed + 1
        else print('backup: could not remove the old periodic snapshot ' .. snapshot.dir) end
      end
    end
  end
  return { removed = removed, kept = math.min(kept, keep) }
end

-- The periodic snapshot, at most one per WA_BACKUP_INTERVAL_S (default 24 h).
--
-- Called from the node's housekeeping tick (lua/core/server.lua), so it is cheap by default: one read of
-- the memo file while the interval has not passed. The memo is a FILE, not a process variable, because a
-- node restarts and a restart must not reset the day.
-- Is a periodic snapshot DUE, without taking one (item 10 of the node-ops round)?
--
-- The sync tick asks this before it launches anything. It is one read of the memo file and no SQLite at
-- all, so a tick that is not due costs nothing and starts no process: measured, the alternative - starting
-- a background operation on every tick and letting it decide - pays a process per tick to learn 'not yet'.
function M.due(opts)
  opts = opts or {}
  local interval = tonumber(host.getenv('WA_BACKUP_INTERVAL_S') or '') or tonumber(opts.interval_s or '') or 86400
  if interval <= 0 then return true, nil end
  local memo = paths.config() .. '/backups/.last-periodic'
  local ok, last = pcall(host.read_file, memo)
  local last_s = ok and type(last) == 'string' and tonumber(last:match('^(%d+)%s*$') or '') or nil
  if last_s == nil then return true, nil end
  local elapsed = os.time() - last_s
  if elapsed >= 0 and elapsed < interval then return false, { elapsed_s = elapsed, interval_s = interval } end
  return true, nil
end

function M.tick(opts)
  opts = opts or {}
  local interval = tonumber(host.getenv('WA_BACKUP_INTERVAL_S') or '') or tonumber(opts.interval_s or '') or 86400
  local memo = paths.config() .. '/backups/.last-periodic'
  local now = os.date('!%Y%m%dT%H%M%SZ')
  -- The memo holds EPOCH SECONDS, not the printable stamp: the stamps are for a reader, and arithmetic on
  -- "20261119T031729Z" is not arithmetic (measured by this item's own test: the second tick took a second
  -- snapshot because tonumber(stamp) was nil and nil < interval is never true).
  local now_s = os.time()
  if interval > 0 then
    local ok, last = pcall(host.read_file, memo)
    local last_s = ok and type(last) == 'string' and tonumber(last:match('^(%d+)%s*$') or '') or nil
    if last_s ~= nil then
      local elapsed = now_s - last_s
      if elapsed >= 0 and elapsed < interval then
        return { ok = true, skipped = 'interval_not_elapsed', elapsed_s = elapsed, interval_s = interval }
      end
    end
  end
  local ok, result = pcall(M.run, 'periodic')
  if not ok then return { ok = false, error = 'periodic_backup_failed', detail = tostring(result) } end
  -- THE MANIFEST IS WRITTEN ONCE, BY M.run (item 10 of the node-ops round). Measured 19/11: M.run called
  -- write_manifest, and this function called it AGAIN over the same directory - two writers of one file,
  -- and the second one re-hashed every copy for a record that already existed. The result M.run returns
  -- carries its manifest; this reads that one.
  local manifest = result.manifest or { stores = {}, skipped = {} }
  pcall(host.write_file, memo, tostring(now_s))
  local pruned = prune_periodic(tonumber(host.getenv('WA_BACKUP_KEEP') or ''))
  return { ok = true, dir = result.dir, stores = #manifest.stores, skipped = #manifest.skipped,
    kept = pruned.kept, removed = pruned.removed }
end

return M
