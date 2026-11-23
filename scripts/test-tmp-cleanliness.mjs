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
import { execFileSync, spawn, spawnSync } from 'node:child_process';
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

// ---------------------------------------------------------------------------------------------------
// D. A SERVER AND A SLEEP DIE WITH THE PROCESS THAT STARTED THEM.
//
// Two leaks measured on this node on 23/11, both from rows that had already passed:
//
//   * `tmux -L wa-run-live-1304985` was alive 41 HOURS after its parent died, holding a session called
//     'live' and a running `wa --db .../wa-run-live-PNgegf/ledger.db`. The parent was killed outright, so
//     the row's `finally` never ran - and there were also 1,340 `wa-*` socket FILES with no server behind
//     them, one per killed row since whenever. D1 keeps every pty row on the one helper that handles both
//     (`scripts/lib/tmux-session.mjs`) and D2 kills one the way the machine did and requires it to be gone;
//   * 108 orphaned `sleep 21600` processes, parent systemd --user, in batches of six - one batch per mission
//     launch. `lua/core/mission.lua` started its timeout watchdog as `( sleep 21600; kill ... ) &`, and
//     `kill $watchdog` kills the subshell, never the sleep inside it, so every launch that ended normally
//     left one behind. D3 RUNS that block out of the shipped file the way the runner does.

// D1: every pty row that starts a tmux server goes through the helper, because the helper is the thing that
// carries the exit handlers and the reclaim. A row that starts its own server is the 41-hour leak again.
function ptyRowsScan() {
  const files = trackedTests().filter(f => /^scripts\/test-.*-pty\.mjs$/.test(f));
  const off = files.filter(file => {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    if (!/new-session/.test(text)) return false;
    return !/from '\.\/lib\/tmux-session\.mjs'/.test(text);
  });
  for (const file of off) fail(`${file} starts a tmux server without scripts/lib/tmux-session.mjs`,
    'the helper kills the server on every exit path and reclaims one left by a SIGKILLed sibling');
  if (!off.length) pass(`every pty row that starts a tmux server does it through the helper (${files.length} files scanned)`);
}

// D2: the SIGKILL path. A child starts a server through the helper and is killed with SIGKILL - nothing in it
// can run, which is exactly what happened - and the next process that asks for a session must reclaim it.
function tmuxKillProbe() {
  const helper = path.join(root, 'scripts', 'lib', 'tmux-session.mjs');
  if (!fs.existsSync(helper)) { fail('scripts/lib/tmux-session.mjs is absent, so no server is reclaimed', 'unknown is not yes'); return; }
  if (spawnSync('tmux', ['-V'], { encoding: 'utf8' }).status !== 0) {
    pass('tmux is not installed here, so no tmux server can leak on this machine');
    return;
  }
  // THE CHILD NAMES ITS SOCKET IN A FILE, not on stdout: this process waits synchronously (the leak it is
  // measuring is worth a 20 s bound), and a synchronous loop never turns the event loop that would deliver a
  // stdout chunk - measured on the first run of this probe: 'the probe child never named its tmux socket'.
  const named = path.join(os.tmpdir(), 'wa-sigkill-probe-' + process.pid + '.name');
  try { fs.rmSync(named, { force: true }); } catch {}
  const childCode = [
    "import(" + JSON.stringify(helper) + ").then(({tmuxSession}) => {",
    "  const {SOCKET, tmux} = tmuxSession('wa-sigkill-probe');",
    "  tmux(['new-session', '-d', '-s', 'probe', 'sleep 60']);",
    "  require('node:fs').writeFileSync(" + JSON.stringify(named) + ", SOCKET);",
    '  setInterval(() => {}, 1000);',
    '});',
  ].join('\n');
  const child = spawn(process.execPath, ['-e', childCode], { stdio: 'ignore' });
  const deadline = Date.now() + 20000;
  let socket = '';
  while (Date.now() < deadline) {
    try { socket = fs.readFileSync(named, 'utf8').trim(); } catch {}
    if (socket) break;
    spawnSync('sleep', ['0.1']);
  }
  const name = socket;
  if (!name) {
    child.kill('SIGKILL');
    fail('the probe child never named its tmux socket, so the kill path was not measured', 'no socket name on stdout');
    return;
  }
  child.kill('SIGKILL');
  spawnSync('sleep', ['0.5']);
  const dir = path.join(process.env.TMUX_TMPDIR || '/tmp', 'tmux-' + String(os.userInfo().uid));
  const left = fs.existsSync(path.join(dir, name));
  if (!left) {
    fail(`the SIGKILLed child left no socket (${name}), so the reclaim was not measured`,
      'the probe proves nothing if the leak it kills cannot be made');
    return;
  }
  // THE SHIPPED RECLAIM, run in a child process: this file waits synchronously, and the rule being judged is
  // scripts/lib/tmux-session.mjs's, not a copy of it.
  const count = path.join(os.tmpdir(), 'wa-sigkill-probe-' + process.pid + '.count');
  try { fs.rmSync(count, { force: true }); } catch {}
  spawnSync(process.execPath, ['-e', [
    "import(" + JSON.stringify(helper) + ").then(m => {",
    "  require('node:fs').writeFileSync(" + JSON.stringify(count) + ", String(m.reclaimStaleServers().length));",
    '});',
  ].join('\n')], { encoding: 'utf8', timeout: 60000 });
  let reclaimed = 0;
  try { reclaimed = Number(fs.readFileSync(count, 'utf8')); } catch {}
  if (fs.existsSync(path.join(dir, name))) {
    fail(`${name} survived a SIGKILLed owner and the reclaim did not remove it`,
      'this is the 41-hour server: tmux-session.mjs reclaimStaleServers() must kill it');
    return;
  }
  pass(`a tmux server whose owner was SIGKILLed (${name}) is reclaimed by the next session (${reclaimed} socket(s) removed)`);
}

