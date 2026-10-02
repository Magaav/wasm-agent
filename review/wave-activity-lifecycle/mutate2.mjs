// Targeted mutations on the FULL tree (so test-wave-proof and test-wave-public can run).
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [, , pristine, mut, bin] = process.argv;
const MUTATIONS = [
  ['M-E an IDLE wave refuses produce/allocate (the live-lane regression)', 'scripts/wave-entry.mjs',
    "if(current.state==='blocked' && ['land','admit'].includes(phase))throw Error('wave_convergence_unverified:'+current.reason);",
    "if(['produce','allocate','land','admit'].includes(phase))throw Error('idle_wave_fences_'+phase);"],
  ['M-G a BLOCKED+idle wave stops refusing land/admit by name', 'scripts/wave-entry.mjs',
    "if(current.state==='blocked' && ['land','admit'].includes(phase))throw Error('wave_convergence_unverified:'+current.reason);",
    '/* the named refusal is gone */'],
  ['M-H create() admits the next wave while a child is really in flight', 'scripts/wave-lifecycle.mjs',
    "if (previous_verdict.activity==='on') fail(`previous_wave_active:${previous.id}`);",
    '/* activity no longer fences create() */'],
];
const SUITES = ['test-wave-derived-state.mjs', 'test-wave-no-orca.mjs', 'test-wave-lifecycle.mjs', 'test-wave-proof.mjs', 'test-wave-public.mjs', 'test-wave-restart.mjs'];
for (const [name, file, from, to] of MUTATIONS) {
  fs.rmSync(mut, {recursive: true, force: true});
  fs.cpSync(pristine, mut, {recursive: true});
  const target = path.join(mut, file);
  const text = fs.readFileSync(target, 'utf8');
  const count = text.split(from).length - 1;
  if (count !== 1) { console.log(`${name}: MUTATION DID NOT APPLY (${count} matches)`); continue; }
  fs.writeFileSync(target, text.replace(from, to));
  const results = [];
  for (const suite of SUITES) {
    const argv = [path.join(mut, 'scripts', suite)];
    if (suite === 'test-wave-public.mjs') argv.push(bin);
    const r = spawnSync(process.execPath, argv, {encoding: 'utf8', windowsHide: true, timeout: 900000});
    results.push(`${suite.replace('test-wave-', '').replace('.mjs', '')}=${r.status === 0 ? 'green' : 'RED'}`);
  }
  console.log(`${results.join(' ').padEnd(96)} ${name}`);
}
