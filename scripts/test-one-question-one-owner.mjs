#!/usr/bin/env node
// one question, one owner - the row (ARCHITECTURE.md law 17).
// The second table of docs/missions/reports/seam-inventory.md says, for each question, the ONE place that answers it and
// every second answer found so far. This row derives the second answers from the tree and refuses to pass when one of them
// is not in that table: a constant that answers a question the table already gives an owner (whether or not it agrees
// with that owner today) fails by name, with the file it lives in.
import fs from 'node:fs';
import path from 'node:path';

const report = process.argv.includes('--report')
  ? process.argv[process.argv.indexOf('--report') + 1]
  : 'docs/missions/reports/seam-inventory.md';
if (!fs.existsSync(report)) {
  console.error(`one question one owner: no table - ${report} does not exist, so no question has a stated owner`);
  process.exit(1);
}
const text = fs.readFileSync(report, 'utf8');
const section = text.split('## The second table')[1];
if (!section) {
  console.error(`one question one owner: ${report} has no "## The second table" section`);
  process.exit(1);
}

const fail = [];
// A. every owner the table names must exist, and a named constant must be found in it.
const ownerCells = [...section.matchAll(/^\|([^|]+)\|([^|]+)\|/gm)]
  .filter((m) => !/^-+$/.test(m[1].trim()) && m[1].trim() !== 'question')
  .map((m) => m[2]);
if (ownerCells.length < 2) fail.push('the table has no rows (a question with its owner, a duplicate, where it is merged)');
for (const cell of ownerCells) {
  const file = (cell.match(/`([^`]+?\.(?:lua|rs|sh|mjs))(?::[^`]*)?`/) || [])[1];
  if (!file) continue;
  if (!fs.existsSync(file)) fail.push(`the table names an owner that does not exist: ${file}`);
  const consts = [...cell.matchAll(/`([A-Z][A-Z0-9_]*_S)`/g)].map((m) => m[1]);
  if (fs.existsSync(file)) {
    const body = fs.readFileSync(file, 'utf8');
    for (const c of consts) if (!body.includes(c)) fail.push(`the owner ${file} does not define ${c}, which the table claims it owns`);
  }
}
// B. every private wait constant in the tree must be named in the table (as a duplicate or as a KEEP with its reason).
const ROOTS = ['rust', 'lua', 'scripts'];
const NAME = /\b[A-Z][A-Z0-9_]*(?:WAIT_MS|_TIMEOUT_MS|_TIMEOUT_S)\b/g;
function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === 'target' || e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (/\.(rs|lua|mjs|sh)$/.test(e.name)) out.push(p);
  }
  return out;
}
const seen = new Map();
for (const f of ROOTS.flatMap((r) => walk(r))) {
  // The owners are not their own duplicates: the wait budget's module, and the crate that owns how long a
  // component call may wait (rust/wa-component-wait, law 17).
  if (f === 'lua/core/codemode_pending.lua' || f.startsWith('rust/wa-component-wait/')) continue;
  let body;
  try { body = fs.readFileSync(f, 'utf8'); } catch { continue; }
  for (const m of body.matchAll(NAME)) {
    // A call site that NAMES the owner (wa_component_wait::DEFAULT_WAIT_MS) is the owner being called, not a
    // second answer to its question.
    if (body.slice(Math.max(0, m.index - 20), m.index).includes('wa_component_wait::')) continue;
    if (!seen.has(m[0])) seen.set(m[0], f);
  }
}
for (const [name, file] of seen) {
  if (!section.includes(name)) fail.push(`a second answer to a question that already has an owner: ${name} (${file}) is not in the table`);
}
// C. a table that never says KEEP or ALREADY ONE is a list of bugs, not a resolved inventory.
if (!/KEEP:/.test(section)) fail.push('the table carries no KEEP with its reason - every second answer needs a merge or a stated exception');
if (!/ALREADY ONE/.test(section)) fail.push('the table carries no ALREADY ONE row - the law also has to show what a clean answer looks like');

if (fail.length) {
  console.error('one question one owner: FAIL');
  for (const f of fail) console.error('  ' + f);
  process.exit(1);
}
console.log(`one question one owner ok (${ownerCells.length} question(s), each with one named owner; ${seen.size} private wait constant(s) in the tree, each named as a duplicate or a KEEP with its reason)`);
