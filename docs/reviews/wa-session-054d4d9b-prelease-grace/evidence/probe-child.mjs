// One sweep whose probe CANNOT be answered: the probe's own rename target is already occupied by a
// non-empty directory - what a probe path left behind by a crashed sweep with a recycled pid is.
// usage: node probe-child.mjs <treeDir> <tmp> <mode:leftover|plain>
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const [tree, tmp, mode] = process.argv.slice(2);
const target = path.join(tmp, 'wa-merge-lane-Probe1');
const leftover = `${target}.in-use-${process.pid}`;
if (mode === 'leftover') { fs.mkdirSync(leftover); fs.writeFileSync(path.join(leftover, 'leftover'), 'x\n'); }
const {sweepClones} = await import(pathToFileURL(path.join(tree, 'scripts', 'merge-lane.mjs')).href);
const record = sweepClones({keep: 0, tmp});
const base = p => String(p).split(/[\/]/).pop();
process.stdout.write('SWEEP ' + JSON.stringify({
  pid: process.pid, mode, grace_seconds: record.grace_seconds,
  removed: record.removed.map(r => [base(r.path), r.evidence]),
  in_use: record.in_use.map(r => [base(r.path), r.evidence]),
  errors: record.errors.map(e => [base(e.path), e.error]),
  not_this_family: record.not_this_family,
  after: fs.readdirSync(tmp).sort(),
}) + '\n');
