#!/usr/bin/env node
// THE INVENTORY STAYS AN INVENTORY (Fable 27/11, docs/missions/reports/seam-inventory.md).
//
// The async law failed silently once already: a WhatsApp read crossed a `wa_queue` job with a private 2 000 ms wait in
// `rust/wa-whatsapp-index/src/lib.rs`, and nothing looked, because the async lint reads `wit/` only. This row is the
// look: it derives the facts from the TREE and requires each one to be named in the inventory, so a new private wait
// or a new non-WIT crossing cannot appear without a row saying what it is.
//
// It fails on the tree BEFORE the inventory existed (no report -> one named refusal), and on any tree where one of
// these facts is unlisted.
//
//   node scripts/test-seam-inventory.mjs [--report <path>]
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const reportAt = argv.includes('--report') ? argv[argv.indexOf('--report') + 1] : path.join(REPO, 'docs', 'missions', 'reports', 'seam-inventory.md');
// The shared wait, in one place (lua/core/codemode_pending.lua): 60 s default, 300 s max, then a pending handle.
const SHARED_WAIT_MS = 60_000;

const failures = [];
const fail = line => failures.push(line);

if (!fs.existsSync(reportAt)) {
  console.error(`FAIL the seam inventory is missing (${reportAt}): a boundary nobody wrote down is a boundary nobody can move`);
  process.exit(1);
}
const report = fs.readFileSync(reportAt, 'utf8');
const named = line => report.includes(line);

// 1. EVERY PRIVATE WAIT BELOW THE SHARED DEFAULT MUST BE NAMED, with its file and its number.
const crates = fs.readdirSync(path.join(REPO, 'rust'), {withFileTypes: true}).filter(e => e.isDirectory() && e.name.startsWith('wa-')).map(e => path.join('rust', e.name));
const waitPattern = /(?:pub )?const ([A-Z][A-Z0-9_]*(?:WAIT_MS|FRESH_MS|_TIMEOUT_MS|_TIMEOUT_S))\s*:\s*u64\s*=\s*([0-9_]+)/g;
let waits = 0;
for (const crate of crates) {
  const src = path.join(REPO, crate, 'src');
  if (!fs.existsSync(src)) continue;
  for (const file of fs.readdirSync(src).filter(f => f.endsWith('.rs'))) {
    const where = path.posix.join(crate, 'src', file);
    const text = fs.readFileSync(path.join(REPO, where), 'utf8');
    for (const match of text.matchAll(waitPattern)) {
      const [, name, raw] = match;
      const value = Number(raw.replaceAll('_', ''));
      const ms = name.endsWith('_TIMEOUT_S') ? value * 1000 : value;
      if (!(ms < SHARED_WAIT_MS)) continue;
      waits += 1;
      if (!named(where)) fail(`private wait ${name} = ${ms} ms in ${where} is below the shared ${SHARED_WAIT_MS} ms and the inventory does not name that file`);
    }
  }
}

// 2. EVERY CRATE THAT CROSSES A QUEUE OR A SOCKET MUST BE NAMED (a row, or the KEEP list).
const crossings = [];
for (const crate of crates) {
  const src = path.join(REPO, crate, 'src');
  if (!fs.existsSync(src)) continue;
  for (const file of fs.readdirSync(src).filter(f => f.endsWith('.rs'))) {
    const text = fs.readFileSync(path.join(src, file), 'utf8');
    if (/EnqueueRequest|UnixStream/.test(text)) { crossings.push(crate); break; }
  }
}
for (const crate of crossings) {
  // The inventory names a crate the way a reader does (`wa-fabric`), not by its path, so the check accepts either.
  if (!named(crate) && !named(path.basename(crate))) fail(`the boundary in ${crate}/ (a queue or a socket) is not in the inventory`);
}

// 3. AT LEAST ONE KEEP WITH ITS REASON, so the inventory is a judgement and not a list of intentions.
if (!/\*\*KEEP\*\*/.test(report)) fail('the inventory carries no KEEP verdict: every boundary either moves or says why it stays');

if (failures.length) {
  for (const line of failures) console.error(`FAIL ${line}`);
  process.exit(1);
}
console.log(`seam inventory ok (${waits} private wait(s) below ${SHARED_WAIT_MS} ms and ${crossings.length} queue/socket boundary(ies), each named in ${path.relative(REPO, reportAt)})`);

