#!/usr/bin/env node
// THE GATE LANE: one CPU-heavy gate at a time per node, queued, with a holder you can name.
//
// WHAT THIS IS. Every producer runs the repository gate (`scripts/test.sh`, through
// `skills/parallel-evolution/scripts/finish.mjs` or `scripts/merge-lane.mjs`) inside its own
// worktree, and nothing coordinates those runs: N finishes mean N cargo builds contending for
// the same cores, each slower than the last, and no run can say which one was starved - the
// retained receipts span 675-1328 s at one setting (`docs/EVOLUTION.md`, "Gate parallelism").
// This program is the missing lane: a durable, node-wide admission queue for gates.
//
// WHAT IT DECIDES, AND WHAT IT DOES NOT. It decides *when* a gate runs, never *what*: the
// command is the caller's, unchanged, and `scripts/test.sh` is still the gate. A skipped test
// is still read out of the gate's own verdict line, not counted here. Nothing in this program
// retries or re-dispatches: one request is one row and at most one process; a request that
// cannot be satisfied ends as a recorded `refused` with the reason it gave up on, not as a
// tick that comes back (the failure class to avoid - a non-terminal refusal that re-dispatched
// every tick once created ~1322 worktrees on this machine).
//
// WHERE IT LIVES, AND WHY NOT SOMEWHERE ELSE (the placement answer).
//   * `rust/wa-jobs` is this project's durable queue and is the right home for a queue whose
//     *runner* is the sentinel's job runner: `Store::claim_next` already refuses to claim a
//     delivery of a job while another delivery of that job runs, and `recover()` settles a
//     `running` row a restart left behind instead of replaying it. But the gate is not a job
//     and its runner is not the sentinel: the child's own closing spell spawns
//     `bash scripts/test.sh` itself (skills/parallel-evolution/scripts/finish.mjs,
//     `spawnSync('bash',['scripts/test.sh'],...)`) and `scripts/merge-lane.mjs` does the same
//     in its disposable clone. wa-jobs is also not reachable from a child script - its only
//     CLI is `wa-sentinel job ...` and its claim lane is the sentinel's tick, which is outside
//     this change's scope - so a `gate` lane kind added there with no runner to consume it
//     would be dead code.
//   * The node's durable resource claims (`rust/wa-host/src/resources.rs`,
//     `lua/core/resources.lua`) have exactly the right *liveness* primitive - an OS-held
//     SQLite lease, never a PID timeout ("Never use a PID timeout as proof of death") - and
//     no queue at all: a claim is grant-or-busy in one shot, and resource names and policy are
//     Lua's, so a change there is a change under `lua/`, another lane's path. This lane
//     borrows that primitive verbatim instead of inventing one, and stays out of `lua/`.
//   * The sentinel's reservations (`WA_SENTINEL_JOB_DETERMINISTIC_CONCURRENCY`, the
//     `child-capacity` file) are in-process counters for job deliveries; a gate is neither.
//   * So the lane lives where its consumers are: `scripts/`, runnable from any worktree with
//     no build step, on Windows and on Linux. One state directory per user per node
//     (`<home>/.wasm-agent/gate-lane`) is what makes it node-wide - every worktree of one node
//     shares it, and the second node has its own.
//
// NOT A SECOND RUNNER. If something already owns the gate process - the sentinel running a
// gate as a `run` job through `wa_operation`, or `merge-lane.mjs` running the gate in its own
// clone - that owner keeps the process and asks here instead: `acquire` hands over the slot,
// the caller runs its own gate, and `release` gives the slot back. `acquire` blocks while it
// holds and spawns no process at all, because the claim's proof of life is that process's own
// lease, and a caller that dies takes its claim with it. With `run`, the lane is the only
// thing that spawns the gate, and it never spawns a second one while a slot is held.
//
// VISIBILITY, NEVER SILENCE. Every request is a durable row: what it will run, where, which
// process asked, which slot it is behind, how long that slot has been held, its position in
// the queue, and - when it ends - why. `status` shows exactly that, `history` keeps every
// transition, and a refusal names the holder, its elapsed time and the depth it gave up at.
//
// A cancelled holder does not prove descendant drain. A live recorded process
// or observed survivor keeps the slot. Even when both roots disappear, detached
// grandchildren may remain; the row stays orphaned until explicit owner drain
// evidence settles it. Execution errors persist drain_required before exit.
// PID age, agent cancellation, queue timers and direct-child absence never free
// running work. A waiting process that loses its lease has started no gate and
// can safely lose only its queue position. Normal owner completion releases its
// own live acquisition through the source-bound consumer.
//
// Usage
//   node scripts/gate-lane.mjs run [-- <command...>] [options]
//   node scripts/gate-lane.mjs acquire [--holder-pid <pid>] [options]   # blocks while it holds
//   node scripts/gate-lane.mjs release --id <n> [--exit <code>] [--detail <text>]
//   node scripts/gate-lane.mjs status [--json] [--limit <n>]
//   node scripts/gate-lane.mjs history [--limit <n>] [--json]
//   node scripts/gate-lane.mjs reconcile --id <n> --evidence <text>
//
//   --holder-pid <pid>    for `acquire`: the process whose life is the claim (default: this
//                         process's parent, which is the shell or runner that invoked it)
//   --label <text>        who asks (default: the repository root and branch of --cwd)
//   --cwd <dir>           working directory of the command (default: this process's cwd)
//   --capacity <n>        gates allowed at once on this node (default WA_GATE_LANE_CAPACITY, 1)
//   --wait-seconds <n>    give up visibly after this long (default WA_GATE_LANE_WAIT_SECONDS, 7200)
//   --no-wait             refuse immediately when no slot is free; never wait
//   --poll-ms <n>         how often a waiter re-reads the queue (default 2000)
//   --sample-seconds <n>  CPU-tree sampling interval, 0 disables (default WA_GATE_LANE_SAMPLE_SECONDS, 2)
//   --dir <dir>           lane state directory (default WA_GATE_LANE_DIR, <home>/.wasm-agent/gate-lane)
//   --log <path>          gate log (default <dir>/logs/<id>.log)
//   --json=<path>         print the receipt as JSON and write it there
//
// `acquire` prints its grant as JSON and then BLOCKS, holding the slot in its own lease, until
// the slot is released (`release --id <n>`) or the holder process is gone. Run the gate that owns
// the process yourself, then release. A holder that dies does not free the slot by itself: the
// lane frees it once nothing that holder started for the slot is still running, and holds it
// (`orphaned`, with the reasons in the row) while something is - because a caller's gate outlives
// the caller on Windows and on a plain `kill`, and a second gate on the same cores is what this
// lane exists to prevent.
//
// `reconcile --evidence <text>` is the one way a person ends a row the lane will not decide for
// itself. It refuses while the gate (or, in a row with no recorded gate pid, a process the holder
// started) is still running, and it is the way out wherever this node cannot answer that question
// at all - on POSIX the parent link dies with the holder, so there the lane holds the slot until
// evidence says what was inspected. What blocks it is a *live holder*, not the lane process
// watching the row: if the caller a slot was granted to is gone, that row is a person's to end,
// and the watchdog stops on its own next pass because the row is no longer live.
//
// Exit codes: the gate's own exit code is passed through unchanged, so a caller sees what the
// gate said. A run the lane could not grant is NOT a gate result and is distinguishable:
// 75 refused/timeout, 76 lane error.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SELF = fileURLToPath(import.meta.url);
const SCHEMA = `
CREATE TABLE IF NOT EXISTS requests(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL, cwd TEXT NOT NULL, mode TEXT NOT NULL, command TEXT NOT NULL,
  gate TEXT NOT NULL,
  pid INTEGER NOT NULL, lease TEXT NOT NULL, holder INTEGER NOT NULL, gate_pid INTEGER,
  state TEXT NOT NULL, reason TEXT, waits_for INTEGER, depth INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, started_at INTEGER, ended_at INTEGER,
  exit_code INTEGER, gate_ms INTEGER, waited_ms INTEGER, log_path TEXT, log_sha256 TEXT,
  skipped INTEGER, verdict TEXT, verdict_found INTEGER NOT NULL DEFAULT 0, cpu TEXT,
  drain_required INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS history(
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, request INTEGER NOT NULL,
  action TEXT NOT NULL, detail TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS requests_state ON requests(state,id);
CREATE INDEX IF NOT EXISTS history_request ON history(request,id);
`;
const now = () => Math.floor(Date.now() / 1000);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const held = new Map();
const laneError = (message, exit = 76) => Object.assign(Error(message), {exit});

