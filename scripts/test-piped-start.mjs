#!/usr/bin/env node
// A PIPED `wa chat` SAYS ITS FIRST LINE WITHOUT READING AND HASHING ITS OWN BINARY FIRST.
//
// WHAT WAS MEASURED (23/11, avell, 16 cores, scratch home, release build of the base 2104a4d8).
// `printf 'hi\n' | wa chat --once` answered its first line (`> hi`, the echo of the line it read) 351 ms
// after exec, and 74.4 MiB of what it had read by then was ONE call: `memory.presence_begin` asked
// `host.runtime_info` for its pid and boot tag, and `runtime_info` can only fill its `binary_sha256`
// field by reading and hashing the whole binary (73.9 MiB of release build, 861 MB of debug one) - 66 ms
// of that release start, and 730 ms of a debug one. Nothing printed before that line needs the digest,
// so `host.process_identity` answers the pair alone and the digest is paid only by the caller that wants
// it: after the fix the same start read 0.54 MiB and answered in 274 ms (medians of five, same node).
//
// WHAT THIS ASSERTS, twice, because the two answer different questions:
//
//   1. THE BYTES: what the process had READ when its first line came out (`/proc/<pid>/io` rchar) stays
//      under 48 MiB. This is the discriminating row: the old path reads its whole binary to answer a
//      presence row, in every build and on every platform with /proc - so a base binary fails it and a
//      fixed one passes with a wide margin (74 MiB against 0.54 MiB here).
//   2. THE TIME: the median of five runs' first line, in ms, under BOUND_MS. A bound is a promise, not a
//      detector: it fails on a slow start, and it cannot see a 66 ms difference inside a 250 ms start on
//      a busy machine - that is what row 1 is for.
//
// The timing row is as stable as the speed-board made its rows (scripts/test-start-instant.lua): MEDIAN of
// several runs, no number measured while the machine is above one load unit per core (the row then SKIPs
// with that reason - a load, not the code, and a skip is a named hole rather than a pass), and every
// sample printed so a reader sees the spread.
//
// ISOLATION: a private scratch root outside the operator's ~/.wasm-agent (refused by name otherwise), a
// scratch HOME and ledger per run, an environment built from an allow-list instead of inherited (no
// provider, no vault, no relay, no WA_* from the caller), and the child killed the moment the line it is
// waiting for has arrived - the test never runs a model turn. No fleet node, no network. WASM_AGENT_LUA_ROOT
// is deliberately NOT passed on: a start path is a property of the BINARY a worker runs, so the run under
// test is the binary's own code (with the tree's Lua root set, a row here would grade a mix of the two).
//
// Run: WA_BIN=<wa binary> node scripts/test-piped-start.mjs  (the fast path and scripts/test.sh hand it
// the tree's own binary; without WA_BIN it finds the one PATH or ~/.local/bin offers).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';

const BOUND_MS = 900;          // the promise: a piped chat's first line in under 900 ms
const SAMPLE_BOUND_MS = 2500;  // one single run may pay a hiccup; the median is what row 2 asserts
const RCHAR_BOUND = 48 * 1024 * 1024;  // bytes read before the first line: 78 MB is the old digest alone
const RUNS = 5;

const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.log('SKIP piped-start: no scratch root outside ' + REAL_HOME);
  process.exit(0);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-piped-start-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('FAIL piped-start: refusing to run with HOME inside the real ' + REAL_HOME);
  process.exit(1);
}

let failures = 0;
function check(condition, label) {
  if (condition) { console.log('ok   ' + label); return true; }
  console.log('FAIL ' + label);
  failures += 1;
  return false;
}
// A run leaves nothing behind when it passes, and keeps its scratch when it fails: the ledger and the log
// are what a reader needs then, and a directory nobody can find again is not.
function done(code) {
  if (code === 0) { try { fs.rmSync(WORK, {recursive: true, force: true}); } catch {} }
  else console.log('piped-start: scratch kept for diagnosis: ' + WORK);
  process.exit(code);
}
function skip(reason) { console.log('SKIP piped-start: ' + reason); done(failures > 0 ? 1 : 0); }

// ---- which binary -------------------------------------------------------------------------------
function executable(candidate) {
  if (!candidate) return null;
  try { fs.accessSync(candidate, fs.constants.X_OK); return fs.statSync(candidate).isFile() ? candidate : null; }
  catch { return null; }
}
function findBinary() {
  for (const name of ['WA_BIN', 'WA_TEST_BIN', 'FAST_BIN', 'WA_FAST_BIN']) {
    const found = executable(process.env[name]);
    if (found) return found;
  }
  const ext = process.platform === 'win32' ? '.exe' : '';
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    const found = executable(path.join(dir, 'wa' + ext));
    if (found) return found;
  }
  return executable(path.join(os.homedir(), '.local', 'bin', 'wa' + ext));
}
const BIN = findBinary();
if (!BIN) skip('no wa binary (WA_BIN/WA_TEST_BIN/FAST_BIN, PATH, ~/.local/bin)');

