// REVIEW FIXTURE (not part of the delivery under review).
//
// Disposable home + destination checkout so the review's tick loop can run the real placement path
// without touching any live node state. Usage: node scripts/review-placement-leak.cjs <wa-binary> <label>
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
const label = process.argv[3] || 'run';
const script = process.argv[4] || 'review-placement-leak.lua';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-review-leak-'));
const home = path.join(root, 'home');
const destination = path.join(root, 'destination');
const install = path.join(root, 'install');
const db = path.join(root, 'memory.db');
function native(value) { return value.replaceAll('/', '\\'); }
function slashes(value) { return value.replaceAll('\\', '/'); }

fs.mkdirSync(home, {recursive:true});
fs.mkdirSync(install, {recursive:true});
fs.mkdirSync(destination, {recursive:true});
spawnSync('git', ['init', destination], {encoding:'utf8'});
spawnSync('git', ['-C', destination, 'config', 'user.name', 'review-fixture']);
spawnSync('git', ['-C', destination, 'config', 'user.email', 'review-fixture@invalid']);
fs.writeFileSync(path.join(destination, 'seed.txt'), 'review baseline\n');
spawnSync('git', ['-C', destination, 'add', 'seed.txt']);
spawnSync('git', ['-C', destination, 'commit', '-m', 'review baseline']);
fs.writeFileSync(path.join(install, 'runtime-worktree.txt'), `${native(destination)}\n`);
const profiles = path.join(home, '.wasm-agent', 'subagent-profiles');
fs.mkdirSync(profiles, {recursive:true});
fs.writeFileSync(path.join(profiles, 'task-worker.json'), JSON.stringify({
  schema_version:1, id:'task-worker', description:'review fixture task worker',
  instructions:'Do the bounded task and report what you did.',
  allowed_tools:['read', 'write', 'bash'], operator_authorized:true,
  limits:{max_depth:0, timeout_seconds:30, max_output_bytes:65536},
}));

const env = {...process.env};
for (const key of Object.keys(env)) if (/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)) delete env[key];
Object.assign(env, {WASM_AGENT_HOME:home, WASM_AGENT_LUA_ROOT:repo, WA_INSTALL_DIR:native(install),
  WA_SCRIPT:path.join(repo, 'scripts', script),
  WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1', WASM_AGENT_LLM_API_KEY:'fixture-only',
  WASM_AGENT_LLM_MODEL:'fixture', WASM_AGENT_RENDEZVOUS:'', WASM_AGENT_RELAY:'', WASM_AGENT_MANAGED:'0',
  // The runtime's own ceiling defaults to 2 concurrent children (rust/wa-host/src/subagents.rs:34),
  // which the fixture's few live runs would saturate; the live node runs with an explicit value
  // (WASM_AGENT_SUBAGENT_CONCURRENCY=4), so the fixture states its own.
  WASM_AGENT_SUBAGENT_CONCURRENCY:'8',
  WASM_AGENT_TEST_DESTINATION_TREE:slashes(destination)});

const run = spawnSync(wa, ['--db', db], {cwd:repo, env, encoding:'utf8', timeout:180000, maxBuffer:8*1024*1024});
console.log(`--- ${label} (lua root ${repo}, script ${script}) ---`);
console.log((run.stdout || '').trim());
if ((run.stderr || '').trim()) console.log(`stderr: ${(run.stderr || '').trim()}`);
console.log(`exit=${run.status}`);
// The fixture is retained on purpose: the worktrees it counted are its own evidence.
console.log(`fixture root (kept): ${root}`);
process.exitCode = run.status === 0 ? 0 : 1;
