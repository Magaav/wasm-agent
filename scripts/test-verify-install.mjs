import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-verify-install-'));
const tree=path.join(root,'source'),install=path.join(root,'install'),home=path.join(root,'home'),mock=path.join(root,'mock-bin');
const verifier=path.resolve('scripts/verify-install.sh');
let checks=0;
function check(value,label){assert.ok(value,label);checks++;}
function run(program,args,cwd=tree,env=process.env){const r=spawnSync(program,args,{cwd,env,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr||r.stdout);return r.stdout.trim();}
const git=(...args)=>run('git',args);
const writeExec=(file,content)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);fs.chmodSync(file,0o755);};
function verify(){
  const env={...process.env,HOME:home,USERPROFILE:home,WA_INSTALL_DIR:install,WA_DEPLOY_ROOT:tree,WASM_AGENT_HOME:undefined,
    PATH:`${mock}${path.delimiter}${process.env.PATH}`};
  env.PATH=`${mock}${path.delimiter}${process.env.PATH}`;
  const r=spawnSync('bash',[verifier,'--json'],{cwd:tree,env,encoding:'utf8',windowsHide:true});
  const result=JSON.parse(r.stdout.trim());
  return {status:r.status,result};
}
try {
  fs.mkdirSync(tree,{recursive:true});fs.mkdirSync(install,{recursive:true});fs.mkdirSync(home,{recursive:true});fs.mkdirSync(mock,{recursive:true});
  git('init','-q','--initial-branch=main');git('config','user.name','verify fixture');git('config','user.email','verify@example.invalid');git('config','core.hooksPath',path.join(root,'no-hooks'));
  const shipped=['scripts/deploy.sh','scripts/upgrade.sh','skills/self-update/SKILL.md','skills/git-orchestrator/SKILL.md','skills/git-orchestrator/scripts/audit.mjs'];
  for(const rel of shipped){const source=path.resolve(rel);const dest=path.join(tree,rel);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.copyFileSync(source,dest);}
  git('add','.');git('commit','-qm','source fixture');
  for(const rel of shipped){
    const dest=rel.startsWith('skills/')?path.join(home,'.wasm-agent',rel):path.join(install,rel);
    fs.mkdirSync(path.dirname(dest),{recursive:true});fs.copyFileSync(path.join(tree,rel),dest);
  }
  for(const [rel,installed] of [['rust/target/release/wa',path.join(install,'wa')]]){
    const source=path.join(tree,rel);fs.mkdirSync(path.dirname(source),{recursive:true});fs.writeFileSync(source,`fixture binary: ${rel}\n`);fs.chmodSync(source,0o755);
    fs.copyFileSync(source,installed);fs.chmodSync(installed,0o755);
  }
  const sentinelBuild=path.join(tree,'rust/wa-sentinel/target/release/wa-sentinel');
  writeExec(sentinelBuild,'#!/usr/bin/env bash\necho "sentinel: watching (pid 5678)"; echo "requests: readable"\n');
  fs.copyFileSync(sentinelBuild,path.join(install,'wa-sentinel'));
  git('add','.');git('commit','-qm','built artifact fixture');
  const installedCommit=git('rev-parse','--short','HEAD');
  const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  fs.writeFileSync(path.join(install,'installed.txt'),`commit=${installedCommit}\nsha256=${hash(path.join(install,'wa'))}\nsentinel_sha256=${hash(path.join(install,'wa-sentinel'))}\nvia=fixture\n`);
  fs.writeFileSync(path.join(install,'serve.pid'),'1234');

  writeExec(path.join(mock,'curl'),'#!/usr/bin/env bash\necho \'{"ok":true}\'\n');
  writeExec(path.join(mock,'ss'),'#!/usr/bin/env bash\necho \'LISTEN 0 4096 127.0.0.1:8799 0.0.0.0:* users:(("wa",pid=1234,fd=3))\'\n');
  writeExec(path.join(mock,'powershell.exe'),'#!/usr/bin/env bash\necho 1234\n');


  const clean=verify();
  check(clean.status===0&&clean.result.failed===0&&clean.result.skipped===0,`consistent fixture passes without skips: ${JSON.stringify(clean.result.results)}`);
  check(clean.result.results.some(item=>item.name==='shipped skills/git-orchestrator/SKILL.md == repo'&&item.status==='ok'),'repository skill is compared to its installed copy');
  check(clean.result.results.some(item=>item.name==='shipped skills/git-orchestrator/scripts/audit.mjs == repo'&&item.status==='ok'),'repository audit helper is compared to its installed copy');

  for(const rel of shipped.filter(item=>item.includes('git-orchestrator'))){
    const dest=path.join(home,'.wasm-agent',rel);fs.appendFileSync(dest,'\ninstalled drift fixture\n');
  }
  const drift=verify();
  check(drift.status===1&&drift.result.failed===2&&drift.result.skipped===0,'both source drifts fail verification without masking other checks');
  const failedNames=drift.result.results.filter(item=>item.status==='fail').map(item=>item.name);
  check(failedNames.includes('shipped skills/git-orchestrator/SKILL.md == repo')&&failedNames.includes('shipped skills/git-orchestrator/scripts/audit.mjs == repo'),'verdict names both exact source/install mismatches');
  check(fs.readFileSync(path.join(home,'.wasm-agent','skills/git-orchestrator/SKILL.md'),'utf8').endsWith('installed drift fixture\n'),'verifier only observes the installed fixture and does not repair it');
  console.log(`verify install checks ok (${checks} checks, 0 skipped; isolated source/install fixture)`);
} finally {
  assert.equal(path.dirname(path.resolve(root)),path.resolve(os.tmpdir()));
  fs.rmSync(root,{recursive:true,force:true});
}
