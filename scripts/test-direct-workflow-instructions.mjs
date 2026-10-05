#!/usr/bin/env node
// Private mutation proof for the active policy; never edit installed instructions.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const fixture=fs.mkdtempSync(path.join(os.tmpdir(),'wa-direct-instructions-'));
const run=root=>spawnSync(process.execPath,[path.join(root,'scripts/check-instructions.mjs')],
  {cwd:root,encoding:'utf8',windowsHide:true,maxBuffer:4*1024*1024});
let checks=0;
const check=(value,label)=>{checks++;if(!value)throw Error(label);};
try {
  // The checker walks these exact instruction roots; copying them preserves its full contract.
  for(const name of fs.readdirSync(repo)) {
    if(/^AGENTS[^/]*\.md$/.test(name)||['docs','skills','.githooks'].includes(name))
      fs.cpSync(path.join(repo,name),path.join(fixture,name),{recursive:true});
  }
  fs.mkdirSync(path.join(fixture,'scripts'));
  for(const name of ['check-instructions.mjs','test-main-guard.sh'])
    fs.copyFileSync(path.join(repo,'scripts',name),path.join(fixture,'scripts',name));
  const baseline=run(fixture);
  check(baseline.status===0,'complete instruction checker must pass current source: '+baseline.stdout.slice(-900));
  const policy=path.join(fixture,'AGENTS.orchestrator.md'),original=fs.readFileSync(policy,'utf8');
  const mutations=[
    ['No subagents','Delegation allowed','home AGENTS.orchestrator.md'],
    ['ordinary Git integration','factory-only integration','home AGENTS.orchestrator.md'],
    ['Periodic watcher wakes remain disabled','Periodic watcher wakes remain enabled','home AGENTS.orchestrator.md'],
    ['never replay or falsely settle','replay missing effects','home AGENTS.orchestrator.md'],
    ['operator-selected direct workflow','parallel workflow','preserved "the coordinator uses the operator-selected direct workflow"'],
  ];
  for(const [before,after,reason] of mutations) {
    check(original.split(before).length===2,'mutation anchor must be unique: '+before);
    fs.writeFileSync(policy,original.replace(before,after));
    const result=run(fixture);
    check(result.status===1&&result.stdout.includes('  failed: '+reason),'policy mutation must fail by name: '+before);
    fs.writeFileSync(policy,original);
  }
  for(const [file,before,reason] of [
    ['AGENTS.md','Do not start subagents or external inference agents','home AGENTS.md'],
    ['skills/parallel-evolution/SKILL.md','Active operator-selected direct workflow','home skills/parallel-evolution/SKILL.md'],
    ['skills/git-orchestrator/SKILL.md','Active operator-selected direct workflow','home skills/git-orchestrator/SKILL.md'],
  ]) {
    const target=path.join(fixture,file),original=fs.readFileSync(target,'utf8');
    check(original.split(before).length===2,'active-policy anchor must be unique: '+file);
    fs.writeFileSync(target,original.replace(before,'retired policy'));
    const result=run(fixture);
    check(result.status===1&&result.stdout.includes('  failed: '+reason),'removing active policy must fail: '+file);
    fs.writeFileSync(target,original);
  }
  const agents=path.join(fixture,'AGENTS.md'),bytes=fs.readFileSync(agents);
  fs.appendFileSync(agents,'\n'+'.'.repeat(10419));
  check(run(fixture).stdout.includes('  failed: AGENTS.md grew'),'original byte budget must remain enforced');
  fs.writeFileSync(agents,bytes);
  check(run(fixture).status===0,'restored private instructions must pass');
  console.log(JSON.stringify({ok:true,checks,skipped:0,scope:'direct-workflow-instruction-mutations',full_release_gate:false}));
} finally {
  fs.rmSync(fixture,{recursive:true,force:true});
}
