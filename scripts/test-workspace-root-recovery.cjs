const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const assert=require('node:assert/strict');const {spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const bin=path.resolve(process.argv[2] || path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-root-workspace-'));
const source=path.join(root,'source'),install=path.join(root,'install');
for(const p of [source,install,path.join(root,'tmp')])fs.mkdirSync(p,{recursive:true});
function git(...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd:source,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout;}
let failed=true;
try {
  git('init','-q','--initial-branch=main');git('config','core.autocrlf','false');
  fs.writeFileSync(path.join(source,'seed'),'source unchanged\n');git('add','.');git('commit','-qm','fixture');
  fs.writeFileSync(path.join(install,'runtime-worktree.txt'),source+'\n');
  // Pin pre-repair bytes; after landing, origin/main is no longer a falsifier.
  const baseline=spawnSync('git',['show','ab827c88a6ac091318b5adb8be34e83e858c4e9a:lua/core/workspaces.lua'],
    {cwd:repo,encoding:'utf8',windowsHide:true});
  assert.equal(baseline.status,0,'pinned pre-repair source is required: '+baseline.stderr);
  const baselineFile=path.join(root,'baseline-workspaces.lua');fs.writeFileSync(baselineFile,baseline.stdout);
  const env={...process.env};
  for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
  Object.assign(env,{WASM_AGENT_HOME:path.join(root,'home'),WASM_AGENT_LUA_ROOT:repo,
    WA_SCRIPT:path.join(repo,'scripts/test-workspace-root-recovery.lua'),WA_INSTALL_DIR:install,
    WASM_AGENT_TEST_SOURCE:source,WASM_AGENT_TEST_BASELINE_WORKSPACES:baselineFile,
    TEMP:path.join(root,'tmp'),TMP:path.join(root,'tmp'),TMPDIR:path.join(root,'tmp'),
    WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',
    WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only'});
  const r=spawnSync(bin,['--db',path.join(root,'memory.db')],{cwd:repo,env,encoding:'utf8',windowsHide:true,timeout:60000});
  assert.equal(r.status,0,r.error?.message || r.stderr || r.stdout);
  assert.match(r.stdout,/root workspace recovery ok/);process.stdout.write(r.stdout);
  failed=false;
} finally {
  assert.equal(path.dirname(root),os.tmpdir());
  if(failed)console.error('failed root recovery fixture retained: '+root);
  else fs.rmSync(root,{recursive:true,force:true});
}
