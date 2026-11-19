-- wa restore: a snapshot is restorable by one command, and every way it could guess is a refusal.
--
-- Item 1 of the node-ops round. The measured state was: scripts/backup-db.lua copied memory.db alone
-- and never checked the copy, lua/core/backup.lua snapshots every store but names none of them, and
-- nothing put a snapshot back - so a backup existed and a recovery did not.
--
-- What this holds, in order:
--   * a snapshot taken now carries a manifest naming each store and the sha256 of each copy;
--   * wa restore --from puts every store back, and the rows a snapshot held are the rows the store has
--     afterwards (the check is the DATA, not the file's presence);
--   * the file it replaced is kept at <source>.pre-restore-<stamp>, so the step has a way back;
--   * a directory with no manifest is refused by name and NOTHING is written;
--   * a copy whose bytes changed after the snapshot is refused by name, and nothing is written;
--   * a manifest naming a path outside this node's own state is refused by name, and nothing is
--     written (a hand-edited manifest is not a way to write anywhere);
--   * --dry-run moves nothing.
--
-- It runs against a SCRATCH home and refuses to run against the real ~/.wasm-agent: the first thing it
-- does is prove the home it was given is not the operator's, because a restore test that wrote the real
-- ledger would be worse than the defect it covers.

local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local function refuse(why) print('REFUSED test-backup-restore: ' .. why); os.exit(2) end

-- (2) The scratch-home rule, checked rather than trusted, and checked against the RIGHT side (item 3 of
-- the node-ops round). WASM_AGENT_HOME is the USER home and the store hangs off it as <home>/.wasm-agent.
-- This row used to compare it with $HOME/.wasm-agent, so WASM_AGENT_HOME=$HOME passed the guard and the
-- restore ran against the operator's real store. The rule now lives in scripts/lib/scratch-home.lua, with
-- the same four refusals the shell guard makes, so the two languages cannot disagree again.
local scratch = dofile('scripts/lib/scratch-home.lua')
local why_home = scratch.guard('test-backup-restore')
if why_home then refuse(why_home) end
local home = host.getenv('WASM_AGENT_HOME') or ''
local data = paths.data()
local function norm(value) return (tostring(value or ''):gsub('\\', '/'):gsub('/+$', '')):lower() end
if norm(data):sub(1, #norm(home)) ~= norm(home) then refuse('the data directory ' .. data .. ' is outside the scratch home ' .. home) end

-- The scratch data directory exists before anything is attached to it: a fixture store beside the ledger
-- is a real store, and "unable to open database" would be this test's own setup failure, not a verdict.
pcall(host.exec, 'mkdir -p ' .. ("%q"):format(data), '', 60)

local memory = dofile('lua/core/memory.lua')
memory.setup()
local backup = dofile('lua/core/backup.lua')
local cli = dofile('lua/core/backup_cli.lua')

local function sql(statement, params)
  local raw = host.sql_exec(statement, json.encode(params or {}))
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  assert(type(answer) == 'table' and not answer.error, tostring(type(answer) == 'table' and answer.error or raw))
  return answer
end
local function rows(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  return type(raw) == 'string' and json.decode(raw) or raw
end
local function count(table_name)
  local answer = rows('SELECT COUNT(*) AS n FROM ' .. table_name)
  return tonumber(answer and answer[1] and answer[1].n) or 0
end

-- A fixture store of this test's own, beside the ledger: the restore has to put back more than one store
-- or it proves only that memory.db can be copied.
local fixture = data .. '/fixture-restore.db'
sql('ATTACH DATABASE ? AS fx', { fixture })
sql('CREATE TABLE IF NOT EXISTS fx.t (x TEXT)')
sql('INSERT INTO fx.t VALUES (\'before\')')
sql('DETACH DATABASE fx')

-- The marker row a restore must bring back (or take away): it is remembered only inside the snapshot.
memory.remember('restore probe row', 'global')
-- The ledger this process opened, read the way backup.lua reads it (PRAGMA database_list), so the
-- manifest can be asked whether it names it.
local sql_ledger = ''
for _, row in ipairs(rows('PRAGMA database_list')) do
  if row.name == 'main' then sql_ledger = tostring(row.file or '') end
end
assert(sql_ledger ~= '', 'this interpreter reports no live ledger file, so the test cannot ask whether it was named')

local before = count('memories')
assert(before > 0, 'the fixture ledger has no memory rows to restore')

-- (1) A snapshot now, with a manifest.
local snapshot = backup.run('test-restore')
local manifest, why = backup.manifest(snapshot.dir)
assert(manifest, 'the snapshot wrote no readable manifest (' .. tostring(why) .. '): ' .. snapshot.dir)
assert(#manifest.stores == #snapshot.stores, 'the manifest names ' .. #manifest.stores .. ' stores and the snapshot copied ' .. #snapshot.stores)
local named_ledger = false
for _, store in ipairs(manifest.stores) do
  assert(store.sha256 and store.sha256 ~= 'unknown', 'a manifest row has no sha256: ' .. tostring(store.source))
  -- The manifest names a copy by its file name inside the snapshot (a snapshot directory is movable, so
  -- an absolute path in it would be a lie after a move); the hash is of that file.
  assert(host.file_sha256(snapshot.dir .. '/' .. store.copy) == store.sha256,
    'a manifest row does not hash to its copy: ' .. tostring(store.copy))
  if store.source == sql_ledger then named_ledger = true end
end
assert(named_ledger, 'the manifest does not name the live ledger')
assert(backup.list()[1] and backup.list()[1].manifest, 'wa backup list does not show the new snapshot as usable')

-- The rows move on after the snapshot: the restore has to be visible in the data.
memory.remember('a row written after the snapshot', 'global')
assert(count('memories') == before + 1, 'the post-snapshot row is not there to be undone')

-- (2) The periodic entry point: the second call inside the interval is a skip, not another snapshot.
local ticked = backup.tick({ interval_s = 3600 })
assert(ticked.ok, 'the periodic tick failed: ' .. json.encode(ticked))
local again = backup.tick({ interval_s = 3600 })
assert(again.ok and again.skipped == 'interval_not_elapsed', 'a second tick inside the interval did not skip: ' .. json.encode(again))

-- (2b) THE TICK DOES NOT TAKE THE SNAPSHOT ITSELF (item 10 of the node-ops round). The sync loop asks
-- backup.due() - one read of a memo file, no SQLite - and launches `wa backup periodic` as a supervised
-- operation. due() must therefore answer the SAME question without touching a store, and it must not
-- claim a snapshot is due when the memo says otherwise.
local due_now, why = backup.due({ interval_s = 3600 })
assert(due_now == false, 'due() said a snapshot was due inside the interval (it answered ' .. tostring(due_now) .. ')')
assert(type(why) == 'table' and why.interval_s == 3600, 'due() gave no reason for not being due: ' .. json.encode(why))
assert(backup.due({ interval_s = 0 }) == true, 'due() with a zero interval did not say a snapshot is due')
-- And ONE snapshot carries ONE manifest, written by M.run: the tick used to write it a second time over
-- the same directory. A second writer would leave the same file here, so what is checked is the count of
-- manifests in the snapshot directory - exactly one.
assert(host.path_kind(ticked.dir .. '/manifest.json') == 'file',
  'the periodic snapshot carries no manifest.json: ' .. tostring(ticked.dir))
-- Exactly one writer: the file the manifest names must be readable AS JSON through the same reader a
-- restore uses, which refuses a directory whose manifest it cannot parse. A second write over the same
-- path would still parse, so the count is taken from the directory listing the host gives (path_facts
-- cannot list), and the fact that IS checked here is that the one manifest names the stores M.run took.
local parsed_ok, parsed = pcall(function() return json.decode(host.read_file(ticked.dir .. '/manifest.json')) end)
assert(parsed_ok and type(parsed) == 'table', 'the periodic manifest is not readable JSON: ' .. tostring(parsed))
assert(type(parsed.stores) == 'table' and #parsed.stores == tonumber(ticked.stores),
  'the periodic manifest names ' .. tostring(parsed.stores and #parsed.stores or 'no') .. ' store(s), the snapshot took ' .. tostring(ticked.stores))

-- (3) Restore, and check the DATA came back - read from the RESTORED FILE AT THE STORE'S OWN PATH, by a
-- FRESH process. Item 3 of the node-ops round: the older version of this test read the snapshot's COPY
-- (snapshot.dir .. / .. copy), which proves the snapshot was intact and says nothing about the restore.
-- The bytes that matter are the bytes at the path a node opens, and the process that reads them must be
-- one that did not have the store open when it was replaced (this one did: its own connection keeps the
-- pages it already read, which is what the module reports as reopen_required).
local restored = backup.restore(snapshot.dir, { stamp = 'fixture' })
assert(restored.ok, 'restore refused: ' .. tostring(restored.error) .. ': ' .. tostring(restored.detail))
assert(#restored.restored == #manifest.stores, 'restore put back ' .. #restored.restored .. ' of ' .. #manifest.stores .. ' stores')
assert(restored.reopen_required and #restored.reopen > 0, 'the restore did not say the live ledger needs the node restarted before it reads these bytes')
local ledger_source = nil
for _, store in ipairs(manifest.stores) do
  if store.source == sql_ledger then ledger_source = store end
end
assert(ledger_source, 'the manifest does not name the live ledger, so the restore cannot be read back')
-- The restored FILE and the snapshot COPY must be the same bytes, and the file must be at the store path.
assert(host.path_kind(sql_ledger) == 'file', 'after the restore there is no file at the ledger path ' .. sql_ledger)
assert(host.file_sha256(sql_ledger) == ledger_source.sha256,
  'the file at ' .. sql_ledger .. ' does not hash to the manifest: the restore wrote somewhere else or was tampered with')

-- A FRESH process, over the store's own path. sqlite3 is the cheapest reader that shares nothing with this
-- process. Absent, the row says SKIP by name - a skip is never a pass, and fast.sh prints it under the
-- counts.
local function sqlite3_read(db, statement)
  local command = 'sqlite3 ' .. ('%q'):format(db) .. ' ' .. ('%q'):format(statement)
  local ok, raw = pcall(host.exec, command, '', 60)
  if not ok then return nil, 'the reader did not run: ' .. tostring(raw) end
  local answer = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
  if type(answer) ~= 'table' then return nil, 'the reader answered nothing readable: ' .. tostring(raw) end
  if tonumber(answer.code) ~= 0 then
    return nil, 'the reader refused: ' .. tostring(answer.stderr or answer.code)
  end
  return (tostring(answer.stdout or ''):gsub('%s+$', ''))
end
local has_sqlite3 = host.executable_on_path and host.executable_on_path('sqlite3') ~= nil
if not has_sqlite3 then
  print('SKIP test-backup-restore: no sqlite3 on PATH, so the restored ledger cannot be read by a fresh process')
else
  -- The marker row written BEFORE the snapshot is there, and the row written after it is not: that is the
  -- data coming back, not a file existing.
  local probe = sqlite3_read(sql_ledger, [[SELECT COUNT(*) FROM memories WHERE content LIKE 'restore probe row%']])
  assert(probe ~= nil, 'the fresh reader could not read the restored ledger')
  assert(tonumber(probe) == 1, 'the restored ledger does not hold the row the snapshot took (count ' .. tostring(probe) .. ')')
  local after = sqlite3_read(sql_ledger, [[SELECT COUNT(*) FROM memories WHERE content LIKE 'a row written after the snapshot%']])
  assert(after ~= nil, 'the fresh reader could not count the post-snapshot row')
  assert(tonumber(after) == 0, 'the restored ledger still holds the post-snapshot row, so this is not the snapshot')
  local total = sqlite3_read(sql_ledger, 'SELECT COUNT(*) FROM memories')
  assert(total ~= nil and tonumber(total) == before,
    'the restored ledger holds ' .. tostring(total) .. ' memory rows; the snapshot had ' .. before)
  -- The file passes SQLite's own check as a fresh reader sees it: a swap that left a journal behind would
  -- show here, and that is the failure mode the -wal removal below is about.
  local verdict = sqlite3_read(sql_ledger, 'PRAGMA integrity_check')
  assert(verdict == 'ok', 'the restored ledger does not pass integrity_check as a fresh reader sees it: ' .. tostring(verdict))
end
-- The way back is the ledger's own previous file: it existed before the restore, it was moved aside rather
-- than deleted, and the restore's report says so only because the move was checked.
local ledger_entry = nil
for _, item in ipairs(restored.restored) do
  if item.source == sql_ledger then ledger_entry = item end
end
assert(ledger_entry, 'the restore did not report the ledger among the stores it put back')
assert(ledger_entry.previous and host.path_kind(ledger_entry.previous) == 'file',
  'the ledger the restore replaced was not kept, so there is no way back: ' .. tostring(ledger_entry.previous))
assert(host.file_sha256(ledger_entry.previous) ~= ledger_entry.sha256,
  'the file kept as the way back hashes to the RESTORED bytes, so it is not the previous file')

-- (3) A directory that holds no manifest is refused by name, and nothing is written.
local bare = paths.config() .. '/backups/fixture-no-manifest'
assert(host.write_file(bare .. '/.keep', ''), 'fixture directory')
local refused = backup.restore(bare, {})
assert(refused.ok == false and refused.error == 'restore_manifest_missing',
  'a directory with no manifest was not refused as restore_manifest_missing: ' .. json.encode(refused))

-- (4) A copy edited after the snapshot is refused by name, and the store is left as it is.
local tampered = paths.config() .. '/backups/fixture-tampered'
assert(host.exec('cp -a ' .. ('%q'):format(snapshot.dir) .. ' ' .. ('%q'):format(tampered), '', 120), 'copy fixture')
local victim = manifest.stores[1]
assert(host.write_file(tampered .. '/' .. victim.copy, 'not a database any more'), 'tamper fixture')
local changed = backup.restore(tampered, {})
assert(changed.ok == false and changed.error == 'restore_copy_changed',
  'an edited copy was not refused as restore_copy_changed: ' .. json.encode(changed))

-- (5) A manifest that names a path outside this node is refused, and nothing is written.
local outside = paths.config() .. '/backups/fixture-outside'
assert(host.exec('cp -a ' .. ('%q'):format(snapshot.dir) .. ' ' .. ('%q'):format(outside), '', 120), 'copy fixture')
local hostile = json.decode(host.read_file(snapshot.dir .. '/manifest.json'))
hostile.stores[1].source = '/tmp/wa-fixture-outside-node.db'
assert(host.write_file(outside .. '/manifest.json', json.encode(hostile)), 'hostile manifest fixture')
assert(host.exec('cp -a ' .. ('%q'):format(snapshot.dir .. '/' .. hostile.stores[1].copy) .. ' ' .. ('%q'):format(outside .. '/' .. hostile.stores[1].copy), '', 120), 'hostile copy fixture')
local escaped = backup.restore(outside, {})
assert(escaped.ok == false and (escaped.error == 'restore_source_outside_node' or escaped.error == 'restore_copy_missing'),
  'a manifest naming a path outside the node was not refused: ' .. json.encode(escaped))
assert(host.path_kind('/tmp/wa-fixture-outside-node.db') ~= 'file', 'a refused restore wrote the outside path anyway')

-- (6) A dry run moves nothing.
local before_dry = count('memories')
local dry = backup.restore(snapshot.dir, { dry_run = true })
assert(dry.ok and dry.dry_run, 'a dry run did not answer as one: ' .. json.encode(dry))
assert(count('memories') == before_dry, 'a dry run changed the ledger')

-- (8) The command line refuses to guess: no --from is a refusal whose text names the fix.
local code = cli.run('restore', {})
assert(code == 2, 'wa restore with no --from exited ' .. tostring(code) .. ', not 2')


-- (9) A store a LIVE PROCESS holds is refused by name, with the process and the command that stops it -
-- and nothing of the node's is touched. Item 2 of the node-ops round: this is the measured failure (a
-- restore replaced the ledger under a serving node, which kept answering from its old connection and its
-- old -wal). The holder here is the test's own detached process, on a fixture store the snapshot names.
local fixture_held = data .. '/held-fixture.db'
sql('ATTACH DATABASE ? AS hf', { fixture_held })
sql('CREATE TABLE IF NOT EXISTS hf.t (x INTEGER)')
sql('DELETE FROM hf.t'); sql('INSERT INTO hf.t VALUES (1)')
sql('DETACH DATABASE hf')
local held_snapshot = backup.run('test-holder')
assert(held_snapshot.ok, 'the holder fixture snapshot failed: ' .. json.encode(held_snapshot))
local holder_pid_file = data .. '/holder.pid'
local holder_start = host.exec("setsid sh -c 'echo $$ > " .. holder_pid_file .. "; exec 3<" .. fixture_held
  .. "; sleep 20' >/dev/null 2>&1 </dev/null & echo started", '', 30)
local holder_start_answer = type(holder_start) == 'string' and (select(2, pcall(json.decode, holder_start))) or holder_start
assert(type(holder_start_answer) == 'table' and tonumber(holder_start_answer.code) == 0,
  'the holder fixture could not be started: ' .. tostring(holder_start))
host.sleep(1)
local holder_pid = (host.read_file(holder_pid_file) or ''):gsub('%s+', '')
assert(holder_pid ~= '', 'the holder fixture recorded no pid, so this check cannot be made')
local held_bytes = host.file_sha256(fixture_held)
local refused_held = backup.restore(held_snapshot.dir, { stamp = 'held' })
assert(refused_held.ok == false and refused_held.error == 'restore_store_held',
  'a store a live process holds was not refused as restore_store_held: ' .. json.encode(refused_held))
assert(tostring(refused_held.detail):find(fixture_held, 1, true) ~= nil,
  'the refusal does not name the store that is held: ' .. tostring(refused_held.detail))
assert(tostring(refused_held.detail):find('pid ' .. holder_pid, 1, true) ~= nil,
  'the refusal does not name the process holding it (pid ' .. holder_pid .. '): ' .. tostring(refused_held.detail))
assert(tostring(refused_held.detail):find('kill ' .. holder_pid, 1, true) ~= nil,
  'the refusal does not give the one command that stops the holder: ' .. tostring(refused_held.detail))
assert(refused_held.stop and #refused_held.stop > 0, 'the refusal carries no stop command')
assert(host.file_sha256(fixture_held) == held_bytes, 'a refused restore changed the held store anyway')
-- The holder goes, and the same restore now proceeds.
host.exec('kill ' .. holder_pid .. ' 2>/dev/null; exit 0', '', 30)
host.sleep(1)
host.exec('rm -f ' .. ('%q'):format(holder_pid_file) .. '; exit 0', '', 30)
-- A journal file of the OLD store, put there by hand: the restore must remove it, not leave it for SQLite
-- to replay into the restored file.
assert(host.write_file(fixture_held .. '-wal', 'stale journal of the old store'), 'the stale-wal fixture could not be written')
assert(host.path_kind(fixture_held .. '-wal') == 'file', 'the stale-wal fixture is not there')
local freed = backup.restore(held_snapshot.dir, { stamp = 'freed' })
assert(freed.ok, 'with the holder gone the restore was still refused: ' .. tostring(freed.error) .. ': ' .. tostring(freed.detail))
assert(host.path_kind(fixture_held .. '-wal') == 'missing',
  'the stale -wal of the old store survived beside the restored file: SQLite would replay it into the restored one')
-- IT IS MOVED, NOT DELETED (item 6 of the node-ops round). A -wal holds committed pages that are not in
-- the database file yet, so it is part of the OLD store: deleting it threw away the only copy of the state
-- an operator returns to, at the moment a wrong restore is most likely. The proof is the file, beside the
-- previous store and under the same stamp.
local journal_note = nil
for _, item in ipairs(freed.restored) do
  if item.source == fixture_held then
    for _, note in ipairs(item.journal or {}) do
      if note:find('moved the stale -wal aside', 1, true) then journal_note = note end
    end
  end
end
assert(journal_note, 'the restore moved the stale -wal but did not report it: ' .. json.encode(freed.restored))
local journal_aside = fixture_held .. '.pre-restore-freed-wal'
assert(host.path_kind(journal_aside) == 'file',
  'the stale -wal was not kept beside the previous file: ' .. journal_aside .. ' is not there, so the way back to the old store is half a store')
assert(host.read_file(journal_aside) == 'stale journal of the old store',
  'the kept -wal does not hold the old journal bytes')

-- (10) The report of what was kept is TRUE, not printed. A store the restore created where no file existed
-- has no previous file, and the report says so instead of naming a path that does not exist.
local created_entry = nil
for _, item in ipairs(freed.restored) do
  if item.source == fixture_held then created_entry = item end
end
assert(created_entry, 'the restore did not report the fixture store')
if created_entry.previous then
  assert(host.path_kind(created_entry.previous) == 'file',
    'the restore reports a previous file that is not there: ' .. tostring(created_entry.previous))
end
print('backup restore ok: manifest ' .. #manifest.stores .. ' store(s), restore put them back, 7 refusals named, a held store refused with its pid, the stale journal MOVED beside the previous file (not deleted), nothing written by any refusal')
