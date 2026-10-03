// REVIEWER: mutation battery. Each mutation is applied to a pristine `git archive e15bdc1` copy and
// the suites are run against it; a mutation that leaves every suite green is a SURVIVOR (a claim the
// suites do not pin). Usage: node mutate.mjs <repoWithTipCommit> <scratchRoot> <wa.exe>
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [REPO, ROOT, BIN] = process.argv.slice(2);
const MUT = [
  ['M1 the complete newest row admits land/admit too', 'scripts/wave-entry.mjs', "if(!['land','admit'].includes(phase))return", 'if(true)return'],
  ['M2 findResolution ignores a corroborating process', 'scripts/lib/wave-activity.mjs', 'if (corroborated === true) return null;', 'if (false) return null;'],
  ['M3 resolve stops refusing a process-held claim', 'scripts/wave-activity.mjs', 'if (positive.corroborated === true) fail(', 'if (false) fail('],
  ['M4 a resolution may be borrowed (identity ignored)', 'scripts/lib/wave-activity.mjs', "for (const field of ['child_id', 'run_id', 'boot'])", "for (const field of [])"],
  ['M5 observe always says a claim is resolvable', 'scripts/wave-activity.mjs', 'resolvable: agent.corroborated !== true,', 'resolvable: true,'],
  ['M6 the refusal stops naming the older unfinished rows', 'scripts/wave-entry.mjs', '${unfinished.length?`:unfinished:${unfinished.map(entry=>entry.row.id).join(\',\')}`:\'\'}', ''],
  ['M7 the closing freeze stops fencing producing', 'scripts/wave-entry.mjs', "if(fs.existsSync(freeze) && phase!=='land')throw Error('wave_closing_frozen');", 'if(false)throw Error(\'wave_closing_frozen\');'],
  ['M8 a positive claim is no longer listed as positive', 'scripts/wave-activity.mjs', '{positive: true, resolvable:', '{positive: false, resolvable:'],
];
const SUITES = [['corners', ['scripts/test-wave-activity-corners.mjs']], ['activity-fix', ['scripts/test-wave-activity-fix.mjs']], ['public', ['scripts/test-wave-public.mjs', BIN]]];
const work = path.join(ROOT, 'mut');
const run = (tree) => {
  const results = [];
  for (const [name, args] of SUITES) {
    const r = spawnSync(process.execPath, [...args], {cwd: tree, encoding: 'utf8', windowsHide: true, timeout: 600000});
    results.push(`${name}=${r.status === 0 ? 'green' : 'RED'}`);
  }
  return results.join(' ');
};
for (const [label, file, from, to] of MUT) {
  fs.rmSync(work, {recursive: true, force: true});
  fs.mkdirSync(work, {recursive: true});
  const tar = spawnSync('tar', ['-x'], {cwd: work, input: spawnSync('git', ['-C', REPO, 'archive', 'e15bdc1'], {encoding: 'buffer', maxBuffer: 1 << 30}).stdout, windowsHide: true});
  if (tar.status !== 0) throw Error(`extract failed: ${tar.stderr}`);
  const target = path.join(work, file);
  const text = fs.readFileSync(target, 'utf8');
  const occurrences = text.split(from).length - 1;
  if (occurrences !== 1) throw Error(`${label}: the anchor occurs ${occurrences} times in ${file}`);
  fs.writeFileSync(target, text.replace(from, to));
  console.log(`${run(work)}   ${label}`);
}
console.log('baseline (unmutated tip)           ' + run(REPO));
