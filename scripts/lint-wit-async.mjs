#!/usr/bin/env node
// ASYNC-BORN INTERFACES: every NEW or MOVED WIT interface is async, and a sync export needs a written reason
// (Victor 26/11: "ensure this is an architectural direction enforced on every building evolution").
//
// WHY A LINT AND NOT A MEMORY. ARCHITECTURE.md says a new interface is async by default (a future per result, a
// stream for output and progress); a direction nobody checks is a wish. This is the check: it reads wit/, and it
// refuses by NAME. The toolchain already supports it (wasmtime 50.0.1 + wit-bindgen 0.63.0: async func, stream<T>
// and future<T> all work at our pins - _orch/async-toolchain.md), so there is no reason line to write about the pin.
//
// THE RULE, in the order the checks run:
//   wit_sync_export_needs_reason   a sync export in a file that is NOT grandfathered, without `// sync-export: <why>`
//                                  within the three lines above it
//   wit_sync_grew                  a GRANDFATHERED file whose sync count is above the number recorded for it (a moved
//                                  interface that added a sync export without the reason line)
//   wit_async_without_result       an async export whose signature carries neither future< nor stream< - nothing for
//                                  the caller to await, or nothing that reports progress
//   wit_async_without_backpressure  a file with async exports but no stream< anywhere: streams are what carry
//                                  backpressure, so an async interface without one has not declared it
//   wit_grandfather_unlisted       a file under wit/ with sync exports absent from wit/async-grandfather.txt is NOT an
//                                  error by itself (that IS the rule working); the line exists so the message says so
//
// GRANDFATHERING IS AN EXPLICIT LIST, never a pattern: wit/async-grandfather.txt names each file and the sync count it
// had on the day the rule landed. A file that is not listed is new, and new means async.
//
//   node scripts/lint-wit-async.mjs [--root <dir>] [--json]
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

const args = process.argv.slice(2);
function flag(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const root = flag('--root', process.cwd());
const asJson = args.includes('--json');
const witDir = join(root, 'wit');

if (!existsSync(witDir)) {
  console.error(`wit_missing: ${witDir} has no wit/ directory`);
  process.exit(2);
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(path));
    else if (entry.name.endsWith('.wit')) out.push(path);
  }
  return out.sort();
}

// The grandfather list: `path max_sync why`, comments allowed. A missing file is not an error (a tree with no sync
// exports needs none), but a malformed line is.
const grandfather = new Map();
const listPath = join(witDir, 'async-grandfather.txt');
if (existsSync(listPath)) {
  for (const raw of readFileSync(listPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(\S+)\s+(\d+)\b/);
    if (!m) {
      console.error(`wit_grandfather_unreadable: ${listPath}: ${line}`);
      process.exit(2);
    }
    grandfather.set(m[1], Number(m[2]));
  }
}

// A sync export is `name: func(...)`; an async one is `name: async func(...)`. MEASURED on this tree (27 files): that
// is the shape every interface uses - the `async` sits between the name and `func`, never before the name.
const SYNC = /^\s*([a-z][a-z0-9-]*)\s*:\s*func\b/;
const ASYNC = /^\s*([a-z][a-z0-9-]*)\s*:\s*async\s+func\b/;
const REASON = /^\s*\/\/\s*sync-export\s*:\s*\S/;

const problems = [];
let files = 0, syncTotal = 0, asyncTotal = 0;
for (const path of walk(witDir)) {
  files += 1;
  const rel = relative(root, path);
  const lines = readFileSync(path, 'utf8').split('\n');
  const recorded = grandfather.get(rel);
  let sync = 0, async = 0, hasStream = false;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (/stream\s*</.test(line)) hasStream = true;
    if (ASYNC.test(line)) {
      async += 1;
      // the signature may wrap: look at the declaration line and the two after it
      // THE DECLARATION'S OWN TEXT, not the next three lines: a signature may wrap, but it ends at its `;` - reading
      // on past it made the check pass for the WRONG reason (the next export's stream<> satisfied this one's rule).
      let sig = line;
      for (let k = 1; k < 5 && !sig.trimEnd().endsWith(';'); k += 1) sig += ' ' + (lines[i + k] || '');
      // ONLY FOR A FILE THAT IS NOT GRANDFATHERED: the rule is about NEW or MOVED interfaces. The tree's own async
      // exports (63 of them, in the grandfathered files) use the async ABI - `async func(...) -> result<T, E>` -
      // which the caller awaits; a new interface must ALSO say what it streams and what it hands back as a handle.
      if (recorded === undefined && !/future\s*</.test(sig) && !/stream\s*</.test(sig)) {
        problems.push({ code: 'wit_async_without_result', file: rel, line: i + 1,
          detail: line.trim(), why: 'an async export must carry a future<result> or a stream<progress> - otherwise nothing is awaited' });
      }
      continue;
    }
    if (SYNC.test(line)) {
      sync += 1;
      if (recorded === undefined) {
        const reasonAbove = [lines[i - 1] || '', lines[i - 2] || '', lines[i - 3] || ''].some((l) => REASON.test(l));
        if (!reasonAbove) {
          problems.push({ code: 'wit_sync_export_needs_reason', file: rel, line: i + 1, detail: line.trim(),
            why: 'this file is not grandfathered: a sync export needs `// sync-export: <why>` within the three lines above it' });
        }
      }
    }
  }
  syncTotal += sync;
  asyncTotal += async;
  if (recorded !== undefined && sync > recorded) {
    problems.push({ code: 'wit_sync_grew', file: rel, line: 0,
      detail: `${sync} sync export(s), the list records ${recorded}`,
      why: 'a grandfathered interface may not ADD a sync export: a moved interface is async, or it carries the reason line' });
  }
  if (recorded === undefined && async > 0 && !hasStream) {
    problems.push({ code: 'wit_async_without_backpressure', file: rel, line: 0,
      detail: `${async} async export(s), no stream<`,
      why: 'streams are what carry backpressure: an async interface without one has not declared it' });
  }
}

const summary = { files, sync: syncTotal, async: asyncTotal, grandfathered: grandfather.size, problems: problems.length };
if (asJson) {
  console.log(JSON.stringify({ ...summary, list: problems }, null, 2));
} else {
  for (const p of problems) {
    console.log(`${p.code}: ${p.file}${p.line ? ':' + p.line : ''} - ${p.detail}`);
    console.log(`  ${p.why}`);
  }
  console.log(`wit async lint: ${files} file(s), ${syncTotal} sync export(s), ${asyncTotal} async, ` +
    `${grandfather.size} grandfathered at 27/11, ${problems.length} problem(s)`);
}
process.exit(problems.length === 0 ? 0 : 1);

