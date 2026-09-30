// READ-ONLY PROBE: can the persistent tree be a candidate of the retention sweep?
//
// Answering C:/Users/Victor/orca/projects/wasm-agent/.git/worktrees/Codex-3's question 2 for the
// persistent-tree delivery: "the new retention rule sweeps the `wa-merge-lane-*` family and asks a
// rename probe before deleting; your persistent tree must never be a deletion candidate - including
// when it is idle between landings".
//
// Run from the lane's worktree:
//   node docs/measurements/merge-lane-tree-vs-retention-probe.mjs
//
// It fabricates a temp root (never the real one) holding one legacy-shaped family clone and one
// directory named like the persistent tree, then asks scripts/merge-lane.mjs's OWN `sweepClones()`.
// Part C sweeps the real temp root with `keep` large enough that nothing may be pruned, purely to read
// the record's candidate lists - it deletes nothing.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const LANE = path.resolve(here, '..', '..', 'scripts', 'merge-lane.mjs');
const {sweepClones, legacyGraceMs} = await import(`file:///${LANE.replace(/\\/g, '/')}`);

const persistent = path.join(os.homedir(), '.wasm-agent', 'merge-lane-tree-landing');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'sweep-probe-'));
const leftover = path.join(fixture, 'wa-merge-lane-abc123');       // the sweep's legacy shape
const myNameOutsideFamily = path.join(fixture, 'merge-lane-tree-landing');
fs.mkdirSync(leftover);
fs.mkdirSync(myNameOutsideFamily);
const old = new Date(Date.now() - 20_000_000);
fs.utimesSync(leftover, old, old);

const show = record => ({
  family: record.family,
  grace_s: Math.round(record.grace_ms / 1000),
  current: record.current && path.basename(record.current),
  current_kept: record.current_kept,
  budget_for_others: record.budget_for_others,
  kept: record.kept.map(item => path.basename(item.path)),
  removed: record.removed.map(item => path.basename(item.path)),
  in_use: record.in_use.map(item => path.basename(item.path)),
  recent_legacy: record.recent_legacy.map(item => path.basename(item.path)),
  live: record.live.map(item => path.basename(item)),
  not_this_family: record.not_this_family,
  errors: record.errors.length});

console.log('legacy grace as merged:', legacyGraceMs({}) / 1000, 's');
console.log('persistent tree exists:', fs.existsSync(persistent), `(${persistent})`);

// B - the merged behaviour: a persistent tree does not spend the retention budget.
const b = sweepClones({keep: 1, tmp: fixture, current: persistent, currentKept: false});
console.log('B currentKept=false (what the merged lane passes for a persistent tree):', JSON.stringify(show(b)));
console.log('   the leftover clone survived B:', fs.existsSync(leftover));

// A - the same sweep read the OLD way, where the tree this run kept counted against the budget.
const a = sweepClones({keep: 1, tmp: fixture, current: persistent, currentKept: true});
console.log('A currentKept=true (the budget read the persistent tree as this run\'s clone):', JSON.stringify(show(a)));
console.log('   the leftover clone survived A:', fs.existsSync(leftover));

// C - the real temp root, budget large enough that nothing may be pruned: read the candidate set.
const c = sweepClones({keep: 1000, tmp: os.tmpdir(), current: persistent});
const names = [...c.kept, ...c.removed, ...c.in_use, ...c.recent_legacy, ...c.live].map(item =>
  path.basename(item.path || item));
console.log('C real temp root, keep=1000 (deletes nothing): family', c.family,
  '| candidates seen', names.length, '| removed', c.removed.length);
console.log('   is the persistent tree among them:', names.includes(path.basename(persistent)));
console.log('   is the persistent tree inside the swept root at all:',
  path.resolve(persistent).toLowerCase().startsWith(`${path.resolve(os.tmpdir()).toLowerCase()}${path.sep}`));

fs.rmSync(fixture, {recursive: true, force: true});
