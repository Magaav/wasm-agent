#!/usr/bin/env node
// PHASE 0 of change/fabric-transport: what today's fabric costs and what it can carry.
//
// The question the brief asks (Victor, 19/11): "will we be able to take full power of the fabric and
// parallel working 100% cpu usage?" A benchmark has to answer with numbers, and the same numbers have
// to be comparable after each phase - so this harness measures the REAL path, unchanged:
//
//   caller 'wa call <peer> bash {...}' (lua/core/nodes.lua remote_call)
//     -> rendezvous /relay/send      (rust/wa-rendezvous, signed envelope, one held connection)
//     -> target /relay/poll          (rust/wa-rendezvous/src/relay_client.rs, the node's poll lane)
//     -> target serve loop           (rust/wa-capabilities/src/serve.rs, node-thread 0 runs the call)
//     -> target /relay/respond       -> the caller collects it.
//
// Nothing here is re-implemented: the caller is the shipped CLI, the relay is the shipped rendezvous,
// the targets are shipped 'wa serve' processes. The harness only starts them, drives them and measures.
//
// What it reports:
//   * serial     - N calls, one at a time, to one unloaded node: the cost of one remote call.
//   * fanout     - --jobs (default 4 x cores) concurrent calls spread over --targets nodes: calls/s,
//                  p50/p95/p99 latency, failures by reason, and the CPU each target turned into work
//                  (from /proc, whole process tree, so the shell a call forks is counted).
//   * storm      - the same fan-out with the rendezvous frozen for --cut-seconds and resumed: how many
//                  calls survive the cut, how the relay behaves (refusals, abandons, late answers), and
//                  the log evidence around it.
//
// Isolation (rule 2 of this branch): every process this script starts gets its own scratch
// WASM_AGENT_HOME, the whole WASM_AGENT_*/WA_* environment of the caller is dropped, and the script
// refuses a home that is the real node's. It never touches the live fleet: the rendezvous is a local
// process on 127.0.0.1 and the nodes are its own.
//
//   node scripts/bench-fabric-transport.mjs --binary rust/target/release/wa [--targets 4] [--jobs 64]
//        [--burn-ms 1000] [--serial 10] [--storm] [--cut-seconds 60] [--json out.json] [--keep]
//        [--smoke]            one target, two short jobs - the self-check a test row can afford.
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLK_TCK = 100; // Linux USER_HZ; the CPU ticks /proc/<pid>/stat counts in.

function parseArgs(argv) {
  const args = {targets: 4, jobs: 0, burn_ms: 1000, serial: 10, storm: false, cut_seconds: 60,
    keep: false, smoke: false, json: '', tag: '', binary: '', verbose: false};
  for (let index = 0; index < argv.length; index++) {
    const word = argv[index];
    const value = () => argv[++index];
    if (word === '--binary') args.binary = value();
    else if (word === '--targets') args.targets = Number(value());
    else if (word === '--jobs') args.jobs = Number(value());
    else if (word === '--burn-ms') args.burn_ms = Number(value());
    else if (word === '--serial') args.serial = Number(value());
    else if (word === '--storm') args.storm = true;
    else if (word === '--cut-seconds') args.cut_seconds = Number(value());
    else if (word === '--json') args.json = value();
    else if (word === '--tag') args.tag = value();
    else if (word === '--keep') args.keep = true;
    else if (word === '--smoke') { args.smoke = true; args.targets = 1; args.jobs = 2; args.burn_ms = 200; args.serial = 2; }
    else if (word === '--verbose') args.verbose = true;
    else if (word === '--help' || word === '-h') { console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(0, 32).join('\n')); process.exit(0); }
    else throw new Error('bench: unknown argument ' + word);
  }
  if (!args.binary) args.binary = path.join(REPO, 'rust', 'target', 'release', 'wa');
  if (!args.jobs) args.jobs = Math.max(4, 4 * os.cpus().length);
  return args;
}

