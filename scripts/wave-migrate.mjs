#!/usr/bin/env node
// MIGRATION OF A LEGACY DURABLE WAVE ROW. Explicit, non-destructive, reversible.
//
// WHY IT EXISTS. Waves used to be a durable row with a manual pending/running/blocked/complete
// state, and an unfinished row refused the next wave. A live example sat in the shared store:
// `wave-2026-10-02-subagent-chat-and-enforcement` in `pending` with its three steps never run,
// although no agent was working and all its work was in main. Under the derived rule that row no
// longer fences anything (the wave is OFF because nothing is running), but it is still a row whose
// convergence was NEVER verified, and that must stay visible rather than quietly disappear.
//
// WHAT IT DOES. Nothing destructive. `apply` records the exact original bookkeeping in a new
// `legacy` column (added additively) and in the append-only event journal, plus a durable
// `migration.json` next to the store. `state`, `reason`, `receipt`, `updated_at` and every step
// row are left exactly as they were - another actor's work is never deleted or rewritten.
//
// HOW TO REVERSE IT. `revert` restores the row to precisely the recorded original: it refuses if
// anything moved since the migration (so it can never clobber a later transition), then clears
// `legacy` and removes the migration record. The original columns were never touched, so the
// reversal is exact by construction.
//
//   node scripts/wave-migrate.mjs plan   <store-dir> [wave-id]
//   node scripts/wave-migrate.mjs apply  <store-dir> <wave-id> [actor]
//   node scripts/wave-migrate.mjs revert <store-dir> <wave-id>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';

const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const fail = reason => { throw new Error(reason); };
const COLUMNS = ['id', 'repo', 'manifest', 'manifest_hash', 'state', 'reason', 'owner', 'boot', 'pid', 'created_at', 'updated_at', 'receipt'];

function open(dir, {readOnly = false} = {}) {
  const file = path.join(dir, 'waves.sqlite');
  if (!fs.existsSync(file)) fail('wave_store_missing');
  const db = new DatabaseSync(file, {readOnly});
  if (!readOnly) db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;');
  return db;
}

function hasLegacyColumn(db) {
  return db.prepare("SELECT count(*) c FROM pragma_table_info('waves') WHERE name='legacy'").get().c > 0;
}

function ensureLegacyColumn(db) {
  if (!hasLegacyColumn(db)) db.exec('ALTER TABLE waves ADD COLUMN legacy TEXT');
}

function row(db, id) {
  const current = db.prepare('SELECT * FROM waves WHERE id=?').get(id);
  if (!current) fail('wave_not_found');
  return current;
}

// The exact original bookkeeping, so a revert can prove the row has not moved since.
function original(current) {
  const exact = {};
  for (const column of COLUMNS) exact[column] = current[column] === undefined ? null : current[column];
  return exact;
}

// ONE RECORD PER WAVE, so a store with more than one legacy row can migrate each of them. The
// single `migration.json` name this first shipped under is still read for its own wave.
const safeId = id => String(id).replace(/[^A-Za-z0-9._-]/g, '_');
function migrationFile(dir, id) { return path.join(dir, `migration-${safeId(id)}.json`); }
function legacyRecordFile(dir) { return path.join(dir, 'migration.json'); }
function readRecordFile(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } }

// The one-row-per-repository unique index is what made an idle row fence the next wave. Dropping it
// is part of this migration and is reported; `revert` puts it back when it still can - and the
// reversal is TRANSIENT, because `wave-lifecycle open()` drops it again on the next read-write wave
// operation (the derived rule cannot coexist with a unique index that cannot see activity).
const INDEX_TRANSIENCE = 'wave-lifecycle open() drops active_repo again on the next create/advance/reconcile/resume: the derived rule cannot coexist with a unique index that cannot see whether agents are working';
function indexPresent(db) {
  return db.prepare("SELECT count(*) c FROM sqlite_master WHERE type='index' AND name='active_repo'").get().c > 0;
}
function dropIndex(db) {
  const before = indexPresent(db);
  db.exec('DROP INDEX IF EXISTS active_repo; CREATE INDEX IF NOT EXISTS waves_repo ON waves(repo, created_at);');
  return before;
}
function restoreIndex(db) {
  try { db.exec("CREATE UNIQUE INDEX IF NOT EXISTS active_repo ON waves(repo) WHERE state!='complete'"); return {restored: true, reason: ''}; }
  catch (e) { return {restored: false, reason: `the index cannot be restored while more than one unfinished wave exists: ${e.message}`}; }
}

