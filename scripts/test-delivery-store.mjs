import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {readRecord,writeRecord,updateRecord,recordPath} from './lib/delivery-store.mjs';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-delivery-cas-'));
const delivery='change/concurrent';
let checks=0;
const check=(ok,label)=>{assert.ok(ok,label);checks++;};
try {
  writeRecord(root,{delivery,review:null,lane:null,landing:null});
  const a=readRecord(root,delivery),b=readRecord(root,delivery);
  a.review={commit:'review-A'};writeRecord(root,a);
  b.lane={verdict:'pass'};
  assert.throws(()=>writeRecord(root,b),/delivery_record_conflict/);checks++;
  check(readRecord(root,delivery).review.commit==='review-A','a stale merger cannot lose review');
  updateRecord(root,delivery,r=>{r.lane={verdict:'pass'};});
  check(readRecord(root,delivery).review.commit==='review-A' && readRecord(root,delivery).lane.verdict==='pass',
    'a reconciled merger preserves both owners fields');

  const worker=path.join(root,'worker.mjs');
  const library=pathToFileURL(path.resolve('scripts/lib/delivery-store.mjs')).href;
  fs.writeFileSync(worker,`import fs from 'node:fs';import {readRecord,writeRecord} from ${JSON.stringify(library)};
const [dir,key]=process.argv.slice(2);const r=readRecord(dir,${JSON.stringify(delivery)});
fs.writeFileSync(dir+'/'+key+'.ready','ready');
while(!fs.existsSync(dir+'/go'))await new Promise(r=>setTimeout(r,20));
r[key]={owner:key};try{writeRecord(dir,r);console.log('written')}catch(e){console.log(e.message);process.exitCode=2}
`);
  const records=['producer','reviewer'].map(key=>{
    const child=spawn(process.execPath,[worker,root,key],{windowsHide:true,stdio:['ignore','pipe','pipe']});
    const rec={child,key,out:''};child.stdout.on('data',b=>{rec.out+=b;});
    rec.done=new Promise(resolve=>child.on('close',exit=>resolve(exit)));return rec;
  });
  const deadline=Date.now()+10000;
  while(!records.every(r=>fs.existsSync(path.join(root,r.key+'.ready')))) {
    assert.ok(Date.now()<deadline,'workers must reach their read barrier');
    await new Promise(r=>setTimeout(r,20));
  }
  fs.writeFileSync(path.join(root,'go'),'go');
  const exits=await Promise.all(records.map(r=>r.done));
  check(exits.filter(c=>c===0).length===1 && exits.filter(c=>c===2).length===1,'real simultaneous writers settle exactly one stale update');
  check(records.some(r=>/delivery_record_conflict/.test(r.out)),'the losing process receives a named refusal');

  const legacy='change/legacy';
  fs.writeFileSync(recordPath(root,legacy),JSON.stringify({delivery:legacy,review:null}));
  updateRecord(root,legacy,r=>{r.review={commit:'legacy-review'};});
  check(readRecord(root,legacy).revision===1,'legacy JSON migrates through its observed snapshot');
  updateRecord(root,delivery,r=>{r.landing={sha:'published'};});
  assert.throws(()=>updateRecord(root,delivery,r=>{r.landing=null;}),/delivery_landing_immutable/);checks++;
  check(readRecord(root,delivery).landing.sha==='published','publication cannot be silently erased');
  writeRecord(root,{delivery:'change/a/b'});
  assert.throws(()=>writeRecord(root,{delivery:'change-a-b'}),/delivery_store_collision/);checks++;
  console.log(`delivery store ok (${checks} checks, 0 skipped; private store, real concurrent writers)`);
} finally {
  assert.equal(path.dirname(root),os.tmpdir());
  fs.rmSync(root,{recursive:true,force:true});
}
