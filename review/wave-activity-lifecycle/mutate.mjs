// Mutation runner: pristine copy of the delivered scripts, one mutation at a time, then the suites.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [, , pristine, mut, out] = process.argv;
const MUTATIONS = [
  ['M-A ON/OFF derived from the durable row again (the old behaviour)', 'scripts/lib/wave-activity.mjs',
    "else activity = inventory.on ? 'on' : 'off';",
    "else activity = (bookkeeping === 'running' || inventory.on) ? 'on' : 'off';"],
  ['M-B the process probe VETOES instead of corroborating', 'scripts/lib/wave-activity.mjs',
    'if (inFlight) {',
    'if (inFlight && (!probe.available || holderOf(probe, treePath))) {'],
  ['M-C the legacy convergence is no longer named', 'scripts/lib/wave-activity.mjs',
    ": legacy ? 'legacy-unverified' : 'open';",
    ": legacy ? 'open' : 'open';"],
  ['M-D create() refuses ANY previous row (the idle wave fences again)', 'scripts/wave-lifecycle.mjs',
    "if (previous_verdict.activity==='on') fail(`previous_wave_active:${previous.id}`);",
    'if (previous) fail(`previous_wave_active:${previous.id}`);'],
  ['M-E an IDLE wave refuses produce/allocate (the live-lane regression)', 'scripts/wave-entry.mjs',
    "if(current.state==='blocked' && ['land','admit'].includes(phase))throw Error('wave_convergence_unverified:'+current.reason);",
    "if(['produce','allocate','land','admit'].includes(phase))throw Error('idle_wave_fences_'+phase);"],
  ['M-F the migration rewrites the durable state it claims not to touch', 'scripts/wave-migrate.mjs',
    "db.prepare('UPDATE waves SET legacy=? WHERE id=?').run(JSON.stringify(body), id);",
    "db.prepare('UPDATE waves SET legacy=?,state=\\'complete\\' WHERE id=?').run(JSON.stringify(body), id);"],
];
const SUITES = ['test-wave-derived-state.mjs', 'test-wave-no-orca.mjs', 'test-wave-lifecycle.mjs', 'test-wave-proof.mjs'];
const rows = [];
for (const [name, file, from, to] of MUTATIONS) {
  fs.rmSync(mut, {recursive: true, force: true});
  fs.cpSync(pristine, mut, {recursive: true});
  const target = path.join(mut, file);
  const text = fs.readFileSync(target, 'utf8');
  const count = text.split(from).length - 1;
  if (count !== 1) { rows.push([name, `MUTATION DID NOT APPLY (${count} matches)`, '']); continue; }
  fs.writeFileSync(target, text.replace(from, to));
  const results = [];
  for (const suite of SUITES) {
    const r = spawnSync(process.execPath, [path.join(mut, 'scripts', suite)], {encoding: 'utf8', windowsHide: true, timeout: 900000});
    const tail = (r.stdout || '').trim().split('\n').filter(Boolean).pop() || (r.stderr || '').trim().split('\n')[0] || '';
    results.push(`${suite.replace('test-wave-', '').replace('.mjs', '')}=${r.status === 0 ? 'green' : 'RED'}`);
  }
  rows.push([name, results.join(' '), '']);
}
console.log('MUTATION RESULTS');
for (const [name, result] of rows) console.log(`  ${result.padEnd(62)} ${name}`);
fs.writeFileSync(out, JSON.stringify(rows, null, 1));
