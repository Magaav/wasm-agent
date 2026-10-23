// Actual coordinator/native child and private Git; deterministic provider, no paid inference.
// Proves the three orchestration routes with real coordinator inference: talk (no child), a short
// direct task (routed direct, done here), and a concrete implementation (refused before its route,
// refused after route=delegate, delegated, then the coordinator may act again).
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process'),{DatabaseSync}=require('node:sqlite'),{pathToFileURL}=require('node:url');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=path.resolve(process.argv[3]);
const embedded=process.argv.includes('--embedded');assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out,{recursive:true});
const fixture=out+'/fixture',main=fixture+'/main',remote=fixture+'/remote.git',home=fixture+'/home';fs.mkdirSync(home,{recursive:true});
const git=(root,...args)=>{const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stdout+r.stderr);return r.stdout.trim();};
git(out,'init','--bare',remote);git(out,'init','-b','main',main);git(main,'config','core.autocrlf','false');git(main,'config','user.name','fixture');git(main,'config','user.email','fixture@invalid');fs.writeFileSync(main+'/base','base');git(main,'add','.');git(main,'commit','-m','baseline');git(main,'remote','add','origin',remote);git(main,'push','-u','origin','main');
let calls=0,parentCalls=0,childCalls=0,held=null,released=false,child,provider;const sockets=new Set();
(async()=>{try{
 const {isolatedEnvironment}=await import(pathToFileURL(repo+'/scripts/agent-benchmark-environment.mjs').href);
 provider=http.createServer((req,res)=>{
  if(req.url==='/release'){released=true;if(held){held();held=null;}res.end('ok');return;}
  let raw='';req.on('data',b=>raw+=b);req.on('end',()=>{try{
   const body=JSON.parse(raw);calls++;const isChild=body.messages[0].content.includes('You are a subagent');
   const send=message=>{const reason=message.tool_calls?'tool_calls':'stop',usage={prompt_tokens:20,completion_tokens:5,total_tokens:25};
    if(body.stream){res.writeHead(200,{'content-type':'text/event-stream'});const delta=message.tool_calls?{tool_calls:message.tool_calls.map((call,index)=>({...call,index}))}:{content:message.content};res.end('data: '+JSON.stringify({choices:[{delta,finish_reason:reason}],usage})+'\n\ndata: [DONE]\n\n');}
    else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({choices:[{message,finish_reason:reason}],usage}));}};
   const tool=(name,args)=>send({content:'',tool_calls:[{id:'fixture-'+calls,type:'function',function:{name,arguments:JSON.stringify(args)}}]});
   const tail=start=>body.messages.slice(start);
   let lastUserIndex=-1;body.messages.forEach((message,index)=>{if(message.role==='user')lastUserIndex=index;});
   const lastUser=String(body.messages[lastUserIndex]&&body.messages[lastUserIndex].content||'');
   const turn=tail(lastUserIndex+1),lastTool=turn.filter(message=>message.role==='tool').at(-1);
   const lastResult=lastTool?JSON.parse(lastTool.content):null;
   if(!isChild){
    parentCalls++;
    assert(body.messages[0].content.includes('assess the request using this conversation'),'decision policy present');
    const names=(body.tools||[]).map(item=>item.function&&item.function.name);
    assert(names.includes('subagent'),'subagent is declared from the start in orchestration mode');
    assert(names.includes('route_task'),'route_task is declared from the start in orchestration mode');
    if(lastUser.includes('READ-ONLY QUESTION')){
     assert.equal(parentCalls,1,'the question is the first coordinator turn');
     send({content:'NO-TOOL-ANSWER'});return;
    }
    if(lastUser.includes('SHORT DIRECT TASK')){
     if(!lastTool){tool('route_task',{route:'direct',task:'add one short note to the fixture',reason:'short one-step change'});return;}
     if(lastTool.name==='route_task'){assert(lastResult.ok&&lastResult.route==='direct'&&lastResult.started_child===false,'direct route recorded, nothing started: '+JSON.stringify(lastResult));tool('write',{path:out+'/direct-note.txt',content:'short direct note\n'});return;}
     assert.equal(lastTool.name,'write',JSON.stringify(lastResult));assert(lastResult.applied||lastResult.ok,'short direct write applied: '+JSON.stringify(lastResult));send({content:'SHORT-DIRECT-ANSWER'});return;
    }
    assert.equal(lastUser,'go','raw continuation preserved');
    assert(body.messages.some(message=>message.role==='user'&&message.content.includes('PRIVATE CONTEXT TASK:')),'coordinator sees original task context');
    if(!lastTool){tool('write',{path:out+'/coordinator-blocked.txt',content:'should not be written\n'});return;}
    if(lastTool.name==='write'&&lastResult.error==='orchestration_route_required'){
     assert(lastResult.effect==='none','pre-route refusal carries no effect');
     assert(!fs.existsSync(out+'/coordinator-blocked.txt'),'pre-route refusal wrote nothing');
     tool('route_task',{route:'delegate',task:'implement task.txt, verify, commit and integrate',reason:'concrete multi-step implementation'});return;
    }
    if(lastTool.name==='route_task'){
     assert(lastResult.ok&&lastResult.route==='delegate','delegate route recorded: '+JSON.stringify(lastResult));
     tool('write',{path:out+'/coordinator-blocked.txt',content:'still not written\n'});return;
    }
    if(lastTool.name==='write'&&lastResult.error==='orchestration_delegate_required'){
     assert(lastResult.handoff&&lastResult.handoff.tool==='subagent','delegate refusal names the handoff');
     assert(!fs.existsSync(out+'/coordinator-blocked.txt'),'delegate route still wrote nothing');
     tool('subagent',{action:'start',profile:'orchestration-worker',prompt:'PRIVATE RESOLVED TASK: implement task.txt, verify it, commit, integrate, report.',context:'This resolves the prior PRIVATE CONTEXT TASK, not the word go.',idempotency_key:'coordinator-decision-first'});return;
    }
    if(lastTool.name==='subagent'){
     assert(lastResult.subagent_id&&!lastResult.error,JSON.stringify(lastResult));
     tool('write',{path:out+'/coordinator-after-admission.txt',content:'coordinator follow-up after admission\n'});return;
    }
    assert.equal(lastTool.name,'write',JSON.stringify(lastResult));
    assert(lastResult.applied||lastResult.ok,'admitted child lifts the floor for the coordinator: '+JSON.stringify(lastResult));
    send({content:'COORDINATOR-READY-REPORT'});return;
   }
   childCalls++;
   if(parentCalls===0){send({content:'BASELINE-PREMATURE-DELEGATION'});return;}
   const childNames=(body.tools||[]).map(item=>item.function&&item.function.name);
   assert(!childNames.includes('subagent')&&!childNames.includes('route_task'),'a child has neither mode tool');
   assert(body.messages.some(message=>message.role==='user'&&message.content.includes('PRIVATE RESOLVED TASK:')),'child receives bounded resolved task, not bare go');
   if(!lastTool){const write=()=>tool('write',{path:'task.txt',content:'worker task verified\n'});if(released)write();else held=write;}
   else if(lastTool.name==='write'){const db=new DatabaseSync(home+'/memory.db',{readOnly:true});const sid=db.prepare("SELECT id FROM sessions WHERE objective='subagent' ORDER BY started_at DESC LIMIT 1").get().id;db.close();tool('bash',{command:"git add task.txt && git commit -m 'private task' -m 'Agent: wasm-agent role=child session="+sid+"' && test -f task.txt"});}
   else if(lastTool.name==='bash')tool('integrate',{});
   else if(lastTool.name==='integrate'){const result=JSON.parse(body.messages.filter(message=>message.role==='tool').at(-1).content);assert(result.ok,JSON.stringify(result));send({content:'WORKER-MERGED-REPORT'});}
   else throw Error('unexpected child tool '+lastTool.name);
  }catch(error){if(!res.headersSent)res.writeHead(500);res.end(String(error));}});
 });
 provider.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});await new Promise(r=>provider.listen(0,'127.0.0.1',r));const port=provider.address().port;
 const log=fs.openSync(out+'/node.log','a');
 child=spawn(binary,['--db',home+'/memory.db'],{cwd:repo,env:isolatedEnvironment(home,{WASM_AGENT_LUA_ROOT:embedded?'':repo,WASM_AGENT_ALLOW_DEV_HOME:'1',WASM_AGENT_CODEMODE:'off',WASM_AGENT_COMPLETION_WAKE:'0',WASM_AGENT_ENVELOPE_MODE:'full',WASM_AGENT_PROVIDER:'opencode-go',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+port,WASM_AGENT_LLM_API_KEY:'private-mock-only',WA_GRAPH_WATCH:'0',WA_SCRIPT:repo+'/scripts/test-orchestration-routing.lua',WA_ROUTING_SOURCE:main,WA_ROUTING_OUT:out,WA_ROUTING_RELEASE:'http://127.0.0.1:'+port+'/release'}),stdio:['ignore',log,log],windowsHide:true});
 const code=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill();reject(Error('fixture deadline'));},180000);child.once('error',reject);child.on('exit',c=>{clearTimeout(timer);resolve(c);});});fs.closeSync(log);
 const text=fs.readFileSync(out+'/node.log','utf8');assert.equal(code,0,text);const proof=JSON.parse(text.trim().split(/\r?\n/).findLast(line=>line.startsWith('{')));assert(proof.ok);
 assert.equal(parentCalls,10);assert.equal(childCalls,4);assert.equal(calls,14);
 assert.equal(fs.readFileSync(out+'/direct-note.txt','utf8'),'short direct note\n');
 assert(!fs.existsSync(out+'/coordinator-blocked.txt'),'a refused coordinator write never reached the tree');
 assert.equal(fs.readFileSync(out+'/coordinator-after-admission.txt','utf8'),'coordinator follow-up after admission\n');
 assert.equal(git(main,'status','--porcelain'),'');assert.equal(git(main,'rev-parse','HEAD'),proof.landed);assert.equal(git(main,'ls-remote','origin','refs/heads/main').split(/\s+/)[0],proof.landed);assert.equal(fs.readFileSync(main+'/task.txt','utf8'),'worker task verified\n');
 const receipt={ok:true,checks:proof.checks+12,skipped:0,calls,parentCalls,childCalls,embedded,evidence:out,real_provider_calls:0};fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
}finally{if(child&&child.exitCode===null)child.kill();for(const s of sockets)s.destroy();if(provider)await new Promise(r=>provider.close(r));}})().catch(error=>{console.error(error);process.exitCode=1;});
