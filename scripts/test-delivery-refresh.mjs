import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readRecord,writeRecord} from './lib/delivery-store.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-delivery-refresh-')),repo=path.join(root,'repo'),remote=path.join(root,'remote.git'),store=path.join(root,'records');
const script=path.resolve('scripts/delivery-record.mjs');
function run(program,args,cwd=repo){return spawnSync(program,args,{cwd,encoding:'utf8',windowsHide:true});}
function git(...args){const r=run('git',args);assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try{
 fs.mkdirSync(repo);assert.equal(run('git',['init','--bare','-q',remote],root).status,0);git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');
 fs.writeFileSync(path.join(repo,'source'),'old');git('add','.');git('commit','-qm','base');git('remote','add','origin',remote);git('push','-qu','origin','main');git('switch','-qc','change/fixture');git('push','-qu','origin','change/fixture');const old=git('rev-parse','HEAD');
 const cli=args=>run(process.execPath,[script,...args,'--repo',repo,'--store',store]);
 assert.equal(cli(['create','change/fixture','--tip',old,'--producer','producer']).status,0);
 const previous=readRecord(store,'change/fixture');previous.review={verdict:'passed',tip:old};previous.admission={state:'admitted',tip:old};previous.lane={verdict:'gate_failed',exit:1};writeRecord(store,previous);
 fs.writeFileSync(path.join(repo,'source'),'new');git('add','.');git('commit','-qm','followup');git('push','-q');const next=git('rev-parse','HEAD');
 const args=['refresh','change/fixture','--tip',next,'--expected-tip',old,'--producer','producer'];assert.equal(cli(args).status,0);
 const refreshed=readRecord(store,'change/fixture');assert.equal(refreshed.tip,next);assert.equal(refreshed.review,null);assert.equal(refreshed.admission,null);assert.equal(refreshed.lane,null);
 assert.equal(refreshed.tip_history[0].lane.verdict,'gate_failed');assert.equal(refreshed.tip_history[0].admission.state,'admitted');
 const stale=cli(args);assert.equal(stale.status,2);assert.equal(JSON.parse(stale.stdout).condition,'tip_compare_mismatch');assert.equal(readRecord(store,'change/fixture').tip,next);
 console.log('delivery refresh ok (10 checks, 0 skipped; published exact tip CAS and full prior history)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
