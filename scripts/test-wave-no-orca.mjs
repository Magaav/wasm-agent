// NO THIRD PARTY IN THE PROOFS - and no silently skipped assertions when it is absent.
//
// The ownership and registry proofs used to resolve through an `orca` CLI. Here they are run in a
// child process whose PATH cannot reach an `orca` binary at all (and, in a second pass, whose
// `orca` is a poisoned stub that fails loudly): both passes must reach the same verdicts, and the
// assertions must still be able to FAIL - an unowned tree is added at the end and must be refused.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {ownerInventory,frozenOwners} from './lib/wave-owners.mjs';

const source=path.resolve('.');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-no-orca-'));
let checks=0,passed=false;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const git=(repo,...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};

// PATH WITHOUT ORCA. Every entry that names an orca installation is removed, so the proofs run
// with the binary genuinely unreachable; Git and the system directories stay, because the proofs
// legitimately use Git.
const orcaFreePath=String(process.env.PATH||'').split(path.delimiter).filter(entry=>entry && !/orca/i.test(entry)).join(path.delimiter);
const poison=path.join(root,'poison');fs.mkdirSync(poison,{recursive:true});
const poisonedPath=[poison,orcaFreePath].join(path.delimiter);
// A REAL executable named `orca.exe` that fails loudly: the node binary itself, which cannot run a
// script called `worktree` and exits non-zero. Any decision path that consulted orca would break.
fs.copyFileSync(process.execPath,path.join(poison,process.platform==='win32'?'orca.exe':'orca'));
const withoutOrca={...process.env,PATH:orcaFreePath};
const withPoisonedOrca={...process.env,PATH:poisonedPath};

function run(kind,configFile,env,extra={}) {
  const r=spawnSync(process.execPath,[path.join(source,'scripts/wave-proof.mjs'),kind,configFile],{encoding:'utf8',windowsHide:true,timeout:120000,env:{...env,WA_WAVE_ID:'no-orca',WA_WAVE_MAIN:extra.main||git(extra.repo||root,'rev-parse','HEAD'),...extra.env}});
  let proof;try{proof=JSON.parse(r.stdout.trim());}catch{throw Error(`${kind} wrote no verdict: ${r.stdout} ${r.stderr}`);}
  return {status:r.status,proof};
}
function adapter(configFile,action,env,args=[]) {
  const r=spawnSync(process.execPath,[path.join(source,'scripts/wave-adapter.mjs'),action,configFile,...args],{encoding:'utf8',windowsHide:true,timeout:120000,env});
  let proof;try{proof=JSON.parse(r.stdout.trim());}catch{throw Error(`${action} wrote no verdict: ${r.stdout} ${r.stderr}`);}
  return proof;
}

