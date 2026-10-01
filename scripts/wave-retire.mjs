#!/usr/bin/env node
// Safe, exact-input retirement by an external finisher after accepted owner
// settlement. No force/reset, wildcard deletion, or inferred quiescence.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const key=x=>{const normalized=path.resolve(x).replaceAll('\\','/');return process.platform==='win32'?normalized.toLowerCase():normalized;};
const quote=x=>`'${x.replaceAll("'","'\\''")}'`;
function fail(reason) { throw new Error(reason); }
function run(argv,cwd,input) { const r=spawnSync(argv[0],argv.slice(1),{cwd,input,encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:8*1024*1024}); if(r.status!==0) fail(`command_failed:${argv.join(' ')}:${r.stderr || r.error?.message}`);return r.stdout.trim(); }
const git=(repo,...args)=>run(['git','-C',repo,...args],repo);
const refs=text=>Object.fromEntries(text.split(/\r?\n/).filter(Boolean).map(line=>{const [tip,ref]=line.split(/\s+/);return [ref,tip];}));
function proof(argv,cwd,env={}) {
  if(!Array.isArray(argv) || !argv.length)fail('fresh_safety_proof_command_required');
  const r=spawnSync(argv[0],argv.slice(1),{cwd,env:{...process.env,...env},encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:8*1024*1024});
  let value;try{value=JSON.parse(r.stdout);}catch{fail('invalid_safety_proof');}
  if(r.status!==0 || value.ok!==true)fail(`safety_proof_failed:${value.error || value.reason}`);
  return value;
}
export function guard(plan,input) {
  const expected=Object.fromEntries(plan.remote.map(row=>[row.ref,row.tip]));
  const lines=input.trim().split(/\r?\n/).filter(Boolean);
  if(!lines.length)fail('empty_push_advertisement');
  for(const line of lines) {
    const [localRef,localTip,remoteRef,remoteTip,...extra]=line.trim().split(/\s+/);
    if(extra.length || localRef!=='(delete)' || !/^0{40,64}$/.test(localTip) || remoteRef==='refs/heads/main' || !expected[remoteRef] || expected[remoteRef]!==remoteTip)fail(`remote_tip_moved_or_out_of_plan:${remoteRef}`);
  }
  if(git(plan.repo,'rev-parse','refs/heads/main')!==plan.main)fail('main_moved_before_push');
  return {ok:true,advertisement_sha256:sha(input)};
}
export function retire(plan,store,resolutions=[]) {
  if(!path.isAbsolute(plan.repo || '') || !plan.wave_id || !plan.owner || !Array.isArray(plan.local) || !Array.isArray(plan.remote) || !Array.isArray(plan.worktrees))fail('exact_retirement_plan_required');
  if(git(plan.repo,'symbolic-ref','HEAD')!=='refs/heads/main' || git(plan.repo,'rev-parse','HEAD')!==plan.main)fail('sanctioned_main_identity_moved');
  if(git(plan.repo,'status','--porcelain','--untracked-files=all'))fail('canonical_dirty');
  if(refs(git(plan.repo,'ls-remote','--heads','origin'))['refs/heads/main']!==plan.main)fail('accepted_main_not_remote');
  fs.mkdirSync(store,{recursive:true});
  const db=new DatabaseSync(path.join(store,'retirement.sqlite'));
  db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS actions(wave TEXT,identity TEXT,plan_hash TEXT,state TEXT,evidence TEXT,PRIMARY KEY(wave,identity)); CREATE TABLE IF NOT EXISTS history(wave TEXT,identity TEXT,action TEXT,evidence TEXT);');
  const planHash=sha(JSON.stringify(plan));
  function action(identity,verify,mutate) {
    const old=db.prepare('SELECT * FROM actions WHERE wave=? AND identity=?').get(plan.wave_id,identity);
    if(old && old.plan_hash!==planHash)fail('retirement_plan_moved');
    if(old?.state==='done'){verify(true);return;}
    if(old) {
      const resolution=resolutions.find(row=>row.identity===identity);
      if(!resolution || resolution.plan_hash!==planHash || !resolution.evidence || !resolution.drain_evidence || !resolution.effect_evidence || resolution.outcome!=='settled')fail(`retirement_effect_unknown:${identity}: inspect and reconcile before any retry`);
      const observed=verify(true);
      db.prepare("INSERT INTO history VALUES(?,?,'reconcile',?)").run(plan.wave_id,identity,JSON.stringify({original:old,resolution,observed}));
      db.prepare("UPDATE actions SET state='done',evidence=? WHERE wave=? AND identity=?").run(JSON.stringify({original:old,resolution,observed}),plan.wave_id,identity);
      return;
    }
    const evidence=verify(false);
    db.prepare("INSERT INTO actions VALUES(?,?,?,'running',?)").run(plan.wave_id,identity,planHash,JSON.stringify(evidence));
    mutate();
    const after=verify(true);
    db.prepare("UPDATE actions SET state='done',evidence=? WHERE wave=? AND identity=?").run(JSON.stringify({before:evidence,after}),plan.wave_id,identity);
  }
  try {
    const owners=proof(plan.owners_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_MAIN:plan.main});
    if(owners.complete!==true || !Array.isArray(owners.unresolved) || owners.unresolved.length)fail('wave_owners_active_or_unverifiable');
    const dependencies=proof(plan.dependencies_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_MAIN:plan.main});
    if(dependencies.complete!==true || !Array.isArray(dependencies.unresolved) || dependencies.unresolved.length)fail('pr_dependencies_unresolved');
    for(const tree of plan.worktrees) {
      const canonical=fs.existsSync(tree.path)?fs.realpathSync(tree.path):tree.path;
      if(key(canonical)!==key(tree.path) || key(tree.path)===key(plan.repo) || key(tree.path)===key(process.cwd()) || !['park','remove'].includes(tree.mode))fail('external_finisher_or_worktree_path_invalid');
      if(!plan.managed_roots?.some(root=>key(tree.path).startsWith(key(fs.realpathSync(root))+'/')))fail('worktree_outside_owned_managed_roots');
      action(`tree:${key(tree.path)}`,after=>{
        if(after) {
          if(tree.mode==='remove') {
            if(fs.existsSync(tree.path) || git(plan.repo,'worktree','list','--porcelain').split(/\r?\n/).some(line=>line.startsWith('worktree ') && key(line.slice(9))===key(tree.path)))fail('worktree_removal_not_observed');
          } else if(git(tree.path,'rev-parse','HEAD')!==tree.tip || spawnSync('git',['-C',tree.path,'symbolic-ref','HEAD'],{encoding:'utf8',windowsHide:true}).status===0)fail('parked_worktree_not_exact_detached_tip');
          return {postcondition:true};
        }
        if(git(tree.path,'rev-parse','HEAD')!==tree.tip || git(tree.path,'symbolic-ref','HEAD')!==tree.branch)fail('worktree_ref_moved');
        if(git(tree.path,'status','--porcelain','--untracked-files=all','--ignored'))fail('worktree_dirty_or_ignored');
        git(plan.repo,'merge-base','--is-ancestor',tree.tip,plan.main);
        const owner=proof(tree.owner_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_TARGET:tree.path,WA_WAVE_TIP:tree.tip});
        if(owner.settled!==true || owner.tip!==tree.tip || key(owner.worktree || '')!==key(tree.path) || owner.owner_id!==tree.owner_id || !owner.evidence)fail('positive_exact_owner_settlement_required');
        const safety=proof(tree.safety_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_TARGET:tree.path});
        if(safety.complete!==true || !Array.isArray(safety.unresolved) || safety.unresolved.length)fail('relevant_operations_or_claims_unresolved');
        return {owner,safety,tip:tree.tip,branch:tree.branch};
      },()=>{
        if(tree.mode==='remove')git(plan.repo,'worktree','remove',tree.path);
        else git(tree.path,'switch','--detach',tree.tip);
      });
      // Git's postcondition does not settle runtime/Orca ownership. The adapter
      // must reconcile those registries and prove the exact same target.
      action(`registry:${key(tree.path)}`,after=>{
        if(!after)return {argv:tree.reconcile_argv};
        const observed=proof(tree.registry_post_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_TARGET:tree.path});
        if(observed.worktree!==tree.path || observed.reconciled!==true)fail('workspace_registries_unreconciled');return observed;
      },()=>proof(tree.reconcile_argv,plan.repo,{WA_WAVE_ID:plan.wave_id,WA_WAVE_TARGET:tree.path}));
    }
    for(const row of plan.local) {
      if(!row.ref.startsWith('refs/heads/') || row.ref==='refs/heads/main')fail('local_ref_out_of_scope');
      action(`local:${row.ref}`,after=>{
        const current=refs(git(plan.repo,'for-each-ref','--format=%(objectname) %(refname)','refs/heads/'))[row.ref];
        if(after){if(current)fail('local_ref_still_present_or_moved');return {absent:true};}
        if(current!==row.tip)fail('local_ref_moved');git(plan.repo,'merge-base','--is-ancestor',row.tip,plan.main);
        if(git(plan.repo,'worktree','list','--porcelain').split(/\r?\n/).includes(`branch ${row.ref}`))fail('local_ref_checked_out');
        return row;
      },()=>git(plan.repo,'update-ref','-d',row.ref,row.tip));
    }
    if(plan.remote.length) {
      const hookDir=fs.mkdtempSync(path.join(store,'push-hooks-'));
      const planFile=path.join(hookDir,'plan.json');fs.writeFileSync(planFile,JSON.stringify(plan));
      const prior=path.resolve(plan.repo,git(plan.repo,'rev-parse','--git-path','hooks/pre-push'));
      const input=path.join(hookDir,'advertisement');
      const body=`#!/bin/sh\nset -eu\ncat > ${quote(input)}\n${fs.existsSync(prior)?`${quote(prior)} "$@" < ${quote(input)}\n`:''}${quote(process.execPath)} ${quote(fileURLToPath(import.meta.url))} guard ${quote(planFile)} < ${quote(input)}\n`;
      fs.writeFileSync(path.join(hookDir,'pre-push'),body,{mode:0o755});
      for(const row of plan.remote) {
        if(!row.ref.startsWith('refs/heads/') || row.ref==='refs/heads/main')fail('remote_ref_out_of_scope');
        action(`remote:${row.ref}`,after=>{
          const current=refs(git(plan.repo,'ls-remote','--heads','origin'))[row.ref];
          if(after){if(current)fail('remote_ref_still_present_or_moved');return {absent:true};}
          if(current!==row.tip)fail('remote_ref_moved');git(plan.repo,'merge-base','--is-ancestor',row.tip,plan.main);return row;
        },()=>git(plan.repo,'-c',`core.hooksPath=${hookDir}`,'push','origin',`:${row.ref}`));
      }
    }
    return {ok:true,wave_id:plan.wave_id,main:plan.main,retired:plan.worktrees.length,local:plan.local.length,remote:plan.remote.length,note:'Retirement settled; final wave verification still required.'};
  } finally { db.close(); }
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [verb,file,store,resolutionFile]=process.argv.slice(2),plan=JSON.parse(fs.readFileSync(file,'utf8'));
    const result=verb==='guard'?guard(plan,fs.readFileSync(0,'utf8')):verb==='apply'?retire(plan,path.resolve(store),resolutionFile?JSON.parse(fs.readFileSync(resolutionFile,'utf8')):[]):fail('usage: guard PLAN | apply PLAN PRIVATE-STATE [RESOLUTIONS]');
    console.log(JSON.stringify(result));
  }catch(e){console.log(JSON.stringify({ok:false,error:e.message}));process.exitCode=1;}
}