// ---- the machine has to be quiet enough for row 2 ------------------------------------------------
const cores = os.cpus().length || 0;
function quietEnough() {
  const load = os.loadavg()[0];
  if (!cores || !Number.isFinite(load)) return {ok: false, why: 'the machine did not say its load or its cores'};
  return {ok: load <= cores, load, why: `the machine is at load ${load.toFixed(2)} on ${cores} cores (ceiling ${cores}): a timing row cannot tell code from load`};
}
async function waitForQuiet(budgetMs) {
  const deadline = Date.now() + budgetMs;
  let last = quietEnough();
  while (Date.now() < deadline) {
    last = quietEnough();
    if (last.ok) return last;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  return last;
}

// ---- one run: the first line's arrival, and what the process had read by then --------------------
// The child runs `chat --once` with `hi` on a pipe, exactly as a worker does. It is killed the moment its
// first line has arrived, so no model call, no provider and no turn is ever run by this test.
function readRchar(pid) {
  try {
    const text = fs.readFileSync(`/proc/${pid}/io`, 'utf8');
    const found = text.match(/^rchar:\s*(\d+)/m);
    return found ? Number(found[1]) : null;
  } catch { return null; }
}
function oneRun() {
  return new Promise(resolve => {
    const env = {
      PATH: process.env.PATH || '/usr/bin:/bin',
      HOME,
      WASM_AGENT_HOME: HOME,
      TMPDIR: WORK,
      WA_GRAPH_WATCH: '0',
      WASM_AGENT_MANAGED: '0',
      LANG: process.env.LANG || 'C.UTF-8',
    };
    const started = process.hrtime.bigint();
    const child = spawn(BIN, ['chat', '--once'], {env, cwd: WORK, stdio: ['pipe', 'pipe', 'pipe']});
    let out = '';
    let stderr = '';
    let done = false;
    // The child is killed and the answer returned at once: waiting for its own 'exit' would hang the whole
    // test on the one run whose kill raced the event (and a promise nobody resolves exits green with no
    // verdict - the one failure mode a test must not have). Node reaps the child on its own.
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { child.kill('SIGKILL'); } catch {}
      resolve(result);
    };
    const timer = setTimeout(() => finish({ms: -1, line: '', rchar: null, stderr: stderr + '\n(no first line within 30 s)'}), 30000);
    child.stderr.on('data', chunk => { stderr += chunk.toString(); }
    );
    child.stdout.on('data', chunk => {
      if (done) return;
      out += chunk.toString();
      const newline = out.indexOf('\n');
      if (newline < 0) return;
      const ms = Number(process.hrtime.bigint() - started) / 1e6;
      const rchar = readRchar(child.pid);
      finish({ms, line: out.slice(0, newline), rchar, stderr});
    });
    child.on('error', error => finish({ms: -1, line: '', rchar: null, stderr: String(error)}));
    child.stdin.end('hi\n');
  });
}

function median(values) {
  const sorted = values.filter(value => Number.isFinite(value)).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

(async () => {
  console.log(`piped-start: binary ${BIN}`);
  const quiet = await waitForQuiet(60000);
  if (!quiet.ok) skip(quiet.why);

  const runs = [];
  for (let index = 0; index < RUNS; index += 1) runs.push(await oneRun());

  // The measurement is the echo of the line piped in: every run must have produced it, or nothing below
  // is about a piped chat's first line.
  const lines = runs.map(run => run.line);
  if (!check(runs.every(run => run.line === '> hi'), `every run answered its first line as the echo of the piped one (${JSON.stringify(lines)})`)) {
    for (const run of runs) if (run.stderr && run.stderr.trim() !== '') console.log('       stderr: ' + run.stderr.trim().split('\n').slice(0, 3).join(' / '));
  }

  // ---- 1. the bytes the start read ----------------------------------------------------------------
  const rchars = runs.map(run => run.rchar);
  if (rchars.some(value => value === null || !Number.isFinite(value))) {
    // A machine without /proc/<pid>/io cannot answer this row, and an unknown is not a pass.
    console.log('SKIP piped-start: this platform does not say what a process has read (/proc/<pid>/io)');
    console.log('     the timing row below still ran: median ' + median(runs.map(run => run.ms)) + ' ms');
    done(failures > 0 ? 1 : 0);
  }
  const readMedian = median(rchars);
  const MB = value => (value / (1024 * 1024)).toFixed(2) + ' MB';
  console.log(`     bytes read before the first line: ${rchars.map(value => MB(value)).join(', ')} (median ${MB(readMedian)})`);
  check(readMedian < RCHAR_BOUND,
    `the start does not read the binary it runs: median ${MB(readMedian)} read before the first line, under ${MB(RCHAR_BOUND)}`);

  // ---- 2. the first line's time -------------------------------------------------------------------
  const times = runs.map(run => run.ms);
  console.log(`     first line: ${times.map(value => value.toFixed(0) + ' ms').join(', ')}`);
  check(times.every(value => value > 0 && value < SAMPLE_BOUND_MS),
    `every run answered within ${SAMPLE_BOUND_MS} ms (slowest ${Math.max(...times).toFixed(0)} ms)`);
  const firstLineMedian = median(times);
  check(firstLineMedian !== null && firstLineMedian < BOUND_MS,
    `a piped chat's first line arrives in under ${BOUND_MS} ms (median ${firstLineMedian === null ? 'unknown' : firstLineMedian.toFixed(0)} ms)`);

  if (failures > 0) {
    console.log(`piped-start: ${failures} FAIL`);
    done(1);
  }
  console.log('piped-start ok');
  done(0);
})();
