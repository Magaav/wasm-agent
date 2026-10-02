// RE-VERIFY 1: the live lane, on a COPY of the live store, before and after everything.
// Store read = copy. Activity source = the real one production derives from the row's manifest.
import {pathToFileURL} from 'node:url';
import {DatabaseSync} from 'node:sqlite';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';

const [W, OLDW, REPO] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const newEntry = await import(mod(W, 'scripts/wave-entry.mjs'));
const oldEntry = await import(mod(OLDW, 'scripts/wave-entry.mjs'));
const migrate = await import(mod(W, 'scripts/wave-migrate.mjs'));
const act = await import(mod(W, 'scripts/lib/wave-activity.mjs'));

const store = path.join(REPO, '.git', 'wa-waves');
const PHASES = ['produce', 'allocate', 'land', 'admit', 'observe'];
const read = () => { const db = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true}); const r = db.prepare('SELECT id,state FROM waves ORDER BY created_at DESC').all(); db.close(); return r; };
const short = r => ({ok: r.ok, reason: r.reason, activity: r.activity, convergence: r.convergence, runtime_state: r.runtime_state, unfinished: r.unfinished && r.unfinished.length});
const dump = (label) => {
  console.log(`\n--- ${label} ---`);
  for (const p of PHASES) {
    console.log(`  BEFORE(old code) ${p.padEnd(9)} ${JSON.stringify(short(oldEntry.checkAdmission(REPO, {phase: p})))}`);
    console.log(`  AFTER (new code) ${p.padEnd(9)} ${JSON.stringify(short(newEntry.checkAdmission(REPO, {phase: p})))}`);
  }
};

const row = (() => { const db = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true}); const r = db.prepare('SELECT * FROM waves ORDER BY created_at DESC LIMIT 1').get(); db.close(); return r; })();
const source = act.activitySource(JSON.parse(row.manifest));
console.log('activity source production derives:', JSON.stringify(source));
const t0 = Date.now();
const inv = act.activityInventory(source);
console.log(JSON.stringify({on: inv.on, activity: inv.activity, off: inv.off, agents: inv.agents.length, claims: inv.claims.map(c => `${c.claim}:${c.session}`), git_worktrees: inv.evidence.git_worktrees, rows: inv.evidence.session_store.rows, processes: inv.evidence.processes, unresolved: inv.unresolved.length, leftovers: inv.leftovers.length, corroborated: inv.agents.map(a => a.corroborated)}, null, 1));
console.log(`inventory elapsed_ms=${Date.now() - t0}`);
console.log('rows in the COPY:', JSON.stringify(read()));
dump('COPY of the live store, as it is now');

const applied = migrate.apply(store, row.id, 'review-worker-8077a6cf');
console.log('\nmigration on the COPY:', JSON.stringify({ok: applied.ok, record: path.basename(applied.record), original_unchanged: applied.original_unchanged, dropped: applied.one_row_per_repository_index_dropped}));
const verdict = act.waveActivity(source, (() => { const db = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true}); const r = db.prepare('SELECT * FROM waves WHERE id=?').get(row.id); db.close(); return r; })());
console.log('waveActivity after the migration:', JSON.stringify({activity: verdict.activity, convergence: verdict.convergence, runtime_state: verdict.runtime_state}));
dump('COPY after the legacy-row migration');
console.log('rows in the COPY after migration:', JSON.stringify(read()));
