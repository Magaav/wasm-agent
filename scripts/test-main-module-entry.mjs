#!/usr/bin/env node
// AN ENTRY GUARD MUST ASK BY REAL PATH, OR A SCRIPT RUN THROUGH A SYMLINK DOES NOTHING AND SAYS IT WORKED.
//
// Measured 24/11 on \`work\` (mission fleet-update-survives-a-slow-relay, G): \`wa update\` from 7865a08e to
// 5bb28d8a pinned the commit and built in \`/tmp/wa-deploy-pins/<sha>\`, a SYMLINK to
// \`/home/agent/.wasm-agent/pins/<sha>\` on that node. scripts/deploy.sh then ran
// \`node /tmp/wa-deploy-pins/<sha>/scripts/codemode-build.mjs build <root>\`, whose guard compared
// \`path.resolve(process.argv[1])\` (which does not resolve symlinks) with
// \`fileURLToPath(import.meta.url)\` (which Node has already canonicalized). They could never match: the
// module loaded, printed NOTHING, ran cargo NEVER and exited 0 - so deploy.sh's \`|| fail\` saw success,
// wa-host.log stayed empty ("compiled 0 crate(s)"), the sentinel built for another 340 s, and the deploy
// died 361 s in with "no built binary at .../release/wa" and no line anywhere saying why.
//
// What this row proves, and it is cheap because it never builds:
//   1. scripts/codemode-build.mjs answers the SAME thing run through a symlinked path as through its real
//      path (this is the case that failed: the symlinked run printed nothing at all);
//   2. no script in this tree carries the fragile idiom any more - the one implementation is
//      scripts/lib/main-module.mjs, so a new script that copies the old line is a red row here instead of
//      a silent install failure months later.
//
//   node scripts/test-main-module-entry.mjs
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let checks = 0;
function check(value, label, detail) {
  checks += 1;
  if (!value) {
    console.error('FAIL ' + label + (detail === undefined ? '' : ' - ' + String(detail)));
    process.exit(1);
  }
  console.log('  ok: ' + label);
}

function run(script, args) {
  const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', cwd: root, timeout: 120000 });
  return { status: result.status, stdout: (result.stdout || '').trim(), stderr: (result.stderr || '').trim() };
}

// ---- 1. the same script, through a real path and through a symlink --------------------------------
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-entry-guard-'));
const link = path.join(scratch, 'linked-root');
fs.symlinkSync(root, link, 'dir');
const script = 'scripts/codemode-build.mjs';
const direct = run(path.join(root, script), ['assets-path', root]);
check(direct.status === 0 && direct.stdout !== '',
  'the build script answers when it is run by its real path', JSON.stringify(direct));
const linked = run(path.join(link, script), ['assets-path', root]);
check(linked.status === 0, 'it exits 0 when it is run through a symlinked path', JSON.stringify(linked));
check(linked.stdout !== '',
  'and it ANSWERS instead of doing nothing (this is the 24/11 failure: empty output, exit 0)', JSON.stringify(linked));
check(linked.stdout === direct.stdout,
  'with the same answer as the real path', JSON.stringify({ direct: direct.stdout, linked: linked.stdout }));
fs.rmSync(scratch, { recursive: true, force: true });

// ---- 2. one implementation, and no copies of the fragile idiom ------------------------------------
const IDIOMS = [
  /path\.resolve\(process\.argv\[1\]\)\s*===?\s*fileURLToPath\(import\.meta\.url\)/,
  /path\.resolve\(process\.argv\[1\]\)\s*===?\s*path\.resolve\(new URL\(import\.meta\.url\)/,
  /pathToFileURL\(path\.resolve\(process\.argv\[1\]\)\)\.href\s*===?\s*import\.meta\.url/,
  /import\.meta\.url\s*===?\s*pathToFileURL\(path\.resolve\(process\.argv\[1\]\)\)\.href/,
];
const offenders = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.mjs') && full !== path.join(root, 'scripts/lib/main-module.mjs')) {
      const text = fs.readFileSync(full, 'utf8');
      if (IDIOMS.some((one) => one.test(text))) offenders.push(path.relative(root, full));
    }
  }
}
walk(path.join(root, 'scripts'));
check(offenders.length === 0,
  'no script compares an unresolved argv[1] with import.meta.url (isMain(import.meta.url) is the one form)',
  offenders.join(', '));
const helper = fs.readFileSync(path.join(root, 'scripts/lib/main-module.mjs'), 'utf8');
check(helper.includes('fs.realpathSync'), 'and the one implementation asks by real path');

console.log('main module entry ok (' + checks + ' checks)');