// ---- isolation ------------------------------------------------------------------------------------
// A child gets this environment and nothing inherited that could name a real node, provider or home.
function scratchEnv(home, extra = {}) {
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|GEMINI_|GOOGLE_)/i.test(key)) continue;
    if (key === 'HOME') continue;
    env[key] = value;
  }
  return Object.assign(env, {HOME: home, WASM_AGENT_HOME: home, WA_GRAPH_WATCH: '0',
    WASM_AGENT_SKIP_UI_TESTS: '1'}, extra);
}

// The real node's home is the one directory this benchmark must never write to. Both names are
// checked, because a child resolves WASM_AGENT_HOME first and HOME second (wa-host-support paths).
function realHomeOverlap(candidate) {
  const real = [process.env.HOME, path.join(os.homedir(), '.wasm-agent')].filter(Boolean);
  for (const other of real) {
    const a = path.resolve(candidate);
    const b = path.resolve(other);
    if (a === b || a.startsWith(b + path.sep) || b.startsWith(a + path.sep)) return other;
  }
  return '';
}

// The BASE is checked before mkdtemp: creating the scratch tree first and refusing afterwards would
// already have written inside the real home, which is the one thing this guard exists to prevent.
function assertScratchBase(base) {
  const bad = realHomeOverlap(base);
  if (bad) throw new Error('bench: refusing to use a real node home (' + base + ' overlaps ' + bad + ')');
}

function assertScratchHome(home) {
  assertScratchBase(home);
  if (!home.includes('wa-fabric-bench-')) {
    throw new Error('bench: scratch home must carry the wa-fabric-bench- marker (' + home + ')');
  }
}

// ---- processes ------------------------------------------------------------------------------------
const children = [];
function startProcess(name, args, env, cwd) {
  const log = path.join(env.WASM_AGENT_HOME, name + '.log');
  const handle = fs.openSync(log, 'a');
  const child = spawn(args[0], args.slice(1), {cwd, env, stdio: ['ignore', handle, handle], windowsHide: true});
  fs.closeSync(handle);
  child.log = log;
  child.title = name;
  children.push(child);
  return child;
}

function stopProcess(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => { if (!settled) { settled = true; clearTimeout(kill); resolve(); } };
    child.once('exit', finish);
    try { child.kill('SIGCONT'); child.kill('SIGTERM'); } catch { finish(); }
    const kill = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* already gone */ } finish(); }, 5000);
  });
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(label, probe, timeoutMs = 60000) {
  const started = Date.now();
  let last = '';
  while (Date.now() - started < timeoutMs) {
    try { const answer = await probe(); if (answer) return answer; }
    catch (error) { last = String(error && error.message || error); }
    await sleep(100);
  }
  throw new Error('bench: timed out waiting for ' + label + (last ? ' (' + last + ')' : ''));
}

async function httpJson(url, options = {}) {
  const response = await fetch(url, Object.assign({signal: AbortSignal.timeout(options.timeout_ms || 70000)}, options));
  const text = await response.text();
  let value;
  try { value = JSON.parse(text); } catch { value = text; }
  return {status: response.status, value};
}

// One signed request sent by a scratch node's own key, the way lua/core/nodes.lua signs it:
// 'action|node_id|ts' plus the sha256 of the body when there is one.
function signedHeaders(node, action, body) {
  const ts = Math.floor(Date.now() / 1000);
  const message = body === undefined ? action + '|' + node.node_id + '|' + ts
    : action + '|' + node.node_id + '|' + ts + '|' + crypto.createHash('sha256').update(body).digest('hex');
  const result = spawnSync(node.binary, ['node', 'sign', message], {cwd: node.home, env: node.env, encoding: 'utf8', timeout: 60000});
  if (result.status !== 0 || !result.stdout.trim()) {
    throw new Error('bench: node sign failed for ' + node.name + ': ' + (result.stderr || result.stdout || result.error));
  }
  return {'content-type': 'application/json', 'x-wa-node': node.node_id,
    'x-wa-pub': node.public_key, 'x-wa-ts': String(ts), 'x-wa-sig': result.stdout.trim()};
}

