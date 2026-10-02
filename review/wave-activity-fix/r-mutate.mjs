// MUTATION BATTERY on the fix. Seven mutations that pinned the REVIEWED tree (re-applied to the new
// code) plus five of my own aimed at the fix's new claims.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [, , pristine, mut, bin] = process.argv;
const MUTATIONS = [
  // ---- the seven that were reverted (re-applied to the new code) -------------------------------
  ['R-A ON/OFF derived from the durable row again', 'scripts/lib/wave-activity.mjs',
    '      activity = inventory.activity;',
    "      activity = bookkeeping === 'running' ? 'on' : inventory.activity;"],
  ['R-B the process probe VETOES instead of corroborating', 'scripts/lib/wave-activity.mjs',
    '      else record.in_flight = true;',
    '      else record.in_flight = corroborated === true;'],
  ['R-C the legacy convergence is no longer named', 'scripts/lib/wave-activity.mjs',
    ": legacy ? 'legacy-unverified' : 'open';",
    ": 'open';"],
  ['R-D create() refuses ANY previous row (the idle wave fences again)', 'scripts/wave-lifecycle.mjs',
    'if (active) fail(`previous_wave_active:${active.row.id}`);',
    'if (rows.length) fail(`previous_wave_active:${rows[0].id}`);'],
  ['R-E an IDLE wave refuses produce/allocate (the live-lane regression)', 'scripts/wave-entry.mjs',
    "    if(['land','admit'].includes(phase) && unverified)throw Error(`wave_convergence_unverified:${unverified.row.id}:${unverified.row.state}:${unverified.verdict.reason}`);",
    "    if(['land','admit'].includes(phase) && unverified)throw Error(`wave_convergence_unverified:${unverified.row.id}:${unverified.row.state}:${unverified.verdict.reason}`);\n    if(['produce','allocate'].includes(phase))throw Error('idle_wave_fences_'+phase);"],
  ['R-F the migration rewrites the durable state it claims not to touch', 'scripts/wave-migrate.mjs',
    "db.prepare('UPDATE waves SET legacy=? WHERE id=?').run(JSON.stringify(body), id);",
    "db.prepare(\"UPDATE waves SET legacy=?,state='complete' WHERE id=?\").run(JSON.stringify(body), id);"],
  ['R-G a blocked/idle wave stops refusing land/admit by name', 'scripts/wave-entry.mjs',
    "    if(['land','admit'].includes(phase) && unverified)throw Error(`wave_convergence_unverified:${unverified.row.id}:${unverified.row.state}:${unverified.verdict.reason}`);",
    '    /* the named refusal is gone */'],
  // ---- my own, aimed at the fix's new claims ---------------------------------------------------
  ['N-1 create() admits while the activity is genuinely UNOBSERVABLE', 'scripts/wave-lifecycle.mjs',
    "      if (unobservable.source?.kind!=='none') fail(`previous_wave_activity_unverifiable:${unobservable.row.id}:${unobservable.verdict.reason}`);",
    '      /* the unobservable answer is not consulted */'],
  ['N-2 land/admit through with an unverified convergence', 'scripts/wave-entry.mjs',
    "const unverified=unfinished.find(entry=>!['verified','open'].includes(entry.verdict.convergence));",
    'const unverified=null;'],
  ['N-3 a resolution is matched by SESSION alone (a later claim borrows it)', 'scripts/lib/wave-activity.mjs',
    "  for (const field of ['child_id', 'run_id', 'boot']) if (String(resolution[field] || '') !== String(claim[field] || '')) return false;",
    '  /* the identity fields are not compared */'],
  ['N-4 checkAdmission reads only the newest row again (the orphan returns)', 'scripts/wave-entry.mjs',
    "    const unfinished=verdicts.filter(entry=>entry.row.state!=='complete');",
    '    const unfinished=[];'],
  ['N-5 the migration no longer refuses a record without its migration', 'scripts/wave-migrate.mjs',
    'if (existing) fail(`migration_record_without_migration:${file}:revert or remove the record first`);',
    '/* the leftover record is not refused */'],
];
const SUITES = ['test-wave-activity-fix.mjs', 'test-wave-derived-state.mjs', 'test-wave-public.mjs'];
const rows = [];
for (const [name, file, from, to] of MUTATIONS) {
  fs.rmSync(mut, {recursive: true, force: true});
  fs.cpSync(pristine, mut, {recursive: true});
  const target = path.join(mut, file);
  const text = fs.readFileSync(target, 'utf8');
  const count = text.split(from).length - 1;
  if (count !== 1) { rows.push([name, `MUTATION DID NOT APPLY (${count} matches)`, '']); console.log(`  ${name}: DID NOT APPLY (${count} matches)`); continue; }
  fs.writeFileSync(target, text.replace(from, to));
  const results = [];
  for (const suite of SUITES) {
    const argv = [path.join(mut, 'scripts', suite)];
    if (suite === 'test-wave-public.mjs') argv.push(bin);
    const r = spawnSync(process.execPath, argv, {encoding: 'utf8', windowsHide: true, timeout: 900000});
    results.push(`${suite.replace('test-wave-', '').replace('.mjs', '')}=${r.status === 0 ? 'green' : 'RED'}`);
  }
  const verdict = results.some(r => r.endsWith('RED')) ? 'CAUGHT' : '*** SURVIVED ***';
  rows.push([name, `${results.join(' ')}  -> ${verdict}`, verdict]);
  console.log(`  ${results.join(' ').padEnd(60)} ${verdict.padEnd(18)} ${name}`);
}
console.log(`\nCAUGHT ${rows.filter(r => r[2] === 'CAUGHT').length}/${rows.length}`);
for (const [name, , v] of rows) if (v !== 'CAUGHT') console.log(`  SURVIVED: ${name} (${rows.find(r => r[0] === name)[1]})`);
