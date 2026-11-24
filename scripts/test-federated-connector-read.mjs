#!/usr/bin/env node
// A federated connector READ between two real nodes, on one machine: the row main-health did not have.
//
//   node scripts/test-federated-connector-read.mjs [<wa binary>]
//
// Why it cannot be a one-process test: the failure it exists for is between processes. A master runs a
// peer's connector as `peer_<node>__mcp_<id>_<tool>`; the call crosses the signed peer call, arrives on
// the peer through its outbound relay lane, and there the node starts a persistent MCP **read session**
// (lua/core/mcp_session.lua) as a supervised operation. Three things meet at that point and none of them
// is visible in a single interpreter:
//
//   * the relay lane makes the request the thread's runtime OWNER (`relay:<rid>`,
//     rust/wa-rendezvous/src/binding_runtime.rs), which decides what the operation RECORDS
//     (rust/wa-capabilities/src/operations.rs, `configure_spec`),
//   * the Lua side names an owner of its own when it starts the session and again on every later
//     observe, and
//   * the operation manager refuses a caller whose name is not the recorded one (`operation_not_yours`).
//
// Measured before the fix (24/11): every pair - main -> main, main -> v0.1.1 and v0.1.1 -> v0.1.1 -
// answered `mcp_session_startup_failed` / `operation_not_yours` and left a 3600 s read session parked on
// the peer, while the same read on the peer itself answered ok. The fix is that `operation start` answers
// the owner it recorded, so this row asserts both halves: the read answers, AND the row it answered from
// was really started by the relay lane (owner `relay:<rid>`). Without the second assertion the row could
// pass on a peer that was reachable directly, where the bug never showed.
//
// Everything is scratch and local: its own HOME, key, database and ports per node, its own rendezvous on
// 127.0.0.1, every WA_*/WASM_AGENT_* variable (vault included) dropped before any child starts, no model,
// no live fleet, and only the child processes this run started are ever killed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE_SCRIPT = path.join(ROOT, 'scripts/test-federated-connector-read-node.lua');
const STUB = path.join(ROOT, 'scripts/fixtures/mcp-session-peer.mjs');
const REAL_HOME = path.resolve(os.homedir());
// The Lua tree the child nodes load. A caller that names one (the gate does, and so does
// scripts/test-discriminates.sh, which puts another tree's code under this file) is obeyed: every row in
// this repository runs that way, and a row that quietly substituted its own tree would be judging a
// different diff than the one it was asked about. Absent, it is this file's own tree.
const LUA_ROOT = process.env.WASM_AGENT_LUA_ROOT || ROOT;

function bin() {
  const given = process.argv[2] || process.env.WA_BIN || '';
  const candidates = [given, path.join(ROOT, 'rust/target/release/wa'), path.join(ROOT, 'rust/target/debug/wa')]
    .filter(Boolean);
  for (const candidate of candidates) if (fs.existsSync(candidate)) return candidate;
  return '';
}
const BIN = bin();
if (!BIN) {
  console.log('federated connector read: SKIPPED (no wa binary: pass one, or set WA_BIN)');
  process.exit(77);
}
if (!fs.existsSync(STUB)) {
  console.log('federated connector read: FAIL (the stdio MCP fixture is missing: ' + STUB + ')');
  process.exit(1);
}

// A test may never write into the node the operator is running on.
const guarded = [process.env.WASM_AGENT_HOME, process.env.HOME].filter(Boolean)
  .map(value => path.resolve(value));
if (guarded.some(value => value === path.join(REAL_HOME, '.wasm-agent') && process.env.WA_FED_ALLOW_REAL_HOME !== '1')) {
  console.log('federated connector read: FAIL (refusing to run with WASM_AGENT_HOME at the real ~/.wasm-agent)');
  process.exit(1);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-fed-read-'));
if (path.resolve(work) === path.join(REAL_HOME, '.wasm-agent')) {
  console.log('federated connector read: FAIL (the scratch directory is the real node home)');
  process.exit(1);
}
// Every variable that could point a child at an operator's node, vault or provider is dropped: what this
// script sets is the whole environment of every process it starts.
const baseEnv = Object.fromEntries(Object.entries(process.env)
  .filter(([name]) => !/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_)/i.test(name)));
