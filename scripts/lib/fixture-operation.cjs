// Private fixture native-program runner using production wa-operation tree containment.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
module.exports=function ownedRun(root,command,args,options={}){
 const repo=path.resolve(__dirname,'../..'),wa=path.join(repo,'rust/target/debug',process.platform==='win32'?'wa.exe':'wa');
 const id=require('node:crypto').randomUUID(),script=path.join(root,id+'.lua');
 const fixtureEnv=Object.fromEntries(Object.entries(options.env||{}).filter(([key])=>/^(WA_TEST_|WA_WHATSAPP_|WASM_AGENT_PLUGINS$|WA_SCRIPT$|WA_CDP_PORT$|WA_INSTALL_DIR$|LOCALAPPDATA$|WASM_AGENT_HOME$|WASM_AGENT_LUA_ROOT$|WA_PREFLIGHT_SCRIPT$)/.test(key)));
 const launcher=path.join(root,id+'-launch.cjs');
 fs.writeFileSync(launcher,`const {spawnSync}=require('child_process');const r=spawnSync(${JSON.stringify(command)},${JSON.stringify(args)},{env:${JSON.stringify(fixtureEnv)},stdio:'inherit'});process.exit(r.status===null?1:r.status);`);
 const spec={program:process.execPath,args:[launcher],cwd:options.cwd||repo,timeout_seconds:240};
 fs.writeFileSync(script,`local j=dofile('lua/vendor/json.lua');local r=j.decode(host.operation('start',${JSON.stringify(JSON.stringify(spec))}));assert(r.operation_id,j.encode(r));local s=j.decode(host.operation('await',j.encode({id=r.operation_id,wait_for='settled'})));assert(s.settled==true,j.encode(s));print(j.encode(s))`);
 const r=spawnSync(wa,['--db',path.join(root,id+'.db')],{env:{...process.env,...options.env,WASM_AGENT_HOME:path.join(root,id+'-home'),WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:script},timeout:260000,encoding:'utf8'});
 fs.writeFileSync(path.join(root,id+'-wrapper.stdout'),r.stdout||'');fs.writeFileSync(path.join(root,id+'-wrapper.stderr'),r.stderr||'');
 assert(!r.error&&r.status===0,'contained runner failed; preserve root: '+r.stderr);
 const s=JSON.parse(r.stdout.trim().split(/\r?\n/).pop());assert(s.settled===true&&s.output_streams_closed===true,'tree/streams not settled');
 const stdout=fs.readFileSync(s.stdout_path),stderr=fs.readFileSync(s.stderr_path);
 fs.writeFileSync(path.join(root,id+'.stdout'),stdout,{flag:'wx'});fs.writeFileSync(path.join(root,id+'.stderr'),stderr,{flag:'wx'});fs.writeFileSync(path.join(root,id+'.state.json'),JSON.stringify(s),{flag:'wx'});
 return {status:s.process_exit_code,stdout:stdout.toString(),stderr:stderr.toString()};
};