// ---- measurement ----------------------------------------------------------------------------------
// CPU of a process tree, from /proc: utime+stime of every descendant of 'root', in ticks. The shell a
// relayed 'bash' call forks is a grandchild of 'wa serve', so the tree is what "CPU per node" means.
function procTable() {
  const table = new Map();
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    let stat;
    try { stat = fs.readFileSync('/proc/' + entry + '/stat', 'utf8'); } catch { continue; }
    const close = stat.lastIndexOf(')');
    if (close < 0) continue;
    const fields = stat.slice(close + 2).split(' ');
    // After the comm field: state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt
    // utime(11) stime(12) ... - so from index 0 = state, ppid is index 1 and utime/stime are 11/12.
    const ppid = Number(fields[1]);
    const ticks = Number(fields[11]) + Number(fields[12]);
    table.set(Number(entry), {ppid, ticks});
  }
  return table;
}

function treeTicks(table, root) {
  const byParent = new Map();
  for (const [pid, row] of table) {
    if (!byParent.has(row.ppid)) byParent.set(row.ppid, []);
    byParent.get(row.ppid).push(pid);
  }
  let total = 0;
  const stack = [root];
  const seen = new Set();
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    const row = table.get(pid);
    if (row) total += row.ticks;
    for (const child of byParent.get(pid) || []) stack.push(child);
  }
  return total;
}

// Open sockets of a process, from /proc/<pid>/fd. The rendezvous is thread-per-connection, so this is
// literally the number of connections it is paying a thread for.
function socketCount(pid) {
  try {
    let count = 0;
    for (const fd of fs.readdirSync('/proc/' + pid + '/fd')) {
      try { if (fs.readlinkSync('/proc/' + pid + '/fd/' + fd).startsWith('socket:')) count++; } catch { /* closed */ }
    }
    return count;
  } catch { return 0; }
}

function percentile(sorted, percent) {
  if (!sorted.length) return 0;
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((percent / 100) * sorted.length) - 1));
  return sorted[index];
}

function summary(values) {
  if (!values.length) return {n: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0};
  const sorted = [...values].sort((left, right) => left - right);
  return {n: values.length, p50: Math.round(percentile(sorted, 50)), p95: Math.round(percentile(sorted, 95)),
    p99: Math.round(percentile(sorted, 99)), max: Math.round(sorted[sorted.length - 1]),
    mean: Math.round(sorted.reduce((sum, value) => sum + value, 0) / sorted.length)};
}

// A sampler that runs for the whole measurement: per target its CPU, and the rendezvous socket count.
// It reads only /proc, so it costs nothing measurable next to the work it watches.
//
// CPU IS ATTRIBUTED TWO WAYS, and the second one was measured, not guessed: a relayed bash call's shell
// is NOT a child of the wa serve process on this node (the sandbox re-parents it, so the serve pid's own
// tree accounted for 2.6 CPU-seconds of the 16 this host burned). So every hot process is attributed by
// the tree it is in AND by the node home its environment carries; whatever neither can claim is counted
// as unattributed and reported, never folded into a node's number.
function treeSet(table, root) {
  const byParent = new Map();
  for (const [pid, row] of table) {
    if (!byParent.has(row.ppid)) byParent.set(row.ppid, []);
    byParent.get(row.ppid).push(pid);
  }
  const seen = new Set();
  const stack = [root];
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    for (const child of byParent.get(pid) || []) stack.push(child);
  }
  return seen;
}

function environHas(pid, marker) {
  try {
    return fs.readFileSync('/proc/' + pid + '/environ', 'utf8').split('\0').includes(marker);
  } catch { return false; }
}

