#!/usr/bin/env node
// Concrete fresh observation adapters for wave-lifecycle. Storage/transport
// errors and incomplete inventories are refusals, never empty successful sets.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {listRecords} from './lib/delivery-store.mjs';
const [kind,file]=process.argv.slice(2);
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
const key=value=>{const p=String(value || '').replaceAll('\\','/').replace(/^\/\/\?\//,'').replace(/\/$/,'');return process.platform==='win32'?p.toLowerCase():p;};
function fail(message){throw new Error(message);}
function run(argv,cwd) {
  if(!Array.isArray(argv)||!argv.length)fail('proof_command_required');
  const r=spawnSync(argv[0],argv.slice(1),{cwd,encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:16*1024*1024});
  if(r.status!==0)fail(r.error?.message || r.stderr || `exit_${r.status}`);return r.stdout.trim();
}
function rows(file,sql) {const db=new DatabaseSync(file,{readOnly:true});try{return db.prepare(sql).all();}finally{db.close();}}
try {
  const config=JSON.parse(fs.readFileSync(file,'utf8'));
  const main=process.env.WA_WAVE_MAIN || run(['git','-C',config.repo,'rev-parse','refs/heads/main'],config.repo),wave_id=process.env.WA_WAVE_ID;
  if(!wave_id)fail('wave_identity_required');
  const target=process.env.WA_WAVE_TARGET;
  let unresolved=[],evidence={};
  if(kind==='operations') {
    const db=new DatabaseSync(path.join(config.data,'operations/index.sqlite'),{readOnly:true});
    try {
      if(!db.prepare("SELECT value FROM meta WHERE key='complete'").get())fail('operation_index_import_required');
      const pending=db.prepare('SELECT id,cwd,state,originals FROM operations o WHERE blocked=1 AND NOT EXISTS(SELECT 1 FROM reconciliation r WHERE r.id=o.id AND r.expected=o.state) ORDER BY id').all();
      unresolved=pending.filter(row=>!target || !row.cwd || key(row.cwd)===key(target) || key(row.cwd).startsWith(key(target)+'/')).map(row=>({id:row.id,cwd:row.cwd,owner:JSON.parse(row.state).owner,originals_sha256:hash(row.originals)}));
      evidence={lookup:'indexed-unresolved',target:target || 'all',total_pending:pending.length};
    }finally{db.close();}
  } else if(kind==='claims') {
    const claims=rows(path.join(config.data,'resources/claims.sqlite'),'SELECT key,principal,session,run,boot,uncertain FROM claims ORDER BY key');
    if(target) {
      const sessions=rows(path.join(config.data,'memory.db'),"SELECT id,worktree FROM sessions WHERE worktree!=''").filter(row=>key(row.worktree)===key(target));
      const ids=new Set(sessions.map(row=>row.id));unresolved=claims.filter(row=>ids.has(row.session) || sessions.some(s=>row.key===`session:${s.id}`));
    }else unresolved=claims;
    evidence={observed_claims:claims.length,note:'Lease/PID age never reconciles a claim; use the resource API with inspected effects.'};
  } else if(kind==='owners') {
    if(!Array.isArray(config.orchestration_run_ids) || !config.orchestration_run_ids.length)fail('complete_owner_inventory_required');
    const inventories=config.orchestration_run_ids.map(run_id=>JSON.parse(run([config.orca || 'orca','orchestration','worker-list','--run',run_id,'--include-remote','--json'],config.repo)));
    const workers=[];
    for(const inventory of inventories) {
      if(inventory.ok!==true || inventory.result?.page?.hasMore!==false || !Array.isArray(inventory.result?.workers))fail('owner_inventory_incomplete');
      workers.push(...inventory.result.workers);
    }
    unresolved=workers.filter(row=>row.dispatchStatus!=='completed' || !['succeeded','failed'].includes(row.workerState) || !['released','retained'].includes(row.terminalState) || row.projection?.stage?.activity==='working').map(row=>({dispatch:row.dispatchId,terminal:row.agentTerminalHandle,reason:'owner_unsettled_or_cleanup_decision_missing'}));
    evidence={runs:config.orchestration_run_ids,workers:workers.length,note:'Retained idle terminals may be parked only after their current accepted settlement.'};
  } else if(kind==='deliveries') {
    if(!config.delivery_store || !fs.existsSync(config.delivery_store))fail('delivery_store_missing');
    const records=listRecords(config.delivery_store);
    for(const record of records) {
      const ancestry=record.landing?.sha && spawnSync('git',['-C',config.repo,'merge-base','--is-ancestor',record.landing.sha,main],{windowsHide:true}).status===0;
      if(!ancestry || record.review?.reviewer===record.producer || !record.review?.reviewer || record.review?.verdict!=='passed')unresolved.push({delivery:record.delivery,tip:record.tip,reason:'unlanded_or_independent_review_unverified'});
    }
    evidence={records:records.length};
  } else if(kind==='registries') {
    const listing=run(['git','-C',config.repo,'worktree','list','--porcelain','-z'],config.repo);
    const trees=listing.split('\0\0').filter(Boolean).map(row=>Object.fromEntries(row.split('\0').filter(Boolean).map(line=>{const space=line.indexOf(' ');return space<0?[line,true]:[line.slice(0,space),line.slice(space+1)];})));
    const byPath=new Map(trees.map(tree=>[key(tree.worktree),tree]));
    const sessions=rows(path.join(config.data,'memory.db'),"SELECT id,worktree,workspace_required,workspace_state,workspace_branch,workspace_start_state FROM sessions WHERE workspace_required=1 OR worktree!=''");
    for(const session of sessions) {
      if(session.workspace_state==='released')continue;
      const tree=byPath.get(key(session.worktree));
      if(session.workspace_state==='parked') {
        const parked=JSON.parse(session.workspace_start_state || '{}').park_reconciliation;
        if(!tree?.detached || !parked?.evidence || tree.HEAD!==parked.head || session.workspace_branch)unresolved.push({session:session.id,reason:'parked_binding_mismatch'});
      } else if(session.workspace_required || key(session.worktree)!==key(config.repo))unresolved.push({session:session.id,reason:'finished_workspace_binding_not_released_or_parked'});
    }
    const orca=JSON.parse(run([config.orca || 'orca','worktree','list','--repo',`id:${config.orca_repo_id}`,'--json'],config.repo));
    if(orca.ok!==true || orca.result?.truncated!==false || !Array.isArray(orca.result?.worktrees))fail('orca_registry_incomplete');
    for(const card of orca.result.worktrees) {
      const tree=byPath.get(key(card.path));
      if(!tree || key(card.git?.path)!==key(card.path) || (card.branch || '')!==(tree.branch || '') || (card.git?.branch || '')!==(tree.branch || '') || card.head!==tree.HEAD)unresolved.push({card:card.id,reason:'orca_git_branch_or_path_mismatch'});
    }
    evidence={git_worktrees:trees.length,runtime_bindings:sessions.length,orca_cards:orca.result.worktrees.length};
  } else if(kind==='runtime') {
    const raw=fs.readFileSync(path.join(config.install,'installed.txt'),'utf8');
    const installed=Object.fromEntries(raw.split(/\r?\n/).filter(Boolean).map(line=>{const equal=line.indexOf('=');return [line.slice(0,equal),line.slice(equal+1)];}));
    if(!/^[0-9a-f]{7,64}$/.test(installed.commit || ''))fail('installed_source_identity_unverified');
    const installedCommit=run(['git','-C',config.repo,'rev-parse',`${installed.commit}^{commit}`],config.repo);
    if(installedCommit!==main || installed.dirty!=='false' && installed.dirty!=='0' || installed.source_provenance!=='clean-built-by-deploy')fail('installed_source_not_exact_clean_accepted_main');
    const binary=path.join(config.install,process.platform==='win32'?'wa.exe':'wa');
    if(hash(fs.readFileSync(binary))!==installed.sha256)fail('installed_artifact_hash_mismatch');
    const install=JSON.parse(run(config.verify_install_argv,config.repo));
    if(install.ok!==true || install.failed!==0 || install.skipped!==0)fail('verify_install_failed_or_skipped');
    const functional=JSON.parse(fs.readFileSync(config.functional_receipt,'utf8'));
    if(functional.ok!==true || functional.main!==main || functional.scope!=='two-window-recovery' || !Number.isSafeInteger(functional.checks) || functional.checks<1 || hash(fs.readFileSync(functional.log))!==functional.log_sha256)fail('functional_recovery_evidence_missing_or_wrong_source');
    const response=await fetch(config.health_url || 'http://127.0.0.1:8799/health',{signal:AbortSignal.timeout(5000)});
    const health=await response.json();if(!response.ok || health.ok!==true || health.ui_error || health.operation_overdue)fail('runtime_health_or_recovery_unverified');
    evidence={installed_commit:installedCommit,artifact_sha256:installed.sha256,install,health,functional};
  } else fail('unknown_wave_proof');
  console.log(JSON.stringify({ok:unresolved.length===0,complete:true,main,wave_id,unresolved,evidence}));
  if(unresolved.length)process.exitCode=1;
}catch(e){console.log(JSON.stringify({ok:false,complete:false,reason:e.message}));process.exitCode=1;}
