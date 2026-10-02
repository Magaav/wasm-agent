#!/usr/bin/env node
// Concrete retirement procedures. These inspect real APIs/records; unavailable
// actors, hosting inventory or source provenance are refusals, never empty sets.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {ownerInventory,frozenOwners} from './lib/wave-owners.mjs';
import {activityInventory,sourceOfConfig,orcaView} from './lib/wave-activity.mjs';
import {location} from './wave-entry.mjs';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const key=x=>{const p=path.resolve(x).replaceAll('\\','/').replace(/^\/\/\?\//,'');return process.platform==='win32'?p.toLowerCase():p;};
function command(argv,cwd,env={}){const r=spawnSync(argv[0],argv.slice(1),{cwd,env:{...process.env,...env},encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:32*1024*1024});if(r.status!==0)throw Error(r.stderr || r.error?.message || 'adapter_command_failed');return r.stdout.trim();}
const git=(repo,...args)=>command(['git','-C',repo,...args],repo);
function ledger(config,sql,params=[]){const db=new DatabaseSync(path.join(config.data,'memory.db'),{readOnly:true});try{return db.prepare(sql).all(...params);}finally{db.close();}}
export function native(config,request) {
  if(!config.wa_binary || !config.source_root || !config.home || key(path.join(config.home,'.wasm-agent'))!==key(config.data))throw Error('native_runtime_home_and_source_binding_required');
  const env={WASM_AGENT_HOME:config.home,WASM_AGENT_LUA_ROOT:config.source_root,WA_SCRIPT:path.join(config.source_root,'scripts/wave-observe.lua'),WA_WAVE_OBSERVATION:JSON.stringify(request),WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'};
  if(request.kind==='legacy')env.WA_LEGACY_EXTERNAL_EXECUTOR='1';
  return JSON.parse(command([config.wa_binary,'--db',path.join(config.data,'memory.db')],config.source_root,env));
}
export function operationSafety(config,target=null){
  if(!fs.existsSync(path.join(config.data,'operations/index.sqlite')))throw Error('operation_index_missing');
  const unresolved=[];let after='';let quarantined=0;
  for(let page=0;page<100;page++) {
    const value=native(config,{kind:'operations',cwd:target || '*',after});
    if(value.ok!==true || !Array.isArray(value.operations))throw Error(value.error || 'operation_inventory_unverifiable');
    unresolved.push(...value.operations);quarantined+=value.quarantined_unknown_outcomes || 0;
    if(!value.next)return {ok:!unresolved.length,complete:true,unresolved,quarantined_unknown_outcomes:quarantined};
    if(value.next===after)throw Error('operation_cursor_did_not_advance');after=value.next;
  }throw Error('operation_discovery_budget_exhausted');
}
export function combinedSafety(config,target){
  const operations=operationSafety(config,target);
  const db=new DatabaseSync(path.join(config.data,'resources/claims.sqlite'),{readOnly:true});let claims;
  try{claims=db.prepare('SELECT * FROM claims').all();}finally{db.close();}
  if(target){const ids=new Set(ledger(config,"SELECT id,worktree FROM sessions WHERE worktree!=''").filter(s=>key(s.worktree)===key(target)).map(s=>s.id));claims=claims.filter(c=>ids.has(c.session) || [...ids].some(id=>c.key===`session:${id}`));}
  return {ok:operations.ok && !claims.length,complete:true,unresolved:[...operations.unresolved,...claims],operations,claims};
}
export function dependencies(config){
  const url=git(config.repo,'remote','get-url','origin');
  if(fs.existsSync(url))return {ok:true,complete:true,unresolved:[],transport:'private_local_git',remote_heads:git(config.repo,'ls-remote','--heads','origin')};
  const name=config.github_repo;
  if(!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(name || '') || !url.toLowerCase().includes(name.toLowerCase()))throw Error('hosting_namespace_unverifiable');
  const pages=JSON.parse(command([config.gh || 'gh','api',`repos/${name}/pulls?state=open&per_page=100`,'--paginate','--slurp'],config.repo));
  if(!Array.isArray(pages) || pages.some(p=>!Array.isArray(p)))throw Error('hosting_dependency_inventory_incomplete');
  const plan=JSON.parse(fs.readFileSync(config.retirement_plan,'utf8')),refs=new Set(plan.remote.map(r=>r.ref.replace(/^refs\/heads\//,'')));
  const unresolved=[];
  for(const pull of pages.flat()) {
    if(!pull.head?.repo?.full_name || !pull.head?.sha || !pull.base?.ref)throw Error('hosting_pull_identity_missing');
    if(refs.has(pull.base.ref) || (pull.head.repo.full_name===name && refs.has(pull.head.ref)))unresolved.push({pull:pull.number,head:pull.head.sha,reason:'open_pr_dependency'});
  }
  return {ok:!unresolved.length,complete:true,unresolved,pulls:pages.flat().length,namespace:name};
}
export function freeze(config,issuer,reviewer) {
  if(!issuer || !reviewer || issuer===reviewer)throw Error('independent_freeze_review_required');
  const observed=ownerInventory(config);if(!observed.ok)throw Error('current_owners_not_quiescent');
  const plan=JSON.parse(fs.readFileSync(config.retirement_plan,'utf8')),trees=[];
  for(const tree of plan.worktrees) {
    if(git(tree.path,'rev-parse','HEAD')!==tree.tip)throw Error('freeze_tip_moved');
    const safety=combinedSafety(config,tree.path);if(!safety.ok)throw Error('freeze_relevant_effects_unresolved');
    // The owner of a tree is the node's own session binding for it, with the runtime identity
    // that session recorded when it allocated the tree. There is no third-party card to fall
    // back to, and none is needed: an unbound tree is refused, never assumed idle.
    const binding=observed.bindings.find(b=>key(b.worktree)===key(tree.path));
    if(!binding)throw Error('unmanaged_tree_owner_identity_unverifiable');
    const session=ledger(config,"SELECT id,worktree,workspace_start_state FROM sessions WHERE id=?",[binding.session]).find(s=>s.id===binding.session);
    if(!session)throw Error('runtime_session_binding_missing');
    if(!JSON.parse(session.workspace_start_state || '{}').executor?.owner_boot)throw Error('runtime_legacy_owner_identity_unverifiable');
    if(tree.owner_id!==binding.owner)throw Error('retirement_owner_identity_mismatch');
    trees.push({path:tree.path,tip:tree.tip,owner_id:tree.owner_id,evidence:JSON.stringify({session:session.id,binding,safety})});
  }
  const ticket={schema:1,kind:'wave-owner-freeze',repo:config.repo,wave_id:process.env.WA_WAVE_ID,main:git(config.repo,'rev-parse','HEAD'),issuer,reviewer,trees,agents:observed.agents,bindings:observed.bindings};
  fs.writeFileSync(config.owner_freeze,JSON.stringify(ticket)+'\n',{flag:'wx'});
  fs.writeFileSync(path.join(location(config.repo),'freeze.json'),JSON.stringify({wave_id:ticket.wave_id,ticket:config.owner_freeze,sha256:hash(JSON.stringify(ticket)+'\n')})+'\n',{flag:'wx'});
  return {ok:true,complete:true,unresolved:[],ticket:config.owner_freeze};
}
export function registry(config,target,apply=false) {
  const plan=JSON.parse(fs.readFileSync(config.retirement_plan,'utf8')),item=plan.worktrees.find(t=>key(t.path)===key(target));if(!item)throw Error('registry_target_not_in_exact_plan');
  const source=sourceOfConfig(config);
  if(apply) {
    // THE OWNER FENCE IS REQUIRED BEFORE ANY EFFECT, and only then: a target whose binding is
    // already released or parked has nothing left to settle (and cannot be in flight), so the
    // postconditions below are what prove it.
    const before=activityInventory(source).bindings.find(b=>key(b.worktree)===key(target));
    let owner=null;
    if(!before || !['released','parked'].includes(before.state)) {
      owner=frozenOwners(config,process.env.WA_WAVE_ID,plan.main,target,item.tip);if(!owner.ok)throw Error('registry_owner_not_frozen');
    }
    if(item.mode==='remove' && fs.existsSync(target)) {
      if(git(target,'rev-parse','HEAD')!==item.tip || spawnSync('git',['-C',target,'symbolic-ref','--quiet','HEAD'],{windowsHide:true}).status!==1)throw Error('removal_requires_exact_detached_tip');
      // The tree is removed through Git itself, so the repository's own registration goes with
      // it; nothing outside this repository is asked to agree.
      git(config.repo,'worktree','remove',target);
    }
    // The runtime's own binding reconciliation (released / parked) is still the authority for
    // what the node records about the session, and it is invoked through our own Lua.
    if(item.session_id){const result=native(config,{kind:'registry',item:{...item,evidence:JSON.stringify(owner||{settled:'binding already reconciled before this call'})}});if(result.ok!==true)throw Error(result.error);}
  }
  const refreshed=activityInventory(source);
  if(!refreshed.ok)throw Error('own_registry_refresh_unavailable:'+refreshed.reason);
  const tree=refreshed.trees.find(entry=>key(entry.path)===key(target));
  const binding=refreshed.bindings.find(entry=>key(entry.worktree)===key(target));
  if(item.mode==='remove' && (fs.existsSync(target) || tree))throw Error('registry_removal_not_observed');
  if(item.mode==='park' && (!fs.existsSync(target) || !tree || tree.head!==item.tip || !tree.detached || tree.branch))throw Error('registry_park_not_observed');
  if(item.session_id){const session=ledger(config,"SELECT id,workspace_state,workspace_branch FROM sessions").find(s=>s.id===item.session_id);
    if(!session || session.workspace_state!==(item.mode==='park'?'parked':'released') || (item.mode==='park'&&session.workspace_branch))throw Error('runtime_registry_not_reconciled');
    if(item.mode==='park' && (!binding || !binding.detached || binding.branch))throw Error('runtime_park_binding_not_reconciled');
    if(item.mode==='remove' && binding && binding.state!=='released')throw Error('runtime_release_binding_not_reconciled');}
  return {ok:true,reconciled:true,worktree:target,mode:item.mode,owner:'node-runtime',orca_view:orcaView(source,{enabled:config.orca_view===true})};
}
export function runtimeRetirement(config,target) {
  const plan=JSON.parse(fs.readFileSync(config.retirement_plan,'utf8')),item=plan.worktrees.find(t=>key(t.path)===key(target));
  if(!item?.session_id)throw Error('exact_runtime_session_retirement_required');
  const owner=frozenOwners(config,process.env.WA_WAVE_ID,plan.main,target,item.tip);if(!owner.ok)throw Error('current_owner_not_frozen');
  const result=native(config,{kind:'retire',item:{...item,evidence:JSON.stringify(owner)}});
  if(result.ok!==true)throw Error(result.error);return {ok:true,worktree:target,retired_under_session_fence:true,workspace:result.workspace};
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [action,file,a,b]=process.argv.slice(2),config=JSON.parse(fs.readFileSync(file,'utf8'));
    const main=process.env.WA_WAVE_MAIN || git(config.repo,'rev-parse','HEAD'),wave_id=process.env.WA_WAVE_ID,target=process.env.WA_WAVE_TARGET;
    let result;
    if(action==='owner')result=frozenOwners(config,wave_id,main,target,process.env.WA_WAVE_TIP);
    else if(action==='owners')result=frozenOwners(config,wave_id,main);
    else if(action==='safety')result=combinedSafety(config,target);
    else if(action==='operations')result=operationSafety(config,target);
    else if(action==='dependencies')result=dependencies(config);
    else if(action==='freeze')result=freeze(config,a,b);
    else if(action==='reconcile')result=registry(config,target,true);
    else if(action==='runtime-retire')result=runtimeRetirement(config,target);
    else if(action==='registry-post')result=registry(config,target,false);
    else throw Error('unknown_wave_adapter');
    console.log(JSON.stringify({...result,main,wave_id}));if(result.ok!==true)process.exitCode=1;
  }catch(e){console.log(JSON.stringify({ok:false,complete:false,reason:e.message}));process.exitCode=1;}
}
