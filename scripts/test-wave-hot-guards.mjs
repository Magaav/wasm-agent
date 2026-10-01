import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {checkWaveAdmission} from './lib/wave-guard.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-hot-guards-'));
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try{
 fs.mkdirSync(path.join(root,'scripts','lib'),{recursive:true});fs.copyFileSync('scripts/lib/wave-guard.mjs',path.join(root,'scripts','lib','wave-guard.mjs'));
 git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');git('add','.');git('commit','-qm','base');
 assert(checkWaveAdmission(root,{phase:'produce'}).ok);assert(!fs.existsSync(path.join(root,'.git','wa-waves')),'checking never bootstraps a fresh store');
 const registry=path.join(root,'.git','wa-waves');fs.mkdirSync(registry);fs.writeFileSync(path.join(registry,'registration.json'),'malformed legacy registration');
 assert(!checkWaveAdmission(root,{phase:'land'}).ok,'registered missing-module state fails closed');
 fs.writeFileSync(path.join(root,'scripts','wave-entry.mjs'),"export function checkAdmission(repo,{phase}){return {ok:false,wave_verified:false,reason:'registered freeze '+phase,wave_id:'fixture'};}\n");git('add','.');git('commit','-qm','guard');
 const run=(file,args)=>spawnSync(process.execPath,[path.resolve(file),...args],{encoding:'utf8',windowsHide:true,timeout:30000});
 const finish=run('skills/parallel-evolution/scripts/finish.mjs',['check',root,git('rev-parse','HEAD')]);assert(/registered freeze/.test(finish.stdout));
 const store=path.join(root,'.git','deliveries');fs.mkdirSync(store);fs.writeFileSync(path.join(store,'change-frozen.json'),JSON.stringify({delivery:'change/frozen',producer:'fixture',repository:root}));
 const admission=run('scripts/delivery-admission.mjs',['check','change/frozen','--repo',root,'--store',store]);assert.equal(admission.status,2);assert.equal(JSON.parse(admission.stdout).condition,'wave_admission_refused');
 const merge=run('scripts/merge-lane.mjs',['--repo',root,'--base','main','--no-reuse-tree']);assert.equal(merge.status,2);assert(/registered freeze/.test(merge.stdout));
 console.log('wave hot guards ok (8 checks, 0 skipped; actual finish/admission/merge entrypoints)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
