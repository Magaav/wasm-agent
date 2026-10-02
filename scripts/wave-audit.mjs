#!/usr/bin/env node
// Read-only recovery evidence. Full historical operation scan happens once per
// explicit audit, never once per workspace release. No age-based retirement.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
const [repo,data,output]=process.argv.slice(2).map(x=>path.resolve(x));
if (!repo || !data || !output) throw new Error('usage: wave-audit REPO DATA NEW-REPORT');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const run=(argv,cwd=repo)=>{const r=spawnSync(argv[0],argv.slice(1),{cwd,encoding:'utf8',timeout:30000,maxBuffer:16*1024*1024,windowsHide:true});return {code:r.status,stdout:r.stdout?.trim(),error:r.stderr?.trim() || r.error?.message};};
const git=(...args)=>run(['git','-C',repo,...args]);
const report={schema_version:1,observed_at:new Date().toISOString(),repo,data,read_only:true,errors:[]};
const main=git('rev-parse','origin/main');report.main=main.stdout;
report.remote=git('ls-remote','--heads','origin');report.local=git('for-each-ref','--format=%(objectname) %(refname)','refs/heads/');
const listing=git('worktree','list','--porcelain','-z');
report.worktrees=listing.stdout?.split('\0\0').filter(Boolean).map(row=>{
  const fields=Object.fromEntries(row.split('\0').filter(Boolean).map(line=>{const space=line.indexOf(' ');return space<0?[line,true]:[line.slice(0,space),line.slice(space+1)];}));
  const status=run(['git','-C',fields.worktree,'status','--porcelain','--untracked-files=all','--ignored']);
  const integrated=git('merge-base','--is-ancestor',fields.HEAD,report.main);
  return {...fields,status,integrated:integrated.code===0,retirement:status.code!==0?'unverifiable':status.stdout?'preserve-dirty-or-ignored':integrated.code!==0?'preserve-unmerged':'candidate-only-pending-positive-owner-quiescence-and-registry-reconciliation'};
}) || [];
const opRoot=path.join(data,'operations');
report.operations={total:0,current_unresolved:0,missing_cwd:0,unreadable:[],original_records:0,unsafe_manual_settlements:[],unresolved:[]};
const facts=state=>Object.fromEntries(['operation_id','owner','owner_boot','owner_process_id','cwd','effective_cwd','state','settled','cleanup','containment','process_exit_code','elapsed_ms','output_bytes'].filter(k=>state[k]!==undefined).map(k=>[k,state[k]]));
const unresolved=state=>state.settled!==true || state.cleanup==='unknown';
for(const entry of fs.readdirSync(opRoot,{withFileTypes:true})) {
  if(!entry.isDirectory())continue;
  report.operations.total++;
  const dir=path.join(opRoot,entry.name);
  try {
    const raw=fs.readFileSync(path.join(dir,'state.json')),state=JSON.parse(raw);
    if(!state.cwd)report.operations.missing_cwd++;
    if(unresolved(state)){report.operations.current_unresolved++;report.operations.unresolved.push({id:entry.name,...facts(state),state_sha256:hash(raw),decision:'preserve: stable process identity, containment drain and external effect reconciliation required'});}
    for(const name of fs.readdirSync(dir)) {
      if(!name.startsWith('state.json.before-reconcile-'))continue;
      report.operations.original_records++;
      const original=fs.readFileSync(path.join(dir,name)),old=JSON.parse(original);
      if(unresolved(old) && !unresolved(state)) report.operations.unsafe_manual_settlements.push({id:entry.name,original_path:path.join(dir,name),original_sha256:hash(original),current_sha256:hash(raw),original:facts(old),current:facts(state),decision:'preserve original uncertainty: elapsed time/output/mtime are not process or effect proof'});
    }
  }catch(e){report.operations.unreadable.push({id:entry.name,error:e.message});}
}
for(const [name,file,query] of [
  ['claims',path.join(data,'resources','claims.sqlite'),'SELECT key,principal,session,run,boot,uncertain FROM claims ORDER BY key'],
  ['bindings',path.join(data,'memory.db'),"SELECT id,user_id,worktree,workspace_required,workspace_state,workspace_branch,workspace_base_commit,workspace_error FROM sessions WHERE worktree!='' OR workspace_required=1 ORDER BY id"]
]) {
  let db;try{db=new DatabaseSync(file,{readOnly:true});report[name]={path:file,rows:db.prepare(query).all(),liveness:'not inferred from timestamps or PID absence'};}catch(e){report.errors.push({scope:name,error:e.message});}finally{db?.close();}
}
// OPTIONAL VIEWER ONLY. A read-only audit must not depend on a third-party CLI: if one is present
// and explicitly asked for (`WA_WAVE_ORCA_VIEW=1`), what it says is recorded as advisory evidence.
// Its absence is a fact about the audit, never an error and never a decision input.
if(process.env.WA_WAVE_ORCA_VIEW==='1') {
  const orca=run(['orca','worktree','list','--json']);
  try{const value=JSON.parse(orca.stdout);report.orca={advisory:true,decision_input:false,code:orca.code,worktrees:value.result?.worktrees?.map(({id,path:p,branch,workspaceStatus,git,instanceId})=>({id,path:p,branch,workspaceStatus,git,instanceId})),complete:value.result?.truncated===false};}catch(e){report.orca={advisory:true,decision_input:false,used:false,reason:e.message};}
} else report.orca={advisory:true,decision_input:false,used:false,reason:'not_requested: this audit reads the node runtime and Git only'};
try{const response=await fetch('http://127.0.0.1:8799/health',{signal:AbortSignal.timeout(5000)});report.health={status:response.status,body:await response.json()};}catch(e){report.health={error:e.message};}
report.summary={worktrees:report.worktrees.length,integrated_clean_candidates:report.worktrees.filter(x=>x.retirement.startsWith('candidate')).length,dirty_or_ignored:report.worktrees.filter(x=>x.retirement==='preserve-dirty-or-ignored').length,unmerged:report.worktrees.filter(x=>!x.integrated).length,operations:report.operations.total,unresolved:report.operations.current_unresolved,manual_original_uncertainty:report.operations.unsafe_manual_settlements.length,claims:report.claims?.rows.length,bindings:report.bindings?.rows.length};
// Never overwrite a diagnostic/report that may be evidence for another run.
fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({ok:true,report_path:output,...report.summary}));