function startSampler(targets, rendezvousPid, extras = []) {
  const samples = [];
  const baseline = new Map();
  const started = Date.now();
  const homes = [...targets, ...extras].map((node) => ({name: node.name, marker: 'WASM_AGENT_HOME=' + node.home}));
  const timer = setInterval(() => {
    const now = procTable();
    const row = {at: Date.now() - started, sockets: socketCount(rendezvousPid), nodes: {}, unattributed: 0};
    for (const target of targets) row.nodes[target.name] = 0;
    const owners = new Map(); // pid -> target name, for the pids in a node's own tree
    for (const target of targets) {
      for (const pid of treeSet(now, target.pid)) if (!owners.has(pid)) owners.set(pid, target.name);
    }
    for (const [pid, current] of now) {
      const previous = baseline.get(pid);
      if (previous === undefined || current.ticks < previous) continue;
      const spent = (current.ticks - previous) / CLK_TCK;
      if (spent <= 0) continue;
      let owner = owners.get(pid);
      if (!owner) {
        for (const home of homes) {
          if (environHas(pid, home.marker)) { owner = home.name; break; }
        }
      }
      if (owner) row.nodes[owner] = (row.nodes[owner] || 0) + spent;
      else row.unattributed += spent;
    }
    for (const [pid, current] of now) baseline.set(pid, current.ticks);
    samples.push(row);
  }, 200);
  timer.unref();
  return {
    stop() {
      clearInterval(timer);
      const seconds = (Date.now() - started) / 1000;
      const per_sample_seconds = 0.2;
      const nodes = {};
      for (const target of [...targets, ...extras]) {
        const values = samples.map((row) => row.nodes[target.name] || 0);
        nodes[target.name] = {
          cores_mean: Number((values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length) / per_sample_seconds).toFixed(2)),
          cores_peak: Number((Math.max(0, ...values) / per_sample_seconds).toFixed(2)),
          cpu_seconds: Number(values.reduce((sum, value) => sum + value, 0).toFixed(2)),
        };
      }
      const sockets = samples.map((row) => row.sockets);
      const unattributed = samples.reduce((sum, row) => sum + row.unattributed, 0);
      return {seconds: Number(seconds.toFixed(1)), samples: samples.length,
        sockets: {mean: Number((sockets.reduce((sum, value) => sum + value, 0) / Math.max(1, sockets.length)).toFixed(1)),
          peak: sockets.length ? Math.max(...sockets) : 0},
        unattributed_cpu_seconds: Number(unattributed.toFixed(2)), nodes};
    },
  };
}

