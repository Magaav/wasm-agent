#!/usr/bin/env node
// The orphaned-test ledger.
//
// Measured 2026-11-11: 237 JavaScript test scripts live in `scripts/`, and 45 of them were named by no
// harness at all - so they could rot (and two WhatsApp operator tests did) while every gate stayed green.
// A test nobody runs is not coverage; it is a claim with no witness.
//
// The rule this check enforces is deliberately mechanical: a JS/CJS test is WIRED when its own file name
// appears in another script, skill, workflow or the root documents (the harnesses name their rows that
// way: `scripts/fast.sh`, `scripts/test.sh`, `scripts/wave-release.mjs`), and ORPHANED otherwise.
//
//   * an orphaned script must be declared in `scripts/test-orphans.json` with the reason it is not wired;
//   * a declared entry whose file is gone is a failure (delete the entry);
//   * a declared entry that has become wired is a failure too: the list only shrinks, because the fix
//     for an orphan is to wire it or to delete it with its subject - not to keep it declared forever.
//
// Exit codes: 0 the ledger matches the tree; 1 it does not; 2 unreadable input.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const INVENTORY = 'scripts/test-orphans.json';
const CHECKER = 'scripts/test-orphan-tests.mjs';
const TEST_FILE = /^test[-.].*\.(mjs|cjs|js)$/;
const SCAN_DIRS = ['scripts', 'skills', '.github'];
const SCAN_FILES = ['package.json', 'AGENTS.md', 'DESIGN.md'];
const SCAN_EXT = /\.(sh|mjs|cjs|js|lua|ps1|json|yml|yaml|md)$/;

const tests = fs.readdirSync(path.join(root, 'scripts')).filter(name => TEST_FILE.test(name)).sort();
assert(tests.length > 0, 'no test scripts found; wrong root?');

const named = new Set();
function scan(rel) {
  let text = '';
  try { text = fs.readFileSync(path.join(root, rel), 'utf8'); } catch { return; }
  for (const name of tests) {
    if (name === path.basename(rel)) continue;
    if (text.includes(name)) named.add(name);
  }
}
function walk(rel) {
  const full = path.join(root, rel);
  let entries;
  try { entries = fs.readdirSync(full, {withFileTypes: true}); } catch { return; }
  for (const entry of entries) {
    const child = `${rel}/${entry.name}`;
    if (entry.isDirectory()) {
      if (/^(node_modules|\.git|target|build)$/.test(entry.name)) continue;
      walk(child);
    } else if (SCAN_EXT.test(entry.name) && child !== INVENTORY && child !== CHECKER) {
      scan(child);
    }
  }
}
for (const dir of SCAN_DIRS) if (fs.existsSync(path.join(root, dir))) walk(dir);
for (const file of SCAN_FILES) if (fs.existsSync(path.join(root, file))) scan(file);

const orphans = tests.filter(name => !named.has(name));
let declared;
try {
  declared = JSON.parse(fs.readFileSync(path.join(root, INVENTORY), 'utf8')).entries || [];
} catch (error) {
  console.error(`orphan-tests: cannot read ${INVENTORY}: ${error.message}`);
  process.exit(2);
}
const declaredFiles = declared.map(entry => path.basename(String(entry.file || '')));
const failures = [];
for (const entry of declared) {
  const file = String(entry.file || '');
  const name = path.basename(file);
  if (!TEST_FILE.test(name)) failures.push(`${file}: not a JavaScript test script`);
  if (!String(entry.reason || '').trim() || String(entry.reason).trim().length < 20) failures.push(`${file}: needs a reason (one sentence, at least 20 characters)`);
  if (!fs.existsSync(path.join(root, file))) failures.push(`${file}: declared, but the file is gone - delete the entry`);
  if (named.has(name)) failures.push(`${file}: declared orphaned, but a harness now names it - delete the entry (the list only shrinks)`);
}
if (new Set(declaredFiles).size !== declaredFiles.length) failures.push(`${INVENTORY}: duplicate entries`);
for (const name of orphans) {
  if (!declaredFiles.includes(name)) failures.push(`scripts/${name}: orphaned and not declared in ${INVENTORY} - wire it into a harness or declare why not`);
}

const wired = tests.length - orphans.length;
if (failures.length) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  console.error(`orphan-tests: FAIL (${wired} wired, ${orphans.length} orphaned, ${declared.length} declared)`);
  process.exit(1);
}
console.log(`orphan-tests ok (${wired} wired, ${orphans.length} orphaned and declared with a reason)`);
