// Real git checkouts, real placement path, no model.
//
// Two disposable repositories stand for the two machines: `foreign` is the tree a coordinator's
// session recorded (`C:/Users/.../wasm_the_first`, meaningless on the destination), `destination` is
// the tree the destination's own node runs from - what `runtime-worktree.txt` points at on a prepared
// node. The first run is a prepared destination; the second has no record and a working directory
// that is not a checkout, which must refuse by name.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-placed-child-'));
const home = path.join(root, 'home');
const foreign = path.join(root, 'foreign');
const destination = path.join(root, 'destination');
const install = path.join(root, 'install');
const bare = path.join(root, 'bare');
const db = path.join(root, 'memory.db');
let checks = 0;
function check(value, message) { assert.ok(value, message); checks++; }
function native(value) { return value.replaceAll('/', '\\'); }
function slashes(value) { return value.replaceAll('\\', '/'); }
function repository(directory, seed, message) {
  fs.mkdirSync(directory, {recursive:true});
  check(spawnSync('git', ['init', directory], {encoding:'utf8'}).status === 0, `initialize ${directory}`);
  spawnSync('git', ['-C', directory, 'config', 'user.name', 'placed-child-fixture']);
  spawnSync('git', ['-C', directory, 'config', 'user.email', 'placed-child-fixture@invalid']);
  fs.writeFileSync(path.join(directory, 'seed.txt'), `${seed}\n`);
  spawnSync('git', ['-C', directory, 'add', 'seed.txt']);
  check(spawnSync('git', ['-C', directory, 'commit', '-m', seed], {encoding:'utf8'}).status === 0, `commit ${message}`);
}
function head(directory) {
  return spawnSync('git', ['-C', directory, 'rev-parse', 'HEAD'], {encoding:'utf8'}).stdout.trim();
}
function envFor(extras) {
  const env = {...process.env};
  for (const key of Object.keys(env)) if (/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)) delete env[key];
  Object.assign(env, {WASM_AGENT_HOME:home, WASM_AGENT_LUA_ROOT:repo,
    WA_SCRIPT:path.join(repo, 'scripts', 'test-placed-child-workspace.lua'),
    WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1', WASM_AGENT_LLM_API_KEY:'fixture-only', WASM_AGENT_LLM_MODEL:'fixture',
    WASM_AGENT_RENDEZVOUS:'', WASM_AGENT_RELAY:'', WASM_AGENT_MANAGED:'0',
    WASM_AGENT_TEST_DESTINATION_TREE:slashes(destination), WASM_AGENT_TEST_FOREIGN_TREE:slashes(foreign),
    ...extras});
  return env;
}
function run(cwd, extras) {
  return spawnSync(wa, ['--db', db], {cwd, env:envFor(extras), encoding:'utf8', timeout:60000, maxBuffer:4*1024*1024});
}

let failed = false;
try {
  fs.mkdirSync(home, {recursive:true});
  fs.mkdirSync(install, {recursive:true});
  fs.mkdirSync(bare, {recursive:true});
  repository(foreign, 'the coordinator tree', 'foreign baseline');
  repository(destination, 'the destination tree', 'destination baseline');
  check(head(foreign) !== head(destination), 'the two trees are different commits');
  // A prepared node: the record points at the tree its node runs from. Written the way the installer
  // writes it - a native path, which is exactly why the reader normalizes it.
  fs.writeFileSync(path.join(install, 'runtime-worktree.txt'), `${native(destination)}\n`);
  // The profile the real placement used, so the facade path is the one under test.
  const profiles = path.join(home, '.wasm-agent', 'subagent-profiles');
  fs.mkdirSync(profiles, {recursive:true});
  fs.writeFileSync(path.join(profiles, 'task-worker.json'), JSON.stringify({
    schema_version:1, id:'task-worker', description:'fixture task worker',
    instructions:'Do the bounded task and report what you did.',
    allowed_tools:['read', 'write', 'bash'], operator_authorized:true,
    limits:{max_depth:0, timeout_seconds:30, max_output_bytes:65536},
  }));

  const prepared = run(repo, {WA_INSTALL_DIR:native(install), WASM_AGENT_TEST_PLACED_SCENARIO:'prepared'});
  check(prepared.status === 0, `prepared destination exit ${prepared.status}: ${prepared.stderr}\n${prepared.stdout}`);
  check(prepared.stdout.includes('placed child forked from'), `the fork tree is shown: ${prepared.stdout}`);
  check(prepared.stdout.includes('placed child workspace ok ('), `missing verdict: ${prepared.stdout}`);
  console.log(prepared.stdout.trim());

  // Unprepared: no record, and a working directory that is not a checkout.
  const empty = path.join(root, 'install-empty');
  fs.mkdirSync(empty, {recursive:true});
  const unprepared = run(bare, {WA_INSTALL_DIR:native(empty), WASM_AGENT_TEST_PLACED_SCENARIO:'unprepared'});
  check(unprepared.status === 0, `unprepared destination exit ${unprepared.status}: ${unprepared.stderr}\n${unprepared.stdout}`);
  check(unprepared.stdout.includes('unprepared destination refused'), `the refusal is shown: ${unprepared.stdout}`);
  console.log(unprepared.stdout.trim());

  console.log(`placed child workspace integration ok (${checks} harness checks; real git checkouts, real placement path, no inference)`);
} catch (error) {
  failed = true;
  console.error(`placed child workspace failed; retained fixture: ${root}\n${error.stack || error}`);
  process.exitCode = 1;
} finally {
  if (!failed) fs.rmSync(root, {recursive:true, force:true});
}
