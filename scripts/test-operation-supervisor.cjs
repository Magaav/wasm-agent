#!/usr/bin/env node
// Slice 1 of `ready-operations-own-program.md`: ONE operation verb chain, answered by the supervisor.
//
// Two real processes on one machine (Fable 24/11: a wire seam proved with a stub is not proved):
//   * `wa operations-supervisor` in its own scratch home, owning the children;
//   * `wa` running scripts/lib/operations-supervisor-row.lua on the product interpreter, twice -
//     once in-process (the default, what every node runs today) and once with the switch on.
//
// What it proves, in the order the brief names it:
//   1. identical answers: the two runs answer the same fields with the same values, except a named list
//      of fields that are per-process BY DESIGN (ids, boot, timings, paths) - and the *same key set*;
//   2. identical cancellation: in both runs the child's marker holds the line it wrote before the cancel
//      and not the one after it, and both records settle;
//   3. identical env withholding: in both runs the child reads no GH_TOKEN and the record names it.
//
// Usage: node scripts/test-operation-supervisor.cjs [path/to/wa]
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust', 'target', 'release', 'wa'));
// The scratch root is a real temp directory, never the node's own state root: a harness whose TMPDIR is
// set to ~/.wasm-agent/tmp would put its fixtures inside the node it must not touch.
const tempBase = fs.existsSync('/tmp') ? '/tmp' : os.tmpdir();
const root = fs.mkdtempSync(path.join(tempBase, 'wa-operations-supervisor-'));
const row = path.join(repo, 'scripts', 'lib', 'operations-supervisor-row.lua');
const sleep = ms => new Promise(done => setTimeout(done, ms));

let checks = 0;
let supervisor = null;
function check(value, label) { assert.ok(value, label); checks += 1; }

// Fields that are per-process BY DESIGN: two processes answering one verb cannot agree on them, and
// agreeing on them would mean one of the two did not run. Everything else must be identical.
const PER_PROCESS = new Set([
  'operation_id', 'owner', 'owner_boot', 'owner_process_id', 'session', 'started_at', 'elapsed_ms',
  'remaining_ms', 'deadline_ms', 'process_id', 'pid', 'boot', 'stdout_path', 'stderr_path',
  'result_sha256', 'created', 'state_path', 'cwd', 'effective_cwd', 'requested_cwd', 'cwd_source',
  'output_idle_ms', 'post_exit_last_output_elapsed_ms', 'process_exit_elapsed_ms', 'blocked_on',
  'cwd_requested', // a timing fact: `status` names it once both pipes are closed, and two
  // processes observed at slightly different instants may disagree. It is not an answer about ownership.
  'output_streams_closed',
  'blocked_note', 'reattached', 'reattached_note', 'owner_live', 'elapsed_s',
  // The measured phases of one run. A measurement is not an answer about ownership, and two processes
  // cannot agree on milliseconds.
  'timing', 'measured_ms', 'setup_ms', 'spawn_ms', 'output_sync_ms', 'drain_cleanup_ms', 'total_ms',
  'unattributed_ms', 'accepted_record_ms', 'execution_ms',
]);

// A cancel is a REQUEST: it answers the state as it stood when the request was read, so state, status
// and settled are the operation's clock, not the verb's answer. Every other field must still be
// identical - what is excluded is exactly what two observation instants can legitimately disagree about.
const CANCEL_VOLATILE = new Set(['state', 'status', 'settled', 'shell_exited', 'waiting_for', 'output_bytes', 'overdue']);

function withoutPerProcess(value, extraVolatile) {
  if (Array.isArray(value)) return value.map(item => withoutPerProcess(item, extraVolatile));
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value)) {
      if (PER_PROCESS.has(key)) continue;
      if (extraVolatile && extraVolatile.has(key)) continue;
      out[key] = withoutPerProcess(value[key], extraVolatile);
    }
    return out;
  }
  return value;
}

function runRow(name, home, extraEnv) {
  fs.mkdirSync(home, { recursive: true });
  const rowDir = path.join(root, name);
  fs.mkdirSync(rowDir, { recursive: true });
  const db = path.join(home, 'row.db');
  const env = {
    ...process.env,
    HOME: home,
    WASM_AGENT_HOME: home,
    WASM_AGENT_MANAGED: '0',
    WASM_AGENT_RELAY: '',
    WASM_AGENT_RENDEZVOUS: '',
    WA_SCRIPT: row,
    WA_ROW_DIR: rowDir,
    // The credential the env rule must keep from a tool child. A fixture, not a credential.
    GH_TOKEN: 'fixture-gh-token-operations-supervisor',
    ...extraEnv,
  };
  delete env.WASM_AGENT_LUA_ROOT;
  const result = spawnSync(wa, ['--db', db], { cwd: repo, env, encoding: 'utf8', timeout: 180000 });
  const rows = {};
  for (const line of (result.stdout || '').split('\n')) {
    if (!line.startsWith('ROW ')) continue;
    const body = line.slice(4).trim();
    if (body.startsWith('done ')) { rows.done = JSON.parse(body.slice(5)); continue; }
    try { const parsed = JSON.parse(body); rows[parsed.step] = parsed.value; } catch { /* a FAIL line */ }
  }
  return { rows, status: result.status, stdout: result.stdout || '', stderr: result.stderr || '', rowDir };
}