function stateDir(options) {
  return path.resolve(options.dir || process.env.WA_GATE_LANE_DIR
    || path.join(os.homedir(), '.wasm-agent', 'gate-lane'));
}
function openLane(dir) {
  fs.mkdirSync(path.join(dir, 'leases'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'logs'), {recursive: true});
  const db = new DatabaseSync(path.join(dir, 'lane.sqlite'));
  // A waiter, a status call and a holder all write this database from separate processes: the
  // busiest it gets is one transaction at a time, and a busy timeout is what keeps them from
  // failing each other. Nothing here polls more often than poll-ms.
  db.exec('PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
  db.exec(SCHEMA);
  db.exec('BEGIN IMMEDIATE');
  try {
    if (!db.prepare('PRAGMA table_info(requests)').all().some(c=>c.name==='drain_required')) {
      db.exec('ALTER TABLE requests ADD COLUMN drain_required INTEGER NOT NULL DEFAULT 0');
    }
    db.exec('COMMIT');
  } catch(error) { db.exec('ROLLBACK'); throw error; }
  return db;
}
// The lease is the proof of life, and it is the repository's own primitive (resources.rs):
// an exclusive SQLite lock that the OS releases when the process dies, so a crashed holder
// never needs a timeout to be recognised.
function leaseFile(dir, uuid) { return path.join(dir, 'leases', `${uuid}.sqlite`); }
function holdLease(dir, uuid) {
  const db = new DatabaseSync(leaseFile(dir, uuid));
  db.exec('PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE');
  held.set(uuid, db);
}
function releaseLease(uuid) {
  const db = held.get(uuid);
  held.delete(uuid);
  if (!db) return;
  try { db.exec('ROLLBACK'); } catch {}
  try { db.close(); } catch {}
}
function leaseHeld(dir, uuid) {
  if (held.has(uuid)) return true;
  const file = leaseFile(dir, uuid);
  if (!fs.existsSync(file)) return false;
  let probe;
  try { probe = new DatabaseSync(file); } catch { return true; }
  try { probe.exec('PRAGMA busy_timeout=0'); probe.exec('BEGIN EXCLUSIVE'); probe.exec('ROLLBACK'); return false; }
  catch { return true; } finally { try { probe.close(); } catch {} }
}
function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === 'EPERM' || error.code === 'EACCES'; }
}
// Release and inheritance are effects of the live holder, not of whoever knows
// the row number. Fail closed if this host cannot observe the caller's ancestry.
function descendantOf(pid, ancestor) {
  if (!pidAlive(ancestor)) return false;
  if (pid === ancestor) return true;
  const parents = new Map();
  if (process.platform === 'win32') {
    const result = spawnSync('powershell.exe', ['-NoProfile', '-Command',
      'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress'],
    {encoding:'utf8', windowsHide:true, timeout:15000});
    if (result.status !== 0) return false;
    try { for (const p of JSON.parse(result.stdout)) parents.set(p.ProcessId,p.ParentProcessId); }
    catch { return false; }
  }
  const seen = new Set();
  while (pid > 1 && !seen.has(pid)) {
    seen.add(pid);
    if (process.platform !== 'win32') {
      try { const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8'); parents.set(pid,Number(stat.slice(stat.lastIndexOf(')')+2).split(' ')[1])); }
      catch { return false; }
    }
    pid=parents.get(pid);
    if (pid === ancestor) return true;
  }
  return false;
}
const row = (db, id) => db.prepare('SELECT * FROM requests WHERE id=?').get(id);
const rows = (db, sql, ...args) => db.prepare(sql).all(...args);
const holders = db => rows(db, "SELECT * FROM requests WHERE state IN ('running','orphaned') ORDER BY id");
const waiters = db => rows(db, "SELECT * FROM requests WHERE state='waiting' ORDER BY id");
const elapsedS = at => (at ? now() - at : 0);
function history(db, id, action, detail) {
  db.prepare('INSERT INTO history(at,request,action,detail) VALUES(?,?,?,?)')
    .run(now(), id, action, String(detail).slice(0, 2000));
}
function setState(db, id, state, reason, extra = {}) {
  const columns = Object.keys(extra);
  db.prepare(`UPDATE requests SET state=?,reason=?${columns.map(column => `,${column}=?`).join('')}`
    + " WHERE id=? AND state<>'done' AND state<>'failed' AND state<>'refused'")
    .run(state, reason, ...columns.map(column => extra[column]), id);
  history(db, id, state, reason);
}
const holderText = entry => `#${entry.id} (${entry.label}, pid ${entry.pid}, held`
  + ` ${elapsedS(entry.started_at)}s${entry.state === 'orphaned' ? ', holder dead' : ''})`;

