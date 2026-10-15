#!/usr/bin/env node
// Non-UI hidden grader/preflight. Runtime binary is separate from task checkout.
// Solvers must never mount this script, hidden oracle, repair, logs or Git history.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import crypto from 'node:crypto';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
import {createGeneration,record,disposable,assertDisposable,containedProcess,seal,cleanup,verifyBundle} from './agent-benchmark-results.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function cmd(exe,args,cwd=repo) {const r=spawnSync(exe,args,{cwd,encoding:'utf8',timeout:120000,maxBuffer:32*1024*1024});if(r.error || r.status!==0)throw Error(`${exe} failed: ${r.error?.message || r.stderr}`);return r.stdout;}
const baseline='dc11c4626358438514624afa05c20bacb68cdbe7',repair='7324ef7493fc4c442d9e0eba6f5000931af17c83';
export function snapshot(ref,destination,{generationRoot=null}={}) {
  if(fs.existsSync(destination)) {
    if(!generationRoot || fs.readdirSync(destination).join(',')!=='.benchmark-owned.json')throw Error('fresh owned snapshot only');assertDisposable(generationRoot,destination);
  } else fs.mkdirSync(destination,{recursive:true});
  const archive=destination+'.tar';cmd('git',['archive','--format=tar','--output='+archive,ref]);cmd('tar',['-xf',path.basename(archive),'-C',path.basename(destination)],path.dirname(destination));fs.unlinkSync(archive);
}
export function exportBinding(destination) {
  if(fs.existsSync(destination))throw Error('fresh solver export only');fs.mkdirSync(destination,{recursive:true});
  const task=path.join(destination,'work');snapshot(baseline,task);
  const context=path.join(destination,'context');fs.mkdirSync(context);
  for(const name of ['input.json','native-declarations.json','native-bootstrap.json','envelope.html'])fs.copyFileSync(path.join(repo,'fixtures/benchmarks/binding-discovery/v1/solver',name),path.join(context,name));
  const artifacts=path.join(destination,'artifacts');fs.mkdirSync(artifacts);fs.copyFileSync(path.join(context,'envelope.html'),path.join(artifacts,'envelope.html'));
  // No .git, remotes, oracle or repair are copied. Instructions are byte-identical.
  for(const name of ['AGENTS.md','AGENTS.guest.md','AGENTS.subagents.md','AGENTS.orchestrator.md','AGENTS.windows.md']) {
    const expected=cmd('git',['show',baseline+':'+name]);if(fs.readFileSync(path.join(task,name),'utf8')!==expected)throw Error('instruction export drift');
  }
  return {taskSource:baseline,runtimeSource:null,taskRoot:task,solverInput:path.join(context,'input.json'),instructionsUntrimmed:true};
}
export function captureDeclarations(binary,taskRoot,evidence) {
  if(fs.existsSync(evidence))throw Error('fresh declarations evidence only');fs.mkdirSync(evidence,{recursive:true});const script=path.join(evidence,'declarations.lua');
  fs.writeFileSync(script,"local j=dofile('lua/vendor/json.lua');print(j.encode(dofile('lua/core/tools.lua').all('master')))\n");
  const env=isolatedEnvironment(evidence);
  const r=spawnSync(binary,['--db',path.join(evidence,'declarations.db')],{cwd:taskRoot,env:{...env,WASM_AGENT_HOME:evidence,WASM_AGENT_LUA_ROOT:taskRoot,WA_SCRIPT:script,WASM_AGENT_MANAGED:'0',WA_GRAPH_WATCH:'0'},encoding:'utf8',timeout:120000,maxBuffer:8388608});
  if(r.status!==0)throw Error('declarations capture failed: '+r.stderr);const definitions=JSON.parse(r.stdout.trim());
  fs.writeFileSync(path.join(evidence,'declarations.json'),r.stdout.trim()+'\n');return definitions;
}
export function prepareGradeOracle(taskRoot,evidence,oracleFile=path.join(repo,'scripts/test-binding-discovery.lua')) {
  if(fs.existsSync(evidence))throw Error('fresh grader evidence only');fs.mkdirSync(evidence,{recursive:true});
  // Hide grader implementation outside taskRoot. The oracle mocks all client/http effects.
  const oracle=path.join(evidence,'hidden-oracle.lua');
  const declarations=JSON.parse(fs.readFileSync(path.join(repo,'fixtures/benchmarks/binding-discovery/v1/solver/native-declarations.json'),'utf8'));
  const expected=Object.fromEntries(declarations.map(x=>[x.function.name,x.function.parameters]));
  const original=fs.readFileSync(oracleFile,'utf8').replace("if phase=='restart' then", "if phase=='restart' then\n local persisted,err=envelope.resolve(tools.all('master'),'read',ctx);check(persisted and not err,'unblocked read definition survives actual native restart')");
  const effectFence="for _,name in ipairs({'client','exec','operation','http','http_stream','remote','shell'})do host[name]=function()error('grader prohibits external effects: '..name)end end\n";
  for(const name of ['AGENTS.md','AGENTS.guest.md','AGENTS.subagents.md','AGENTS.orchestrator.md','AGENTS.windows.md'])if(fs.readFileSync(path.join(taskRoot,name),'utf8')!==cmd('git',['show',baseline+':'+name]))throw Error('candidate instruction trimming/drift');
  const finalPrint="print(json.encode({ok=true,phase=phase,checks=checks,planner_refused_calls=refused_calls,planner_client_calls=0,mocked_client_calls=client_calls,provider_calls=0}))";
  if(!original.includes(finalPrint))throw Error('hidden oracle source drift');
  fs.writeFileSync(oracle,effectFence+original.replace(finalPrint,'')+"\nlocal persisted=tools.dispatch(bound,'tool_search',{query='read',limit=1},'master',ctx);check(persisted.loaded==1,'persist unblocked read loadout')\nlocal expected=json.decode("+JSON.stringify(JSON.stringify(expected))+");local seen={};for _,s in ipairs(tools.all('master')) do local f=s['function'];check(expected[f.name] and json.encode(f.parameters)==json.encode(expected[f.name]), 'native parameter schema drift: '..f.name);seen[f.name]=true end;for name in pairs(expected)do check(seen[name], 'native declaration hidden: '..name) end\n"+finalPrint+"\n");
  return oracle;
}
export async function gradeBinding(binary,taskRoot,evidence,oracleFile=path.join(repo,'scripts/test-binding-discovery.lua'),restartLoss=false,generationRoot=null) {
  if (!generationRoot)throw Error('grading requires an owned result generation; use gradeStandalone');
  const oracle=prepareGradeOracle(taskRoot,evidence,oracleFile),clean=isolatedEnvironment(evidence);
  const results=[];
  for(const phase of ['seed','restart']) {
    if(phase==='restart' && restartLoss) {
      // Causal storage-loss control: discard only this private grade DB, never a real session.
      fs.unlinkSync(path.join(evidence,'test.db'));
    }
    const started=performance.now();
    let r;
    const env={...clean,WASM_AGENT_HOME:evidence,WASM_AGENT_LUA_ROOT:taskRoot,WA_SCRIPT:oracle,WA_BINDING_PHASE:phase,WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0'};
    if(generationRoot) {
      const launcher=path.join(evidence,phase+'-launcher.cjs');fs.writeFileSync(launcher,'const cp=require("node:child_process");const r=cp.spawnSync('+JSON.stringify(binary)+','+JSON.stringify(['--db',path.join(evidence,'test.db')])+',{cwd:'+JSON.stringify(taskRoot)+',env:'+JSON.stringify(env)+',stdio:"inherit"});process.exit(r.status===null?1:r.status);');
      const operation=await containedProcess(generationRoot,binary,process.execPath,[launcher],{cwd:taskRoot,luaRoot:repo,timeout_seconds:120});
      r={status:operation.process_exit_code,stdout:fs.readFileSync(operation.stdout_path,'utf8'),stderr:fs.readFileSync(operation.stderr_path,'utf8')};
    } else r=spawnSync(binary,['--db',path.join(evidence,'test.db')],{cwd:taskRoot,env,encoding:'utf8',timeout:120000,maxBuffer:8388608});
    for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(evidence,phase+'.'+stream),r[stream]||'');
    let summary=null;try{summary=JSON.parse(r.stdout.trim());}catch{}
    results.push({phase,exit:r.status,error:r.error?.message || null,elapsed_ms:performance.now()-started,summary});
    if(r.status!==0)break;
  }
  const pass=results.length===2 && results.every(r=>r.exit===0 && r.summary?.ok===true && r.summary.provider_calls===0 && r.summary.planner_client_calls===0);
  const receipt={adapter:'binding-discovery-native-v1',pass,binary_sha256:sha(fs.readFileSync(binary)),oracle_sha256:sha(fs.readFileSync(oracle)),task_tools_sha256:sha(fs.readFileSync(path.join(taskRoot,'lua/core/tools.lua'))),results};
  fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(receipt,null,2));return receipt;
}
function replace(file,oldText,newText) {const s=fs.readFileSync(file,'utf8');if(s.split(oldText).length!==2)throw Error('mutant anchor drift');fs.writeFileSync(file,s.replace(oldText,newText));}
export async function gradeStandalone(binary,taskRoot,out) {
  createGeneration(out,'binding-grade-'+crypto.randomUUID());
  const result=await gradeBinding(binary,taskRoot,path.join(out,'records','grade'),undefined,false,out);
  record(out,'manifest',{id:'binding-grade',task_id:'binding-discovery-v1',binary_sha256:result.binary_sha256});record(out,'task',{id:'binding-discovery-v1',candidate_tools_sha256:result.task_tools_sha256});record(out,'context',{id:'binding-discovery-v1-sanitized'});record(out,'oracle',{id:result.oracle_sha256});record(out,'outputs',result);record(out,'patches',{candidate_owned_by_caller:true,not_deleted:true});record(out,'traces',{native_raw_receipts_retained:true});record(out,'failed_attempts',result.pass?[]:result.results.filter(x=>x.exit!==0));record(out,'receipts',result);record(out,'accounting',{benchmark_solver_inference_calls:0,provider_calls:0,preparation_usage:null});record(out,'cache',{backend_kv_contents:'opaque'});record(out,'quality',{scores:null});
  const bundle=seal(out);const cleaned=cleanup(out);const report={...result,bundle,cleanup:cleaned};fs.writeFileSync(path.join(out,'grade.json'),JSON.stringify(report,null,2));return report;
}
export function bindingControls() {
  const cases=[{name:'broken',ref:baseline,pass:false},{name:'repair',ref:repair,pass:true},
    {name:'blanket-deny',pass:false,edit:(t)=>replace(t,'function M.discovery_execution(memory,ctx)','function M.discovery_execution(memory,ctx)\n  return function() return {status="blocked",available=false} end, {required=true}\nend\nlocal function unused_discovery(memory,ctx)')},
    {name:'discovery-hide',pass:false,edit:(t,e)=>replace(e,'function M.search(catalog,args,ctx,describe_execution)','function M.search(catalog,args,ctx,describe_execution) return {tools={},matches=0,loaded=0,guidance={}} end\nlocal function unused_search(catalog,args,ctx,describe_execution)')},
    {name:'hardcoded-unavailable',pass:false,edit:(t)=>replace(t,"local required=workspace and workspace.required and true or false","local required=true; workspace={required=true,state='allocated',worktree='hardcoded'}")},
    {name:'guard-bypass',pass:false,edit:(t)=>replace(t,'local function required_workspace_error(memory, ctx, name, args)','local function required_workspace_error(memory, ctx, name, args) return nil end\nlocal function unused_guard(memory, ctx, name, args)')},
    {name:'unbound-rejection',pass:false,edit:(t)=>replace(t,'if not required then return result end',"if not required then result.status='blocked';result.available=false;return result end")},
    {name:'profile-bypass',pass:false,edit:(t)=>replace(t,'function M.dispatch(memory, name, args, role, ctx)','function M.dispatch(memory, name, args, role, ctx)\nctx=ctx or {}; ctx.subagent=nil; role="master"')},
    {name:'stale-load-state',pass:false,edit:(t,e)=>replace(e,"local names=raw and json.decode(raw) or {};", "local names=raw and {client=string.rep('0',64)} or {};")},
    {name:'restart-loss',pass:false,restart_loss:true},
    {name:'role-bypass',pass:false,edit:(t)=>replace(t,'function M.dispatch(memory, name, args, role, ctx)','function M.dispatch(memory, name, args, role, ctx)\nrole="master"')},
    {name:'dynamic-scope-hardcode',pass:false,edit:(t)=>replace(t,'if workspace.state~=\'allocated\' or not workspace.worktree or workspace.worktree==\'\' then',"if false then")},
    {name:'schema-drift',pass:false,edit:(t)=>replace(t,"query={type='string',maxLength=256}", "query={type='number',maxLength=256}")}
  ];
  const failureLabels={broken:'discovery reports blocked client', 'blanket-deny':'permitted client has truthful binding refusal','discovery-hide':'discovery reports blocked client','hardcoded-unavailable':'unbound discovery and definition loading unchanged','guard-bypass':'direct native guard remains','unbound-rejection':'unbound discovery and definition loading unchanged','profile-bypass':'capabilities respects exact profile','stale-load-state':'routed blocked tool cannot acquire load authority','restart-loss':'unblocked read definition survives actual native restart','role-bypass':'role-hidden tool has no execution metadata leak','dynamic-scope-hardcode':'missing required binding never advertises writable execution','schema-drift':'native parameter schema drift'};
  return {cases,failureLabels};
}
export async function preflight(binary,out) {
  const invocationStarted=performance.now();let setupMs=0;
  if(fs.existsSync(out))throw Error('fresh preflight generation only');createGeneration(out,'binding-preflight-'+crypto.randomUUID());
  const {cases,failureLabels}=bindingControls();
  const results=[];
  for(const c of cases) {
    const setupStarted=performance.now();
    const task=disposable(out,c.name+'-task');snapshot(c.ref || repair,task,{generationRoot:out});
    if(c.edit)c.edit(path.join(task,'lua/core/tools.lua'),path.join(task,'lua/core/envelope.lua'));
    setupMs+=performance.now()-setupStarted;
    const gradeDir=path.join(out,'records',c.name+'-grade');
    const r=await gradeBinding(binary,task,gradeDir,undefined,c.restart_loss,out);
    for(const name of ['tools.lua','envelope.lua'])fs.copyFileSync(path.join(task,'lua/core',name),path.join(gradeDir,'candidate-'+name));
    if(r.pass!==c.pass)throw Error('behavioral control disagreement: '+c.name);
    if(!c.pass && !r.results.some(phase=>fs.readFileSync(path.join(gradeDir,phase.phase+'.stderr'),'utf8').includes(failureLabels[c.name])))throw Error('negative control failed for an unrelated reason: '+c.name);
    results.push({name:c.name,expected_pass:c.pass,...r});
  }
  const preflight={ok:true,benchmark_solver_inference_calls:0,provider_calls:0,real_client_calls:0,baseline,repair,results};
  record(out,'manifest',{id:'binding-discovery-preflight',task_source:baseline,runtime_binary_sha256:sha(fs.readFileSync(binary)),adapter_source_sha256:sha(fs.readFileSync(fileURLToPath(import.meta.url)))});
  record(out,'task',{id:'binding-discovery-v1',source:baseline});record(out,'context',{id:'binding-discovery-v1-sanitized',input_sha256:sha(fs.readFileSync(path.join(repo,'fixtures/benchmarks/binding-discovery/v1/solver/input.json')))});
  record(out,'oracle',{id:results[0].oracle_sha256,results});record(out,'outputs',preflight);record(out,'patches',{control_mutations:cases.map(c=>c.name),candidate_modules_retained:true});record(out,'traces',{raw_directories:results.map(c=>c.name+'-grade'),native_tree_receipts_retained:true});record(out,'failed_attempts',results.filter(r=>!r.pass));record(out,'receipts',{behavioral_controls:results.length});record(out,'accounting',{benchmark_solver_inference_calls:0,real_provider_calls:0,preparation_assistant_usage:null});record(out,'cache',{backend_kv_contents:'opaque',measured_provider_cache:null});record(out,'quality',{scores:null});
  const sealStarted=performance.now();const bundle=seal(out);verifyBundle(out);const sealMs=performance.now()-sealStarted;
  const cleanupStarted=performance.now();const cleanupReceipt=cleanup(out);const cleanupMs=performance.now()-cleanupStarted;
  const summary={...preflight,bundle,cleanup:cleanupReceipt,timings_ms:{adapter_invocation:performance.now()-invocationStarted,snapshot_setup:setupMs,oracle_process:results.flatMap(r=>r.results).reduce((n,r)=>n+r.elapsed_ms,0),seal:sealMs,cleanup:cleanupMs,build:null,index:null,model:null,tool:null,sandbox_startup:null},timing_scope:'model-free adapter invocation; not complete preparation-worker wall time'};fs.writeFileSync(path.join(out,'preflight.json'),JSON.stringify(summary,null,2));return summary;
}
if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const [action,binary,root,out]=process.argv.slice(2);
  if(action==='--export')console.log(JSON.stringify(exportBinding(path.resolve(binary))));
  else if(action==='--preflight')console.log(JSON.stringify(await preflight(path.resolve(binary),path.resolve(root))));
  else if(action==='--grade')console.log(JSON.stringify(await gradeStandalone(path.resolve(binary),path.resolve(root),path.resolve(out))));
  else throw Error('usage: --preflight <binary> <fresh-evidence> | --grade <binary> <candidate-source> <fresh-evidence>');
}