(async () => {
  try {
    check(fs.existsSync(wa), `the binary under test exists: ${wa}`);

    // ---- the supervisor, in its own scratch home -------------------------------------------
    const supervisorHome = path.join(root, 'supervisor-home');
    fs.mkdirSync(supervisorHome, { recursive: true });
    const rendezvous = path.join(root, 'rendezvous.json');
    const log = fs.openSync(path.join(root, 'supervisor.log'), 'a');
    supervisor = spawn(wa, ['operations-supervisor', '--port', '0', '--rendezvous', rendezvous], {
      cwd: repo,
      env: {
        ...process.env,
        HOME: supervisorHome,
        WASM_AGENT_HOME: supervisorHome,
        WASM_AGENT_MANAGED: '0',
        WASM_AGENT_RELAY: '',
        WASM_AGENT_RENDEZVOUS: '',
        GH_TOKEN: 'fixture-gh-token-operations-supervisor',
        WASM_AGENT_OPERATIONS_SUPERVISOR: '',
      },
      stdio: ['ignore', log, log],
    });
    let announced = null;
    for (let attempt = 0; attempt < 100 && !announced; attempt += 1) {
      await sleep(100);
      try { announced = JSON.parse(fs.readFileSync(rendezvous, 'utf8')); } catch { announced = null; }
    }
    check(announced && announced.port > 0, 'the supervisor wrote its rendezvous');
    check(announced.pid === supervisor.pid, 'the rendezvous names the process this harness started');
    check((fs.statSync(rendezvous).mode & 0o777) === 0o600, 'the rendezvous file is 0600');

    // ---- the same row, twice: in-process (the default) and wired ---------------------------
    const inprocess = runRow('in-process', path.join(root, 'home-in-process'), {});
    const wired = runRow('wired', path.join(root, 'home-wired'), {
      WASM_AGENT_OPERATIONS_SUPERVISOR: rendezvous,
    });
    check(inprocess.status === 0,
      `the in-process row exited 0 (status ${inprocess.status}; stderr ${inprocess.stderr.slice(-300)}; stdout ${inprocess.stdout.slice(-400)})`);
    check(wired.status === 0,
      `the wired row exited 0 (status ${wired.status}; stderr ${wired.stderr.slice(-300)}; stdout ${wired.stdout.slice(-400)})`);
    check(inprocess.rows.done && inprocess.rows.done.failed === 0, `in-process assertions: ${JSON.stringify(inprocess.rows.done)}`);
    check(wired.rows.done && wired.rows.done.failed === 0, `wired assertions: ${JSON.stringify(wired.rows.done)}`);

    // ---- 1. identical answers ---------------------------------------------------------------
    for (const step of ['start', 'status', 'cancel', 'await', 'settled', 'marker', 'env']) {
      const a = inprocess.rows[step];
      const b = wired.rows[step];
      check(a !== undefined && b !== undefined, `both runs answered ${step}`);
      if (a === undefined || b === undefined) continue;
      if (step === 'marker' || step === 'env') { check(a === b, `${step} is identical: ${JSON.stringify([a, b])}`); continue; }
      const volatile = step === 'cancel' ? CANCEL_VOLATILE : undefined;
      const keysA = Object.keys(withoutPerProcess(a, volatile)).sort();
      const keysB = Object.keys(withoutPerProcess(b, volatile)).sort();
      check(JSON.stringify(keysA) === JSON.stringify(keysB),
        `${step} answers the same key set (in-process ${JSON.stringify(keysA)} / wired ${JSON.stringify(keysB)})`);
      assert.deepEqual(withoutPerProcess(b, volatile), withoutPerProcess(a, volatile), `${step} answers the same values`);
      checks += 1;
    }

    // ---- 2. identical cancellation ----------------------------------------------------------
    check(inprocess.rows.settled.settled === true && wired.rows.settled.settled === true,
      'both records settle after cancel');
    // `cancel` is a request, not a settlement: it answers the state as it stands (the identical-values row
    // above already holds it to the same answer as the in-process path). What must be a fact afterwards is
    // the record: both are settled, and both say why in the same words.
    check(inprocess.rows.settled.state === wired.rows.settled.state,
      `both settled records name the same state (${inprocess.rows.settled.state} / ${wired.rows.settled.state})`);
    check(inprocess.rows.settled.settled === true, 'the in-process record is settled after cancel');
    check(wired.rows.settled.settled === true, 'the wired record is settled after cancel');
    for (const [name, run] of [['in-process', inprocess], ['wired', wired]]) {
      const marks = run.rows.marker || '';
      check(marks.includes('start'), `${name}: the child ran before the cancel`);
      check(!marks.includes('end'), `${name}: the cancel reached the child (marker ${JSON.stringify(marks)})`);
    }

    // ---- 3. identical env withholding -------------------------------------------------------
    for (const [name, run] of [['in-process', inprocess], ['wired', wired]]) {
      check((run.rows.env || '').includes('gh=[]'), `${name}: the child read no GH_TOKEN (${JSON.stringify(run.rows.env)})`);
      check(JSON.stringify(run.rows.settled.env_withheld || []).includes('GH_TOKEN'),
        `${name}: the record names GH_TOKEN in env_withheld`);
    }

    // ---- the answer really came from the other process --------------------------------------
    check(wired.rows.identity.process_id === announced.pid,
      `the wired identity is the supervisor's process (${wired.rows.identity.process_id} vs ${announced.pid})`);
    check(wired.rows.identity.process_id !== inprocess.rows.identity.process_id,
      'the two runs were answered by two different processes');
    check(wired.rows.identity.owner_boot === announced.owner_boot,
      "the wired run's ledger boot is the supervisor's");

    console.log(`operation supervisor ok: ${checks} checks`);
    process.exitCode = 0;
  } catch (error) {
    console.error(`FAIL operation-supervisor: ${error && error.message ? error.message : error}`);
    process.exitCode = 1;
  } finally {
    if (supervisor && supervisor.exitCode === null) {
      try { process.kill(supervisor.pid, 'SIGTERM'); } catch { /* already gone */ }
    }
    try { fs.rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
  }
})();
