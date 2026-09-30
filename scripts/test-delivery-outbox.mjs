import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {pathToFileURL} from 'node:url';
import {writeRecord,readRecord} from './lib/delivery-store.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-delivery-outbox-'));
const repo=path.join(root,'repo'),store=path.join(root,'store'),dbFile=path.join(root,'jobs.db');
fs.mkdirSync(repo);let checks=0;
function git(...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
const check=(ok,message)=>{assert.ok(ok,message);checks++;};
try {
  git('init','-q','--initial-branch=main');git('config','core.autocrlf','false');
  fs.writeFileSync(path.join(repo,'a'),'source');git('add','.');git('commit','-qm','source\n\nAgent: codex session=producer');
  const tip=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');
  fs.writeFileSync(path.join(repo,'review'),'independent');git('add','.');git('commit','-qm','review\n\nAgent: codex session=reviewer');
  const review=git('rev-parse','HEAD');git('update-ref','refs/remotes/origin/change/delivery',tip);
  git('update-ref','refs/remotes/origin/change/review',review);
  const delivery='change/delivery';
  writeRecord(store,{delivery,branch:delivery,repository:repo,producer:'producer',tip,tree,
    review:{reviewer:'reviewer',commit:review,tip,tree,verdict:'passed',findings:[]},landing:null});
  const db=new DatabaseSync(dbFile);
  db.exec('CREATE TABLE jobs(id TEXT PRIMARY KEY,revision INTEGER,enabled INTEGER,definition TEXT);CREATE TABLE deliveries(id INTEGER PRIMARY KEY,job_id TEXT,revision INTEGER,event_id TEXT,payload TEXT,state TEXT,UNIQUE(job_id,revision,event_id));');
  const definition={id:'delivery-lane',trigger:{kind:'event',topic:'delivery.admitted'}};
  db.prepare('INSERT INTO jobs VALUES(?,?,?,?)').run('delivery-lane',1,1,JSON.stringify(definition));
  const mock=path.join(root,'sentinel-mock.mjs');
  fs.writeFileSync(mock,`import fs from 'node:fs';import {DatabaseSync} from 'node:sqlite';
if(process.argv[1]?.endsWith('job')){
 const [verb,...a]=process.argv.slice(2),db=new DatabaseSync(${JSON.stringify(dbFile)});
 if(verb==='list'){const r=db.prepare('SELECT * FROM jobs').all().map(r=>({...JSON.parse(r.definition),revision:r.revision,enabled:!!r.enabled}));console.log(JSON.stringify(r));}
 else if(verb==='emit'){
  if(process.env.OUTBOX_FAIL==='1'){console.error('injected emitter failure');process.exit(7);}
  if(process.env.OUTBOX_ZERO==='1'){console.log(JSON.stringify({queued:0}));process.exit(0);}
  const job=db.prepare('SELECT * FROM jobs WHERE id=?').get('delivery-lane');
  db.prepare('INSERT OR IGNORE INTO deliveries(job_id,revision,event_id,payload,state) VALUES(?,?,?,?,?)').run(job.id,job.revision,a[1],fs.readFileSync(a[2],'utf8'),'queued');console.log(JSON.stringify({queued:db.prepare('SELECT changes() AS n').get().n}));
 }
 else {console.error('unknown job action '+verb);process.exit(4);}
 db.close();process.exit(0);
}
`);
  const trigger=path.resolve('scripts/delivery-trigger.mjs');
  const run=(extra={})=>spawnSync(process.execPath,[trigger,'--store',store,'--emit-command',process.execPath,'--receipt-db',dbFile],
    {encoding:'utf8',windowsHide:true,env:{...process.env,NODE_OPTIONS:`--import=${pathToFileURL(mock).href}`,...extra}});
  const failed=run({OUTBOX_FAIL:'1'});
  check(failed.status===4,'emitter failure is reported as a failed pass');
  let record=readRecord(store,delivery);
  check(record.admission.event.state==='pending' && !record.emitted_events?.length,'failed intent remains pending, not suppressed');
  const zero=run({OUTBOX_ZERO:'1'});
  check(zero.status===4 && readRecord(store,delivery).admission.event.state==='pending','queued zero without exact effect is not acknowledgement');
  const recovered=run();assert.equal(recovered.status,0,recovered.stderr);
  record=readRecord(store,delivery);
  check(record.admission.event.state==='acknowledged','real durable enqueue acknowledges the pending intent');
  check(db.prepare('SELECT count(*) AS n FROM deliveries').get().n===1,'failure recovery queues exactly one effect');
  const again=run();assert.equal(again.status,0,again.stderr);
  check(JSON.parse(again.stdout).counts.emitted===0 && db.prepare('SELECT count(*) AS n FROM deliveries').get().n===1,'acknowledged effect is not reemitted');
  // Simulate crash after enqueue but before producer acknowledgement.
  record=readRecord(store,delivery);record.admission.event.state='pending';
  record.outbox[record.admission.event.id].state='pending';record.emitted_events=[];writeRecord(store,record);
  const queued=db.prepare('SELECT id,payload FROM deliveries').get();
  const parsed=JSON.parse(queued.payload);
  db.prepare('UPDATE deliveries SET payload=? WHERE id=?').run(JSON.stringify(Object.fromEntries(Object.entries(parsed).reverse())),queued.id);
  const reconciled=run({OUTBOX_FAIL:'1'});assert.equal(reconciled.status,0,reconciled.stderr);
  check(readRecord(store,delivery).admission.event.state==='acknowledged','existing exact effect reconciles without failed emitter, independent of JSON key order');
  db.prepare('UPDATE jobs SET revision=2').run();
  const newRevision=run();assert.equal(newRevision.status,0,newRevision.stderr);
  check(db.prepare('SELECT count(*) AS n FROM deliveries').get().n===2,'subscription revision creates a distinct acknowledged generation');
  db.close();console.log(`delivery outbox ok (${checks} checks, 0 skipped; isolated store and emitter)`);
} finally {assert.equal(path.dirname(root),os.tmpdir());fs.rmSync(root,{recursive:true,force:true});}
