// The request (and seed) file an MCP launch reads decides WHICH program the child spawns, and the child
// inherits the vault values the kernel put in its environment. Round 5's first hole: nothing compared
// that file's "server" against the operator's approval, and the directory was not in secret_guard, so a
// background loop could rewrite server.program between the console's write and the child's read.
//
// Two halves answer it, and this file proves the child's half on a real process: the kernel checks the
// server against the approval and passes the sha256 of the bytes it read (WA_MCP_REQUEST_SHA256 /
// WA_MCP_REQUEST_FILE); mcp-client.mjs and mcp-session.mjs hash the bytes THEY read and refuse anything
// else before spawning or connecting. The kernel's half is rust/wa-capabilities/src/operations.rs
// (requests_server_problem / seal_request, "the_request_the_child_reads_must_name_the_approved_command").
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

const scripts = fileURLToPath(new URL('.', import.meta.url));
const client = join(scripts, 'mcp-client.mjs');
const session = join(scripts, 'mcp-session.mjs');
const peer = join(scripts, 'fixtures', 'mcp-peer.mjs');
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const dir = mkdtempSync(join(tmpdir(), 'mcp-request-seal-'));
test.after(() => rmSync(dir, {recursive: true, force: true}));

// The environment a launch gets: this test's own, WITHOUT a seal inherited from anywhere else.
function env(seal = undefined) {
  const base = {...process.env, MCP_TEST_MODE: 'normal'};
  delete base.WA_MCP_REQUEST_SHA256;
  delete base.WA_MCP_REQUEST_FILE;
  return seal ? {...base, WA_MCP_REQUEST_SHA256: seal.digest, WA_MCP_REQUEST_FILE: seal.path} : base;
}
function server(program, args, extra = {}) {
  return {transport: 'stdio', program, args, env: {MCP_TEST_MODE: 'MCP_TEST_MODE'}, timeout_seconds: 5, ...extra};
}
function write(name, bytes) {
  const path = join(dir, name);
  writeFileSync(path, bytes);
  return {path, bytes};
}
function request(serverValue, name = 'request.json') {
  return write(name, Buffer.from(JSON.stringify({action: 'call', tool: 'echo', server: serverValue, arguments: {value: 'sealed'}})));
}
function run(path, seal) {
  const result = spawnSync(process.execPath, [client, '--request-file', path], {env: env(seal), encoding: 'utf8', timeout: 30000});
  const lines = result.stdout.trim().split('\n').filter(Boolean);
  return {result, answer: lines.length ? JSON.parse(lines.at(-1)) : null};
}

test('an unsealed or mismatched request never spawns: the bytes must be the ones the kernel checked', () => {
  const approved = request(server(process.execPath, [peer]));

  // No seal at all: a direct invocation is not a launch the kernel read.
  const unsealed = run(approved.path);
  assert.equal(unsealed.answer.error, 'mcp_request_not_approved');
  assert.equal(unsealed.answer.tool_call_issued, false);
  assert.notEqual(unsealed.result.status, 0);

  // A seal for different bytes: the file changed between the kernel's read and this one.
  const stale = run(approved.path, {path: approved.path, digest: sha(Buffer.from('{"other":true}'))});
  assert.equal(stale.answer.error, 'mcp_request_changed_since_approval');
  assert.equal(stale.answer.tool_call_issued, false);

  // A seal for another file: the launch names the file it approves.
  const elsewhere = run(approved.path, {path: join(dir, 'elsewhere.json'), digest: sha(approved.bytes)});
  assert.equal(elsewhere.answer.error, 'mcp_request_path_mismatch');
});

test('the approved bytes do spawn the approved command', () => {
  const approved = request(server(process.execPath, [peer]));
  const {result, answer} = run(approved.path, {path: approved.path, digest: sha(approved.bytes)});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(answer.ok, true, JSON.stringify(answer));
  assert.deepEqual(JSON.parse(answer.result_json).structuredContent, {value: 'sealed'}, 'the peer the request names answered');
});

