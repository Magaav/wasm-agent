import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-merge-gate-source-'));
const lane=path.resolve('scripts/merge-lane.mjs');
let checks=0;
try {
  for(const [name,body] of [['tracked',"printf 'mutated\\n' > value"],['untracked','touch untracked'],['head',"git -c user.name=fixture -c user.email=fixture@local commit --allow-empty -qm moved-head"]]) {
    const repo=path.join(root,name);fs.mkdirSync(path.join(repo,'scripts'),{recursive:true});
    const git=(...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
    git('init','-q','--initial-branch','main');git('config','core.autocrlf','false');git('config','user.name','fixture');git('config','user.email','fixture@local');
    fs.writeFileSync(path.join(repo,'value'),'base\n');fs.writeFileSync(path.join(repo,'scripts','test.sh'),body+"\necho 'smoke ok'\n");
    git('add','.');git('commit','-qm','base');git('switch','-qc','change/fixture');fs.writeFileSync(path.join(repo,'addition'),'reviewed');git('add','.');git('commit','-qm','addition');
    const result=spawnSync(process.execPath,[lane,'--repo',repo,'--base','main','--no-reuse-tree','--no-hooks','--clone',path.join(root,'candidate-'+name),'--keep-clone','change/fixture'],{
      encoding:'utf8',windowsHide:true,timeout:60000,env:{...process.env,WA_GATE_LANE_DIR:path.join(root,'queue'),WA_GATE_LANE_SAMPLE_SECONDS:'0',GATE_LANE_HELD:'',GATE_LANE_ORIGIN:''}});
    const receipt=JSON.parse(result.stdout);
    assert.equal(result.status,3,result.stderr);checks++;
    assert.equal(receipt.gate.exit,0,'real process success is preserved, not rewritten');checks++;
    assert(receipt.gate.verdict_found&&!receipt.gate.source_verified,'source mutation prevents source-bound pass despite terminal smoke text');checks++;
    assert(!receipt.gate.full_receipt&&!fs.existsSync(path.join(repo,'.git','wa-combined-gate.json')),'no reusable full proof written');checks++;
  }
  console.log(`merge gate source ok (${checks} checks, 0 skipped; actual default command, isolated stand-in gate source)`);
} finally {fs.rmSync(root,{recursive:true,force:true});}