function event(db, id, type, body) {
  db.prepare('INSERT INTO events(wave,at,type,body) VALUES(?,?,?,?)').run(id, Date.now(), type, JSON.stringify(body));
}

export function plan(dir, id = null) {
  const db = open(dir, {readOnly: true});
  try {
    const latest = id ? row(db, id) : db.prepare('SELECT * FROM waves ORDER BY created_at DESC LIMIT 1').get();
    if (!latest) fail('wave_not_found');
    const steps = db.prepare('SELECT wave,position,name,state,attempts FROM steps WHERE wave=? ORDER BY position').all(latest.id);
    const legacy = hasLegacyColumn(db) ? latest.legacy : null;
    return {
      ok: true, store: dir, wave_id: latest.id, state: latest.state, reason: latest.reason,
      legacy_migrated: Boolean(legacy), legacy: legacy ? JSON.parse(legacy) : null,
      steps, original: original(latest),
      one_row_per_repository_index: indexPresent(db) ? 'present (it fences the next wave and is dropped by apply)' : 'already dropped (the derived rule is in force)',
      one_row_per_repository_index_transient: INDEX_TRANSIENCE,
      // A row is not an activity fact. This is the derived verdict the wave now reports.
      derived: {
        activity: 'off-when-nothing-is-in-flight (read from the node runtime, not from this row)',
        convergence: legacy ? 'legacy-unverified' : latest.state === 'complete' ? 'verified' : latest.state === 'blocked' ? 'unverified' : 'open',
        report: 'the row keeps its durable bookkeeping; the wave reports activity/convergence/runtime_state'
      },
      reversible: {file: migrationFile(dir, latest.id), legacy_record: legacyRecordFile(dir), how: `node scripts/wave-migrate.mjs revert ${dir} ${latest.id}`}
    };
  } finally { db.close(); }
}

