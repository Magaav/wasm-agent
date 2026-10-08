// Private Windows console-isolation proof. No production watcher, task, node or model.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawn,spawnSync}=require('node:child_process');
const [binary,out]=process.argv.slice(2);assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out));assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out,{recursive:true});
if(process.platform!=='win32'){console.log(JSON.stringify({ok:true,checks:0,skipped:1,reason:'Windows console fixture'}));process.exit(0);}
let checks=0;const check=(v,why)=>{assert(v,why);checks++};
const home=path.join(out,'home');fs.mkdirSync(home);const box=path.join(home,'.wasm-agent','sentinel');
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(k)));
Object.assign(env,{WASM_AGENT_HOME:home,WA_SENTINEL_SUPERVISOR:'none',WASM_AGENT_PORT:'1',WA_SENTINEL_WAKE_BUDGET:'0'});
const run=(args,e=env)=>spawnSync(binary,args,{env:e,encoding:'utf8',timeout:10000,windowsHide:true});
const ps=path.join(out,'console-proof.ps1');fs.writeFileSync(ps,`$ErrorActionPreference='Stop'\nAdd-Type @'\nusing System; using System.Runtime.InteropServices; public static class ConsoleProbe {\n[DllImport("kernel32.dll")] public static extern bool FreeConsole();\n[DllImport("kernel32.dll",SetLastError=true)] public static extern bool AttachConsole(uint pid);\n}\n'@\n[ConsoleProbe]::FreeConsole() | Out-Null\n$attached=[ConsoleProbe]::AttachConsole([uint32]$env:PROBE_WATCHER)\n$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error()\nif($attached){[ConsoleProbe]::FreeConsole()|Out-Null;throw 'watcher unexpectedly owns a console'}\n@{ok=$true;attach_refused=$true;attach_error=$errorCode}|ConvertTo-Json -Compress\n`);
let parent;
(async()=>{try{
 const refused=run(['start'],{...env,WASM_AGENT_IN_TURN:'1'});check(refused.status!==0&&refused.stderr.includes('requires_external_executor'),'in-turn start refuses');check(!fs.existsSync(path.join(box,'sentinel.pid')),'refusal spawned nothing');
 const launcher=path.join(out,'private-launcher.cjs');
 fs.writeFileSync(launcher,`const {spawnSync}=require('node:child_process'),fs=require('node:fs');const r=spawnSync(${JSON.stringify(binary)},['start'],{encoding:'utf8'});fs.writeFileSync(${JSON.stringify(path.join(out,'start.log'))},r.stdout+r.stderr);if(r.status!==0)process.exit(1);fs.writeFileSync(${JSON.stringify(path.join(out,'parent-ready'))},'ready');setInterval(()=>{},1000);`);
 parent=spawn(process.execPath,[launcher],{env,windowsHide:true,stdio:'ignore'});
 const parentExit=new Promise(resolve=>parent.once('exit',resolve));
 const until=async(fn)=>{const end=Date.now()+15000;while(Date.now()<end){if(fn())return;await new Promise(r=>setTimeout(r,40));}throw Error('fixture readiness timeout');};
 await until(()=>fs.existsSync(path.join(out,'parent-ready'))&&fs.existsSync(path.join(box,'sentinel.pid')));
 let p=JSON.parse(run(['preflight']).stdout);check(p.watcher==='running','native detached watcher ready');
 const proof=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-File',ps],{env:{...env,PROBE_WATCHER:String(p.watcher_pid),PROBE_PARENT:String(parent.pid)},encoding:'utf8',timeout:15000});
 fs.writeFileSync(path.join(out,'console.stdout'),proof.stdout||'');fs.writeFileSync(path.join(out,'console.stderr'),proof.stderr||'');check(proof.status===0,proof.stderr);const observed=JSON.parse(proof.stdout);check(observed.attach_refused&&observed.attach_error===6,'watcher has no console (ERROR_INVALID_HANDLE)');parent.kill();
 await parentExit;p=JSON.parse(run(['preflight']).stdout);check(p.watcher==='running','watcher survives owned parent exit');
 const stop=run(['stop']);check(stop.status===0,'supported stop');await until(()=>JSON.parse(run(['preflight']).stdout).watcher==='not_running');
 check(fs.existsSync(path.join(box,'stop')),'intentional stop preserved');const restart=run(['restart']);check(restart.status!==0&&restart.stderr.includes('intentionally stopped'),'restart cannot undo intentional stop');
 const r={ok:true,checks,skipped:0,console_independent:true,live_effects:false};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(r));console.log(JSON.stringify(r));
}finally{run(['stop']);if(parent&&parent.exitCode===null)parent.kill();
 const end=Date.now()+10000;let drained=false;while(Date.now()<end){const state=run(['preflight']);if(state.status===0&&JSON.parse(state.stdout).watcher==='not_running'){drained=true;break;}await new Promise(r=>setTimeout(r,50));}assert(drained,'private watcher did not drain; retain evidence');
}})().catch(e=>{console.error(e.stack);process.exitCode=1;});
