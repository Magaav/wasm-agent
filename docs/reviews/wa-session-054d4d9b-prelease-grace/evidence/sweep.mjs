// Independent sweep runner: imports the sweepClones of one tree and prints its record.
// usage: node sweep.mjs <treeDir> <tmp> <keep> [waitSecondsEnv]
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
const [tree, tmp, keepRaw, waitEnv] = process.argv.slice(2);
if (waitEnv !== undefined && waitEnv !== '') process.env.WA_GATE_LANE_WAIT_SECONDS = waitEnv;
else delete process.env.WA_GATE_LANE_WAIT_SECONDS;
const mod = await import(pathToFileURL(path.join(tree, 'scripts', 'merge-lane.mjs')).href);
const keep = keepRaw === 'all' ? 'all' : Number(keepRaw);
const before = fs.readdirSync(tmp).sort();
const record = mod.sweepClones({keep, tmp});
const base = p => String(p).split(/[\/]/).pop();
process.stdout.write('SWEEP ' + JSON.stringify({
  tree: path.resolve(tree),
  env_wait: process.env.WA_GATE_LANE_WAIT_SECONDS ?? null,
  grace_seconds: record.grace_seconds, keep: record.keep, budget_for_others: record.budget_for_others,
  before, after: fs.readdirSync(tmp).sort(),
  removed: (record.removed || []).map(r => [base(r.path), r.evidence ?? null]),
  kept: (record.kept || []).map(r => [base(r.path), r.lease]),
  recent_legacy: (record.recent_legacy || []).map(base),
  live: (record.live || []).map(base),
  in_use: (record.in_use || []).map(r => [base(r.path), r.evidence ?? null]),
  not_this_family: record.not_this_family,
  errors: (record.errors || []).map(e => [base(e.path), e.error]),
}) + '\n');
