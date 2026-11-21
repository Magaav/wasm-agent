#!/usr/bin/env node
// Rule 2 (heat): one heavy build at a time on this node, a bounded default job count, and the lock is the
// WAIT's - never a child's.
//
// The day this answers for (20/11): a land gate, a mission's fast.sh and a developer's build each started
// a 16-job cargo at the same time. Load average 105 on 16 cores, CPU at 95 C, timing rows failing at
// random. Measured on this node for the job cap (cold wa-host release, 21/11): 6 jobs 144 s, 10 jobs
// 136 s, 16 jobs 132 s - so ten is within 3% of sixteen and leaves half the cores free.
//
// Proven here, against the real functions:
//   1. two builds on this node do not run at the same time - the second WAITS, and says how long;
//   2. the lock belongs to the wait: a grandchild a build leaves behind does NOT hold it (that is the
//      20/11 -o incident, and this row goes red if -o is dropped);
//   3. a nested build does not deadlock (a build script that runs cargo);
//   4. the job cap: the caller's CARGO_BUILD_JOBS always wins, the default is used otherwise;
//   5. a command that is not cargo is never put behind the build lock.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const RESOLVER = path.join(REPO, 'scripts', 'lib', 'build-target.sh');
const WORK = fs.mkdtempSync(path.join(process.env.WA_SEED_SCRATCH || os.homedir(), 'wa-heat-'));
const HOME = path.join(WORK, 'home');
const ROOT = path.join(HOME, '.wasm-agent');
const LOCK = path.join(ROOT, 'build', 'build.lock');
fs.mkdirSync(path.join(ROOT, 'build', 'target'), {recursive: true});
if (HOME === path.join(os.homedir(), '.wasm-agent')) throw new Error('refusing to run against a real home');

let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) {
    console.error('build-heat: assert failed - ' + name + (detail ? ': ' + detail : ''));
    process.exitCode = 1;
    throw new Error('check failed: ' + name);
  }
  passed += 1;
  console.log('ok - ' + name);
}
const ENV = {...process.env, WASM_AGENT_HOME: HOME};
delete ENV.CARGO_BUILD_JOBS;
delete ENV.WA_BUILD_JOBS_DEFAULT;
delete ENV.WA_BUILD_HOST_LOCK_HELD;
const bash = (script, extraEnv = {}) => spawnSync('bash', ['-c', script], {
  encoding: 'utf8', env: {...ENV, ...extraEnv}, timeout: 120000,
});
const say = (r) => String(r.stdout || '') + String(r.stderr || '');
const free = () => spawnSync('flock', ['-n', LOCK, 'true'], {encoding: 'utf8'}).status === 0;

// ---- 4. the job cap ---------------------------------------------------------------------------------
{
  check('no caller value: the default is used',
    bash('. "' + RESOLVER + '"; wa_build_jobs').stdout.trim() === '10');
  check('WA_BUILD_JOBS_DEFAULT moves the default',
    bash('. "' + RESOLVER + '"; wa_build_jobs', {WA_BUILD_JOBS_DEFAULT: '4'}).stdout.trim() === '4');
  check("the caller's CARGO_BUILD_JOBS always wins",
    bash('. "' + RESOLVER + '"; wa_build_jobs', {CARGO_BUILD_JOBS: '3'}).stdout.trim() === '3');
}

// ---- 5. only cargo is queued ------------------------------------------------------------------------
{
  check('a cargo command line is recognised (env-prefixed too)',
    bash('. "' + RESOLVER + '"; wa_build_is_cargo env A=1 cargo build && echo yes').stdout.trim() === 'yes');
  check('a script is not a cargo command line',
    bash('. "' + RESOLVER + '"; wa_build_is_cargo bash scripts/test.sh || echo no').stdout.trim() === 'no');
}

// ---- 1. two builds do not run at the same time -------------------------------------------------------
{
  // The lock is taken by a REAL concurrent process (spawn, not spawnSync: a synchronous holder would
  // finish before the queued build started, and the row would prove nothing).
  const {spawn} = await import('node:child_process');
  const holder = spawn('bash', ['-c', '. "' + RESOLVER + '"; wa_build_host_lock sleep 4'], {env: ENV});
  await new Promise((r) => setTimeout(r, 700));   // let the holder take the lock
  check('while a build runs, the node lock is held', !free());
  const started = Date.now();
  const queued = bash('. "' + RESOLVER + '"; wa_build_host_lock echo ran');
  const ms = Date.now() - started;
  check('a build waits when another build holds the node lock', say(queued).includes('waited'), say(queued).slice(-400));
  check('it reports the wait as the node build lock', say(queued).includes('node build lock'), say(queued).slice(-400));
  check('and it runs once the lock is free', say(queued).includes('ran'), say(queued).slice(-300));
  check('the wait is real time, not a message (it waited for the holder)', ms > 2000, 'waited ' + ms + 'ms');
  await new Promise((r) => holder.on('exit', r));
  check('the lock is free again when the holder ends', free());
}

// ---- 2. the lock belongs to the wait, never to a child ------------------------------------------------
{
  // A build that leaves a child behind must not hand the lock to it: without flock -o the child inherits
  // the descriptor and holds the lock while it lives (measured 20/11: a fixture sleep 600 held it for ten
  // minutes after its suite ended). The child lives 1 s and this test waits it out, so the row proves the
  // property and leaves no process behind. The child is a script FILE, not a quoting exercise.
  const child = path.join(WORK, 'child.sh');
  const marker = path.join(WORK, 'child-alive');
  fs.writeFileSync(child, ["sleep 1", "echo done > " + JSON.stringify(marker)].join(String.fromCharCode(10)) + String.fromCharCode(10));
  // The child must not hold the pipe this test reads, or the synchronous call would wait for it
  // and the row could not tell "the build returned while its child ran" from "the child finished first".
  const r = bash(". " + JSON.stringify(RESOLVER) + "; wa_build_host_lock bash " + child + " >/dev/null 2>&1 </dev/null & echo started");
  check('a build that leaves a child behind returns at once', r.status === 0 && say(r).includes('started'), say(r).slice(-300));
  check('the child is still running when the build is over (so the check below means something)', !fs.existsSync(marker));
  check('the lock is NOT held by that surviving child (flock -o)', free());
  for (let i = 0; i < 40 && !fs.existsSync(marker); i++) spawnSync('bash', ['-c', 'sleep 0.1'], {encoding: 'utf8'});
  check('the child finished and wrote its marker', fs.existsSync(marker));
  check('the lock is still free after the child has gone', free());
}

// ---- 3. a nested build does not deadlock --------------------------------------------------------------
{
  const r = spawnSync('bash', ['-c', '. "' + RESOLVER + '"; timeout 20 bash -c ". \\"' + RESOLVER + '\\"; wa_build_host_lock echo nested-ok"'], {encoding: 'utf8', env: ENV, timeout: 40000});
  check('a build started inside a build does not queue behind itself', say(r).includes('nested-ok'), say(r).slice(-400));
  check('the lock is free after the nested build', free());
}

console.log('build-heat ok (' + passed + ' checks)');
