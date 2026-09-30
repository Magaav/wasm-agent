// The in-flight review change: the race that leaves one generation's intent pending.
//
// THE SCENARIO, REPRODUCED FROM THE INDEPENDENT REVIEW OF THIS DELIVERY. An intent and its exact
// payload are durable before the emitter is called. While the emission is in flight, the delivery's
// review is rewritten through the real revisioned `writeRecord` - the emitter observes that write
// between the queue row and the trigger's acknowledgement. The queue row is durable, the
// acknowledgement write loses the CAS (exit 4, `write_errors=1`), and the record now holds a
// DIFFERENT generation than the one whose intent is pending.
//
// WHAT IS ASSERTED. The next reconciler must settle that older intent from the exact durable effect
// it can observe - never by invoking the emitter a second time - or report it as unsettled. It may
// not exit 0 saying `pending_events: 0` over a durable pending intent. Both legs are checked here,
// because "settle" and "report" are different fixes and only one of them is right per state: the
// third pass adds an older intent with NO durable effect and requires the report, not an invented
// acknowledgement.
//
// Everything is private: a scratch store, a scratch Git repository, a scratch job database and an
// isolated emitter. No live sentinel, model or store is contacted.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {writeRecord,readRecord} from './lib/delivery-store.mjs';
const HERE=path.dirname(fileURLToPath(import.meta.url));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-delivery-intent-race-'));
const repo=path.join(root,'repo'),store=path.join(root,'store'),dbFile=path.join(root,'jobs.db');
const mock=path.join(root,'sentinel-mock.mjs'),callsFile=path.join(root,'emitter-calls.json'),intentProof=path.join(root,'durable-intent.json');
fs.mkdirSync(repo);let checks=0,db=null;
function git(...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
const check=(ok,message)=>{assert.ok(ok,message);checks++;};
const calls=()=>fs.existsSync(callsFile)?JSON.parse(fs.readFileSync(callsFile,'utf8')):0;
try {
  git('init','-q','--initial-branch=main');git('config','core.autocrlf','false');
  fs.writeFileSync(path.join(repo,'source.txt'),'source\n');git('add','.');git('commit','-qm','source\n\nAgent: wasm-agent node=fixture session=producer');
  const tip=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');
  fs.writeFileSync(path.join(repo,'review.txt'),'passed\n');git('add','.');git('commit','-qm','review passed\n\nAgent: wasm-agent node=fixture session=reviewer');
  const review=git('rev-parse','HEAD');
  fs.writeFileSync(path.join(repo,'review.txt'),'refused\n');git('add','.');git('commit','-qm','review refused\n\nAgent: wasm-agent node=fixture session=reviewer');
  const review2=git('rev-parse','HEAD');
  git('update-ref','refs/remotes/origin/change/delivery',tip);git('update-ref','refs/remotes/origin/change/review',review2);
  const delivery='change/delivery';
  writeRecord(store,{delivery,branch:delivery,repository:repo,producer:'producer',tip,tree,
    review:{reviewer:'reviewer',commit:review,tip,tree,verdict:'passed',findings:[]},landing:null});
  db=new DatabaseSync(dbFile);
  db.exec('CREATE TABLE jobs(id TEXT PRIMARY KEY,revision INTEGER,enabled INTEGER,definition TEXT);CREATE TABLE deliveries(id INTEGER PRIMARY KEY,job_id TEXT,revision INTEGER,event_id TEXT,payload TEXT,state TEXT,UNIQUE(job_id,revision,event_id));');
  db.prepare('INSERT INTO jobs VALUES(?,?,?,?)').run('delivery-lane',1,1,JSON.stringify({id:'delivery-lane',trigger:{kind:'event',topic:'delivery.admitted'}}));
  // The sentinel stand-in: `job list`, and an `job emit` that verifies the intent was durable
  // BEFORE it enqueues, records the exact effect, and - under RACE_REVIEW - rewrites the review
  // through the real revisioned store while the trigger still holds its pre-emission copy.
  fs.writeFileSync(mock,`import fs from 'node:fs';import {DatabaseSync} from 'node:sqlite';
import {readRecord,writeRecord} from ${JSON.stringify(pathToFileURL(path.join(HERE,'lib','delivery-store.mjs')).href)};
if(process.argv[1]?.endsWith('job')){
 const [verb,...a]=process.argv.slice(2),db=new DatabaseSync(${JSON.stringify(dbFile)});
 if(verb==='list'){console.log(JSON.stringify(db.prepare('SELECT * FROM jobs').all().map(r=>({...JSON.parse(r.definition),revision:r.revision,enabled:!!r.enabled}))));}
 else if(verb==='emit'){
  const record=readRecord(${JSON.stringify(store)},${JSON.stringify(delivery)}),intent=record.outbox[a[1]],payload=JSON.parse(fs.readFileSync(a[2],'utf8'));
  if(!intent||intent.state!=='pending'||JSON.stringify(intent.payload)!==JSON.stringify(payload)) throw Error('intent was not durable before enqueue');
  fs.writeFileSync(${JSON.stringify(intentProof)},JSON.stringify({revision:record.revision,event:intent,payload}));
  fs.writeFileSync(${JSON.stringify(callsFile)},JSON.stringify((fs.existsSync(${JSON.stringify(callsFile)})?JSON.parse(fs.readFileSync(${JSON.stringify(callsFile)},'utf8')):0)+1));
  const job=db.prepare('SELECT * FROM jobs WHERE id=?').get('delivery-lane');
  db.prepare('INSERT OR IGNORE INTO deliveries(job_id,revision,event_id,payload,state) VALUES(?,?,?,?,?)').run(job.id,job.revision,a[1],JSON.stringify(payload),'queued');
  if(process.env.RACE_REVIEW==='1'){
   record.review={reviewer:'reviewer',commit:${JSON.stringify(review2)},tip:${JSON.stringify(tip)},tree:${JSON.stringify(tree)},verdict:'refused',findings:[{class:'summary_exceeds_code',status:'unresolved',text:'review refused while the enqueue acknowledgement was in flight'}]};
   writeRecord(${JSON.stringify(store)},record);
  }
  console.log(JSON.stringify({queued:db.prepare('SELECT changes() AS n').get().n}));
 } else {console.error('unknown job action '+verb);process.exit(4);}
 db.close();process.exit(0);
}
`);
  const trigger=path.join(HERE,'delivery-trigger.mjs');
  const run=extra=>spawnSync(process.execPath,[trigger,'--store',store,'--emit-command',process.execPath,'--receipt-db',dbFile],
    {encoding:'utf8',windowsHide:true,env:{...process.env,NODE_OPTIONS:`--import=${pathToFileURL(mock).href}`,...extra}});

  const first=run({RACE_REVIEW:'1'}),firstResult=JSON.parse(first.stdout);
  check(first.status===4 && firstResult.counts.write_errors===1,'the acknowledgement write loses the CAS and the pass reports exit 4');
  const afterFirst=readRecord(store,delivery),eventId=Object.keys(afterFirst.outbox)[0];
  check(afterFirst.review.commit===review2,'the in-flight review change wins the race and is preserved');
  check(afterFirst.outbox[eventId].state==='pending','the intent stays durable and pending when its acknowledgement loses the CAS');
  check(db.prepare('SELECT count(*) AS n FROM deliveries').get().n===1,'the emitter queued exactly one effect before the race');
  check(calls()===1,'the emitter was invoked once');

  const second=run({RACE_REVIEW:'0'}),secondResult=JSON.parse(second.stdout),afterSecond=readRecord(store,delivery);
  check(afterSecond.outbox[eventId].state==='acknowledged'||second.status===4,
    'unsettled prior-generation intent is settled from its durable effect or reported, never silently omitted');
  check(afterSecond.outbox[eventId].state==='acknowledged'&&secondResult.counts.prior_generations_settled===1,
    'the older generation is settled exactly once, from the effect it already has');
  check(secondResult.counts.pending_events===0&&second.status===0,'the settled pass reports no pending event because none is pending');
  check(calls()===1,'no double emission: the durable effect is observed, never re-enqueued');
  check(afterSecond.review.verdict==='refused'&&afterSecond.admission.state==='refused',
    'the current refused review is still refused, and the refusal is recorded');

  const orphan=JSON.stringify({id:`delivery:${'0'.repeat(64)}`,subscription:{id:'delivery-lane',revision:1},
    state:'pending',attempts:0,at:new Date().toISOString(),payload:{delivery,note:'intent whose queue effect was never written'},
    payload_file:path.join(store,'events','delivery-0000.json')});
  fs.writeFileSync(path.join(store,'events','delivery-0000.json'),JSON.stringify(JSON.parse(orphan).payload)+'\n');
  const orphanId=JSON.parse(orphan).id,current=readRecord(store,delivery);
  current.outbox={...current.outbox,[orphanId]:JSON.parse(orphan)};writeRecord(store,current);
  const third=run({RACE_REVIEW:'0'}),thirdResult=JSON.parse(third.stdout),afterThird=readRecord(store,delivery);
  check(third.status===4&&thirdResult.counts.pending_events>=1,
    'a prior-generation intent with no durable effect is reported as an unsettled pending event');
  check(thirdResult.skipped.some(item=>item.reason==='prior_generation_pending'),'the report names the reason, not just a count');
  check(afterThird.outbox[orphanId].state==='pending','an intent with no durable effect is never invented into acknowledgement');
  check(afterThird.outbox[eventId].state==='acknowledged'&&calls()===1,'the settled intent stays settled and the emitter is still invoked once');
  console.log(`delivery intent race ok (${checks} checks, 0 skipped; isolated store, repository, database and emitter)`);
} finally {assert.equal(path.dirname(root),os.tmpdir());
  // The database and a Windows handle can outlive a failed check by a few milliseconds, and a
  // cleanup that throws here would hide the check that actually failed. Release, then delete.
  try { db?.close(); } catch {}
  fs.rmSync(root,{recursive:true,force:true,maxRetries:20,retryDelay:100});}
