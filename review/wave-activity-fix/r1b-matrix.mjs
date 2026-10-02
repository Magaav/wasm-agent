// RE-VERIFY 1b: the full admission matrix for the LIVE row's shape on COPIES of the live store,
// with the real activity source (the live lane is ON), reviewed code vs fix.
//   copy M = the live store as it is (already migrated by the coordinator)
//   copy R = the same store with the migration REVERTED on the copy (the pre-migration row)
//   copy R2 = copy R, then migrated again by this review
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const [W, OLDW, LIVE, SCRATCH] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const fix = await import(mod(W, 'scripts/wave-entry.mjs'));
const reviewed = await import(mod(OLDW, 'scripts/wave-entry.mjs'));
const migrate = await import(mod(W, 'scripts/wave-migrate.mjs'));
const act = await import(mod(W, 'scripts/lib/wave-activity.mjs'));
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); if (r.status !== 0) throw Error(r.stderr); return r.stdout.trim(); };

let n = 0;
function copy(label) {
  const repo = path.join(SCRATCH, `c${++n}-${label}`);
  fs.rmSync(repo, {recursive: true, force: true}); fs.mkdirSync(repo);
  git(repo, 'init', '-q'); git(repo, 'remote', 'add', 'origin', 'https://example.invalid/x.git');
  const store = path.join(repo, '.git', 'wa-waves');
  fs.cpSync(LIVE, store, {recursive: true});
  const reg = path.join(store, 'registration.json');
  const registration = JSON.parse(fs.readFileSync(reg, 'utf8')); registration.repo = repo; fs.writeFileSync(reg, JSON.stringify(registration, null, 1));
  return {repo, store};
}
const PHASES = ['produce', 'allocate', 'land', 'admit'];
const short = r => ({ok: r.ok, reason: r.reason, activity: r.activity, convergence: r.convergence, runtime_state: r.runtime_state, unfinished: r.unfinished?.length});
function matrix(title, c) {
  console.log(`\n===== ${title} =====`);
  for (const p of PHASES) {
    console.log(`  ${p.padEnd(9)} reviewed(6a61338) ${JSON.stringify(short(reviewed.checkAdmission(c.repo, {phase: p})))}`);
    console.log(`  ${p.padEnd(9)} fix(6b30ca7)     ${JSON.stringify(short(fix.checkAdmission(c.repo, {phase: p})))}`);
  }
}

const migrated = copy('live-as-is');
matrix('LIVE row AS IT IS (the coordinator already migrated the live store)', migrated);

const reverted = copy('live-reverted');
const rev = migrate.revert(reverted.store, 'wave-2026-10-02-subagent-chat-and-enforcement');
console.log('\nrevert on the COPY:', JSON.stringify({ok: rev.ok, legacy_migrated: rev.legacy_migrated, removed: rev.removed_records?.map(f => path.basename(f)), index: rev.one_row_per_repository_index}));
matrix('LIVE row with the migration REVERTED on the copy (pre-migration shape)', reverted);

const applied = migrate.apply(reverted.store, 'wave-2026-10-02-subagent-chat-and-enforcement', 'review-worker-8077a6cf');
console.log('\napply on that copy:', JSON.stringify({ok: applied.ok, record: path.basename(applied.record), already_migrated: applied.already_migrated, original_unchanged: applied.original_unchanged, dropped: applied.one_row_per_repository_index_dropped}));
matrix('LIVE row AFTER the migration (freshly applied on the copy)', reverted);

const row = (() => { const {DatabaseSync} = require0(); return null; })();
function require0() { return {}; }