// ---- the fabric under test ------------------------------------------------------------------------
async function startFabric(args) {
  const binary = path.resolve(args.binary);
  if (!fs.existsSync(binary)) throw new Error('bench: no binary at ' + binary + ' (build it: cargo build --release --manifest-path rust/Cargo.toml)');
  // The scratch tree lives outside every node home: a session's TMPDIR can point INSIDE one (this
  // agent's does), and a benchmark that wrote there would be exactly the accident the guard refuses.
  const base = process.env.WA_FABRIC_BENCH_TMP || (fs.existsSync('/tmp') ? '/tmp' : os.tmpdir());
  assertScratchBase(base);
  const root = fs.mkdtempSync(path.join(base, 'wa-fabric-bench-'));
  const service = 'http://127.0.0.1:' + (await freePort());
  const port = Number(service.split(':').pop());
  const nodes = [];
  const make = async (name) => {
    const home = path.join(root, name);
    fs.mkdirSync(home, {recursive: true});
    assertScratchHome(home);
    const node = {name, home, binary, env: scratchEnv(home)};
    const identity = spawnSync(binary, ['node'], {cwd: home, env: node.env, encoding: 'utf8', timeout: 60000});
    if (identity.status !== 0) throw new Error('bench: wa node failed in ' + home + ': ' + (identity.stderr || identity.stdout));
    Object.assign(node, JSON.parse(identity.stdout));
    nodes.push(node);
    return node;
  };
  const caller = await make('caller');
  const targets = [];
  for (let index = 1; index <= args.targets; index++) targets.push(await make('target' + index));

  // Every scratch node is named in the registry's operator list: with no admins nobody is master
  // (rust/wa-rendezvous/src/rendezvous.rs register()), and /relay/send and /nodes both require it.
  const admins = nodes.map((node) => node.node_id).join(',');
  const registryHome = path.join(root, 'registry');
  fs.mkdirSync(registryHome, {recursive: true});
  assertScratchHome(registryHome);
  const registry = startProcess('rendezvous',
    [binary, 'rendezvous', '--port', String(port), '--db', path.join(registryHome, 'rendezvous.db')],
    scratchEnv(registryHome, {WASM_AGENT_NETWORK_ADMINS: admins}), registryHome);

  await waitFor('rendezvous /health', async () => (await httpJson(service + '/health', {timeout_ms: 2000})).status === 200);

  // Register every node: the announcement a rendezvous verifies is
  // 'v2|node_id|ts|name|endpoints' signed by the node key (rust/wa-rendezvous/src/node.rs).
  for (const node of nodes) {
    const ts = Math.floor(Date.now() / 1000);
    const message = 'v2|' + node.node_id + '|' + ts + '|' + node.name + '|[]';
    const signature = spawnSync(binary, ['node', 'sign', message], {cwd: node.home, env: node.env, encoding: 'utf8', timeout: 60000});
    if (signature.status !== 0) throw new Error('bench: could not sign the announcement for ' + node.name);
    const payload = JSON.stringify({node_id: node.node_id, public_key: node.public_key, name: node.name,
      endpoints: [], ts, signature: signature.stdout.trim()});
    const answer = await httpJson(service + '/register', {method: 'POST', body: payload, headers: {'content-type': 'application/json'}});
    if (answer.status !== 200) throw new Error('bench: /register refused ' + node.name + ': ' + answer.status + ' ' + JSON.stringify(answer.value));
  }

  // Each target serves on its own ports and attaches to the relay: WASM_AGENT_RELAY starts the poll
  // lane (rust/wa-capabilities/src/serve.rs), so a call to it travels the relay, never a direct hop.
  for (const target of targets) {
    target.port = await freePort();
    target.client_port = await freePort();
    target.serve = startProcess('serve',
      [binary, 'serve', '--port', String(target.port), '--client-port', String(target.client_port), '--ui', path.join(REPO, 'ui')],
      Object.assign({}, target.env, {WASM_AGENT_RELAY: service, WASM_AGENT_RENDEZVOUS: service}), target.home);
    target.pid = target.serve.pid;
    await waitFor('target ' + target.name + ' /health', async () => (await httpJson('http://127.0.0.1:' + target.port + '/health', {timeout_ms: 2000})).status === 200);
  }
  // The caller needs the relay for 'wa call' to take the relay path.
  caller.env = Object.assign({}, caller.env, {WASM_AGENT_RELAY: service, WASM_AGENT_RENDEZVOUS: service});

  // Attach is observable: /relay/status names every node that polled within the attach window, and a
  // call to a node that is not there is the difference between a transport measurement and noise.
  const statusHeaders = signedHeaders(caller, 'relay-status');
  const attached = await waitFor('relay attach of every target', async () => {
    const answer = await httpJson(service + '/relay/status', {headers: statusHeaders, timeout_ms: 5000});
    if (answer.status !== 200) return false;
    const list = answer.value.attached || [];
    return targets.every((target) => list.includes(target.node_id)) ? list : false;
  }, 90000);

  return {root, binary, service, port, registry, caller, targets, attached};
}