// D3: the mission runner's timeout watchdog, run out of the shipped file. The runner kills the watchdog on its
// normal path; what must not survive that kill is a sleep the length of the deadline.
function watchdogProbe() {
  const source = fs.readFileSync(path.join(root, 'lua', 'core', 'mission.lua'), 'utf8');
  const at = source.indexOf('TIMEOUT: signals the CLI pid');
  const endMark = '>/dev/null 2>&1 &';
  const end = source.indexOf(endMark, at);
  // THE BLOCK STARTS AT THE LINE THAT OPENS IT, not at the first '(' after the comment: the comment above it
  // quotes `$(bash run.sh)`, so a search for '(' found that one - measured: the probe then ran a fragment of
  // prose and reported a pass it had not earned, on the base tree where the leak is certain.
  const opened = Math.max(source.lastIndexOf('\n( ', end), source.lastIndexOf('\n  ( ', end));
  if (at < 0 || end < 0 || opened < 0) {
    fail('the timeout watchdog could not be found in lua/core/mission.lua', 'the shape this check knows is gone');
    return;
  }
  const block = source.slice(opened + 1, end + endMark.length);
  const before = longSleeps();
  const script = [
    'cli=$$',
    'wa_deadline=${MISSION_TIMEOUT_SECONDS:-21600}',
    block,
    'watchdog=$!',
    'sleep 1',
    'kill "$watchdog" 2>/dev/null',   // what the runner does when the CLI exits normally
    'sleep 2',
  ].join('\n');
  spawnSync('bash', ['-c', script], { encoding: 'utf8', timeout: 60000 });
  const after = longSleeps();
  const leaked = [...after].filter(pid => !before.has(pid));
  if (leaked.length) {
    fail(`the mission runner's watchdog left ${leaked.length} long sleep(s) behind on its normal exit`,
      'pids ' + leaked.join(', ') + ' - kill $watchdog ends the subshell, never the sleep inside it: count the deadline in short steps (lua/core/mission.lua)');
    for (const pid of leaked) { try { process.kill(pid, 'SIGKILL'); } catch {} }
    return;
  }
  pass('the mission runner leaves no long sleep behind when its watchdog is killed the way the runner kills it');
}

// Every sleep whose argument is 10 minutes or more, by pid: a deadline that outlives its process would be a
// sleep this long, and a fixture's own short sleep is not a leak.
function longSleeps() {
  const ps = spawnSync('ps', ['-eo', 'pid=,args='], { encoding: 'utf8' });
  const pids = new Set();
  for (const line of String(ps.stdout || '').split('\n')) {
    const match = /^\s*(\d+)\s+sleep\s+(\d+)\s*$/.exec(line);
    if (!match) continue;
    if (Number(match[2]) >= 600) pids.add(Number(match[1]));
  }
  return pids;
}

console.log('test-tmp-cleanliness: a row cleans up after itself, never mints under a literal /tmp, and the suite refuses a full machine');
staticScan();
dynamicScan();
floorScan();
ptyRowsScan();
tmuxKillProbe();
watchdogProbe();
for (const c of checks) console.log(`  ${c.ok ? 'ok  ' : 'FAIL'} - ${c.label}`);
const failedRows = checks.filter(c => !c.ok).length;
console.log(`test-tmp-cleanliness: ${failedRows ? 'FAIL' : 'PASS'} (${checks.length} checks${failedRows ? ', ' + failedRows + ' failed' : ''})`);
process.exitCode = failedRows ? 1 : 0;
