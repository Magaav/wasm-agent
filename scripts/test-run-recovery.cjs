// Real server crash/restart and durable stream proof; local mock inference, no account.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const {spawn} = require('node:child_process');
const assert = require('node:assert/strict');
const {once} = require('node:events');
const repo = path.resolve(__dirname,'..');
const binary = path.resolve(process.argv[2] || 'rust/target/release/wa.exe');
const root = fs.mkdtempSync(path.join(os.tmpdir(),'wa-run-recovery-'));
const db = path.join(root,'memory.db');
let checks=0, calls=0, provider, child, port, currentLog, other;
const connections = new Set();
const check = (value,label) => { assert.ok(value,label); checks++; };
const delay = ms => new Promise(resolve=>setTimeout(resolve,ms));
async function freePort() { const s=net.createServer(); s.listen(0,'127.0.0.1'); await once(s,'listening'); const p=s.address().port; await new Promise(r=>s.close(r)); return p; }
async function until(fn,label) { for(let i=0;i<160;i++) { const value=await fn(); if(value) return value; await delay(50); } throw new Error('timeout: '+label+'\n'+fs.readFileSync(currentLog,'utf8')); }
async function api(route,body,headers={}) {
  const response=await fetch('http://127.0.0.1:'+port+'/'+route,{method:body===undefined?'GET':'POST',headers:{'content-type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(3000)});
  return {status:response.status,...await response.json()};
}
function launch(p,cp,number) {
  const env={...process.env};
  for(const key of Object.keys(env)) if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)) delete env[key];
  Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+provider.address().port,
    WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'});
  // Deliberately no disk Lua override: this tests the installed/embedded execution shape.
  const file=path.join(root,'server-'+number+'.log'); const log=fs.openSync(file,'w');
  const c=spawn(binary,['--db',db,'serve','--port',String(p),'--client-port',String(cp),'--ui',path.join(repo,'ui')],{cwd:repo,env,stdio:['ignore',log,log],windowsHide:true});
  fs.closeSync(log); currentLog=file; return c;
}
async function stop(c) { if(c && c.exitCode===null && c.signalCode===null) { const done=once(c,'exit'); c.kill('SIGKILL'); await done; } }
async function start(n) { port=await freePort(); child=launch(port,await freePort(),n); await until(async()=>{try{return (await api('health')).status===200;}catch{return false;}},'server ready'); }
function chat(text) {
  return fetch('http://127.0.0.1:'+port+'/chat',{method:'POST',headers:{'content-type':'application/json','accept':'text/event-stream'},body:JSON.stringify({thread:'recovery-thread',text})}).then(r=>r.text()).catch(e=>'disconnected: '+e.message);
}
(async()=>{
  try {
    provider=http.createServer((req,res)=>{
      let raw=''; req.on('data',c=>raw+=c); req.on('end',()=>{
        calls++;
        const body=JSON.parse(raw); const text=body.messages.filter(m=>m.role==='user').at(-1)?.content || '';
        res.writeHead(200,{'content-type':'text/event-stream'});
        res.write('data: '+JSON.stringify({choices:[{delta:{content:'DURABLE-RESTART-MARKER'},finish_reason:null}]})+'\n\n');
        if(String(text).includes('finish now')) res.end('data: '+JSON.stringify({choices:[{delta:{},finish_reason:'stop'}],usage:{prompt_tokens:10,completion_tokens:4,total_tokens:14}})+'\n\ndata: [DONE]\n\n');
      });
    });
    provider.on('connection',s=>{connections.add(s);s.on('close',()=>connections.delete(s));});
    provider.listen(0,'127.0.0.1'); await once(provider,'listening');
    await start(1);
    const pending=chat('hold this response open');
    const first=await until(async()=>{const s=await api('runs',{thread:'recovery-thread'});return s.runs?.find(r=>r.state==='running');},'running admission');
    const replay=await until(async()=>{const r=await api('run-events',{thread:'recovery-thread',run_id:first.run_id});return JSON.stringify(r.events).includes('DURABLE-RESTART-MARKER')&&r;},'durable output');
    check(replay.durable===true,'HTTP replay is durable');
    const queued=chat('queued request must not run after restart');
    const second=await until(async()=>{const s=await api('runs',{thread:'recovery-thread'});return s.runs?.find(r=>r.state==='queued');},'queued admission');
    check(calls===1,'same conversation queues without a second inference');
    const otherPort=await freePort(); other=launch(otherPort,await freePort(),2);
    await until(async()=>other.exitCode!==null,'duplicate server refuses shared journal');
    check(other.exitCode!==0,'duplicate server fails rather than stealing recovery ownership');
    await stop(child); await pending; await queued;
    await start(3);
    const recovered=await api('runs',{thread:'recovery-thread'});
    check(recovered.runs.find(r=>r.run_id===first.run_id)?.state==='unknown','running crash is explicit unknown');
    check(recovered.runs.find(r=>r.run_id===second.run_id)?.state==='not_started','queued crash is explicitly not started');
    const receipt=await api('runs',{action:'inspect',thread:'recovery-thread',run_id:second.run_id});
    check(JSON.parse(receipt.request).text==='queued request must not run after restart','queued request remains available for explicit recovery');
    const persisted=await api('run-events',{thread:'recovery-thread',run_id:first.run_id});
    check(JSON.stringify(persisted.events).includes('DURABLE-RESTART-MARKER'),'unsaved live output survives process death');
    check(persisted.next_seq===replay.next_seq,'event cursor survives process death');
    check((await api('run-events',{thread:'different-thread',run_id:first.run_id})).status===404,'different conversation cannot read replay');
    check((await api('run-events',{thread:'recovery-thread',run_id:first.run_id},{'x-wa-session':'invalid'})).status===401,'invalid credential cannot read replay');
    await delay(250); check(calls===1,'restart does not replay queued or uncertain inference');
    await chat('finish now');
    const finished=await until(async()=>{const r=await api('runs',{thread:'recovery-thread'});return r.runs?.find(r=>r.run_id>second.run_id&&r.state==='completed');},'new run settled');
    check(finished.run_id>second.run_id,'new run IDs cannot alias pre-restart operations');
    const settled=await api('run-events',{thread:'recovery-thread',run_id:finished.run_id});
    check(settled.status===200&&settled.events.some(e=>e.event.type==='done'),'settled replay remains available');
    console.log(`run recovery ok (${checks} checks, 0 skipped; real process restart, mock inference)`);
  } catch(e) { console.error(e.stack); process.exitCode=1; }
  finally { await stop(child); await stop(other); for(const s of connections)s.destroy(); if(provider)provider.close(); console.log('evidence: '+root); }
})();