// One call through the shipped caller: 'wa call <peer> bash {"command": ...}'.
function callOnce(fabric, target, burnMs, timeoutMs) {
  const command = 'timeout ' + (burnMs / 1000) + " sh -c 'while :; do :; done'";
  const payload = JSON.stringify({command});
  const started = Date.now();
  return new Promise((resolve) => {
    // Addressed by node id, never by name: a serving node re-announces itself under its host name on
    // its own heartbeat (measured in the first smoke run: 're-registered as host (was target1)'), so a
    // name is not a stable selector for a peer.
    const child = spawn(fabric.binary, ['call', target.node_id, 'bash', payload],
      {cwd: fabric.caller.home, env: fabric.caller.env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
    let stdout = '';
    let stderr = '';
    let timed_out = false;
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => { timed_out = true; child.kill('SIGKILL'); }, timeoutMs);
    child.on('exit', (code) => {
      clearTimeout(timer);
      const ms = Date.now() - started;
      let answer = null;
      try { answer = JSON.parse(stdout); } catch { answer = null; }
      const reason = timed_out ? 'caller_timeout'
        : answer && typeof answer.error === 'string' ? answer.error + (answer.detail ? ':' + answer.detail : '')
        : code !== 0 ? 'exit_' + code
        : answer === null ? 'unreadable_answer' : '';
      resolve({ok: reason === '', reason, ms, code, answer, stderr: stderr.slice(0, 400)});
    });
  });
}

function logCounts(log, patterns) {
  let text = '';
  try { text = fs.readFileSync(log, 'utf8'); } catch { return {}; }
  const counts = {};
  for (const [label, pattern] of Object.entries(patterns)) {
    counts[label] = (text.match(pattern) || []).length;
  }
  return counts;
}

async function serial(fabric, args) {
  const target = fabric.targets[0];
  const samples = [];
  const answers = [];
  for (let index = 0; index < args.serial; index++) {
    const result = await callOnce(fabric, target, args.burn_ms, 120000);
    samples.push(result.ms);
    answers.push(result);
    if (!result.ok) break;
  }
  return {n: samples.length, latency_ms: summary(samples),
    ok: answers.filter((answer) => answer.ok).length,
    failed: answers.filter((answer) => !answer.ok).map((answer) => answer.reason)};
}

async function fanout(fabric, args, options = {}) {
  // The caller pays CPU too (one CLI process per call), and folding it into "unattributed" would hide
  // it: it gets its own bucket, so the unattributed number means foreign load on this host.
  const sampler = startSampler(fabric.targets, fabric.registry.pid, [{name: 'caller', home: fabric.caller.home}]);
  const started = Date.now();
  const pending = [];
  for (let index = 0; index < args.jobs; index++) {
    const target = fabric.targets[index % fabric.targets.length];
    pending.push(callOnce(fabric, target, args.burn_ms, 180000).then((result) =>
      Object.assign(result, {target: target.name, index, at: Date.now() - started})));
  }
  let cut = null;
  if (options.cut_ms) {
    await sleep(options.cut_after_ms || 2000);
    cut = {at: Date.now() - started};
    try { process.kill(fabric.registry.pid, 'SIGSTOP'); } catch { cut.failed = true; }
    cut.stopped = Date.now() - started;
    await sleep(options.cut_ms);
    try { process.kill(fabric.registry.pid, 'SIGCONT'); } catch { cut.failed = true; }
    cut.resumed = Date.now() - started;
  }
  const results = await Promise.all(pending);
  const wall_s = Number(((Date.now() - started) / 1000).toFixed(1));
  const cpu = sampler.stop();
  const ok = results.filter((result) => result.ok);
  const failures = {};
  for (const result of results.filter((result) => !result.ok)) {
    failures[result.reason] = (failures[result.reason] || 0) + 1;
  }
  // Only the targets are the fabric's capacity; the caller's own CPU is reported beside it, not
  // counted as capacity the fan-out reached.
  const busy = fabric.targets.map((target) => (cpu.nodes[target.name] || {cores_mean: 0}).cores_mean);
  // Convergence, for the storm: when the last call answered, when the last failure happened, and how
  // long after the rendezvous came back the first call succeeded again.
  let convergence = null;
  if (cut) {
    const after = results.filter((result) => result.at >= (cut.resumed || 0));
    const okAfter = after.filter((result) => result.ok);
    const failures = results.filter((result) => !result.ok);
    convergence = {
      successes_after_resume: okAfter.length,
      first_success_after_resume_ms: okAfter.length ? Math.min(...okAfter.map((result) => result.at - cut.resumed)) : null,
      last_failure_at_ms: failures.length ? Math.max(...failures.map((result) => result.at)) : null,
      last_call_at_ms: Math.max(...results.map((result) => result.at)),
      converged_ms: okAfter.length && failures.length
        ? Math.max(0, Math.max(...failures.map((result) => result.at)) - cut.resumed) : null,
    };
  }
  const cores_busy = Number(busy.reduce((sum, value) => sum + value, 0).toFixed(2));
  return {
    jobs: args.jobs, targets: fabric.targets.length, burn_ms: args.burn_ms, wall_s,
    calls_per_s: Number((ok.length / Math.max(0.001, wall_s)).toFixed(2)),
    ok: ok.length, failed: results.length - ok.length, failures,
    latency_ms: summary(results.map((result) => result.ms)),
    latency_ok_ms: summary(ok.map((result) => result.ms)),
    cpu: Object.assign({cores_busy_mean: cores_busy, cores_total: os.cpus().length,
      utilisation_pct: Number((100 * cores_busy / os.cpus().length).toFixed(1))}, cpu),
    cut,
    convergence,
    logs: {
      rendezvous: logCounts(fabric.registry.log, {
        attach: /\[relay\] attach /g, detach: /\[relay\] detach /g, abandon: /\[relay\] abandon /g,
        busy: /\[relay\] busy /g, late: /\[relay\] late /g, too_many: /too_many_connections/g,
      }),
      targets: fabric.targets.map((target) => ({name: target.name, counts: logCounts(target.serve.log, {
        dispatch: /\[relay\] dispatch /g, busy: /\[relay\] busy /g, timeout: /\[relay\] timeout /g,
        late: /\[relay\] late /g, answer_not_delivered: /answer not delivered/g,
      })})),
    },
  };
}

// ---- main -----------------------------------------------------------------------------------------
async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.smoke) args.storm = false;
  const started = Date.now();
  let fabric;
  const report = {tag: args.tag || 'phase0', at: new Date().toISOString(), host: {cpus: os.cpus().length},
    binary: path.resolve(args.binary), config: {targets: args.targets, jobs: args.jobs, burn_ms: args.burn_ms, serial: args.serial}};
  try {
    fabric = await startFabric(args);
    report.attached = fabric.attached.length;
    if (args.serial > 0) {
      report.serial = await serial(fabric, args);
      process.stderr.write('serial: ' + JSON.stringify(report.serial.latency_ms) + '\n');
    }
    report.fanout = await fanout(fabric, args);
    process.stderr.write('fanout: ' + JSON.stringify({ok: report.fanout.ok, failed: report.fanout.failed,
      calls_per_s: report.fanout.calls_per_s, latency: report.fanout.latency_ok_ms,
      cpu: {utilisation_pct: report.fanout.cpu.utilisation_pct, cores_busy_mean: report.fanout.cpu.cores_busy_mean},
      sockets: report.fanout.cpu.sockets, failures: report.fanout.failures}) + '\n');
    if (args.storm) {
      report.storm = await fanout(fabric, args, {cut_ms: args.cut_seconds * 1000, cut_after_ms: 2000});
      process.stderr.write('storm: ' + JSON.stringify({ok: report.storm.ok, failed: report.storm.failed,
        failures: report.storm.failures, wall_s: report.storm.wall_s, cut: report.storm.cut,
        logs: report.storm.logs.rendezvous}) + '\n');
    }
    report.elapsed_s = Number(((Date.now() - started) / 1000).toFixed(1));
    report.root = fabric.root;
  } finally {
    for (const child of [...children].reverse()) await stopProcess(child);
    const keep = args.keep || process.env.WA_FABRIC_BENCH_KEEP === '1';
    if (fabric && !keep) fs.rmSync(fabric.root, {recursive: true, force: true});
    else if (fabric) process.stderr.write('kept: ' + fabric.root + '\n');
  }
  const text = JSON.stringify(report, null, 2);
  if (args.json) fs.writeFileSync(args.json, text + '\n');
  process.stdout.write(text + '\n');
  if (args.smoke) {
    const fan = report.fanout;
    const problems = [];
    if (!report.serial || report.serial.ok !== report.serial.n) problems.push('serial calls did not all answer');
    if (fan.ok < 1) problems.push('no fan-out call answered');
    if (!(fan.cpu.cores_busy_mean >= 0)) problems.push('cpu accounting produced nothing');
    if (fan.latency_ok_ms.n < 1) problems.push('no latency sample');
    if (problems.length) { console.error('bench smoke: FAIL ' + problems.join('; ')); process.exit(1); }
    console.log('bench smoke: PASS ' + fan.ok + '/' + fan.jobs + ' calls answered, ' + fan.latency_ok_ms.p50 + ' ms p50');
  }
}

main().catch((error) => { console.error(String(error && error.stack || error)); process.exit(1); });