test('the attack: server.program rewritten after the kernel read is refused, and the smuggled program never runs', () => {
  // What the console wrote, and what the kernel read and sealed.
  const approved = request(server(process.execPath, [peer]));
  const seal = {path: approved.path, digest: sha(approved.bytes)};
  // The background loop: the same path, a program of the attacker's choosing that records that it ran.
  const marker = join(dir, 'smuggled-ran');
  const smuggled = write('smuggled.mjs', Buffer.from('import {writeFileSync} from "node:fs";\n' + 'writeFileSync(process.argv[2], String(process.env.MCP_TEST_MODE ?? ""));\n'));
  writeFileSync(approved.path, JSON.stringify({action: 'call', tool: 'echo', server: server(process.execPath, [smuggled.path, marker]), arguments: {}}));
  const rewritten = run(approved.path, seal);
  assert.equal(rewritten.answer.error, 'mcp_request_changed_since_approval');
  assert.equal(rewritten.answer.tool_call_issued, false);
  assert.equal(existsSync(marker), false, 'the program the rewrite named was never spawned');

  // And the kernel's own half would have refused it first: the request no longer names the approved
  // command (rust/wa-capabilities/src/operations.rs, vault_request_program_mismatch).
  assert.notEqual(sha(readFileSync(approved.path)), seal.digest);
});

test('a read session seed is sealed the same way, before it connects', () => {
  const seedFile = (name) => join(dir, name);
  const seed = (serverValue, extra = {}) => write('seed.json', Buffer.from(JSON.stringify({
    server: serverValue, read_tools: ['echo'], token: 't'.repeat(64), ready_file: seedFile('ready.json'),
    request_dir: dir, credential_hashes: {}, idle_ms: 2000, ...extra})));
  const approved = seed(server(process.execPath, [peer]));

  const unsealed = spawnSync(process.execPath, [session, '--seed-file', approved.path], {env: env(), encoding: 'utf8', timeout: 30000});
  assert.match(unsealed.stderr, /mcp_request_not_approved/);
  assert.notEqual(unsealed.status, 0);
  assert.equal(existsSync(seedFile('ready.json')), false, 'nothing was connected, let alone served');

  const stale = spawnSync(process.execPath, [session, '--seed-file', approved.path],
    {env: env({path: approved.path, digest: sha(Buffer.from('{}'))}), encoding: 'utf8', timeout: 30000});
  assert.match(stale.stderr, /mcp_request_changed_since_approval/);
  assert.equal(existsSync(seedFile('ready.json')), false);
});

test('the sealed seed connects and serves, and says so once', async () => {
  const ready = join(dir, 'sealed-ready.json');
  const seedBytes = Buffer.from(JSON.stringify({server: server(process.execPath, [peer]), read_tools: ['echo'],
    token: 's'.repeat(64), ready_file: ready, request_dir: dir, credential_hashes: {}, idle_ms: 5000}));
  writeFileSync(join(dir, 'sealed-seed.json'), seedBytes);
  const child = spawn(process.execPath, [session, '--seed-file', join(dir, 'sealed-seed.json')],
    {env: env({path: join(dir, 'sealed-seed.json'), digest: sha(seedBytes)}), stdio: ['ignore', 'ignore', 'pipe']});
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    const started = Date.now();
    while (!existsSync(ready) && Date.now() - started < 20000 && child.exitCode === null) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.ok(existsSync(ready), 'the session wrote its ready file: ' + stderr);
    const opened = JSON.parse(readFileSync(ready, 'utf8'));
    assert.match(opened.url, /^http:\/\/127\.0\.0\.1:\d+$/);
    assert.equal(typeof opened.metadata.schema_hash, 'string');
  } finally {
    child.kill();
    await new Promise((resolve) => child.once('exit', resolve));
  }
});
