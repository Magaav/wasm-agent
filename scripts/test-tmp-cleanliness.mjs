#!/usr/bin/env node
// A ROW MAY NOT LEAVE ITS SCRATCH IN THE OS TEMP DIRECTORY, AND THE CHECK IS A TEST.
//
// WHY. The runner gives every row a scratch home and a TMPDIR inside ONE parent directory
// (scripts/fast.sh, "THE RUN'S OWN SCRATCH ROOT") and removes that directory on exit, so a row that takes
// its scratch root from the environment it was given is already bounded. A row that roots its scratch at a
// literal /tmp is not: it writes where the runner cannot clean, and what it leaves is one more entry in the
// 16 G tmpfs that filled up three times in one day (23/11; scripts/lib/temp-floor.sh has the measurements).
//
// MEASURED on this node with the real binary, one row at a time, each in its own isolated environment and
// with /tmp diffed afterwards (23/11, avell):
//   scripts/test-changeset.lua            1 entry per run, EVERY run (70 on disk when the round started)
//   scripts/test-agent-control-e2e.cjs    1 entry per run, even when it passes (8 on disk)
//   scripts/test-mission-amend-resume.mjs 1 entry per FAILING run, kept forever (8 on disk)
//   scripts/test-mission-amend.mjs        1 entry per failing run
// Those are what half A's DEFERRED list and half B exist for; half A is what stops the next one.
//
// WHAT IT CHECKS:
//
//   A. STATIC, no binary needed. Every tracked scripts/test-* file that ROOTS a temp family at a literal
//      /tmp fails, unless the environment the runner sets (TMPDIR, GATE_ROOT, WA_TEST_ROOT, os.tmpdir(),
//      host.paths().temp) is asked FIRST on that line, or the file is listed in DEFERRED with a reason AND
//      still removes what it mints. The list is printed on every run and an entry that stops matching is
//      reported `resolved`, so it shrinks instead of rotting - the same shape
//      scripts/check-temp-retention.mjs uses.
//
//   B. DYNAMIC, the row itself. Each file in CLEANED is RUN with TMPDIR pointed at a fresh directory and its
//      own scratch HOME; afterwards that TMPDIR must be EMPTY. A row that keeps what it made has not cleaned
//      up, wherever else it also wrote. These are the rows this change fixed, so the half proves the fix
//      instead of restating it. A machine with no `wa` binary REFUSES (exit 2, named) rather than passing on
//      the half it could check - unknown is not yes.
//
//   C. THE FLOOR IS WIRED (item 4 of the round). main-health, preflight and the fast path must refuse a
//      machine with no room in /tmp BY NAME (`tmp_low`), before they start, instead of going red on a
//      product row. Each is run here with WA_TMP_MIN_FREE_MB set above any machine's free space, so the
//      refusal is the only possible answer, and with nothing else to build or check it costs a second.
//
// Run: node scripts/test-tmp-cleanliness.mjs
//      WA_BIN=<wa> node scripts/test-tmp-cleanliness.mjs     # half B runs the rows with this binary
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const checks = [];
const fail = (label, detail) => checks.push({ ok: false, label: label + (detail ? ': ' + detail : '') });
const pass = label => checks.push({ ok: true, label });

