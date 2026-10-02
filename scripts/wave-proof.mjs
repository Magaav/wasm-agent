#!/usr/bin/env node
// Concrete fresh observation adapters for wave-lifecycle. Storage/transport
// errors and incomplete inventories are refusals, never empty successful sets.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {listRecords} from './lib/delivery-store.mjs';
import {verifyDelivered} from './lib/wave-delivery.mjs';
import {frozenOwners,ownerInventory} from './lib/wave-owners.mjs';
import {activityInventory,sourceOfConfig,orcaView} from './lib/wave-activity.mjs';
import {operationSafety} from './wave-adapter.mjs';
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
    const safety=operationSafety(config,target);unresolved=safety.unresolved;evidence=safety;
  } else if(kind==='claims') {
    const claims=rows(path.join(config.data,'resources/claims.sqlite'),'SELECT key,principal,session,run,boot,uncertain FROM claims ORDER BY key');
    if(target) {
      const sessions=rows(path.join(config.data,'memory.db'),"SELECT id,worktree FROM sessions WHERE worktree!=''").filter(row=>key(row.worktree)===key(target));
      const ids=new Set(sessions.map(row=>row.id));unresolved=claims.filter(row=>ids.has(row.session) || sessions.some(s=>row.key===`session:${s.id}`));
    }else unresolved=claims;
    evidence={observed_claims:claims.length,note:'Lease/PID age never reconciles a claim; use the resource API with inspected effects.'};
  } else if(kind==='owners') {
    const owners=process.env.WA_WAVE_ADMISSION==='1'?ownerInventory(config):frozenOwners(config,wave_id,main);
    // COMPLETION FOLDS IN THE LEFTOVERS. An allocated managed binding is work a retirement plan
    // may still be settling, so the freeze fence reports it separately - but a wave cannot be
    // complete while this repository still holds an unreconciled managed workspace.
    unresolved=[...owners.unresolved,...(owners.leftovers||[])];evidence=owners;
  } else if(kind==='deliveries') {
    if(!config.delivery_store || !fs.existsSync(config.delivery_store))fail('delivery_store_missing');
    const records=listRecords(config.delivery_store);
    for(const record of records) {
      const verified=verifyDelivered(config.repo,record,main);
      if(!verified.ok)unresolved.push({delivery:record.delivery,tip:record.tip,reason:verified.reason});
    }
    evidence={records:records.length};
  } else if(kind==='registries') {
    // OUR OWN REGISTRY. The repository's real Git worktree list, the node's own session
    // bindings, and the agreement between them. No third party is consulted: an `orca`
    // binary is at most an optional viewer, and its absence changes no verdict.
    const source=sourceOfConfig(config);
    const inventory=activityInventory(source);
    if(!inventory.ok)fail('own_registry_inventory_unavailable:'+inventory.reason);
    const trees=inventory.trees,bindings=inventory.bindings;
    const byPath=new Map(trees.map(tree=>[key(tree.path),tree]));
    for(const binding of bindings) {
      if(binding.state==='released') {
        if(binding.registered || fs.existsSync(binding.worktree))unresolved.push({session:binding.session,reason:'released_binding_tree_present',worktree:binding.worktree});
        continue;
      }
      const tree=byPath.get(key(binding.worktree));
      if(!tree)unresolved.push({session:binding.session,reason:'binding_tree_not_registered',worktree:binding.worktree,state:binding.state});
      else {
        if(binding.state==='parked') {
          if(!tree.detached || tree.branch || binding.branch || binding.recorded_branch)unresolved.push({session:binding.session,reason:'parked_binding_not_a_detached_exact_tip',worktree:binding.worktree});
        } else if((tree.branch||'')!==(binding.recorded_branch||'')) {
          unresolved.push({session:binding.session,reason:'binding_branch_disagrees_with_git',worktree:binding.worktree,tree_branch:tree.branch,recorded:binding.recorded_branch});
        }
      }
    }
    for(const tree of trees) {
      if(key(tree.path)===key(config.repo))continue;
      if(bindings.some(binding=>key(binding.worktree)===key(tree.path)))continue;
      unresolved.push({worktree:tree.path,reason:'unowned_worktree_registration',head:tree.head,branch:tree.branch});
    }
    for(const item of inventory.unresolved)if(!unresolved.some(x=>x.reason===item.reason&&key(x.worktree||'')===key(item.worktree||'')&&x.session===item.session))unresolved.push(item);
    for(const item of inventory.leftovers)if(!unresolved.some(x=>x.reason===item.reason&&key(x.worktree||'')===key(item.worktree||'')&&x.session===item.session))unresolved.push(item);
    evidence={git_worktrees:trees.length,runtime_bindings:bindings.length,managed_bindings:inventory.held.length,canonical:config.repo,third_party:'none',orca_view:orcaView(source,{enabled:config.orca_view===true})};
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