try {
  const repo=path.join(root,'canonical'),data=path.join(root,'data'),executor=path.join(root,'executor');
  fs.mkdirSync(repo);fs.mkdirSync(data,{recursive:true});fs.mkdirSync(executor);
  git(repo,'init','-q','-b','main');git(repo,'config','user.name','fixture');git(repo,'config','user.email','fixture@invalid');
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');git(repo,'add','.');git(repo,'commit','-qm','baseline');
  const main=git(repo,'rev-parse','HEAD');
  const parked=path.join(data,'wa-worktree-parked-session'),missing=path.join(data,'wa-worktree-released-session');
  git(repo,'worktree','add','--detach',parked);
  const db=new DatabaseSync(path.join(data,'memory.db'));
  db.exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
      workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
      workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
      started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
    CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',
      boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
    CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',
      state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`);
  // ONE PARKED BINDING (a real detached exact tip, empty branch) AND ONE RELEASED BINDING (no tree
  // left behind): the two reconciled shapes the registry proof must accept.
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_branch,workspace_base_commit,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,1,'parked','',?,?,?,0,1,0)")
    .run('parked-session',parked.replaceAll('\\','/'),main,repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:'boot-parked'}}));
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_branch,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,1,'released','',?,?,0,1,0)")
    .run('released-session',missing.replaceAll('\\','/'),repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:'boot-released'}}));
  db.close();
  const config={repo,data,source_root:source,orca_repo_id:'no-third-party-is-consulted',process_probe:false};
  const configFile=path.join(executor,'config.json');fs.writeFileSync(configFile,JSON.stringify(config));

  // THE BINARY REALLY IS UNREACHABLE, AND REALLY IS POISONED IN THE SECOND PASS.
  const absent=spawnSync('orca',['--version'],{encoding:'utf8',windowsHide:true,env:withoutOrca});
  check(Boolean(absent.error)||absent.status!==0,'no orca binary is reachable on the sanitized PATH');
  // The broken `orca.exe` fails on the very invocation a decision path would use.
  const poisoned=spawnSync('orca',['worktree','list','--json'],{encoding:'utf8',windowsHide:true,env:withPoisonedOrca});
  check(!poisoned.error&&poisoned.status!==0,'the second pass really has a broken orca on PATH that fails the registry invocation');

  for (const [label,env] of [['orca absent',withoutOrca],['orca present but broken',withPoisonedOrca]]) {
    const registries=run('registries',configFile,env,{repo});
    check(registries.proof.ok===true&&registries.proof.complete===true,`registries passes with ${label}`);
    check(registries.proof.unresolved.length===0,`registries reports no unresolved leftovers with ${label}`);
    check(registries.proof.evidence.third_party==='none',`registries names its own inventory as the only source with ${label}`);
    check(registries.proof.evidence.git_worktrees>=2,`registries really read the Git worktree list with ${label}`);
    check(registries.proof.evidence.runtime_bindings===2,`registries really read the session bindings with ${label}`);
    check(registries.proof.evidence.orca_view?.used===false,`the optional viewer is not used unless asked for, with ${label}`);

    const owners=run('owners',configFile,env,{repo,env:{WA_WAVE_ADMISSION:'1'}});
    check(owners.proof.ok===true&&owners.proof.complete===true,`owners passes with ${label}`);
    check(owners.proof.unresolved.length===0,`owners reports no unresolved owners with ${label}`);
    check(owners.proof.evidence.bindings.length===2,`owners really enumerated the bindings with ${label}`);
    check(owners.proof.evidence.third_party==='none',`owners names its own inventory as the only source with ${label}`);
  }

  // THE OWNERSHIP ASSERTIONS ARE LIVE, NOT SKIPPED: an unowned managed tree must be refused.
  const orphan=path.join(data,'wa-worktree-orphan');
  git(repo,'worktree','add','--detach',orphan);
  const refused=run('registries',configFile,withoutOrca,{repo});
  check(refused.proof.ok===false,'an unowned managed worktree is refused with orca absent');
  check(refused.proof.unresolved.some(item=>item.reason==='unowned_worktree_registration'),'and the refusal names it');
  const ownersRefused=run('owners',configFile,withoutOrca,{repo,env:{WA_WAVE_ADMISSION:'1'}});
  check(ownersRefused.proof.ok===false&&ownersRefused.proof.unresolved.some(item=>item.reason==='unowned_managed_worktree'),'owners refuses it too, by name');
  git(repo,'worktree','remove',orphan);

  // THE REGISTRY ADAPTER, and the freeze recheck, on our own inventory.
  const plan={wave_id:'no-orca',owner:'fixture',repo,main,managed_roots:[data],local:[],remote:[],
    worktrees:[{path:parked,tip:main,branch:'',mode:'park',owner_id:'runtime:parked-session:boot-parked',owner_argv:[],safety_argv:[],reconcile_argv:[],registry_post_argv:[]},
               {path:missing,tip:main,branch:'',mode:'remove',owner_id:'runtime:released-session:boot-released',owner_argv:[],safety_argv:[],reconcile_argv:[],registry_post_argv:[]}],
    owners_argv:[],dependencies_argv:[]};
  const planFile=path.join(executor,'retire.json');fs.writeFileSync(planFile,JSON.stringify(plan));
  const freezeFile=path.join(executor,'freeze.json');
  const adapterConfig={...config,retirement_plan:planFile,owner_freeze:freezeFile};
  const adapterFile=path.join(executor,'adapter-config.json');fs.writeFileSync(adapterFile,JSON.stringify(adapterConfig));
  const parkedResult=adapter(adapterFile,'registry-post',{...withoutOrca,WA_WAVE_ID:'no-orca',WA_WAVE_MAIN:main,WA_WAVE_TARGET:parked});
  check(parkedResult.ok===true&&parkedResult.reconciled===true,'the parked tree reconciles through Git and the node binding alone');
  check(parkedResult.owner==='node-runtime'&&parkedResult.orca_view?.used===false,'and it names our own inventory as the reconciling authority');
  const removedResult=adapter(adapterFile,'registry-post',{...withoutOrca,WA_WAVE_ID:'no-orca',WA_WAVE_MAIN:main,WA_WAVE_TARGET:missing});
  check(removedResult.ok===true&&removedResult.reconciled===true,'the released tree reconciles with no tree left behind');

  const observed=ownerInventory(adapterConfig);
  check(observed.ok===true,'the frozen inventory is quiescent');
  fs.writeFileSync(freezeFile,JSON.stringify({schema:1,kind:'wave-owner-freeze',repo,wave_id:'no-orca',main,issuer:'fixture-coordinator',reviewer:'fixture-independent',trees:[{path:parked,tip:main,owner_id:'runtime:parked-session:boot-parked',evidence:['fixture: parked detached exact tip']}],agents:observed.agents,bindings:observed.bindings}));
  const frozen=frozenOwners(adapterConfig,'no-orca',main);
  check(frozen.ok===true&&frozen.settle===undefined,'a freeze built from our own inventory rechecks clean');
  const settled=frozenOwners(adapterConfig,'no-orca',main,parked,main);
  check(settled.settled===true&&settled.owner_id==='runtime:parked-session:boot-parked','the exact tree, tip and owner settle');
  assert.throws(()=>frozenOwners(adapterConfig,'no-orca',main,parked,'0'.repeat(40)),/exact_tree_owner_settlement_required/);checks++;
  // A binding that moved after the freeze is refused, and so is a live agent the freeze never saw:
  // the guard that protects against retiring live work is still there, now on our own inventory.
  const staleTicket=JSON.parse(fs.readFileSync(freezeFile,'utf8'));
  fs.writeFileSync(freezeFile,JSON.stringify({...staleTicket,bindings:staleTicket.bindings.map(binding=>binding.session==='parked-session'?{...binding,recorded_branch:'change/taken-over'}:binding)}));
  assert.throws(()=>frozenOwners(adapterConfig,'no-orca',main),/current_binding_changed_after_freeze/);checks++;
  fs.writeFileSync(freezeFile,JSON.stringify(staleTicket));
  const liveTree=path.join(data,'wa-worktree-live-session');
  git(repo,'worktree','add','--detach',liveTree);
  const live=new DatabaseSync(path.join(data,'memory.db'));
  live.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,1,'allocated',?,?,0,NULL,0)")
    .run('live-session',liveTree.replaceAll('\\','/'),repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:'boot-live'}}));
  live.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES('live-session','fixture','run-live','boot-live','active',1)").run();
  live.close();
  assert.throws(()=>frozenOwners(adapterConfig,'no-orca',main),/owner_takeover_or_inventory_movement/);checks++;

  // AND NO REQUIRED-ORCA SOURCE REMAINS IN THE PROOF MODULES.
  const ownersSource=fs.readFileSync(path.join(source,'scripts/lib/wave-owners.mjs'),'utf8');
  const adapterSource=fs.readFileSync(path.join(source,'scripts/wave-adapter.mjs'),'utf8');
  const proofSource=fs.readFileSync(path.join(source,'scripts/wave-proof.mjs'),'utf8');
  const activitySource=fs.readFileSync(path.join(source,'scripts/lib/wave-activity.mjs'),'utf8');
  for (const [name,text] of [['wave-owners.mjs',ownersSource],['wave-adapter.mjs',adapterSource],['wave-proof.mjs',proofSource]])
    for (const marker of ['orcaJSON','orca_registry_incomplete','orca_inventory_unavailable','orca_inventory_unreadable'])
      check(!text.includes(marker),`${name} carries no required-orca marker (${marker})`);
  check(activitySource.includes('decision_input: false'),'the optional viewer declares itself a non-decision input');
  passed=true;
  console.log(`wave no-third-party ok (${checks} checks; ownership and registry proofs pass with orca absent and with orca broken, and still refuse an unowned tree)`);
} finally {
  if(passed) fs.rmSync(root,{recursive:true,force:true}); else console.error(`wave no-orca fixtures retained: ${root}`);
}
