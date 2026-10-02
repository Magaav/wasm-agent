import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {catalog} from './gate-checks.mjs';
const require=createRequire(import.meta.url);
const {verdict}=require('./lib/test-verdict.cjs');
export const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
export function checkVerdict(check, exit, output) {
  const text=String(output);
  if(check.verdict==='js')return verdict('js',exit,text);
  if(check.verdict==='browser') {
    // The browser check's terminal verdict line, in two parts: the prefix that identifies *which* check this
    // is ("ok   UI structure"), and a subject this stage owns - the mid-run reload or the startup recovery
    // it is the verdict for. Deliberately not the whole sentence: the sentence names the stages test-ui.ps1
    // covers, those grow, and an anchored end-of-line match turned an honest added stage (the inspector
    // window) into a gate FAIL only the full gate could see. Nor is the prefix alone enough - `ok   UI
    // structure, and then something else entirely` named no stage at all and was accepted. `markers.length===1`
    // and the FAIL guard below are what reject a mangled or repeated report.
    const prefix=/^\s*ok   UI structure\b/;
    const subjects=[/mid-run reload/i,/startup recovery/i];
    const markers=text.split(/\r?\n/).filter(line=>prefix.test(line)&&subjects.some(subject=>subject.test(line)));
    return {ok:exit===0&&markers.length===1&&!/^\s*(?:FAIL(?:[:\s]|$)|ALL FAIL(?:[:\s]|$)|DEPENDENCY_MISSING)/m.test(text),reason:'browser_terminal_verdict_required'};
  }
  if(check.verdict==='proof') {
    try {const counts=require('./lib/proof-verdict.cjs').validate(check.proof_kind,exit,text,check.minimum);return {ok:true,...counts};}
    catch(error){return {ok:false,reason:error.message};}
  }
  return {ok:exit===0};
}
export async function executeChecks(repo, ids, {jobs=1, output=null, emit=true, memoryMb=Math.floor(os.freemem()/1048576)}={}) {
  if(!Number.isInteger(jobs)||jobs<1||jobs>4) throw Error('jobs must be 1..4; default 1 until measured');
  const all=catalog(repo), selected=ids.map(id=>{const c=all.find(c=>c.id===id);if(c&&c.available===false)throw Error(`check ${id} fixture unavailable in this source tree`);if(c&&c.platform&&c.platform!==process.platform)throw Error(`check ${id} requires ${c.platform}`);if(!c||id==='full')throw Error(`unsupported focused check ${id}; full needs finish.mjs gate and reservation`);return c;});
  if(!Number.isInteger(memoryMb)||memoryMb<1||selected.some(c=>c.resources.memory_mb>memoryMb))throw Error('insufficient declared check memory budget');
  if(new Set(ids).size!==ids.length||!ids.length)throw Error('select distinct nonempty checks');
  const root=output||fs.mkdtempSync(path.join(os.tmpdir(),'wa-checks-'));
  fs.mkdirSync(root,{recursive:true});
  const started=performance.now(), pending=[...selected], running=new Set(), held=new Set(), results=[];
  let reservedMemory=0;
  async function run(check) {
    const home=fs.mkdtempSync(path.join(root,'home-')), env={...process.env};
    for(const key of Object.keys(env)) if(/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(key))delete env[key];
    Object.assign(env,{HOME:home,USERPROFILE:home,LOCALAPPDATA:path.join(home,'LocalAppData'),APPDATA:path.join(home,'AppData'),WASM_AGENT_HOME:home,WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',
      WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only',HTTP_PROXY:'',HTTPS_PROXY:'',ALL_PROXY:'',NO_PROXY:'127.0.0.1,localhost,::1'});
    const log=path.join(root,`${check.id.replaceAll(/[^a-z0-9.-]/gi,'_')}.log`),fd=fs.openSync(log,'w'),begin=performance.now();
    const command=[...check.command];
    if(check.binary)command.splice(2,0,path.join(repo,'rust','target','release',process.platform==='win32'?'wa.exe':'wa'));
    if(check.verdict==='browser') {
      const freePort=()=>new Promise((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});});
      const candidate=path.join(repo,'rust','target','release',process.platform==='win32'?'wa.exe':'wa');
      const runtime=fs.existsSync(candidate)?candidate:path.join(process.env.LOCALAPPDATA||'', 'wasm-agent','wa.exe');
      command.push('-WaExe',runtime);
      command.push('-Port',String(await freePort()),'-ClientPort',String(await freePort()));
    }
    const result=await new Promise(resolve=>{
      const child=spawn(command[0],command.slice(1),{cwd:repo,env,stdio:['ignore',fd,fd],windowsHide:true});
      child.on('error',error=>resolve({exit:null,error:error.message}));
      child.on('close',(exit,signal)=>resolve({exit,signal}));
    });
    fs.closeSync(fd);
    const bytes=fs.readFileSync(log), text=bytes.toString(), proof=checkVerdict(check,result.exit,text);
    const record={id:check.id,...result,passed:proof.ok,reason:proof.reason||result.error||null,ms:performance.now()-begin,started_ms:begin-started,ended_ms:performance.now()-started,home,log,log_sha256:hash(bytes),resources:check.resources,skipped:0};
    results.push(record);
    if(emit)process.stdout.write(`check ${check.id}: ${record.passed?'PASS':'FAIL'} exit=${result.exit} ms=${record.ms.toFixed(1)} log=${log}\n`);
    // Keep full child output and failure attribution, including successful assertions.
    if(emit){process.stdout.write(text);if(!text.endsWith('\n'))process.stdout.write('\n');}
    if(record.passed)fs.rmSync(home,{recursive:true,force:true});
  }
  while(pending.length||running.size) {
    for(let i=0;i<pending.length&&running.size<jobs;) {
      const c=pending[i];if(c.resources.exclusive.some(key=>held.has(key))||reservedMemory+c.resources.memory_mb>memoryMb){i++;continue;}
      pending.splice(i,1);reservedMemory+=c.resources.memory_mb;for(const key of c.resources.exclusive)held.add(key);
      const task=run(c).finally(()=>{running.delete(task);reservedMemory-=c.resources.memory_mb;for(const key of c.resources.exclusive)held.delete(key);});running.add(task);
    }
    if(running.size)await Promise.race(running);
  }
  const receipt={schema:1,kind:'focused',repo,passed:results.every(r=>r.passed),jobs,memory_budget_mb:memoryMb,ms:performance.now()-started,
    workload:ids,results:ids.map(id=>results.find(r=>r.id===id)),skipped:0,resources:{logical_cpus:os.cpus().length,total_memory_bytes:os.totalmem(),free_memory_bytes:os.freemem()},
    limits:'memory admission uses declared estimates, not OS quotas; no per-child CPU/RAM/I/O sampling; concurrency hard bound 4; no test-result cache',at:new Date().toISOString()};
  fs.writeFileSync(path.join(root,'checks.json'),JSON.stringify(receipt,null,2)+'\n');return receipt;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [mode,...args]=process.argv.slice(2),repo=process.cwd();
  try {
    if(mode==='list')console.log(JSON.stringify(catalog(repo),null,2));
    else if(mode==='run') {
      const j=args.indexOf('--jobs'), jobs=j<0?1:Number(args.splice(j,2)[1]);
      const o=args.indexOf('--output'), output=o<0?null:path.resolve(args.splice(o,2)[1]);
      const ids=args.includes('ui-js')?catalog(repo).filter(c=>c.id.startsWith('js:')).map(c=>c.id):args;
      const result=await executeChecks(repo,ids,{jobs,output});process.exitCode=result.passed?0:1;
    } else throw Error('usage: gate-check.mjs list | run <check IDs|ui-js> [--jobs 1..4] [--output directory]');
  } catch(error){console.error(error.stack);process.exitCode=1;}
}
