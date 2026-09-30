// Independent construction for the review of tree 72e807b3c1ccd6214df53ff71b3516b8692341e6.
// Question: with the persistent tree present, IDLE and OLDER THAN ANY GRACE, does the retention
// sweep (scripts/merge-lane.mjs sweepClones, the merged derived-grace + rename-probe version) delete it?
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const LANE = path.join(here, "src", "scripts", "merge-lane.mjs");
import {pathToFileURL} from "node:url";
const {sweepClones, legacyGraceMs} = await import(pathToFileURL(LANE).href);

const REAL_TREE = path.join(os.homedir(), '.wasm-agent', 'merge-lane-tree-landing');
const REAL_PARENT = path.join(os.homedir(), '.wasm-agent');
const GRACE = legacyGraceMs({});
const show = r => ({
  grace_s: Math.round(r.grace_ms / 1000),
  current: r.current && path.basename(r.current),
  current_kept: r.current_kept,
  budget_for_others: r.budget_for_others,
  kept: r.kept.map(i => path.basename(i.path)),
  removed: r.removed.map(i => path.basename(i.path)),
  in_use: r.in_use.map(i => path.basename(i.path)),
  recent_legacy: r.recent_legacy.map(i => path.basename(i)),
  live: r.live.map(i => path.basename(i)),
  not_this_family: r.not_this_family,
  errors: r.errors.length});

const stat = p => { try { const s = fs.statSync(p); return {mtime: s.mtime.toISOString(), age_s: Math.round((Date.now() - s.mtimeMs) / 1000), dir: s.isDirectory()}; } catch (e) { return {error: e.code}; } };

console.log('== 0. the real tree, as it is right now (READ ONLY) ==');
console.log('   path', REAL_TREE);
console.log('   stat', JSON.stringify(stat(REAL_TREE)));
console.log('   lock present:', fs.existsSync(path.join(REAL_TREE, '.git', 'wa-merge-lane-tree.lock')));
console.log('   derived grace legacyGraceMs({}) =', GRACE, 'ms =', GRACE / 1000, 's');
console.log('   basename in the sweep family (wa-merge-lane-*)?', path.basename(REAL_TREE).startsWith('wa-merge-lane-'));
const tmp = os.tmpdir();
console.log('   os.tmpdir() =', tmp);
console.log('   inside os.tmpdir()?', path.resolve(REAL_TREE).toLowerCase().startsWith(path.resolve(tmp).toLowerCase() + path.sep));

console.log('\n== 1. the sweep run with the REAL tree own parent as its root (keep=1, real semantics) ==');
console.log('   (verified first: ' + REAL_PARENT + ' holds no wa-merge-lane-* entry, so nothing can be pruned)');
console.log('   family entries there:', fs.readdirSync(REAL_PARENT).filter(n => n.startsWith('wa-merge-lane-')).length);
const one = sweepClones({keep: 1, tmp: REAL_PARENT, current: REAL_TREE, currentKept: false, gateTimeoutSeconds: 3600});
console.log('   record', JSON.stringify(show(one)));
console.log('   the real tree still exists:', fs.existsSync(REAL_TREE), '| stat after:', JSON.stringify(stat(REAL_TREE)));

console.log('\n== 2. a scratch root holding (a) a MIMIC of the tree by name, idle and 20x the grace old,');
console.log('      and (b) a real in-family LEFT OVER, idle and 20x the grace old ==');
const scratch = fs.mkdtempSync(path.join(here, 'tmp', 'sweep-'));
const mimic = path.join(scratch, 'merge-lane-tree-landing');
const family = path.join(scratch, 'wa-merge-lane-999998-Ab3XyZ');
const familyInFamilyName = path.join(scratch, 'wa-merge-lane-tree');
fs.mkdirSync(mimic); fs.mkdirSync(family); fs.mkdirSync(familyInFamilyName);
fs.writeFileSync(path.join(mimic, 'wa-merge-lane-tree.json'), '{"schema":1}\n');
fs.writeFileSync(path.join(mimic, 'a.txt'), 'the persistent tree\n');
fs.writeFileSync(path.join(family, 'a.txt'), 'a leftover clone\n');
fs.writeFileSync(path.join(familyInFamilyName, 'a.txt'), 'named in the family prefix but not its shape\n');
const old = new Date(Date.now() - 20_000_000);
for (const p of [mimic, family, familyInFamilyName]) fs.utimesSync(p, old, old);
console.log('   scratch', scratch);
console.log('   mimic age_s', stat(mimic).age_s, '(grace is', GRACE / 1000, 's)');
const two = sweepClones({keep: 1, tmp: scratch, current: mimic, currentKept: false, gateTimeoutSeconds: 3600});
console.log('   record', JSON.stringify(show(two)));
console.log('   mimic survived:', fs.existsSync(mimic), '| family leftover survived:', fs.existsSync(family),
  '| wa-merge-lane-tree survived:', fs.existsSync(familyInFamilyName));

console.log('\n== 3. the decisive shape: an IDLE, OLD family member with the budget spent elsewhere ==');
const three = sweepClones({keep: 0, tmp: scratch, current: null, currentKept: false, gateTimeoutSeconds: 3600});
console.log('   record', JSON.stringify(show(three)));
console.log('   mimic survived:', fs.existsSync(mimic), '| family leftover survived:', fs.existsSync(family));
fs.rmSync(scratch, {recursive: true, force: true});
console.log('\n   (scratch removed; the real tree was only read)');