export function apply(dir, id, actor = 'operator') {
  const db = open(dir);
  try {
    const current = row(db, id);
    if (current.state === 'complete') fail('completed_wave_needs_no_migration');
    ensureLegacyColumn(db);
    const file = migrationFile(dir, id);
    const existing = readRecordFile(file);
    const legacyRecord = readRecordFile(legacyRecordFile(dir));
    const namesThisWave = legacyRecord?.wave_id === id;
    // IDEMPOTENT. A second apply of the same wave is the same request, not an error - and it must
    // not be an error AFTER the transaction has already committed.
    if (row(db, id).legacy && (existing || namesThisWave)) {
      return {ok: true, wave_id: id, state: row(db, id).state, legacy_migrated: true, already_migrated: true, record: existing ? file : legacyRecordFile(dir), original_unchanged: true};
    }
    if (row(db, id).legacy) fail('wave_already_migrated');
    // REFUSE BEFORE THE TRANSACTION, NEVER AFTER IT. A record that already exists is either a
    // leftover of an interrupted revert or another wave's; both need a decision, not a mutation.
    if (existing) fail(`migration_record_without_migration:${file}:revert or remove the record first`);
    if (legacyRecord && !namesThisWave) fail(`migration_record_belongs_to_another_wave:${legacyRecord.wave_id}`);
    if (legacyRecord && namesThisWave) fail(`migration_record_without_migration:${legacyRecordFile(dir)}:revert or remove the record first`);
    const droppedIndex = dropIndex(db);
    const body = {schema: 1, kind: 'derived-activity-migration', wave_id: id, at: Date.now(), by: actor, original: original(current), why: 'the wave is OFF because nothing is in flight; its convergence was never verified and stays named as legacy-unverified'};
    db.exec('BEGIN IMMEDIATE');
    try {
      db.prepare('UPDATE waves SET legacy=? WHERE id=?').run(JSON.stringify(body), id);
      event(db, id, 'legacy_state_migrated', body);
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    // A durable, human-readable record beside the store; never overwritten.
    const record = {schema: 1, kind: 'wave-legacy-migration', store: dir, wave_id: id, at: body.at, by: actor, original: body.original, sha256: hash(JSON.stringify(body)), revert: `node scripts/wave-migrate.mjs revert ${dir} ${id}`};
    fs.writeFileSync(file, `${JSON.stringify(record)}\n`, {flag: 'wx'});
    const after = row(db, id);
    // PROOF THAT NOTHING ELSE MOVED: every original column is byte-identical.
    for (const column of COLUMNS) if (JSON.stringify(after[column] ?? null) !== JSON.stringify(current[column] ?? null)) fail(`migration_moved_${column}`);
    return {ok: true, wave_id: id, state: after.state, legacy_migrated: true, record: file, original_unchanged: true, one_row_per_repository_index_dropped: droppedIndex};
  } finally { db.close(); }
}

export function revert(dir, id) {
  const db = open(dir);
  try {
    if (!hasLegacyColumn(db)) fail('wave_not_migrated');
    const current = row(db, id);
    if (!current.legacy) fail('wave_not_migrated');
    const body = JSON.parse(current.legacy);
    if (body?.wave_id !== id) fail('legacy_record_identity_mismatch');
    // Never clobber a later transition: the row must still be exactly what was migrated.
    for (const column of COLUMNS) {
      if (column === 'boot' || column === 'pid') continue; // owner lease fields move while a finisher drives it
      if (JSON.stringify(current[column] ?? null) !== JSON.stringify(body.original?.[column] ?? null)) fail(`row_changed_since_migration:${column}`);
    }
    db.exec('BEGIN IMMEDIATE');
    try {
      db.prepare('UPDATE waves SET legacy=NULL WHERE id=?').run(id);
      event(db, id, 'legacy_state_migration_reverted', {wave_id: id, at: Date.now(), restored: body.original, sha256: body.sha256 ?? null});
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    // Remove whichever record names this wave - the per-wave file, or the single-file name this
    // first shipped under. A record that names another wave is left alone.
    const files = [migrationFile(dir, id), legacyRecordFile(dir)];
    const removed = [];
    for (const candidate of files) {
      if (!fs.existsSync(candidate)) continue;
      const record = readRecordFile(candidate);
      if (record?.wave_id !== id) continue;
      try { fs.unlinkSync(candidate); removed.push(candidate); } catch { /* leave an unreadable record alone */ }
    }
    const after = row(db, id);
    const index = restoreIndex(db);
    return {ok: true, wave_id: id, state: after.state, legacy_migrated: false, restored: original(after), removed_records: removed,
      one_row_per_repository_index: {...index, transient: true, note: INDEX_TRANSIENCE}};
  } finally { db.close(); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [action, dir, id, actor] = process.argv.slice(2);
  try {
    if (!dir) fail('usage: plan DIR [ID] | apply DIR ID [ACTOR] | revert DIR ID');
    let result;
    if (action === 'plan') result = plan(path.resolve(dir), id || null);
    else if (action === 'apply') result = apply(path.resolve(dir), id, actor);
    else if (action === 'revert') result = revert(path.resolve(dir), id);
    else fail('usage: plan DIR [ID] | apply DIR ID [ACTOR] | revert DIR ID');
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (e) {
    process.stdout.write(`${JSON.stringify({ok: false, error: e.message})}\n`);
    process.exitCode = 1;
  }
}
