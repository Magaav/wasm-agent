// Real git-worktree allocation, concurrent session writes, refusal and process-restart proof.
// Uses a disposable local source repository and no model/provider.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const assert = require('node:assert/strict');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-session-workspaces-'));
const home = path.join(root, 'home');
const source = path.join(root, 'source');
const db = path.join(root, 'memory.db');
const install = path.join(root, 'install');
fs.mkdirSync(home, {recursive:true}); fs.mkdirSync(source, {recursive:true}); fs.mkdirSync(install, {recursive:true});
let checks = 0;
function check(value, message) { assert.ok(value, message); checks++; }
function git(args) { spawnSync('git', ['-C', source, ...args], {stdio:'ignore'}); }
function envFor(script, extras={}) {
  const env = {...process.env};
  for (const key of Object.keys(env)) if (/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)) delete env[key];
  // `WA_INSTALL_DIR` with a `runtime-worktree.txt` inside it is what makes this fixture hermetic:
  // the tree a node runs from is read from that record, so the fallback a session uses when the
  // source it names is gone is the disposable repo below - not whatever the machine's own install
  // happens to point at (a real checkout would collect branches from a test run).
  Object.assign(env, {WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(repo,'scripts',script),
    WA_INSTALL_DIR:install.replaceAll('/', '\\'),
    WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_MODEL:'fixture',
    WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',...extras});
  return env;
}
function run(script, extras={}) {
  return spawnSync(wa,['--db',db],{cwd:repo,env:envFor(script,extras),encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
}
function runAsync(script, extras={}) {
  return new Promise((resolve,reject)=>{
    const child=spawn(wa,['--db',db],{cwd:repo,env:envFor(script,extras),stdio:['ignore','pipe','pipe']});
    let stdout='',stderr=''; child.stdout.on('data',x=>stdout+=x);child.stderr.on('data',x=>stderr+=x);
    child.on('error',reject);child.on('close',code=>resolve({code,stdout,stderr}));
  });
}
(async()=>{
  let failed=false;
  try {
    const init=spawnSync('git',['init',source],{encoding:'utf8'});check(init.status===0,'initialize disposable source repo');
    git(['config','user.name','workspace-fixture']);git(['config','user.email','workspace-fixture@invalid']);
    fs.writeFileSync(path.join(source,'seed.txt'),'clean baseline\n');
    git(['add','seed.txt']);git(['commit','-m','baseline']);
    git(['update-ref','refs/remotes/origin/main','HEAD']); // private integrated baseline for release reconciliation
    fs.writeFileSync(path.join(install,'runtime-worktree.txt'),`${source.replaceAll('/', '\\')}\n`);
    const seeded=run('test-session-workspaces.lua',{WASM_AGENT_TEST_SOURCE:source});
    check(seeded.status===0,`allocator/fail-closed fixture exit ${seeded.status}: ${seeded.stderr}\n${seeded.stdout}`);
    check(seeded.stdout.includes('session workspaces ok (23 checks)'),`missing 23-check verdict: ${seeded.stdout}`);

    const [a,b]=await Promise.all([
      runAsync('test-session-workspace-worker.lua',{WASM_AGENT_TEST_SESSION:'workspace-a',WASM_AGENT_TEST_CONTENT:'concurrent-a'}),
      runAsync('test-session-workspace-worker.lua',{WASM_AGENT_TEST_SESSION:'workspace-b',WASM_AGENT_TEST_CONTENT:'concurrent-b'}),
    ]);
    check(a.code===0 && b.code===0,`concurrent workers exit ${a.code}/${b.code}: ${a.stderr}\n${b.stderr}`);
    check(a.stdout.includes('workspace-a') && b.stdout.includes('workspace-b'),'both simultaneous sessions completed writes');

    const restarted=run('test-session-workspace-verify.lua');
    check(restarted.status===0 && restarted.stdout.includes('session workspace restart ok (4 checks)'),
      `fresh-process binding recovery failed (${restarted.status}): ${restarted.stderr}\n${restarted.stdout}`);
    checks+=4;
    const released=run('test-workspace-release.lua',{WASM_AGENT_TEST_SOURCE:source});
    check(released.status===0 && released.stdout.includes('workspace release ok (34 checks)'),
      `workspace release failed (${released.status}): ${released.stderr}\n${released.stdout}`);
    console.log(released.stdout.trim());
    console.log(`session workspaces integration ok (${checks} checks; real git worktrees, two concurrent processes, restart, no inference)`);
  } catch (error) {
    failed=true; console.error(`session workspaces failed; retained fixture: ${root}\n${error.stack||error}`); process.exitCode=1;
  } finally {
    if (!failed) fs.rmSync(root,{recursive:true,force:true});
  }
})();
