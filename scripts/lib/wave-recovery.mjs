// Explicit remediation authority; never settlement or convergence proof.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
import {fullProof} from './full-gate-proof.mjs';import {verifyFocused} from '../producer-admission.mjs';
export const digest=x=>crypto.createHash('sha256').update(x).digest('hex');
function need(x,s){if(!x)throw Error(`recovery_${s}`);}
function git(repo,...a){const r=spawnSync('git',['-C',repo,...a],{encoding:'utf8',windowsHide:true});need(r.status===0,'git_identity_unavailable');return r.stdout.trim();}
function session(repo,commit){const last=git(repo,'show','-s','--format=%B',commit).split(/\r?\n/).pop();need(last.startsWith('Agent:'),'agent_anchor_required');const m=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];need(m.length===1,'agent_session_required');return m[0][1];}
export function recoverySnapshot(store,wave){const db=new DatabaseSync(path.join(store,'waves.sqlite'),{readOnly:true});try{const row=db.prepare('SELECT * FROM waves WHERE id=?').get(wave);need(row,'wave_missing');return {row,snapshot:digest(JSON.stringify({row,steps:db.prepare('SELECT * FROM steps WHERE wave=? ORDER BY position').all(wave),events:db.prepare('SELECT * FROM events WHERE wave=? ORDER BY sequence').all(wave)})),registration:digest(fs.readFileSync(path.join(store,'registration.json')))};}finally{db.close();}}
export function recoveryAdmission(repo,store,{phase,recovery,original_refusal,named}, {reservation=null}={}){
 need(['admit','land'].includes(phase),'action_forbidden');
 need(recovery&&typeof recovery.receipt_file==='string','receipt_file_required');
 const envelope=JSON.parse(fs.readFileSync(recovery.receipt_file,'utf8'));
 need(/^[a-f0-9]{40}$/.test(envelope.commit||'')&&/^recovery\/[a-zA-Z0-9._-]+\.json$/.test(envelope.path||''),'immutable_receipt_anchor_required');
 const raw=git(repo,'show',`${envelope.commit}:${envelope.path}`),ticket=JSON.parse(raw);
 need(envelope.sha256===digest(raw),'receipt_bytes_mismatch');
 need(ticket.schema===1&&ticket.kind==='wave-recovery-admission','receipt_kind');
 const registration=JSON.parse(fs.readFileSync(path.join(store,'registration.json'))),canonical=fs.realpathSync(registration.repo);
 need(fs.realpathSync(ticket.repo)===canonical,'canonical_repo_mismatch');
 const common=fs.realpathSync(git(canonical,'rev-parse','--path-format=absolute','--git-common-dir'));
 need(fs.realpathSync(path.dirname(store))===common,'shared_store_mismatch');
 const snap=recoverySnapshot(store,ticket.wave);
 need(ticket.owner===registration.owner&&ticket.owner===snap.row.owner&&session(repo,envelope.commit)===ticket.owner,'owner_authority_mismatch');
 need(ticket.snapshot===snap.snapshot&&ticket.registration===snap.registration&&ticket.manifest===snap.row.manifest_hash&&ticket.legacy===digest(snap.row.legacy||''),'snapshot_moved');
 need(ticket.expected_main===git(canonical,'rev-parse','refs/heads/main')&&ticket.expected_main===git(canonical,'rev-parse','refs/remotes/origin/main'),'main_moved');
 need(Number.isSafeInteger(ticket.expires)&&ticket.expires>Date.now()&&ticket.expires<=Date.now()+86400000,'expired_or_unbounded');
 need(Array.isArray(ticket.entries)&&ticket.entries.length>0&&ticket.entries.length<=16,'enumeration_required');
 const entry=ticket.entries.find(x=>x.branch===recovery.delivery&&x.tip===recovery.tip&&x.tree===recovery.tree&&x.action===phase);
 need(recovery.expected_main===ticket.expected_main&&entry?.review_commit===recovery.review_commit&&entry?.reviewer===recovery.reviewer,'consumer_identity_mismatch');
 need(entry&&ticket.entries.filter(x=>x.nonce===entry.nonce).length===1&&/^[a-f0-9]{32}$/.test(entry.nonce),'exact_entry_required');
 need(/^change\/[a-zA-Z0-9._/-]+$/.test(entry.branch)&&!entry.branch.includes('..')&&git(repo,'rev-parse',`refs/heads/${entry.branch}`)===entry.tip&&git(repo,'rev-parse',`${entry.tip}^{tree}`)===entry.tree,'delivery_moved');
 need(entry.producer&&entry.reviewer&&entry.producer!==entry.reviewer&&session(repo,entry.tip)===entry.producer&&session(repo,entry.review_commit)===entry.reviewer,'independent_review_required');
 const review=JSON.parse(git(repo,'show',`${entry.review_commit}:${entry.review_path}`));
 need(review.tip===entry.tip&&review.tree===entry.tree&&review.producer===entry.producer&&review.reviewer===entry.reviewer&&['passed','narrowed'].includes(review.verdict)&&review.scope==='full-delivery','review_binding');
 need(!review.findings?.some(x=>x.class==='summary_exceeds_code'&&x.status==='unresolved'),'review_blocked');
 const evidence=JSON.parse(git(repo,'show',`${entry.evidence_commit}:${entry.evidence_path}`));
 need(fullProof(evidence,entry.tree,{ownerRepo:repo}).verified||verifyFocused(repo,evidence,entry.tip).admission_verified,'source_evidence_required');
 // No caller-prose target settlement: existing resource/operation inspection must
 // be independently reviewed and committed for exact intended effect target.
 const target=JSON.parse(git(repo,'show',`${entry.review_commit}:${entry.target_path}`));
 need(target.schema===1&&target.kind==='recovery-target-inspection'&&target.main===ticket.expected_main&&target.action===phase&&target.tip===entry.tip&&target.target===canonical&&target.reviewer===entry.reviewer&&target.conflicts==='none'&&Array.isArray(target.artifacts)&&target.artifacts.length>0,'target_ownership_unknown');
 for(const a of target.artifacts){need(a.path&&/^[a-f0-9]{64}$/.test(a.sha256)&&digest(fs.readFileSync(a.path))===a.sha256,'target_evidence_moved');}
 need(!fs.existsSync(path.join(store,'freeze.json')),'closing_frozen');
 const consumption=path.join(store,'recovery-consumption.sqlite');
 if(reservation)need(!reservation.prepare('SELECT 1 FROM consumed WHERE nonce=?').get(entry.nonce),'already_consumed_or_uncertain');
 else if(fs.existsSync(consumption)){const db=new DatabaseSync(consumption,{readOnly:true});try{need(!db.prepare('SELECT 1 FROM consumed WHERE nonce=?').get(entry.nonce),'already_consumed_or_uncertain');}finally{db.close();}}
 // Check never creates a consumption database or mutates the wave.
 return {ok:true,recovery_admitted:true,wave_verified:false,wave_id:ticket.wave,phase,...named,original_refusal,consumption:'not_consumed',nonce:entry.nonce,ticket_hash:digest(raw),ticket_commit:envelope.commit,delivery:entry.branch,tip:entry.tip,tree:entry.tree,review_commit:entry.review_commit,reviewer:entry.reviewer,expected_main:ticket.expected_main,snapshot:snap.snapshot,note:'read-only remediation check; landing consumer must reserve separately'};
}
// Reservation is not effect success. Lost response remains uncertain forever;
// no prose settlement/retry endpoint exists.
export function consumeRecovery(repo,store,context) {
 recoveryAdmission(repo,store,context); // full fresh validation before any write
 const db=new DatabaseSync(path.join(store,'recovery-consumption.sqlite'));
 try {
  db.exec('PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS consumed(nonce TEXT PRIMARY KEY, binding TEXT NOT NULL, state TEXT NOT NULL)');
  db.exec('BEGIN IMMEDIATE');
  try {
   const checked=recoveryAdmission(repo,store,context,{reservation:db});
   db.prepare('INSERT INTO consumed VALUES(?,?,?)').run(checked.nonce,JSON.stringify(checked),'uncertain');
   db.exec('COMMIT');
   return {...checked,consumption:'uncertain',effect_authorized:false,note:'reservation only; consumer must hold target resource/CAS and revalidate before effect'};
  } catch(error){db.exec('ROLLBACK');throw error;}
 } finally {db.close();}
}