// ---- Is anything the holder started still running? ------------------------------------------
// A row with a recorded gate pid is decided by that pid and by nothing else (see the header). A
// row without one - every `acquire` row - is decided by the one question this lane can ask from
// any process: does a process the dead holder started for this slot still exist? Windows keeps a
// process's parent link after the parent is gone, so an empty answer there is proof; POSIX
// reparents an orphan to init, so there the lane cannot prove anything and does not guess.
const CONSOLE_HOSTS = /^(conhost|openconsole|conhostv2)\.exe$/i;
const survivorText = list => list.map(child => `pid ${child.pid} (${child.name})`).join(', ');
function win32HolderChildren(holderPid) {
  const script = `Get-CimInstance Win32_Process -Filter "ParentProcessId=${holderPid}"`
    + ' | ForEach-Object { "{0} {1} {2}" -f $_.ProcessId, $_.Name,'
    + ' [DateTimeOffset]::new($_.CreationDate).ToUnixTimeSeconds() }';
  const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-Command', script], {encoding: 'utf8', windowsHide: true, timeout: 30000});
  if (result.error) return {ok: false, reason: `powershell.exe could not be run: ${result.error.message}`};
  if (result.status !== 0) {
    const last = String(result.stderr).split('\n').map(line => line.trim()).filter(Boolean).pop();
    return {ok: false, reason: `reading the process list exited ${result.status}${last ? `: ${last}` : ''}`};
  }
  const children = [];
  for (const line of String(result.stdout).split('\n')) {
    const [pid, name, createdAt] = line.trim().split(/\s+/);
    if (!/^\d+$/.test(pid || '') || !/^\d+$/.test(createdAt || '')) continue;
    children.push({pid: Number(pid), name, created_at: Number(createdAt)});
  }
  return {ok: true, children};
}
// Whoever is asking, the answer is about the row: the holder's own children, created no earlier
// than the moment the row asked for a slot (a gate the caller starts after its grant, never
// before), still alive, minus the two processes that are *this lane* rather than work - the
// asker itself and the row's recorded lane process (`pid`, which in `acquire` mode is the
// acquirer watching the row, a child of the holder too) - and minus console hosts, which are the
// OS's window on a process, not that process's work. A pid that was recycled between a death and
// this read can only make the lane hold a slot too long, which `reconcile --evidence` ends - never
// the other way round.
function survivorsOf(entry) {
  const holderPid = entry.holder || entry.pid;
  if (!Number.isInteger(holderPid) || holderPid <= 0) {
    return {authoritative: false, survivors: [], note: `row #${entry.id} records no holder pid to check`};
  }
  if (process.platform !== 'win32') {
    return {authoritative: false, survivors: [], note: 'this platform reparents an orphan as soon as'
      + ' its holder dies, so the parent link is gone with the holder and the lane cannot ask here'
      + ' whether what the holder started is still running'};
  }
  const listed = win32HolderChildren(holderPid);
  if (!listed.ok) {
    return {authoritative: false, survivors: [],
      note: `the node's process list could not be read for row #${entry.id} (${listed.reason})`};
  }
  const survivors = listed.children.filter(child => child.pid !== process.pid
    && child.pid !== entry.pid && child.pid !== holderPid
    && !CONSOLE_HOSTS.test(String(child.name))
    && child.created_at >= entry.created_at - 1 && pidAlive(child.pid));
  return {authoritative: true, survivors, note: survivors.length
    ? `process(es) the holder started for this slot are still alive: ${survivorText(survivors)}`
    : 'nothing the holder started for this slot is still running'};
}
// One decision, used by the reconciler, by the acquirer's own watchdog and by `reconcile`, so the
// three cannot drift apart: is the gate this row was granted for still running? The pid that
// matters is the *holder* - in `acquire` mode the lane process's own `pid` is the acquirer, and
// the gate belongs to the caller it was granted to (`holder`).
function gateStillRunning(entry) {
  if (entry.drain_required) {
    const look=survivorsOf(entry);
    return {running:true,recorded:entry.gate_pid,survivors:look.survivors,authoritative:false,
      how:'execution ended without proof of descendant drain; explicit owner evidence is required'};
  }
  if (entry.gate_pid) return {running: pidAlive(entry.gate_pid), recorded: entry.gate_pid,
    survivors: [], authoritative: true,
    how: `the gate it started (pid ${entry.gate_pid}) is ${pidAlive(entry.gate_pid) ? 'still running' : 'gone'}`};
  const look = survivorsOf(entry);
  const running = look.survivors.length > 0 || !look.authoritative;
  return {running, recorded: null, survivors: look.survivors, authoritative: look.authoritative,
    how: look.survivors.length ? look.note : (look.authoritative ? look.note
      : `this node cannot say whether what the holder started is gone: ${look.note}`)};
}
// The two endings a dead holder's row can have, worded once. The recorded-pid wording is the
// original one and is unchanged: it is the `run` record and the tests pin it.
function orphanReason(entry, holderAlive, live) {
  const holderPid = entry.holder || entry.pid;
  const died = holderAlive ? 'is alive but holds no lease' : 'died';
  return entry.gate_pid
    ? `orphaned: pid ${holderPid} ${died} and the gate it started (pid ${entry.gate_pid}) is still`
      + ' running; the slot stays held while that process runs, and is released when it exits or by'
      + ' `reconcile` with evidence'
    : `orphaned: pid ${holderPid} ${died} and no gate pid was recorded for it, so the slot stays held`
      + ` while ${live.how}; it is released when that stops, or by \`reconcile --evidence\` saying`
      + ' what was inspected';
}
function abandonedReason(entry, live) {
  const holderPid = entry.holder || entry.pid;
  return entry.gate_pid
    ? `abandoned: holder pid ${holderPid} gone, its gate pid ${entry.gate_pid} gone, lease`
      + ` ${entry.lease} not held; slot released after ${elapsedS(entry.started_at)}s`
    : `abandoned: holder pid ${holderPid} gone, no gate pid was recorded and ${live.how}, lease`
      + ` ${entry.lease} not held; slot released after ${elapsedS(entry.started_at)}s`;
}
// What a death left behind, before any decision is taken from the queue. A live lease is
// never touched: only the process that holds it ends its own claim.
function reconcileHolders(db, dir) {
  const moved = [];
  for (const entry of rows(db, "SELECT * FROM requests WHERE state IN ('running','waiting','orphaned')")) {
    if (held.has(entry.lease) || leaseHeld(dir, entry.lease)) continue;
    const holderAlive = pidAlive(entry.pid);
    if (entry.state === 'waiting') {
      const reason = `abandoned while waiting: pid ${entry.pid}`
        + `${holderAlive ? ' is alive but holds no lease' : ' is gone'}, lease ${entry.lease} not`
        + ` held; its place in the queue is released, not inherited (it had waited`
        + ` ${elapsedS(entry.created_at)}s)`;
      setState(db, entry.id, 'abandoned', reason, {ended_at: now()});
      moved.push({id: entry.id, state: 'abandoned', reason});
      continue;
    }
    const live = gateStillRunning(entry);
    if (live.running) {
      // Windows does not kill a child with its parent: a dead holder can leave a live gate behind.
      const reason = orphanReason(entry, holderAlive, live);
      if (entry.state !== 'orphaned') { setState(db, entry.id, 'orphaned', reason); moved.push({id: entry.id, state: 'orphaned', reason}); }
      continue;
    }
    // Both recorded roots can be gone while detached grandchildren survive.
    // Only an owned completion/drain receipt can settle that uncertainty.
    const uncertain=`orphaned: holder pid ${entry.holder || entry.pid} and gate pid ${entry.gate_pid || '(unrecorded)'} no longer observed; automatic release withheld: owner drain evidence required`;
    setState(db,entry.id,'orphaned',uncertain,{drain_required:1});
    moved.push({id:entry.id,state:'orphaned',reason:uncertain});
  }
  return moved;
}
function capacityOf(options) {
  const raw = options.capacity ?? process.env.WA_GATE_LANE_CAPACITY;
  const value = Number(raw === undefined || raw === '' ? 1 : raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > 64) throw laneError(`invalid capacity ${raw} (1..64)`);
  return value;
}
function waitSecondsOf(options) {
  const raw = options.waitSeconds ?? process.env.WA_GATE_LANE_WAIT_SECONDS;
  const value = Number(raw === undefined || raw === '' ? 7200 : raw);
  if (!Number.isFinite(value) || value < 0) throw laneError(`invalid wait-seconds ${raw}`);
  return value;
}
function sampleSecondsOf(options) {
  const raw = options.sampleSeconds ?? process.env.WA_GATE_LANE_SAMPLE_SECONDS;
  const value = Number(raw === undefined || raw === '' ? 2 : raw);
  return Number.isFinite(value) && value >= 0 ? value : 2;
}
function pollMsOf(options) {
  return Number.isFinite(options.pollMs) && options.pollMs >= 100 ? options.pollMs : 2000;
}
function defaultLabel(cwd) {
  const git = args => {
    const result = spawnSync('git', args, {cwd, encoding: 'utf8', windowsHide: true, timeout: 20000});
    return result.status === 0 ? String(result.stdout).trim() : '';
  };
  const root = git(['rev-parse', '--show-toplevel']) || cwd;
  return `${path.basename(root)}@${git(['symbolic-ref', '--short', 'HEAD']) || 'detached'}`;
}
function parseArgs(argv) {
  const options = {command: null, json: false, jsonPath: null, noWait: false};
  const rest = [];
  let command = false;
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (command) { rest.push(arg); continue; }
    if (arg === '--') { command = true; continue; }
    const equals = arg.startsWith('--') ? arg.indexOf('=') : -1;
    const name = equals > 0 ? arg.slice(0, equals) : arg;
    const inline = equals > 0 ? arg.slice(equals + 1) : null;
    const value = () => {
      if (inline !== null) return inline;
      index += 1;
      if (index >= argv.length) throw laneError(`${name} needs a value`);
      return argv[index];
    };
    switch (name) {
      case '--label': options.label = value(); break;
      case '--cwd': options.cwd = value(); break;
      case '--capacity': options.capacity = value(); break;
      case '--wait-seconds': options.waitSeconds = value(); break;
      case '--poll-ms': options.pollMs = Number(value()); break;
      case '--sample-seconds': options.sampleSeconds = value(); break;
      case '--dir': options.dir = value(); break;
      case '--log': options.log = value(); break;
      case '--no-wait': options.noWait = true; break;
      case '--json': options.json = true; options.jsonPath = inline; break;
      case '--id': options.id = Number(value()); break;
      case '--evidence': options.evidence = value(); break;
      case '--exit': options.exit = Number(value()); break;
      case '--detail': options.detail = value(); break;
      case '--limit': options.limit = Number(value()); break;
      case '--holder-pid': options.holderPid = Number(value()); break;
      case '--lease': options.lease = value(); break;
      case '--gate-pid': options.gatePid = Number(value()); break;
      default: throw laneError(`unknown option ${arg}`);
    }
  }
  return {options, rest};
}
function emit(value, options) {
  const text = JSON.stringify(value, null, 2);
  console.log(text);
  if (options.jsonPath) {
    fs.mkdirSync(path.dirname(path.resolve(options.jsonPath)), {recursive: true});
    fs.writeFileSync(path.resolve(options.jsonPath), `${text}\n`);
  }
}
function request(db, options, {command, mode, holderPid, lease}) {
  const cwd = path.resolve(options.cwd || process.cwd());
  const inserted = db.prepare(`INSERT INTO requests(label,cwd,mode,command,gate,pid,lease,holder,state,created_at)
    VALUES(?,?,?,?,?,?,?,?,?,?)`).run(options.label || defaultLabel(cwd), cwd, mode,
    JSON.stringify(command), command.join(' '), process.pid, lease, holderPid, 'waiting', now());
  const id = Number(inserted.lastInsertRowid);
  history(db, id, 'requested', `${options.label || defaultLabel(cwd)} in ${cwd} asks for a slot: ${command.join(' ')}`);
  return {id, lease};
}
// The lease is taken before the row exists: a reconciler that read the row between the two
// would see a claim with no proof of life and abandon a request whose process is alive.
function requestHoldingLease(db, dir, options, spec) {
  const lease = crypto.randomUUID();
  holdLease(dir, lease);
  return request(db, options, {...spec, lease});
}
function queuePosition(db, id) {
  return rows(db, "SELECT id FROM requests WHERE state='waiting' AND id<?", id).length + 1;
}
function reasonText(db, capacity, id, waited) {
  const busy = holders(db);
  const position = queuePosition(db, id);
  return `capacity ${capacity} of ${capacity} in use; running ${busy.map(holderText).join(', ') || 'nobody'}`
    + `; queue depth ${position} (${position === 1 ? 'next to run' : `${position - 1} ahead`})`
    + `; waited ${waited}s; also waiting:`
    + ` ${waiters(db).filter(entry => entry.id !== id).map(entry => `#${entry.id}`).join(', ') || 'nobody'}`;
}
// The grant is one atomic transition, and the order comes from the queue rather than from who
// polled first: the lowest waiting id grants itself, so a later request cannot overtake an
// earlier one by being luckier with its interval.
function tryGrant(db, dir, capacity, id) {
  db.exec('BEGIN IMMEDIATE');
  try {
    reconcileHolders(db, dir);
    const busy = holders(db);
    const mine = row(db, id);
    const earlier = rows(db, "SELECT id FROM requests WHERE state='waiting' AND id<?", id).length;
    if (!mine || mine.state !== 'waiting') { db.exec('ROLLBACK'); return {lost: true}; }
    if (busy.length < capacity && earlier === 0) {
      db.prepare("UPDATE requests SET state='running',started_at=?,waits_for=NULL,depth=0,reason=NULL WHERE id=? AND state='waiting'")
        .run(now(), id);
      history(db, id, 'running', `granted a slot after ${now() - mine.created_at}s of waiting;`
        + ` ${busy.length} of ${capacity} were in use at that moment`);
      db.exec('COMMIT');
      return {granted: true};
    }
    db.exec('ROLLBACK');
    return {busy};
  } catch (error) { try { db.exec('ROLLBACK'); } catch {} throw error; }
}
function readVerdict(logPath) {
  let tail = '';
  try {
    const bytes = fs.readFileSync(logPath);
    tail = bytes.subarray(Math.max(0, bytes.length - 8192)).toString('utf8');
  } catch { return {found: false, line: null, skipped: 0}; }
  const match = /(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?\s*$/u.exec(tail);
  return match ? {found: true, line: match[0].trim(), skipped: Number(match[1] || 0)}
    : {found: false, line: null, skipped: 0};
}
// ---- CPU sampling: the gate's own process tree, never the machine --------------------------
function reduceSamples(lines, intervalMs, sampler) {
  const seen = new Map();
  let cpuSeconds = 0;
  let peakProcesses = 0;
  let peakCompilers = 0;
  let samples = 0;
  const names = new Map();
  for (const line of lines) {
    let sample;
    try { sample = JSON.parse(line); } catch { continue; }
    if (!sample || !Array.isArray(sample.tree)) continue;
    samples += 1;
    peakProcesses = Math.max(peakProcesses, sample.tree.length);
    const observed = sample.tree.map(entry => String(entry.name || '').replace(/\.exe$/i, ''));
    peakCompilers = Math.max(peakCompilers, observed.filter(name => /^(rustc|cargo)$/i.test(name)).length);
    for (const name of observed) names.set(name, (names.get(name) || 0) + 1);
    for (const entry of sample.tree) {
      const pid = Number(entry.pid);
      const ticks = Number(entry.ticks) || 0;
      const previous = seen.get(pid);
      if (previous === undefined) seen.set(pid, ticks);
      else { cpuSeconds += Math.max(0, ticks - previous) / 1e7; seen.set(pid, ticks); }
    }
  }
  return {
    sampler, interval_ms: intervalMs, samples, available: samples > 0,
    cpu_seconds: Number(cpuSeconds.toFixed(1)),
    peak_processes_in_tree: peakProcesses,
    peak_rustc_in_tree: peakCompilers,
    process_name_samples: [...names.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6)
      .map(([name, count]) => `${name}x${count}`).join(', '),
    note: "CPU is the sum of per-pid deltas observed inside the gate's own process tree"
      + ' (UserModeTime+KernelModeTime), not the machine: a process that starts and exits between'
      + ' two samples contributes only what was seen while it was on the tree, so cpu_seconds is a'
      + ' lower bound and peak_processes is a floor.',
  };
}
function posixStat(pid) {
  try {
    const text = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const open = text.indexOf('(');
    const close = text.lastIndexOf(')');
    const fields = text.slice(close + 2).split(' ');
    return {name: text.slice(open + 1, close), ppid: Number(fields[1]),
      ticks: Number(fields[11]) + Number(fields[12])};
  } catch { return null; }
}
function posixSampler(root, intervalMs, stop) {
  const lines = [];
  const clockTicks = Number(spawnSync('getconf', ['CLK_TCK'], {encoding: 'utf8', windowsHide: true}).stdout) || 100;
  const started = Date.now();
  const one = () => {
    const table = new Map();
    for (const name of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(name)) continue;
      const pid = Number(name);
      const stat = posixStat(pid);
      if (stat) table.set(pid, stat);
    }
    const tree = new Set([root]);
    let grew = true;
    while (grew) {
      grew = false;
      for (const [pid, stat] of table) {
        if (tree.has(stat.ppid) && !tree.has(pid)) { tree.add(pid); grew = true; }
      }
    }
    lines.push(JSON.stringify({t_ms: Date.now() - started,
      tree: [...tree].filter(pid => table.has(pid)).map(pid => ({pid, name: table.get(pid).name,
        ticks: table.get(pid).ticks / clockTicks * 1e7}))}));
  };
  return new Promise(resolve => {
    const timer = setInterval(() => { one(); if (stop.done) { clearInterval(timer); resolve(lines); } }, intervalMs);
    stop.finish = () => { clearInterval(timer); one(); resolve(lines); };
  });
}
async function runCommand({command, cwd, logPath, sampleSeconds, onSpawn}) {
  fs.mkdirSync(path.dirname(logPath), {recursive: true});
  const descriptor = fs.openSync(logPath, 'w');
  const started = Date.now();
  const hash = crypto.createHash('sha256');
  const child = spawn(command[0], command.slice(1), {cwd, stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true, env: process.env});
  // Register before sampler setup: a fast command can exit during its startup.
  const exited=new Promise(resolve=>{
    child.once('exit',(code,signal)=>resolve({code,signal}));
    child.once('error',error=>resolve({code:76,error}));
  });
  if (Number.isInteger(child.pid)) onSpawn(child.pid);
  const finished = Promise.all([child.stdout, child.stderr].map(stream => new Promise(resolve => {
    stream.on('data', chunk => {
      fs.writeSync(descriptor, chunk);
      hash.update(chunk);
      (stream === child.stdout ? process.stdout : process.stderr).write(chunk);
    });
    stream.on('end', resolve);
    stream.on('error', resolve);
    stream.on('close', resolve);
  })));
  let sampler = null;
  let samplerFile = null;
  let samplerKind = 'disabled (--sample-seconds 0)';
  const intervalMs = Math.max(250, Math.round(sampleSeconds * 1000));
  const stop = {done: false};
  let posix = null;
  if (sampleSeconds > 0 && process.platform === 'win32') {
    samplerFile = `${logPath}.cpu.jsonl`;
    fs.rmSync(samplerFile, {force: true});
    sampler = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(here, 'lib', 'gate-lane-sample.ps1'), '-Root', String(child.pid),
      '-IntervalMs', String(intervalMs), '-Out', samplerFile],
    {stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true});
    samplerKind = 'powershell.exe Get-CimInstance Win32_Process, descendants of gate pid'
      + ` ${child.pid}, every ${intervalMs} ms`;
    await sleep(Math.min(1200, intervalMs));
  } else if (sampleSeconds > 0) {
    samplerKind = `in-process /proc walk, descendants of gate pid ${child.pid}, every ${intervalMs} ms`;
    posix = posixSampler(child.pid, intervalMs, stop);
  }
  const exit = await exited;
  stop.done = true;
  if (sampler) sampler.kill('SIGKILL');
  if (stop.finish) stop.finish();
  await finished;
  fs.closeSync(descriptor);
  let cpu = {sampler: samplerKind, samples: 0, available: false,
    reason: 'sampling was disabled, or the sampler produced no sample'};
  if (samplerFile) {
    const lines = fs.existsSync(samplerFile) ? fs.readFileSync(samplerFile, 'utf8').split('\n').filter(Boolean) : [];
    cpu = lines.length ? reduceSamples(lines, intervalMs, samplerKind)
      : {...cpu, sampler: samplerKind, reason: 'the Windows sampler wrote no sample line'};
  } else if (posix) {
    cpu = reduceSamples(await posix, intervalMs, samplerKind);
  }
  return {exit_code: exit.code, signal: exit.signal, error:exit.error?.message,gate_ms: Date.now() - started,
    log_sha256: hash.digest('hex'), cpu, verdict: readVerdict(logPath)};
}
function receiptOf(db, id, dir, capacity, extra = {}) {
  const entry = row(db, id);
  return {
    lane: 'gate', dir, capacity, obtained: false,
    id: entry.id, label: entry.label, mode: entry.mode, state: entry.state, reason: entry.reason,
    cwd: entry.cwd, command: entry.gate, pid: entry.pid, holder_pid: entry.holder,
    runner: {path:SELF, sha256:crypto.createHash('sha256').update(fs.readFileSync(SELF)).digest('hex')},
    inheritance: {id:entry.id,dir,lease:entry.lease,holder_pid:entry.holder},
    gate_pid: entry.gate_pid, waits_for: entry.waits_for, queue_position: entry.depth,
    requested_at: entry.created_at, started_at: entry.started_at, ended_at: entry.ended_at,
    waited_ms: entry.waited_ms, gate_ms: entry.gate_ms, exit_code: entry.exit_code,
    verdict: entry.verdict, verdict_found: Boolean(entry.verdict_found), skipped: entry.skipped,
    log: entry.log_path, log_sha256: entry.log_sha256, cpu: entry.cpu ? JSON.parse(entry.cpu) : null,
    ...extra,
  };
}
async function waitForGrant({db, dir, id, lease, capacity, waitSeconds, pollMs, verb, noWait}) {
  const entered = Date.now();
  let lastNotice = -1;
  for (;;) {
    const waited = Math.floor((Date.now() - entered) / 1000);
    const granted = tryGrant(db, dir, capacity, id);
    if (granted.lost) throw laneError(`request #${id} was settled by another process while waiting`);
    if (granted.granted) return {granted: true, waited, waitedMs: Date.now() - entered};
    const position = queuePosition(db, id);
    const reason = reasonText(db, capacity, id, waited);
    const front = holders(db)[0]?.id ?? null;
    if (noWait) {
      setState(db, id, 'refused', `refused without waiting: ${reason}`,
        {ended_at: now(), waits_for: front, depth: position});
      console.error(`gate lane: ${verb} #${id} refused (--no-wait). ${reason}`);
      console.error(`gate lane: nothing ran and nothing will be retried; ask again when #${front} is done.`);
      releaseLease(lease);
      return {granted: false, waited, waitedMs: Date.now() - entered, refused: 'no-wait'};
    }
    if (waited >= waitSeconds) {
      setState(db, id, 'refused', `refused after holding no slot for ${waited}s of ${waitSeconds}s: ${reason}`,
        {ended_at: now(), waits_for: front, depth: position});
      console.error(`gate lane: ${verb} #${id} gave up after ${waited}s (limit ${waitSeconds}s). ${reason}`);
      console.error('gate lane: this is terminal, not a retry: the holder above is named, and the'
        + ' request is recorded as refused. Reconcile that holder or ask again later.');
      releaseLease(lease);
      return {granted: false, waited, waitedMs: Date.now() - entered, refused: 'timeout'};
    }
    db.prepare('UPDATE requests SET reason=?,waits_for=?,depth=? WHERE id=?').run(reason, front, position, id);
    if (lastNotice < 0 || waited - lastNotice >= 30) {
      console.error(`gate lane: ${verb} #${id} waiting (${waited}s). ${reason}`);
      lastNotice = waited;
    }
    await sleep(pollMs);
  }
}
function commandRun(options, rest) {
  const dir = stateDir(options);
  const db = openLane(dir);
  const capacity = capacityOf(options);
  const waitSeconds = waitSecondsOf(options);
  const sampleSeconds = sampleSecondsOf(options);
  const pollMs = pollMsOf(options);
  const command = rest.length ? rest : ['bash', 'scripts/test.sh'];
  const cwd = path.resolve(options.cwd || process.cwd());
  const holderPid = process.pid;
  const {id, lease} = requestHoldingLease(db, dir, {...options, cwd},
    {command, mode: 'run', holderPid});
  return (async () => {
    try {
      const granted = await waitForGrant({db, dir, id, lease, capacity, waitSeconds, pollMs,
        verb: 'run', noWait: options.noWait});
      if (!granted.granted) {
        const receipt = receiptOf(db, id, dir, capacity, {obtained: false, waited_ms: granted.waitedMs});
        if (options.json) emit(receipt, options);
        return {exit: 75, receipt};
      }
      const logPath = path.resolve(options.log || path.join(dir, 'logs', `${id}.log`));
      db.prepare('UPDATE requests SET log_path=? WHERE id=?').run(logPath, id);
      const result = await runCommand({command, cwd, logPath, sampleSeconds,
        onSpawn: pid => db.prepare('UPDATE requests SET gate_pid=? WHERE id=?').run(pid, id)});
      if (result.exit_code === 0 && !result.verdict.found) {
        console.error(`gate lane: #${id} exited 0 but printed no gate verdict line; recording it as`
          + ' un-verdicted rather than as a pass. A run that did not test something must not read'
          + ' as a run that did.');
      }
      const state = result.exit_code === 0 ? 'done' : 'failed';
      const detail = `exit ${result.exit_code}${result.signal ? ` (${result.signal})` : ''} in`
        + ` ${result.gate_ms} ms${result.verdict.found ? `; "${result.verdict.line}"` : '; NO gate verdict line'}`
        + `${result.error ? `; spawn: ${result.error}` : ''}`;
      db.prepare(`UPDATE requests SET state=?,reason=?,ended_at=?,gate_ms=?,exit_code=?,skipped=?,
        verdict=?,verdict_found=?,cpu=?,log_sha256=?,gate_pid=NULL,waited_ms=? WHERE id=?`)
        .run(state, detail, now(), result.gate_ms, result.exit_code, result.verdict.skipped,
          result.verdict.line, result.verdict.found ? 1 : 0, JSON.stringify(result.cpu),
          result.log_sha256, granted.waitedMs, id);
      history(db, id, state, detail);
      const receipt = receiptOf(db, id, dir, capacity, {obtained: true});
      if (options.json) emit(receipt, options);
      else console.log(`gate lane: #${id} ${state} exit ${result.exit_code} after ${result.gate_ms} ms`
        + `${result.verdict.found ? `; verdict "${result.verdict.line}"` : '; no verdict line'}`
        + `; waited ${(granted.waitedMs / 1000).toFixed(1)}s; log ${logPath}`);
      return {exit: result.exit_code ?? 76, receipt};
    } finally {
      releaseLease(lease);
    }
  })().catch(error => {
    try {
      if (row(db, id)?.state === 'running') setState(db, id, 'orphaned', `lane error: ${error.message}; drain evidence required`, {drain_required:1});
    } catch {}
    releaseLease(lease);
    throw error;
  });
}
async function commandAcquire(options) {
  const dir = stateDir(options);
  const db = openLane(dir);
  const capacity = capacityOf(options);
  const waitSeconds = waitSecondsOf(options);
  const pollMs = pollMsOf(options);
  // The caller that asked is the holder, so a caller that dies takes its claim with it: the
  // default is this process's parent, which is the shell or the runner that invoked it.
  const holderPid = Number.isInteger(options.holderPid) ? options.holderPid : process.ppid;
  if (!pidAlive(holderPid)) throw laneError(`--holder-pid ${holderPid} is not a live process`);
  const {id, lease} = requestHoldingLease(db, dir, options,
    {command: ['(the caller runs its own gate)'], mode: 'acquire', holderPid});
  const entered = Date.now();
  for (;;) {
    const waited = Math.floor((Date.now() - entered) / 1000);
    const granted = tryGrant(db, dir, capacity, id);
    if (granted.lost) throw laneError(`request #${id} was settled by another process while waiting`);
    if (granted.granted) break;
    const position = queuePosition(db, id);
    const reason = reasonText(db, capacity, id, waited);
    const front = holders(db)[0]?.id ?? null;
    if (options.noWait || waited >= waitSeconds) {
      setState(db, id, 'refused', `refused after ${waited}s waiting for a slot: ${reason}`,
        {ended_at: now(), waits_for: front, depth: position});
      console.error(`gate lane: acquire #${id} refused after ${waited}s (terminal, not a retry). ${reason}`);
      releaseLease(lease);
      return {exit: 75, receipt: receiptOf(db, id, dir, capacity,
        {obtained: false, waited_ms: Date.now() - entered})};
    }
    db.prepare('UPDATE requests SET reason=?,waits_for=?,depth=? WHERE id=?').run(reason, front, position, id);
    console.error(`gate lane: acquire #${id} waiting (${waited}s). ${reason}`);
    await sleep(pollMs);
  }
  // Granted. The slot is held by THIS process's lease, which is why acquire blocks: the caller
  // keeps its own gate runner (it must not have a second one here), and releases the slot when
  // its gate is done. Nothing is spawned: the lane supervises no process in this mode.
  const receipt = receiptOf(db, id, dir, capacity, {obtained: true, waited_ms: Date.now() - entered});
  emit(receipt, {jsonPath: options.jsonPath});
  console.error(`gate lane: acquire #${id} granted to holder pid ${holderPid}; this process now`
    + ` holds the slot and blocks. Run your own gate, then: gate-lane.mjs release --id ${id}`);
  for (;;) {
    await sleep(2000);
    const entry = row(db, id);
    if (!entry || !/^(running|orphaned)$/.test(entry.state)) break;
    if (pidAlive(holderPid)) continue;
    // The holder is gone. Its gate may not be: on Windows (and on a plain `kill` anywhere) the
    // caller's own gate survives the caller, and this row records no gate pid to check. So the
    // slot is let go only once nothing the holder started for it is still running, and the row
    // says which it is either way.
    const live = gateStillRunning(entry);
    if (live.running) {
      if (entry.state !== 'orphaned') {
        const reason = orphanReason(entry, false, live);
        setState(db, id, 'orphaned', reason);
        console.error(`gate lane: acquire #${id} ${reason}`);
      }
      continue;
    }
    setState(db,id,'orphaned',`holder pid ${holderPid} is gone; ${live.how}; owner descendant drain evidence required`,
      {drain_required:1});
  }
  releaseLease(lease);
  return {exit: 0, receipt: receiptOf(db, id, dir, capacity, {obtained: true})};
}
function commandRelease(options) {
  const dir = stateDir(options);
  const db = openLane(dir);
  const entry = row(db, options.id);
  if (!entry) throw laneError(`no request #${options.id}`);
  if (!/^(running|orphaned)$/.test(entry.state)) {
    throw laneError(`request #${options.id} is ${entry.state}, not a live slot`, 1);
  }
  if (entry.mode !== 'acquire' || !descendantOf(process.ppid, entry.holder)) {
    throw laneError(`refusing release #${entry.id}: only the acquire holder's process tree may settle it; use reconcile with drain evidence after owner death`, 1);
  }
  if (!leaseHeld(dir, entry.lease)) throw laneError(`refusing release #${entry.id}: its acquisition lease is gone; reconcile ownership first`, 1);
  if (entry.drain_required) throw laneError(`refusing release #${entry.id}: explicit descendant drain evidence is required`,1);
  const detail = options.detail || `released by its holder with exit`
    + ` ${options.exit === null || options.exit === undefined ? 'unrecorded' : options.exit}`;
  setState(db, options.id, options.exit === 0 ? 'done' : 'failed', detail,
    {ended_at: now(), exit_code: options.exit ?? null});
  return {exit: 0, receipt: receiptOf(db, options.id, dir, capacityOf(options))};
}
function commandDefer(options) {
  const dir=stateDir(options),db=openLane(dir),entry=row(db,options.id);
  if (!entry || !['running','orphaned'].includes(entry.state) || entry.mode!=='acquire'
      || !descendantOf(process.ppid,entry.holder) || !leaseHeld(dir,entry.lease)) {
    throw laneError(`refusing defer #${options.id}: this caller does not own its live acquisition`,1);
  }
  setState(db,entry.id,'orphaned',options.detail || 'execution ended without descendant drain proof',
    {drain_required:1,gate_pid:Number.isInteger(options.gatePid)&&options.gatePid>0?options.gatePid:null});
  return {exit:0};
}
function commandValidate(options) {
  const dir=stateDir(options);
  const db=new DatabaseSync(path.join(dir,'lane.sqlite'),{readOnly:true});
  try {
    const entry=row(db,options.id);
    if (!entry || entry.state !== 'running' || entry.lease !== options.lease
        || options.holderPid !== process.ppid || !descendantOf(process.ppid,entry.holder)
        || !pidAlive(entry.pid) || !leaseHeld(dir,entry.lease)) {
      throw laneError(`invalid_inheritance: #${options.id} has no live lease owned by this caller's ancestor`,1);
    }
    emit({valid:true,id:entry.id,dir,holder_pid:entry.holder,lease:entry.lease},options);
    return {exit:0};
  } finally { db.close(); }
}
function commandReconcile(options) {
  const dir = stateDir(options);
  if (!options.evidence || !String(options.evidence).trim()) {
    throw laneError('reconcile needs --evidence saying what was inspected', 1);
  }  const db = openLane(dir);
  const entry = row(db, options.id);
  if (!entry) throw laneError(`no request #${options.id}`);
  if (!/^(running|orphaned|waiting)$/.test(entry.state)) {
    throw laneError(`request #${options.id} is ${entry.state}; nothing to reconcile`, 1);
  }
  // A live owner is never reconciled by someone else. For an `acquire` row the owner is the caller
  // the slot was granted to (`holder`), not the lane process watching it: that caller's own gate
  // is the thing being guarded, and if it is gone the row is a person's to end - the watchdog
  // stops on its next pass because the row is no longer live.
  const owner = entry.holder || entry.pid;
  if (leaseHeld(dir, entry.lease) && pidAlive(owner)) {
    throw laneError(`refusing to reconcile #${entry.id}: its lease is held and its holder (pid`
      + ` ${owner}) is alive. A live owner is never reconciled by someone else.`, 1);
  }
  // A lease that is still held while the *holder* is gone belongs to the acquirer's own watchdog,
  // which is watching the same row: evidence may end the row, and the watchdog stops on its next
  // pass because the row is no longer live. Refusing here would leave an orphaned row with no way
  // out but killing the watchdog.
  const live = gateStillRunning(entry);
  if (entry.gate_pid && pidAlive(entry.gate_pid)) {
    throw laneError(`refusing to reconcile #${entry.id}: the gate it started (pid ${entry.gate_pid})`
      + ' is still running on the node. The lane must not free a slot that is still burning cores -'
      + ' stop that process, then reconcile it.', 1);
  }
  if (live.survivors.length) {
    throw laneError(`refusing to reconcile #${entry.id}: no gate pid was recorded for it, and ${live.how}`
      + ' - a slot must not be freed while work the holder started is still burning cores. Stop that'
      + ' process, then reconcile it.', 1);
  }
  setState(db, options.id, 'abandoned', `reconciled: ${String(options.evidence).trim()}`, {ended_at: now(),drain_required:0});
  return {exit: 0, receipt: receiptOf(db, options.id, dir, capacityOf(options))};
}
function commandStatus(options, readOnly = false) {
  const dir = stateDir(options);
  const db = readOnly ? new DatabaseSync(path.join(dir, 'lane.sqlite'), {readOnly:true}) : openLane(dir);
  const capacity = capacityOf(options);
  const moved = readOnly ? [] : reconcileHolders(db, dir);
  const limit = Number.isFinite(options.limit) ? options.limit : 20;
  const busy = holders(db);
  const queue = waiters(db);
  const recent = rows(db, `SELECT * FROM requests WHERE state NOT IN ('running','waiting','orphaned') ORDER BY id DESC LIMIT ${limit}`);
  const lines = [`gate lane: ${busy.length} of ${capacity} slot(s) held (capacity from`
    + ` ${process.env.WA_GATE_LANE_CAPACITY ? 'WA_GATE_LANE_CAPACITY' : 'the default'}), ${queue.length} waiting`,
  `  state dir: ${dir}`];
  for (const entry of busy) {
    lines.push(`  slot #${entry.id} ${entry.state} mode=${entry.mode}: ${entry.label} pid ${entry.pid}`
      + `${entry.gate_pid ? ` gate pid ${entry.gate_pid}` : ''} held ${elapsedS(entry.started_at)}s`);
    lines.push(`      command: ${entry.gate}`);
    if (entry.reason) lines.push(`      why: ${entry.reason}`);
  }
  queue.forEach((entry, index) => {
    lines.push(`  waiting #${entry.id} position ${index + 1} depth ${entry.depth}: ${entry.label}`
      + ` pid ${entry.pid} for ${elapsedS(entry.created_at)}s`);
    lines.push(`      reason: ${entry.reason}`);
  });
  if (!busy.length && !queue.length) lines.push('  nobody holds a slot and nobody is waiting');
  for (const entry of recent) {
    lines.push(`  ${entry.state} #${entry.id} ${entry.label}`
      + `${entry.exit_code === null || entry.exit_code === undefined ? '' : ` exit ${entry.exit_code}`}`
      + `${entry.skipped === null || entry.skipped === undefined ? '' : ` skipped ${entry.skipped}`}`
      + `${entry.gate_ms === null || entry.gate_ms === undefined ? '' : ` ${entry.gate_ms} ms`}`
      + `: ${entry.reason}`);
  }
  for (const move of moved) lines.push(`  reconciled #${move.id} -> ${move.state}: ${move.reason}`);
  if (options.json) {
    emit({lane: 'gate', dir, capacity, slots_held: busy.length, waiting: queue.length,
      held: busy.map(entry => ({...entry, cpu: undefined})),
      queue: queue.map(entry => ({...entry, cpu: undefined})),
      recent: recent.map(entry => ({...entry, cpu: undefined})), reconciled: moved, read_only:readOnly}, options);
  } else console.log(lines.join('\n'));
  return {exit: 0, held: busy.length, queue: queue.length};
}
function commandHistory(options) {
  const dir = stateDir(options);
  const db = openLane(dir);
  const limit = Number.isFinite(options.limit) ? options.limit : 40;
  const entries = rows(db, `SELECT * FROM history ORDER BY id DESC LIMIT ${limit}`);
  if (options.json) emit(entries, options);
  else for (const entry of entries.reverse()) {
    console.log(`${new Date(entry.at * 1000).toISOString()} #${entry.request} ${entry.action}: ${entry.detail}`);
  }
  return {exit: 0};
}
async function main() {
  const [command, ...argv] = process.argv.slice(2);
  const {options, rest} = parseArgs(argv);
  if (command === 'run') {
    const result = await commandRun(options, rest);
    process.exitCode = result.exit;
  } else if (command === 'acquire') {
    const result = await commandAcquire(options);
    process.exitCode = result.exit;
  } else if (command === 'validate') {
    process.exitCode = commandValidate(options).exit;
  } else if (command === 'inspect') {
    process.exitCode = commandStatus(options, true).exit;
  } else if (command === 'defer') {
    process.exitCode = commandDefer(options).exit;
  } else if (command === 'release') {
    const result = commandRelease(options);
    emit(result.receipt, options);
    process.exitCode = result.exit;
  } else if (command === 'reconcile') {
    const result = commandReconcile(options);
    emit(result.receipt, options);
    process.exitCode = result.exit;
  } else if (command === 'status') {
    process.exitCode = commandStatus(options).exit;
  } else if (command === 'history') {
    process.exitCode = commandHistory(options).exit;
  } else {
    throw laneError('usage: gate-lane.mjs run|acquire|release|validate|defer|inspect|status|history|reconcile [options]');
  }
}
main().catch(error => {
  console.error(`gate lane: ${error.message}`);
  process.exitCode = error.exit || 76;
});
