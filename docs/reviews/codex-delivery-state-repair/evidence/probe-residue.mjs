// Independent probe: which pending-intent shapes does the 43893c3 repair NOT reconcile or report?
// Uses the repaired tip's own trigger/store/admission modules, unmodified. Private scratch only.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath,pathToFileURL} from 'node:url';

const SRC='C:/Users/Victor/AppData/Local/Temp/wa-verdict-43893c3/tip-run';
const HERE=path.dirname(fileURLToPath(import.meta.url));
const root=path.join(HERE,'run');
fs.rmSync(root,{recursive:true,force:true});
const repo=path.join(root,'repo'),store=path.join(root,'store'),dbFile=path.join(root,'jobs.db');
const mock=path.join(root,'sentinel-mock.mjs'),callsFile=path.join(root,'emitter-calls.json');
fs.mkdirSync(repo,{recursive:true});

const {writeRecord,readRecord}=await import(pathToFileURL(path.join(SRC,'scripts','lib','delivery-store.mjs')).href);
const db=new DatabaseSync(dbFile);
function git(...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
git('init','-q','--initial-branch=main');git('config','core.autocrlf','false');
fs.writeFileSync(path.join(repo,'source.txt'),'source\n');git('add','.');git('commit','-qm','source\n\nAgent: wasm-agent node=fixture session=producer');
const tip=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');
fs.writeFileSync(path.join(repo,'review.txt'),'passed\n');git('add','.');git('commit','-qm','review passed\n\nAgent: wasm-agent node=fixture session=reviewer');
const review=git('rev-parse','HEAD');
for (const d of ['change/aaa','change/lll','change/zzz']) git('update-ref',`refs/remotes/origin/${d}`,tip);
git('update-ref','refs/remotes/origin/change/review',review);

db.exec('CREATE TABLE jobs(id TEXT PRIMARY KEY,revision INTEGER,enabled INTEGER,definition TEXT);CREATE TABLE deliveries(id INTEGER PRIMARY KEY,job_id TEXT,revision INTEGER,event_id TEXT,payload TEXT,state TEXT,UNIQUE(job_id,revision,event_id));');
db.prepare('INSERT INTO jobs VALUES(?,?,?,?)').run('delivery-lane',1,1,JSON.stringify({id:'delivery-lane',trigger:{kind:'event',topic:'delivery.admitted'}}));
fs.writeFileSync(mock,`import fs from 'node:fs';import {DatabaseSync} from 'node:sqlite';
if(process.argv[1]?.endsWith('job')){
 const [verb,...a]=process.argv.slice(2),db=new DatabaseSync(${JSON.stringify(dbFile)});
 if(verb==='list'){console.log(JSON.stringify(db.prepare('SELECT * FROM jobs').all().map(r=>({...JSON.parse(r.definition),revision:r.revision,enabled:!!r.enabled}))));}
 else if(verb==='emit'){
  if(process.env.EMIT_FAIL==='1'){console.error('emitter refused for this probe pass');process.exit(1);}
  const payload=JSON.parse(fs.readFileSync(a[2],'utf8'));
  fs.writeFileSync(${JSON.stringify(callsFile)},JSON.stringify((fs.existsSync(${JSON.stringify(callsFile)})?JSON.parse(fs.readFileSync(${JSON.stringify(callsFile)})):0)+1));
  const job=db.prepare('SELECT * FROM jobs WHERE id=?').get('delivery-lane');
  db.prepare('INSERT OR IGNORE INTO deliveries(job_id,revision,event_id,payload,state) VALUES(?,?,?,?,?)').run(job.id,job.revision,a[1],JSON.stringify(payload),'queued');
  console.log(JSON.stringify({queued:db.prepare('SELECT changes() AS n').get().n}));
 } else {console.error('unknown job action '+verb);process.exit(4);}
 db.close();process.exit(0);
}
`);

function admit(delivery){
  writeRecord(store,{delivery,branch:delivery,repository:repo,producer:'producer',tip,tree,
    review:{reviewer:'reviewer',commit:review,tip,tree,verdict:'passed',findings:[]},landing:null});
}
admit('change/aaa');admit('change/zzz');

const run=(extra=[],env={})=>spawnSync(process.execPath,[path.join(SRC,'scripts','delivery-trigger.mjs'),
  '--store',store,'--emit-command',process.execPath,'--receipt-db',dbFile,...extra],
  {encoding:'utf8',windowsHide:true,env:{...process.env,NODE_OPTIONS:`--import=${pathToFileURL(mock).href}`,...env}});
const brief=r=>{const j=JSON.parse(r.stdout);return {exit:r.status,records:j.counts.records,admitted:j.counts.admitted,refused:j.counts.refused,
  pending:j.counts.pending_events,settled_prior:j.counts.prior_generations_settled,emitted:j.counts.emitted,skipped:j.counts.skipped,
  reasons:j.skipped.map(s=>s.reason),zzzSrc:r.stderr.split(String.fromCharCode(10)).filter(l=>l.startsWith('change/zzz')).map(l=>l.trim()),refusals:j.refused.map(x=>x.condition+" | "+x.refusal)};};
const intents=d=>Object.entries(readRecord(store,d).outbox||{}).map(([id,i])=>`${id.slice(9,17)}:${i.state}`);

const out={};
out.pass0=brief(run(['--limit','8'],{EMIT_FAIL:'1'}));
out.pass0_intents={aaa:intents('change/aaa'),zzz:intents('change/zzz')};
console.log('pass0 (both intents durable, emitter refuses): '+JSON.stringify(out.pass0)+' '+JSON.stringify(out.pass0_intents));
out.pass1_limit1=brief(run(['--limit','1'],{EMIT_FAIL:'0'}));
out.pass1_intents={aaa:intents('change/aaa'),zzz:intents('change/zzz')};
console.log('RESIDUE limit-exhaustion: '+JSON.stringify({exit:out.pass1_limit1.exit,pending_events:out.pass1_limit1.pending,
  prior_generations_settled:out.pass1_limit1.settled_prior,notes:out.pass1_limit1.zzzSrc,intents:out.pass1_intents}));
out.pass2_noemit=brief(run(['--no-emit']));
out.pass2_intents={zzz:intents('change/zzz')};
console.log('RESIDUE no-emit: '+JSON.stringify({exit:out.pass2_noemit.exit,pending_events:out.pass2_noemit.pending,intents:out.pass2_intents}));
out.pass3_clear=brief(run(['--limit','8'],{EMIT_FAIL:'0'}));
const old=readRecord(store,'change/aaa');
const pendingId='delivery:'+'f'.repeat(64);
const payloadFile=path.join(store,'events','change-lll.json');
fs.writeFileSync(payloadFile,JSON.stringify({delivery:'change/lll',topic:'delivery.admitted'})+'\n');
admit('change/lll');
const lll=readRecord(store,'change/lll');
lll.landing={sha:'0'.repeat(40),at:new Date().toISOString()};
lll.outbox={[pendingId]:{id:pendingId,subscription:{id:'delivery-lane',revision:1},state:'pending',attempts:1,at:new Date().toISOString(),payload:{delivery:'change/lll'},payload_file:payloadFile}};
writeRecord(store,lll);
assert.equal(readRecord(store,'change/lll').outbox[pendingId].state,'pending');
out.pass4_landed=brief(run(['--limit','8'],{EMIT_FAIL:'0'}));
out.pass4_intents={lll:intents('change/lll')};
console.log('RESIDUE already-landed record: '+JSON.stringify({exit:out.pass4_landed.exit,pending_events:out.pass4_landed.pending,
  reasons:out.pass4_landed.reasons,intents:out.pass4_intents}));
out.pass5_otherrepo=brief(run(['--limit','8','--repo',path.join(root,'elsewhere')],{EMIT_FAIL:'0'}));
out.pass5_intents={lll:intents('change/lll')};
console.log('RESIDUE other_repository filter: '+JSON.stringify({exit:out.pass5_otherrepo.exit,pending_events:out.pass5_otherrepo.pending,
  reasons:out.pass5_otherrepo.reasons,intents:out.pass5_intents}));
out.emitterCalls=fs.existsSync(callsFile)?JSON.parse(fs.readFileSync(callsFile,'utf8')):0;
out.settledRowCount=db.prepare('SELECT count(*) AS n FROM deliveries').get().n;
fs.writeFileSync(path.join(HERE,'residue.json'),JSON.stringify(out,null,2)+'\n');
db.close();
console.log('emitter calls='+out.emitterCalls+', durable queue rows='+out.settledRowCount);
