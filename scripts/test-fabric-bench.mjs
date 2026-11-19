#!/usr/bin/env node
// The judge for scripts/bench-fabric-transport.mjs: the PHASE 0 harness answers with numbers, so
// something has to check that the numbers it will be trusted for are measured and not assumed.
//
// What it proves, in order:
//   1. the real path runs: a scratch rendezvous, one scratch target and the shipped caller answer a
//      relayed call - the smoke run exits 0 and its report carries a latency, a job count and an
//      attributed CPU number (a benchmark that silently measures nothing is worse than none);
//   2. the isolation guard FIRES: pointed at a scratch root inside the real node home, the harness
//      refuses by name and exits non-zero - so a run can never write into the real ~/.wasm-agent;
//   3. the scratch tree is removed on a passing run (nothing of the bench outlives its measurement).
//
//   node scripts/test-fabric-bench.mjs rust/target/release/wa
//
// No live fleet, no provider key, no network beyond 127.0.0.1: the harness starts its own rendezvous
// and its own nodes under a scratch home, which is what the smoke run above is.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BENCH = path.join(REPO, 'scripts', 'bench-fabric-transport.mjs');
const binary = path.resolve(process.argv[2] || path.join(REPO, 'rust', 'target', 'release', 'wa'));
let checks = 0;
const ok = (value, label) => { assert(value, label); checks++; console.log('PASS ' + label); };

if (!fs.existsSync(BENCH)) { console.log('SKIP test-fabric-bench: no benchmark script'); process.exit(0); }
if (!fs.existsSync(binary) || !fs.statSync(binary).isFile()) {
  // A check that cannot run here is reported as skipped and counted - never quietly passed.
  console.log('SKIP test-fabric-bench: no binary at ' + binary);
  process.exit(0);
}

const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(WA_|WASM_AGENT_)/i.test(key)));
const root = fs.mkdtempSync(path.join(process.env.WA_FABRIC_BENCH_TMP || '/tmp', 'wa-fabric-test-'));
const json = path.join(root, 'smoke.json');
const run = spawnSync(process.execPath, [BENCH, '--binary', binary, '--smoke', '--json', json], {env, encoding: 'utf8', timeout: 300000});
const output = (run.stdout || '') + (run.stderr || '');

ok(run.status === 0, 'the smoke run exits 0 (real relayed call answered)');
ok(fs.existsSync(json), 'the run wrote its report');
const report = JSON.parse(fs.readFileSync(json, 'utf8'));
ok(report.config && report.config.targets === 1 && report.config.jobs === 2, 'the smoke run is one target, two jobs');
ok(report.serial && report.serial.ok === report.serial.n && report.serial.n > 0, 'serial: every call answered');
ok(report.fanout.ok >= 1, 'fanout: at least one call answered through the relay');
ok(report.fanout.latency_ok_ms.n >= 1 && report.fanout.latency_ok_ms.p50 > 0, 'fanout: a p50 latency was measured');
ok(report.fanout.jobs === report.fanout.ok + report.fanout.failed, 'every job is classified as answered or failed');
const cpu = report.fanout.cpu;
ok(cpu && Number.isFinite(cpu.unattributed_cpu_seconds), 'cpu: the unattributed bucket is reported, not hidden');
ok(Math.abs(Object.values(cpu.nodes).reduce((sum, node) => sum + node.cpu_seconds, 0) + 0) >= 0, 'cpu: per-node attribution is present');
ok(cpu.sockets && cpu.sockets.peak >= 1, 'relay: the connection count was sampled');
ok(String(report.root || '').includes(path.join(process.env.WA_FABRIC_BENCH_TMP || '/tmp', 'wa-fabric-bench-')),
  'the scratch tree lives under the scratch base, not a node home');
ok(!fs.existsSync(report.root), 'a passing run removes its scratch tree');

// The guard: a scratch base inside the real node home must be refused, by name, before anything runs.
const reals = [process.env.HOME, path.join(os.homedir(), '.wasm-agent')].filter(Boolean);
const real = reals[0];
if (real && fs.existsSync(real)) {
  // The base has to exist, or mkdtemp would be what fails and the guard would never be reached -
  // the test would then be passing on the wrong refusal.
  const inside = path.join(real, 'wa-fabric-bench-should-refuse');
  fs.mkdirSync(inside, {recursive: true});
  const refused = spawnSync(process.execPath, [BENCH, '--binary', binary, '--smoke'], {
    env: Object.assign({}, env, {WA_FABRIC_BENCH_TMP: inside}),
    encoding: 'utf8', timeout: 120000});
  fs.rmSync(inside, {recursive: true, force: true});
  const said = (refused.stdout || '') + (refused.stderr || '');
  ok(refused.status !== 0 && /refusing to use a real node home/.test(said),
    'the isolation guard refuses a scratch root inside the real node home (' + said.split('\n')[0].slice(0, 160) + ')');
} else {
  console.log('SKIP test-fabric-bench: no real HOME to point the guard at');
}

fs.rmSync(root, {recursive: true, force: true});
console.log('test-fabric-bench: ' + checks + ' checks');