const children = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let checks = 0;
let fails = 0;
function check(condition, label, detail) {
  checks += 1;
  if (condition) { console.log('  ok: ' + label); return true; }
  fails += 1;
  console.log('  FAIL: ' + label + (detail ? ' - ' + detail : ''));
  return false;
}
function homeOf(name) {
  const home = path.join(work, name);
  fs.mkdirSync(path.join(home, '.wasm-agent'), {recursive: true});
  fs.writeFileSync(path.join(home, '.wasm-agent/node.name'), name + '\n');
  return home;
}
function envFor(name, extra = {}) {
  return {...baseEnv, HOME: homeOf(name), WASM_AGENT_HOME: homeOf(name),
    WASM_AGENT_LUA_ROOT: LUA_ROOT, WASM_AGENT_MANAGED: '0', WASM_AGENT_RELAY: '',
    WA_GRAPH_WATCH: '0', PATH: process.env.PATH, ...extra};
}
function cli(name, args, input, extra) {
  return spawnSync(BIN, args, {cwd: homeOf(name), env: envFor(name, extra), input, encoding: 'utf8', timeout: 180000});
}
function script(name, action, extra) {
  const r = cli(name, [], '', {WA_SCRIPT: NODE_SCRIPT, WA_FED_ACTION: action,
    WA_FED_NODE_PROGRAM: process.execPath, WA_FED_STUB: STUB, WA_FED_STUB_LOG: path.join(work, 'stub.jsonl'), ...extra});
  const line = (r.stdout || '').trim().split('\n').pop() || '';
  let answer; try { answer = JSON.parse(line); } catch { answer = {error: 'unreadable_answer', stdout: line, stderr: r.stderr}; }
  return answer;
}
function start(name, args, extra) {
  const logPath = path.join(work, name + '-' + children.length + '.log');
  const out = fs.openSync(logPath, 'a');
  const child = spawn(BIN, args, {cwd: homeOf(name), env: envFor(name, extra), stdio: ['ignore', out, out], windowsHide: true});
  fs.closeSync(out);
  children.push(child);
  return child;
}
function stopAll() {
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) { try { child.kill(); } catch {} }
  }
}
function finish(code) {
  stopAll();
  if (process.env.WA_FED_KEEP === '1') console.log('  work kept: ' + work);
  else fs.rmSync(work, {recursive: true, force: true});
  process.exit(code);
}
async function port() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const chosen = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return chosen;
}
async function request(url, method = 'GET', body, headers = {}) {
  const response = await fetch(url, {method, body, headers, signal: AbortSignal.timeout(180000)});
  const text = await response.text();
  let value; try { value = JSON.parse(text); } catch { value = text; }
  return {status: response.status, value};
}
async function until(probe, label, tries = 240) {
  for (let i = 0; i < tries; i += 1) { if (await probe()) return true; await sleep(250); }
  throw new Error('timed out waiting for ' + label);
}
const sha = text => crypto.createHash('sha256').update(text).digest('hex');

