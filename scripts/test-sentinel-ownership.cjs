// Actual sentinel processes, private home and mock health; never the user watcher.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-sentinel-ownership-'));
let binary=path.resolve(process.argv[2]||path.join('rust/wa-sentinel/target/release',process.platform==='win32'?'wa-sentinel.exe':'wa-sentinel'));
if(process.platform==='win32'&&!fs.existsSync(binary)&&fs.existsSync(binary+'.exe'))binary+='.exe';
let checks=0,server,watcherPid,held=[],healthCalls=0,hold=false;
const env={...process.env,WASM_AGENT_HOME:root,WA_SENTINEL_SUPERVISOR:'none',WA_SENTINEL_WAKE_BUDGET:'0'};
for(const key of Object.keys(env))if(/^(OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)||key==='WASM_AGENT_IN_TURN')delete env[key];
const check=(v,label)=>{assert.ok(v,label);checks++};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label){const until=Date.now()+10000;while(Date.now()<until){if(await fn())return;await sleep(30);}throw Error('timeout '+label);}
function run(args){return new Promise((resolve,reject)=>{const child=spawn(binary,args,{env,windowsHide:true,stdio:['ignore','pipe','pipe']});let out='',err='';child.stdout.on('data',d=>out+=d);child.stderr.on('data',d=>err+=d);child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal,out,err}));});}
async function probe(){const r=await run(['preflight']);check(r.code===0,'preflight exits zero');return JSON.parse(r.out);}
(async()=>{try{
 server=http.createServer((q,s)=>{healthCalls++;if(hold){held.push(s);return;}s.setHeader('content-type','application/json');s.end(JSON.stringify({ok:true,busy:true}));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));env.WASM_AGENT_PORT=String(server.address().port);
 let p=await probe();check(p.watcher==='not_running','empty home has no watcher');
 const state=path.join(root,'.wasm-agent','sentinel');
 fs.writeFileSync(path.join(state,'sentinel.pid'),String(process.pid));
 p=await probe();check(p.watcher==='unverified','recycled live PID does not prove watcher identity');
 const recycled=await run(['start']);check(recycled.code!==0&&/unverified/.test(recycled.err),'start refuses a live unverified PID');
 fs.unlinkSync(path.join(state,'sentinel.pid'));
 const starts=await Promise.all(Array.from({length:6},()=>run(['start'])));
 check(starts.filter(r=>/started the sentinel/.test(r.out)).length===1,'concurrent starts confirm exactly one watcher');
 p=await probe();watcherPid=p.watcher_pid;check(p.watcher==='running'&&Number.isInteger(watcherPid),'lifetime lock and actual PID are exposed');
 const second=await run(['watch']);check(second.code!==0&&/another watcher/.test(second.err),'second watch cannot own lifetime lease');
 hold=true;await until(()=>held.length>0,'watcher held in health probe');
 const begin=performance.now();p=await probe();check(performance.now()-begin<1500,'preflight stays bounded while watcher health is blocked');check(p.capabilities.health_free&&p.ownership==='watcher_lifetime_lock','health-free ownership contract advertised');
 const writers=await Promise.all(Array.from({length:12},(_,i)=>run(['request','deploy','--if-no-pending','--reason','fixture-'+i])));
 check(writers.filter(r=>r.code===0&&/requested deploy:/.test(r.out)).length===1,'atomic concurrent deploy writers create one durable request');
 check(writers.every(r=>r.code===0||/lifecycle change in progress/.test(r.err)),'every other writer names existing request or explicit admission refusal');
 const requests=path.join(state,'requests'),files=fs.readdirSync(requests).filter(f=>f.endsWith('.json'));
 check(files.length===1,'one request on disk');const bytes=fs.readFileSync(path.join(requests,files[0]));
 hold=false;for(const s of held)s.end(JSON.stringify({ok:true,busy:true}));held=[];
 await until(()=>healthCalls>2,'watcher queue observation');
 check(fs.existsSync(path.join(requests,files[0])),'busy node preserves queued deployment rather than executing it');
 // Reproduce the claim boundary under the same OS queue lock via the native once path's
 // real run request: deployment remains held, and independent requests are still claimed.
 const other=await run(['request','run','--script',path.join(root,'not-approved.sh'),'--reason','claim-fixture']);check(other.code===0,'independent request is durable');
 await until(()=>fs.readdirSync(path.join(state,'failed')).some(f=>f!==files[0]),'independent claim settles with explicit refusal');
 const again=await run(['request','deploy','--if-no-pending','--reason','duplicate']);check(again.code===0&&/existing deploy request/.test(again.out),'dedupe survives concurrent watcher claims');
 check(fs.readFileSync(path.join(requests,files[0])).equals(bytes),'duplicate preserves original effect evidence');
 const uncertain=path.join(state,'claimed','uncertain.json');fs.writeFileSync(uncertain,'malformed claimed effect evidence');
 p=await probe();check(p.watcher==='running'&&p.inventory_verified===false&&p.inventory_error.includes('uncertain.json'),'preflight surfaces unknown claimed inventory without losing watcher identity');
 const refusedInventory=await run(['request','deploy','--if-no-pending']);check(refusedInventory.code!==0&&/unknown_inventory/.test(refusedInventory.err),'unknown inventory refuses atomic deploy admission');
 check(fs.readFileSync(uncertain,'utf8')==='malformed claimed effect evidence','uncertain intent remains untouched');
 fs.unlinkSync(uncertain); // This private record was manufactured here and never executed.
 const stop=await run(['stop']);check(stop.code===0,'explicit stop accepted');
 await until(async()=>{const r=await run(['preflight']);return JSON.parse(r.out).watcher==='not_running';},'watcher drains after stop');
 p=await probe();check(p.stop_file===true,'intentional stop is durable');
 const unsolicited=await run(['watch']);check(unsolicited.code!==0&&/intentionally stopped/.test(unsolicited.err),'unsolicited watcher cannot clear intentional stop');
 const restart=await run(['restart']);check(restart.code!==0&&/intentionally stopped/.test(restart.err),'restart preserves existing intentional stop');
 const blocked=await run(['request','deploy','--if-no-pending']);check(blocked.code!==0&&/intentionally stopped/.test(blocked.err),'stopped watcher cannot accept update admission');
 console.log(`sentinel ownership ok (${checks} checks, 0 skipped; actual processes, mock health)`);
}finally{
 hold=false;for(const s of held)s.end('{}');
 let drained=true;
 if(fs.existsSync(binary)){
   await run(['stop']).catch(()=>{});
   try{await until(async()=>{const r=await run(['preflight']);return r.code===0&&JSON.parse(r.out).watcher==='not_running';},'owned fixture watcher drain');}
   catch(error){drained=false;console.error(`retained ${root}: ${error.message}`);process.exitCode=1;}
 }
 if(server){server.closeAllConnections();await new Promise(r=>server.close(r));}
 if(drained)fs.rmSync(root,{recursive:true,force:true});
}})().catch(e=>{console.error(e.stack);process.exitCode=1;});
