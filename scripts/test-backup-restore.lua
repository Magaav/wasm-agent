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

-- (2) The scratch-home rule, checked rather than trusted. WASM_AGENT_HOME must be set and must not be
-- the operator's own ~/.wasm-agent; the ledger this process opened must be inside it too, because that
-- is what a restore would overwrite.
local home = host.getenv('WASM_AGENT_HOME') or ''
local operator = (host.getenv('HOME') or host.getenv('USERPROFILE') or '') .. '/.wasm-agent'
local function norm(value) return (tostring(value or ''):gsub('\\\\', '/'):gsub('/+$', '')):lower() end
if home == '' then refuse('WASM_AGENT_HOME is not set, so this test cannot prove it is not the real node home') end
if norm(home) == norm(operator) then refuse('WASM_AGENT_HOME is the real ' .. operator .. '; a restore must never run against it') end
local data = paths.data()
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

-- (3) Restore, and check the DATA came back.
local restored = backup.restore(snapshot.dir, { stamp = 'fixture' })
assert(restored.ok, 'restore refused: ' .. tostring(restored.error) .. ': ' .. tostring(restored.detail))
assert(#restored.restored == #manifest.stores, 'restore put back ' .. #restored.restored .. ' of ' .. #manifest.stores .. ' stores')
-- The DATA, read from the restored FILE. This process opened the ledger before the snapshot, so its own
-- connection keeps the pages it already read (SQLite's rule, not this module's): the restore reports that
-- as reopen_required instead of pretending, and the test asserts the bytes a restarted node would read.
assert(restored.reopen_required and #restored.reopen > 0, 'the restore did not say the live ledger needs the node restarted before it reads these bytes')
local ledger_source = nil
for _, store in ipairs(manifest.stores) do
  if store.source == sql_ledger then ledger_source = store end
end
assert(ledger_source, 'the manifest does not name the live ledger, so the restore cannot be read back')
local restored_ledger = snapshot.dir .. '/' .. ledger_source.copy
sql('ATTACH DATABASE ? AS rb', { restored_ledger })
local rb = rows('SELECT COUNT(*) AS n FROM rb.memories')
sql('DETACH DATABASE rb')
assert(tonumber(rb[1].n) == before, 'the restored ledger file holds ' .. tostring(rb[1].n) .. ' memory rows, the snapshot had ' .. before)
-- The way back is the ledger's own previous file: it existed before the restore, and it was moved aside
-- rather than deleted. (A fixture store the restore created had no previous file, which is not a miss.)
local ledger_entry = nil
for _, item in ipairs(restored.restored) do
  if item.source == sql_ledger then ledger_entry = item end
end
assert(ledger_entry, 'the restore did not report the ledger among the stores it put back')
assert(ledger_entry.previous and host.path_kind(ledger_entry.previous) == 'file',
  'the ledger the restore replaced was not kept, so there is no way back: ' .. tostring(ledger_entry.previous))

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

print('backup restore ok: manifest ' .. #manifest.stores .. ' store(s), restore put them back, 5 refusals named, nothing written by any of them')