async function main() {
  console.log('federated connector read: ' + BIN + ' (lua ' + LUA_ROOT + ')');
  const identity = {};
  for (const name of ['caller', 'peer', 'registry']) {
    const r = cli(name, ['node']);
    if (r.status !== 0) throw new Error('wa node failed for ' + name + ': ' + (r.stderr || r.stdout));
    identity[name] = JSON.parse(r.stdout);
  }
  const sign = (name, text) => cli(name, ['node', 'sign', text]).stdout.trim();
  const headers = (name, action, body) => {
    const ts = Math.floor(Date.now() / 1000);
    const text = action + '|' + identity[name].node_id + '|' + ts + (body === undefined ? '' : '|' + sha(body));
    return {'content-type': 'application/json', 'x-wa-node': identity[name].node_id,
      'x-wa-pub': identity[name].public_key, 'x-wa-ts': String(ts), 'x-wa-sig': sign(name, text)};
  };

  const registryPort = await port();
  start('registry', ['rendezvous', '--port', String(registryPort), '--bind', '127.0.0.1'],
    {WASM_AGENT_NETWORK_ADMINS: identity.caller.node_id});
  const service = 'http://127.0.0.1:' + registryPort;
  await until(async () => { try { return (await request(service + '/health')).status === 200; } catch { return false; } }, 'the rendezvous');
  for (const [name, role] of [['caller', 'master'], ['peer', 'guest']]) {
    const ts = Math.floor(Date.now() / 1000);
    const body = JSON.stringify({node_id: identity[name].node_id, public_key: identity[name].public_key,
      name, role, endpoints: [], ts,
      signature: sign(name, 'v2|' + identity[name].node_id + '|' + ts + '|' + name + '|[]')});
    const answer = await request(service + '/register', 'POST', body, {'content-type': 'application/json'});
    if (answer.status !== 200) throw new Error('register ' + name + ' refused: ' + answer.status + ' ' + JSON.stringify(answer.value));
  }
  check(true, 'a scratch rendezvous lists both nodes (' + service + ')');

  // The peer is enrolled the product's own way: it asks, the master accepts, and its outbound lane takes
  // the calls. That lane is what makes the call arrive as `relay:<rid>` - the condition under test.
  const bind = cli('peer', ['bind', service], 'BIND\n');
  check(bind.status === 0, 'the peer submits its binding request', bind.stdout + bind.stderr);
  const pending = JSON.parse(fs.readFileSync(path.join(homeOf('peer'), '.wasm-agent/binding.json'), 'utf8'));
  const accept = cli('caller', ['accept', pending.request.code], 'ACCEPT\n', {WASM_AGENT_RENDEZVOUS: service});
  check(accept.status === 0, 'the master accepts the peer', accept.stdout + accept.stderr);
  start('peer', ['bind', 'run']);
  await until(async () => {
    const answer = await request(service + '/lookup?node_id=' + identity.peer.node_id, 'GET', undefined,
      headers('caller', 'lookup'));
    return answer.value && answer.value.relay_attached === true;
  }, 'the peer relay attach', 480);
  check(true, 'the peer is attached to the relay (its calls arrive in the relay lane)');

  // The connector: mcp.control put -> probe -> enable, the three steps /mcp <id> probe and on run.
  const setup = script('peer', 'setup');
  const tool = setup.tool;
  check(setup.step === 'done' && typeof tool === 'string', 'the peer publishes the stub read tool', JSON.stringify(setup));
  if (!tool) return finish(1);

  const control = script('peer', 'local', {WA_FED_TOOL: tool});
  check(control.control && control.control.ok === true && control.control.session_mode === 'persistent-read',
    'the same read answers ON the peer with no relay lane under it (the control)', JSON.stringify(control).slice(0, 400));

  const call = script('caller', 'call', {WA_FED_TOOL: tool, WA_FED_PEER: identity.peer.node_id,
    WASM_AGENT_RENDEZVOUS: service, WASM_AGENT_RELAY: service});
  const answer = call.call || {};
  const echoed = answer.result && answer.result.structuredContent && answer.result.structuredContent.value;
  check(answer.ok === true && echoed && echoed.federated === 1,
    'the federated connector read answers the caller', JSON.stringify(call).slice(0, 600));

  // ... and it answered FROM the relay lane: the row this call started carries the runtime owner the
  // lane imposed. This is what makes the check above cover the bug instead of passing beside it.
  const operationsDir = path.join(homeOf('peer'), '.wasm-agent/operations');
  const rows = fs.existsSync(operationsDir)
    ? fs.readdirSync(operationsDir).filter(entry => entry.startsWith('op-')).map(entry => {
        const file = path.join(operationsDir, entry, 'state.json');
        return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
      }).filter(Boolean)
    : [];
  const relayed = rows.filter(row => typeof row.owner === 'string' && row.owner.startsWith('relay:'));
  check(relayed.length >= 1, 'the call was really run in the relay lane (its read session is owned by relay:<rid>)',
    rows.map(row => row.owner).join(', '));
  check(relayed.every(row => row.session === '' || typeof row.session === 'string'),
    'the read session rows carry the session the node recorded', JSON.stringify(rows.map(row => ({owner: row.owner, session: row.session}))));

  console.log(fails === 0 ? 'federated connector read ok (' + checks + ' checks)'
    : 'federated connector read FAILED (' + fails + ' of ' + checks + ' checks)');
  return finish(fails === 0 ? 0 : 1);
}

main().catch(error => {
  console.log('  FAIL: the harness threw - ' + (error && error.message));
  return finish(1);
});
