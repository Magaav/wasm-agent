#!/usr/bin/env node
// Deterministic external finisher. Admission/execution are durable; ambiguous
// effects are observed and reconciled, never replayed on restart.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {fullProof,findFullProof} from './lib/full-gate-proof.mjs';

const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const requiredChecks = ['operations','claims','runtime','registries','deliveries','owners'];
function fail(reason) { throw new Error(reason); }
function command(argv, cwd, env = {}, timeout = 30000) {
  if (!Array.isArray(argv) || !argv.length || argv.some(x => typeof x !== 'string')) fail('argv_required');
  const result = spawnSync(argv[0], argv.slice(1), {cwd, env:{...process.env,...env}, encoding:'utf8', timeout, maxBuffer:16*1024*1024, windowsHide:true});
  return {code:result.status,error:result.error?.message,signal:result.signal,stdout:result.stdout || '',stderr:result.stderr || ''};
}
function git(repo, args) {
  const result = command(['git', '-C', repo, ...args], repo);
  if (result.code !== 0) fail(`git_failed:${args.join(' ')}:${result.stderr || result.error}`);
  return result.stdout.trim();
}
function native(value) { const normalized=path.resolve(value).replaceAll('\\','/'); return process.platform==='win32'?normalized.toLowerCase():normalized; }
function heads(text) {
  return text.split(/\r?\n/).filter(Boolean).map(line => {
    const [sha,ref] = line.split(/\s+/); return {sha,ref};
  }).sort((a,b) => a.ref.localeCompare(b.ref));
}
export function gitBaseline(repo) {
  const main = git(repo,['rev-parse','refs/heads/main']);
  if (git(repo,['symbolic-ref','HEAD']) !== 'refs/heads/main') fail('canonical_not_main');
  if (git(repo,['status','--porcelain','--untracked-files=all'])) fail('canonical_dirty_or_untracked');
  const remote = heads(git(repo,['ls-remote','--heads','origin']));
  const local = heads(git(repo,['for-each-ref','--format=%(objectname) %(refname)','refs/heads/']));
  const onlyMain = rows => rows.length === 1 && rows[0].ref === 'refs/heads/main' && rows[0].sha === main;
  if (!onlyMain(remote)) fail('remote_not_main_only_or_moved');
  if (!onlyMain(local)) fail('local_not_main_only_or_moved');
  if (git(repo,['rev-parse','refs/remotes/origin/main']) !== main) fail('origin_main_tracking_mismatch');
  const rows = git(repo,['worktree','list','--porcelain','-z']).split('\0\0').filter(Boolean);
  const worktrees = rows.map(row => Object.fromEntries(row.split('\0').filter(Boolean).map(item => {
    const space = item.indexOf(' '); return space < 0 ? [item,true] : [item.slice(0,space),item.slice(space+1)];
  })));
  for (const tree of worktrees) {
    if (tree.locked || tree.prunable) fail(`worktree_unresolved:${tree.worktree}`);
    if (native(tree.worktree) !== native(repo) && !tree.detached) fail(`worktree_not_detached:${tree.worktree}`);
    const statusArgs=['status','--porcelain','--untracked-files=all'];
    // The canonical build cache is retained for the next verified wave. Other
    // trees may not be retired while ignored evidence/artifacts remain there.
    if (native(tree.worktree)!==native(repo)) statusArgs.push('--ignored');
    if (git(tree.worktree,statusArgs)) fail(`worktree_dirty_or_ignored:${tree.worktree}`);
    if (command(['git','-C',repo,'merge-base','--is-ancestor',tree.HEAD,main],repo).code !== 0) fail(`worktree_unmerged:${tree.worktree}`);
  }
  // Read again after the worktree checks so a moving ref cannot earn a receipt.
  if (JSON.stringify(heads(git(repo,['ls-remote','--heads','origin']))) !== JSON.stringify(remote) ||
      JSON.stringify(heads(git(repo,['for-each-ref','--format=%(objectname) %(refname)','refs/heads/']))) !== JSON.stringify(local) ||
      git(repo,['rev-parse','HEAD']) !== main) fail('refs_moved_during_verification');
  return {ok:true,main,remote,local,worktrees};
}
function open(dir) {
  fs.mkdirSync(path.join(dir,'leases'),{recursive:true});
  const db = new DatabaseSync(path.join(dir,'waves.sqlite'));
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS waves(id TEXT PRIMARY KEY,repo TEXT NOT NULL,manifest TEXT NOT NULL,manifest_hash TEXT NOT NULL,state TEXT NOT NULL,reason TEXT,owner TEXT NOT NULL,boot TEXT,pid INTEGER,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,receipt TEXT);
    CREATE UNIQUE INDEX IF NOT EXISTS active_repo ON waves(repo) WHERE state!='complete';
    CREATE TABLE IF NOT EXISTS steps(wave TEXT NOT NULL,position INTEGER NOT NULL,name TEXT NOT NULL,state TEXT NOT NULL,operation_id TEXT,attempts INTEGER NOT NULL DEFAULT 0,post_attempts INTEGER NOT NULL DEFAULT 0,next_at INTEGER NOT NULL DEFAULT 0,result TEXT,PRIMARY KEY(wave,position));
    CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY,wave TEXT NOT NULL,at INTEGER NOT NULL,type TEXT NOT NULL,body TEXT NOT NULL);`);
  return db;
}
function event(db,id,type,body) { db.prepare('INSERT INTO events(wave,at,type,body) VALUES(?,?,?,?)').run(id,Date.now(),type,JSON.stringify(body)); }
function transaction(db, fn) { db.exec('BEGIN IMMEDIATE'); try { const value=fn(); db.exec('COMMIT'); return value; } catch(e) { db.exec('ROLLBACK'); throw e; } }
function lease(dir, boot) {
  const db = new DatabaseSync(path.join(dir,'leases',`${boot}.sqlite`));
  db.exec('PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE'); return db;
}
function alive(dir, boot) {
  if (!boot) return false;
  const file = path.join(dir,'leases',`${boot}.sqlite`);
  if (!fs.existsSync(file)) return null;
  let db;
  try { db=new DatabaseSync(file); db.exec('PRAGMA busy_timeout=0; BEGIN EXCLUSIVE; ROLLBACK'); return false; }
  catch { return true; } finally { db?.close(); }
}
function wave(db,id) { const row=db.prepare('SELECT * FROM waves WHERE id=?').get(id); if (!row) fail('wave_not_found'); return row; }
function block(db,id,reason) { db.prepare("UPDATE waves SET state='blocked',reason=?,updated_at=? WHERE id=?").run(reason,Date.now(),id); event(db,id,'blocked',{reason,next_action:'Inspect durable step/operation and reconcile; never replay unknown effects.'}); }
function validate(manifest) {
  if (!manifest.id || !manifest.owner || !path.isAbsolute(manifest.repo || '') || !path.isAbsolute(manifest.executor_cwd || '')) fail('wave_identity_and_native_paths_required');
  if(native(fs.realpathSync(manifest.repo))!==native(manifest.repo) || native(fs.realpathSync(manifest.executor_cwd))!==native(manifest.executor_cwd)) fail('canonical_repo_and_executor_paths_required');
  if (!Array.isArray(manifest.steps) || manifest.steps.map(x=>x.name).join(',') !== 'land,deploy,retire') fail('ordered_land_deploy_retire_steps_required');
  if (!manifest.verifiers || requiredChecks.some(name=>!manifest.verifiers[name])) fail('all_convergence_verifiers_required');
  for (const step of [...manifest.steps,...Object.values(manifest.verifiers)]) {
    if (!Array.isArray(step.argv) || !step.argv.length || step.argv.some(x=>typeof x!=='string') || !step.post?.argv && manifest.steps.includes(step)) fail('step_argv_and_post_required');
    if (step.timeout_ms !== undefined && (!Number.isSafeInteger(step.timeout_ms) || step.timeout_ms<1 || step.timeout_ms>10800000)) fail('invalid_step_timeout');
    if (manifest.steps.includes(step)) {
      if(!Array.isArray(step.post.argv) || !step.post.argv.length || step.post.argv.some(x=>typeof x!=='string')) fail('post_argv_required');
      if(step.post.max_attempts!==undefined && (!Number.isSafeInteger(step.post.max_attempts) || step.post.max_attempts<1 || step.post.max_attempts>5)) fail('invalid_post_attempts');
      if(step.post.timeout_ms!==undefined && (!Number.isSafeInteger(step.post.timeout_ms) || step.post.timeout_ms<1 || step.post.timeout_ms>60000)) fail('invalid_post_timeout');
    }
  }
  if (manifest.steps.some(s=>s.cwd && native(s.cwd)!==native(manifest.executor_cwd))) fail('executor_cwd_must_own_all_steps');
}
function runProof(spec, cwd, env) {
  const result = command(spec.argv,cwd,env,spec.timeout_ms || 30000);
  let proof; try { proof=JSON.parse(result.stdout); } catch { return {ok:false,result,reason:'invalid_proof_json'}; }
  return {ok:result.code===0 && proof.ok===true,result,proof,reason:result.error || proof.reason || 'postcondition_failed'};
}
export function verify(manifest, id=manifest.id,admission=false) {
  const baseline = gitBaseline(manifest.repo);
  const sourceTree=git(manifest.repo,['rev-parse',`${baseline.main}^{tree}`]);
  let gate;
  if(manifest.gate_receipt) {
    const receipt=JSON.parse(fs.readFileSync(manifest.gate_receipt,'utf8'));
    const storageOwner=receipt.owner_repo || receipt.repo;
    if(!storageOwner || native(git(storageOwner,['rev-parse','--path-format=absolute','--git-common-dir']))!==native(git(manifest.repo,['rev-parse','--path-format=absolute','--git-common-dir'])))fail('combined_full_gate_source_registry_mismatch');
    gate={...fullProof(receipt,sourceTree),receipt:manifest.gate_receipt};
  }else gate=findFullProof(manifest.repo,sourceTree);
  if(!gate.verified)fail('combined_full_gate_receipt_unverified:'+gate.reason);
  const env = {WA_WAVE_ID:id,WA_WAVE_MAIN:baseline.main,WA_WAVE_ADMISSION:admission?'1':'0'};
  const proofs={};
  for (const name of requiredChecks) {
    const observed=runProof(manifest.verifiers[name],manifest.executor_cwd,env);
    if (!observed.ok || observed.proof?.main !== baseline.main || observed.proof?.wave_id !== id) fail(`${name}_unverified:${observed.reason}`);
    // The operation/claim projections must report their complete unresolved set,
    // not just a count of resources this cleanup happened to release.
    if (['operations','claims','deliveries','owners'].includes(name) &&
        (!Array.isArray(observed.proof.unresolved) || observed.proof.unresolved.length || observed.proof.complete!==true)) fail(`${name}_unresolved_or_incomplete`);
    proofs[name]={proof:observed.proof,stdout_sha256:hash(observed.result.stdout),argv:manifest.verifiers[name].argv};
  }
  const after=gitBaseline(manifest.repo);
  if (hash(JSON.stringify(after))!==hash(JSON.stringify(baseline))) fail('baseline_moved_during_proofs');
  return {ok:true,wave_id:id,main:baseline.main,git:baseline,gate:{tree:gate.tree,skipped:gate.skipped,log_sha256:gate.log_sha256,receipt:gate.receipt},proofs,verified_at:Date.now()};
}
export function create(dir, manifest) {
  validate(manifest);
  const db=open(dir);
  try {
    const previous=db.prepare('SELECT * FROM waves WHERE repo=? ORDER BY created_at DESC LIMIT 1').get(native(manifest.repo));
    if (previous) {
      if (previous.state!=='complete') fail(`previous_wave_${previous.state}:${previous.id}`);
      // Completion receipts can go stale. Recheck actual baseline, install, owners
      // and registries before admitting another wave.
      verify(JSON.parse(previous.manifest),previous.id,true);
    } else if (manifest.bootstrap !== true) {
      verify(manifest);
    }
    transaction(db,()=>{
      db.prepare('INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)').run(manifest.id,native(manifest.repo),JSON.stringify(manifest),hash(JSON.stringify(manifest)),'pending',manifest.owner,Date.now(),Date.now());
      manifest.steps.forEach((step,i)=>db.prepare("INSERT INTO steps(wave,position,name,state) VALUES(?,?,?,'pending')").run(manifest.id,i,step.name));
      event(db,manifest.id,'created',{owner:manifest.owner,bootstrap:manifest.bootstrap===true});
    });
    return {ok:true,id:manifest.id,state:'pending',next_action:{argv:[process.execPath,fileURLToPath(import.meta.url),'advance',dir,manifest.id]}};
  } finally { db.close(); }
}
export async function advance(dir,id) {
  const db=open(dir),boot=crypto.randomUUID(); let held;
  try {
    transaction(db,()=>{
      const row=wave(db,id),live=alive(dir,row.boot);
      if (live!==false) fail(live===true?'wave_owner_live':'wave_owner_identity_unverifiable');
      if (row.state==='complete') fail('wave_already_complete');
      held=lease(dir,boot);
      // A crashed launch may have executed before its receipt reached SQLite.
      // Never rerun it; completion recovery is a separate observed transition.
      const interrupted=db.prepare("SELECT * FROM steps WHERE wave=? AND state='running'").get(id);
      if (interrupted) {
        db.prepare("UPDATE steps SET state='unknown' WHERE wave=? AND position=?").run(id,interrupted.position);
        block(db,id,`interrupted_operation:${interrupted.operation_id}`);
      }
      db.prepare('UPDATE waves SET boot=?,pid=?,updated_at=? WHERE id=?').run(boot,process.pid,Date.now(),id);
    });
    let row=wave(db,id); if (row.state==='blocked') return {ok:false,...row};
    const manifest=JSON.parse(row.manifest);
    if (hash(JSON.stringify(manifest))!==row.manifest_hash) fail('wave_manifest_moved');
    db.prepare("UPDATE waves SET state='running',reason=NULL WHERE id=?").run(id);
    for (const step of db.prepare('SELECT * FROM steps WHERE wave=? ORDER BY position').all(id)) {
      if (step.state==='complete') continue;
      const spec=manifest.steps[step.position];
      const env={WA_WAVE_ID:id,WA_WAVE_STATE_DIR:dir,WA_WAVE_OPERATION_ID:step.operation_id || crypto.randomUUID()};
      if (step.state==='pending') {
        const operation_id=env.WA_WAVE_OPERATION_ID;
        transaction(db,()=>{
          db.prepare("UPDATE steps SET state='running',operation_id=?,attempts=attempts+1,post_attempts=0 WHERE wave=? AND position=?").run(operation_id,id,step.position);
          event(db,id,'operation_admitted',{position:step.position,operation_id,owner:row.owner,boot,cwd:manifest.executor_cwd,argv:spec.argv});
        });
        const result=command(spec.argv,manifest.executor_cwd,{...spec.env,...env},spec.timeout_ms || 10800000);
        let settlement; try { settlement=JSON.parse(result.stdout); } catch {}
        const settled=result.code===0 && settlement?.ok===true && settlement.settled===true && settlement.operation_id===operation_id && settlement.cleanup && settlement.cleanup!=='unknown';
        transaction(db,()=>{
          db.prepare('UPDATE steps SET state=?,result=? WHERE wave=? AND position=?').run(settled?'checking':'unknown',JSON.stringify({result,settlement}),id,step.position);
          event(db,id,settled?'command_settled':'effect_unknown',{position:step.position,operation_id,result,settlement});
          if (!settled) block(db,id,`operation_outcome_unknown:${operation_id}`);
        });
        if (!settled) return {ok:false,state:'blocked',reason:'operation_outcome_unknown',operation_id};
      }
      // Postconditions are observations and are safe to repeat. Their bounded
      // budget/backoff is persisted; commands with effects never retry here.
      const retries=spec.post.max_attempts===undefined?3:spec.post.max_attempts;
      if(!Number.isSafeInteger(retries) || retries<1 || retries>5)fail('invalid_persisted_post_budget');
      for (;;) {
        const current=db.prepare('SELECT * FROM steps WHERE wave=? AND position=?').get(id,step.position);
        const postAttempts=current.post_attempts;
        if (postAttempts>=retries) { block(db,id,`postcondition_exhausted:${spec.name}`); return {ok:false,state:'blocked'}; }
        if (current.next_at>Date.now()) await new Promise(resolve=>setTimeout(resolve,Math.min(60000,current.next_at-Date.now())));
        const post=runProof(spec.post,manifest.executor_cwd,env);
        transaction(db,()=>{
          db.prepare('UPDATE steps SET state=?,post_attempts=post_attempts+1,next_at=? WHERE wave=? AND position=?').run(post.ok?'complete':'checking',Date.now()+Math.min(30000,1000*2**postAttempts),id,step.position);
          event(db,id,'postcondition',{position:step.position,operation_id:env.WA_WAVE_OPERATION_ID,...post});
        });
        if (post.ok) break;
      }
      // No model/human ping is needed: settled completion directly continues the
      // next admitted stage on this external owner, within the same durable wave.
    }
    try {
      const receipt=verify(manifest,id);
      transaction(db,()=>{
        db.prepare("UPDATE waves SET state='complete',reason=NULL,receipt=?,updated_at=? WHERE id=?").run(JSON.stringify(receipt),Date.now(),id);
        event(db,id,'complete',receipt);
      });
      return receipt;
    } catch(e) { block(db,id,`convergence_failed:${e.message}`); return {ok:false,state:'blocked',reason:e.message}; }
  } finally { held?.close(); db.close(); }
}
export function reconcile(dir,id,input) {
  const db=open(dir);
  try { return transaction(db,()=>{
    const row=wave(db,id); if (alive(dir,row.boot)!==false) fail('wave_owner_live_or_unverifiable');
    if (!input.evidence || !input.drain_evidence || !input.effect_evidence || input.expected_manifest_hash!==row.manifest_hash) fail('exact_identity_drain_and_effect_evidence_required');
    const step=db.prepare('SELECT * FROM steps WHERE wave=? AND operation_id=?').get(id,input.operation_id);
    if (!step || step.state!=='unknown') fail('unknown_operation_identity_required');
    if (!['settled','no_effect'].includes(input.outcome)) fail('observed_settlement_or_no_effect_required');
    if (input.outcome==='settled' && (input.settlement?.operation_id!==step.operation_id || input.settlement?.settled!==true || input.settlement?.cleanup==='unknown' || !input.settlement?.cleanup || input.settlement?.ok!==true)) fail('settlement_proof_required');
    // no_effect explicitly authorizes a bounded replacement attempt; IDs of all
    // previous attempts stay in the append-only event journal.
    if (input.outcome==='no_effect' && step.attempts>=3) fail('command_retry_exhausted');
    db.prepare('UPDATE steps SET state=?,operation_id=?,next_at=0 WHERE wave=? AND position=?').run(input.outcome==='settled'?'checking':'pending',input.outcome==='settled'?step.operation_id:null,id,step.position);
    db.prepare("UPDATE waves SET state='pending',reason=NULL WHERE id=?").run(id);
    event(db,id,'reconciled',input); return {ok:true,state:'pending',next_action:`advance ${id}`};
  }); } finally { db.close(); }
}
export function inspect(dir,id) {
  const db=new DatabaseSync(path.join(dir,'waves.sqlite'),{readOnly:true});
  try {
    const row=wave(db,id),live=alive(dir,row.boot);
    const next_action=row.state==='complete' || live!==false?{kind:'none',argv:[]}:
      row.state==='blocked'?{kind:'inspect_effects_and_reconcile_or_resume',argv:[]}:
      {kind:'advance',argv:[process.execPath,fileURLToPath(import.meta.url),'advance',dir,id]};
    return {...row,owner_liveness:live,next_action,steps:db.prepare('SELECT * FROM steps WHERE wave=? ORDER BY position').all(id),events:db.prepare('SELECT * FROM events WHERE wave=? ORDER BY sequence').all(id)};
  }
  finally { db.close(); }
}
export function resume(dir,id,evidence) {
  if (!evidence?.trim()) fail('observed_resolution_evidence_required');
  const db=open(dir);
  try { return transaction(db,()=>{
    const row=wave(db,id);
    if (row.state!=='blocked' || alive(dir,row.boot)!==false) fail('blocked_wave_with_dead_owner_required');
    if (db.prepare("SELECT 1 FROM steps WHERE wave=? AND state IN ('unknown','running')").get(id)) fail('unknown_effect_requires_reconciliation');
    db.prepare("UPDATE steps SET post_attempts=0,next_at=0 WHERE wave=? AND state='checking'").run(id);
    db.prepare("UPDATE waves SET state='pending',reason=NULL WHERE id=?").run(id);
    event(db,id,'resolution_observed',{evidence}); return {ok:true,state:'pending'};
  }); } finally { db.close(); }
}
if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [action,dir,id,file]=process.argv.slice(2);
  try {
    let result;
    if (action==='create') result=create(path.resolve(dir),JSON.parse(fs.readFileSync(id,'utf8')));
    else if (action==='advance') result=await advance(path.resolve(dir),id);
    else if (action==='inspect') result=inspect(path.resolve(dir),id);
    else if (action==='reconcile') result=reconcile(path.resolve(dir),id,JSON.parse(fs.readFileSync(file,'utf8')));
    else if (action==='resume') result=resume(path.resolve(dir),id,file);
    else if (action==='verify') result=verify(JSON.parse(fs.readFileSync(dir,'utf8')));
    else fail('usage: create DIR MANIFEST | advance DIR ID | inspect DIR ID | reconcile DIR ID EVIDENCE | verify MANIFEST');
    process.stdout.write(`${JSON.stringify(result,null,2)}\n`); if (result.ok===false) process.exitCode=1;
  } catch(e) { process.stdout.write(`${JSON.stringify({ok:false,error:e.message})}\n`); process.exitCode=1; }
}