// The environment the runner hands a row. A root taken from one of these is a root the runner deletes.
const ENV_SOURCE = /TMPDIR|GATE_ROOT|WA_TEST_ROOT|WA_FABRIC_BENCH_TMP|os\.tmpdir\(\)|host\.paths\(\)\.temp/;
// THE LITERAL /tmp, not the tail of another path: .wasm-agent/tmp and $work/tmp are the node's own state
// directory, and a detector that counted them would report the rows that assert about it (measured on the
// first run of this file: scripts/test-scratch-home.sh was named for a string in an assertion).
const TMP_LITERAL = /(?<![\w.])\/tmp(?![\w-])/;
// "THIS LINE ROOTS A TEMP FAMILY AT A LITERAL /tmp", as the five shapes that were actually measured in this
// tree. Each needs the literal to be the ROOT of the path, not a segment of a path built from something else
// (`state .. '/tmp/x'` and `$work/tmp/x` are the node's own state directory and are not this).
const ROOTS_AT_TMP = [
  { id: 'mktemp', re: /\bmktemp\s+(?:-[A-Za-z]+\s+)*["']?\/tmp\// },
  { id: 'mkdtemp', re: /\bmkdtemp(?:Sync)?\([^)]{0,160}?["']\/tmp["']/ },
  { id: 'family-literal', re: /["']\/tmp\/[A-Za-z0-9][\w.-]{2,}["']/ },
  { id: 'root-then-family', re: /\(\s*(?:[^()]{0,80}\bor\b\s*)?["']\/tmp["']\s*\)\s*\.\./ },
  { id: 'join-literal', re: /path\.join\(\s*(?:process\.env\.[\w]+\s*\|\|\s*)?["']\/tmp["']\s*,/ },
  // A bare '/tmp' that is then joined onto a family: (os.getenv(...) or "/tmp") .. "/wa-x-" and
  // '/tmp' + '/wa-x-'. The first detector missed exactly this one, which is the leak this round started
  // from - measured on the base commit: half A passed there while the row was minting in /tmp every run.
  { id: 'bare-tmp-root', re: /["']\/tmp["']\s*\)?\s*(?:\.\.|\+)\s*["']\/[A-Za-z0-9]/ },
];
// A path under /tmp named as a VALUE is not a mint: a fixture the row refuses, a path in an assertion, an
// argument to a function under test. Only the line that CREATES it counts.
const CREATES = /\b(mktemp|mkdtemp|mkdir|write_file|writeFileSync|append_file|io\.open|:open\(\s*|cp\s|touch\s|open\()/;

// Files that already root a temp family at /tmp and clean up after themselves. Each is named with the
// removal that bounds it: a file that stops removing is a leak, so the removal is checked, not assumed.
// Each of these mints ONE directory (or database) directly under /tmp and removes it on exit (the removal
// is checked below, not assumed), so it leaks nothing - what it does not do is live under the single parent
// scratch dir the runner owns, which is the other half of this round and a change to nine gate rows this
// delivery did not run. They are named here so the next file that does it fails review instead of adding a
// tenth.
const DEFERRED_WHY = 'TMPDIR-ising it is the remaining fix: today it mints under the literal /tmp and removes it on exit';
const DEFERRED = [
  'scripts/test-append-race.sh',
  'scripts/test-behavior.sh',
  'scripts/test-foreground-cancel.sh',
  'scripts/test-health-build-label.sh',
  'scripts/test-run-isolation.sh',
  'scripts/test-serve-concurrency.sh',
  'scripts/test-update.sh',
  'scripts/test-upgrade-idle.sh',
  'scripts/test-upgrade-ui-fonts.sh',
];

function trackedTests() {
  const out = execFileSync('git', ['ls-files', '-z', 'scripts'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return out.split('\0').filter(f => /^scripts\/(?:lib\/)?test-[^/]*\.(?:lua|mjs|cjs|sh|ps1)$/.test(f));
}

const REMOVES = [
  /\brm\s+-[rRf]/, /fs\.rmSync\s*\(/, /fs\.rm\s*\(/, /rmdirSync\s*\(/, /shutil\.rmtree/,
  /Remove-Item/, /trap\s+[^\n]*\brm\b/, /host\.exec\s*\(\s*["'][^"']*rm -rf/,
];

function staticScan() {
  const allowed = new Map(DEFERRED.map(file => [file, true]));
  const seen = new Set();
  let offenders = 0;
  const files = trackedTests();
  for (const file of files) {
    const full = path.join(root, file);
    if (!fs.existsSync(full)) continue;
    const text = fs.readFileSync(full, 'utf8');
    const lines = text.split('\n');
    let hit = null;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (/^\s*(#|\/\/|--)/.test(line)) continue;              // a comment is prose, not a mint
      const shape = ROOTS_AT_TMP.find(s => s.re.test(line));
      const envAt = line.search(ENV_SOURCE);
      const tmpAt = line.search(TMP_LITERAL);
      // RULE B, and it is the shape the leaf cause takes: a literal '/tmp' PREFERRED over the environment
      // the runner sets (fs.existsSync('/tmp') ? '/tmp' : os.tmpdir()). It reads like a fallback and is a
      // preference - measured on the base commit in three rows, one of which wrote there even when green.
      const prefersLiteral = tmpAt >= 0 && envAt > tmpAt;
      if (!shape && !prefersLiteral) continue;
      if (shape && !CREATES.test(line)) continue;               // named, not made: a fixture or an assertion
      if (envAt >= 0 && envAt < tmpAt) continue;                // the runner's environment is asked FIRST
      // A literal that follows a concatenation is a SUFFIX of a path built from something else
      // (root .. "/tmp/x" is the node's own state directory), never the root of a temp family.
      if (!prefersLiteral && /\.\.\s*$|\+\s*$/.test(line.slice(0, tmpAt))) continue;
      hit = { line: i + 1, shape: shape ? shape.id : 'literal-before-environment', text: line.trim().slice(0, 150) };
      break;
    }
    if (!hit) continue;
    if (allowed.has(file)) {
      seen.add(file);
      if (!REMOVES.some(re => re.test(text))) {
        offenders++;
        fail(`${file}:${hit.line} is listed as cleaning up after itself but no removal is in the file`,
          'a DEFERRED entry without its removal is a leak with a note attached');
      }
      continue;
    }
    offenders++;
    fail(`${file}:${hit.line} roots its scratch at a literal /tmp (${hit.shape})`,
      `${hit.text}\n           take the root from TMPDIR/GATE_ROOT (the runner sets both), remove what you made, or add the\n           file to DEFERRED with the reason`);
  }
  if (!offenders) pass(`no scripts/test-* file roots a temp family at a literal /tmp without the runner's environment (${files.length} files scanned)`);
  for (const file of DEFERRED) if (!seen.has(file)) console.log(`  resolved  ${file} no longer roots a temp family at /tmp - delete its DEFERRED entry`);
}

// The rows half B runs: the ones this change fixed, so a regression fails here.
const CLEANED = ['scripts/test-changeset.lua', 'scripts/test-environment-notes.lua'];

function dynamicScan() {
  const bin = process.env.WA_BIN || process.env.WA_FAST_BIN || '';
  if (!bin || !fs.existsSync(bin)) {
    fail('the rows could not be run, so their cleanup was not judged', 'no wa binary: pass WA_BIN=<wa>');
    return 1;
  }
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-tmp-cleanliness-'));
  try {
    for (const row of CLEANED) {
      const tmp = path.join(work, 'tmp-' + path.basename(row));
      const home = path.join(work, 'home-' + path.basename(row));
      fs.mkdirSync(tmp, { recursive: true });
      fs.mkdirSync(home, { recursive: true });
      const env = {
        PATH: process.env.PATH,
        HOME: home,
        WASM_AGENT_HOME: home,
        WASM_AGENT_LUA_ROOT: root,
        WASM_AGENT_MANAGED: '0',
        WA_SCRIPT: row,
        TMPDIR: tmp,
        GATE_ROOT: work,
        WA_FAST_BIN: bin,
      };
      const r = spawnSync(bin, ['--db', path.join(home, 't.db')], { cwd: root, env, encoding: 'utf8', timeout: 180000 });
      if (r.status !== 0) {
        fail(`${row} did not pass, so its cleanup could not be judged`,
          `exit ${r.status}: ${(r.stderr || r.stdout || '').trim().split('\n').slice(-2).join(' | ').slice(0, 200)}`);
        continue;
      }
      const left = fs.readdirSync(tmp);
      if (left.length) {
        fail(`${row} left ${left.length} entr${left.length === 1 ? 'y' : 'ies'} in the TMPDIR it was given`,
          `${left.slice(0, 5).join(', ')} - a row removes its scratch on exit, pass or fail`);
        continue;
      }
      pass(`${row} removed the scratch it made under the TMPDIR it was given`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  return 0;
}

// The three entry points that must refuse a full machine by name, before they start anything.
//
// EACH ONE IS ALSO GIVEN A SECOND, BROKEN PREREQUISITE, and the assertion is that the floor is what refuses.
// Two reasons, both measured-shaped: it proves the floor comes FIRST (once it refuses, nothing else runs -
// which is the whole claim), and it keeps this test cheap on a tree that has no floor check, because the
// only thing such a tree can do with these commands is refuse the other prerequisite in a second. Without
// it, half C would run a whole health run or a whole gate in the very gate that is running this file.
const FLOOR_WIRED = [
  { name: 'main-health', cmd: ['bash', 'scripts/main-health.sh'], expect: /main-health: refused\(tmp_low\)/,
    broken: { WA_MAIN_HEALTH_REPO: '/nonexistent-repo-for-the-floor-check' },
    because: 'the repo does not exist, so without a floor check this refuses no_repo' },
  { name: 'preflight', cmd: ['bash', 'scripts/preflight.sh', 'demo'], expect: /preflight: refused\(tmp_low\)/,
    broken: { WA_PYTHON: '/nonexistent-python-for-the-floor-check' }, mission: true,
    because: 'the interpreter does not exist, so without a floor check this refuses python_missing' },
  { name: 'fast', cmd: ['bash', 'scripts/fast.sh'], expect: /fast: refused\(tmp_low\)/,
    broken: {}, home: true,
    because: 'the build record below names a key no build reads, so without a floor check this refuses in a second' },
];

function floorScan() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-tmp-floor-'));
  try {
    fs.mkdirSync(path.join(work, 'missions', 'demo'), { recursive: true });
    for (const entry of FLOOR_WIRED) {
      const env = Object.assign({}, process.env, { WA_TMP_MIN_FREE_MB: '999999999' }, entry.broken);
      if (entry.mission) env.WA_MISSIONS_ROOT = path.join(work, 'missions');
      if (entry.home) {
        // A scratch home whose build record names a key no build reads: the fast path refuses that in a
        // second (measured on the base commit), which is what keeps this half cheap on a tree without a
        // floor check. On a tree WITH one, the floor is asked first and this is never reached.
        env.WASM_AGENT_HOME = path.join(work, 'fast-home');
        fs.mkdirSync(path.join(env.WASM_AGENT_HOME, '.wasm-agent'), { recursive: true });
        fs.writeFileSync(path.join(env.WASM_AGENT_HOME, '.wasm-agent', 'build.env'), 'WA_BUILD_NOT_A_KEY=1\n');
      }
      const r = spawnSync(entry.cmd[0], entry.cmd.slice(1), { cwd: root, env, encoding: 'utf8', timeout: 120000 });
      const out = (r.stdout || '') + (r.stderr || '');
      if (r.status !== 2 || !entry.expect.test(out)) {
        fail(`${entry.name} did not refuse a machine with no room in /tmp by name`,
          `exit ${r.status}, expected 2 and ${entry.expect}: ${out.trim().split('\n').slice(-2).join(' | ').slice(0, 240)}`);
        continue;
      }
      pass(`${entry.name} refuses a machine with no room in /tmp by name (tmp_low), before it starts`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

console.log('test-tmp-cleanliness: a row cleans up after itself, never mints under a literal /tmp, and the suite refuses a full machine');
staticScan();
dynamicScan();
floorScan();
for (const c of checks) console.log(`  ${c.ok ? 'ok  ' : 'FAIL'} - ${c.label}`);
const failedRows = checks.filter(c => !c.ok).length;
console.log(`test-tmp-cleanliness: ${failedRows ? 'FAIL' : 'PASS'} (${checks.length} checks${failedRows ? ', ' + failedRows + ' failed' : ''})`);
process.exitCode = failedRows ? 1 : 0;
