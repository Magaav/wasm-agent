// Explicit remediation authority; never settlement or convergence proof.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
import {fullProof} from './full-gate-proof.mjs';import {verifyFocused} from '../producer-admission.mjs';
import {mainOnly,managedLocal} from './delivery-local.mjs';
import {externalCustody} from './wave-recovery-custody.mjs';
export const digest=x=>crypto.createHash('sha256').update(x).digest('hex');
function need(x,s){if(!x)throw Error(`recovery_${s}`);}
function git(repo,...a){const r=spawnSync('git',['-C',repo,...a],{encoding:'utf8',windowsHide:true});need(r.status===0,'git_identity_unavailable');return r.stdout.trim();}
function session(repo,commit){const last=git(repo,'show','-s','--format=%B',commit).split(/\r?\n/).pop();need(last.startsWith('Agent:'),'agent_anchor_required');const m=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];need(m.length===1,'agent_session_required');return m[0][1];}
export function recoverySnapshot(store,wave){const db=new DatabaseSync(path.join(store,'waves.sqlite'),{readOnly:true});try{const row=db.prepare('SELECT * FROM waves WHERE id=?').get(wave);need(row,'wave_missing');return {row,snapshot:digest(JSON.stringify({row,steps:db.prepare('SELECT * FROM steps WHERE wave=? ORDER BY position').all(wave),events:db.prepare('SELECT * FROM events WHERE wave=? ORDER BY sequence').all(wave)})),registration:digest(fs.readFileSync(path.join(store,'registration.json')))};}finally{db.close();}}
export function recoveryAdmission(repo,store,{phase,recovery,original_refusal,named}, {reservation=null,native=null,source=null,reserved=null}={}){
 need(['admit','land'].includes(phase),'action_forbidden');
 need(recovery&&typeof recovery.receipt_file==='string','receipt_file_required');
 const envelope=JSON.parse(fs.readFileSync(recovery.receipt_file,'utf8'));
 need(/^[a-f0-9]{40}$/.test(envelope.commit||'')&&/^recovery\/[a-zA-Z0-9._-]+\.json$/.test(envelope.path||''),'immutable_receipt_anchor_required');
 const raw=git(repo,'show',`${envelope.commit}:${envelope.path}`),ticket=JSON.parse(raw);
 need(envelope.sha256===digest(raw),'receipt_bytes_mismatch');
 need([1,2].includes(ticket.schema)&&ticket.kind==='wave-recovery-admission','receipt_kind');
 const registration=JSON.parse(fs.readFileSync(path.join(store,'registration.json'))),canonical=fs.realpathSync(registration.repo);
 need(fs.realpathSync(ticket.repo)===canonical,'canonical_repo_mismatch');
 const common=fs.realpathSync(git(canonical,'rev-parse','--path-format=absolute','--git-common-dir'));
 need(fs.realpathSync(path.dirname(store))===common,'shared_store_mismatch');
 const snap=recoverySnapshot(store,ticket.wave);
 need(ticket.owner===registration.owner&&ticket.owner===snap.row.owner,'owner_authority_mismatch');
 const issuer=session(repo,envelope.commit);
 let currentBinding=null;
 if(ticket.schema===2||ticket.current_issuer_binding){
  const ref=ticket.current_issuer_binding;need(ref,'current_issuer_binding_required');
  currentBinding=JSON.parse(git(repo,'show',`${ref.commit}:${ref.path}`));
  need(currentBinding.schema===2&&currentBinding.kind==='wave-current-issuer-binding'&&currentBinding.wave===ticket.wave&&currentBinding.owner_label===ticket.owner&&currentBinding.issuer_session===issuer&&currentBinding.registration_sha256===snap.registration,'current_issuer_binding_mismatch');
  need(session(repo,ref.commit)===issuer,'current_issuer_provenance');
  const approval=JSON.parse(git(repo,'show',`${ref.review_commit}:${ref.review_path}`));
  need(approval.schema===2&&approval.kind==='wave-current-issuer-binding-review'&&approval.descriptor_commit===ref.commit&&approval.descriptor_path===ref.path&&approval.descriptor_sha256===digest(git(repo,'show',`${ref.commit}:${ref.path}`))&&approval.verdict==='passed'&&approval.reviewer!==issuer&&session(repo,ref.review_commit)===approval.reviewer,'current_issuer_independent_review');
  need(currentBinding.effect==='canonical-local-main-cas'&&currentBinding.repo===canonical&&currentBinding.ref==='refs/heads/main'&&typeof currentBinding.native_principal==='string'&&typeof currentBinding.native_session==='string'&&typeof currentBinding.resource_data==='string','current_issuer_scope');
  need(Array.isArray(currentBinding.historical_facts)&&currentBinding.historical_facts.every(a=>a.path&&/^[a-f0-9]{64}$/.test(a.sha256)&&digest(fs.readFileSync(a.path))===a.sha256),'current_issuer_historical_facts_moved');
  if(source)need(source.schema===2&&source.tip===currentBinding.source_tip&&source.tree===currentBinding.source_tree&&source.authority===currentBinding.authority,'current_source_binding');
  if(native){
   need(source&&native.receipt?.principal===currentBinding.native_principal&&native.receipt.session===currentBinding.native_session&&fs.realpathSync(native.data)===fs.realpathSync(currentBinding.resource_data),'current_native_owner_binding');
   const normalize=p=>{const nativePath=p.replace(/^\/\/\?\/unc\//i,'//').replace(/^\/\/\?\//,'');const value=fs.realpathSync(nativePath).replaceAll('\\','/').replace(/^\/\/\?\//,'');return process.platform==='win32'?value.toLowerCase():value;};
   need(native.receipt.scope?.ref==='refs/heads/main'&&normalize(native.receipt.scope.git_common_dir)===normalize(common),'current_native_target_scope');
  }
 }else if(issuer!==ticket.owner){
  need(ticket.issuer_binding,'issuer_descriptor_required');
  const ref=ticket.issuer_binding,descriptor=JSON.parse(git(repo,'show',`${ref.commit}:${ref.path}`));
  need(descriptor.schema===1&&descriptor.kind==='wave-issuer-binding'&&descriptor.wave===ticket.wave&&descriptor.owner_label===ticket.owner&&descriptor.issuer_session===issuer&&descriptor.registration_sha256===snap.registration,'issuer_descriptor_mismatch');
  need(session(repo,ref.commit)===issuer,'issuer_descriptor_provenance');
  need(registration.attestation&&digest(fs.readFileSync(registration.attestation))===descriptor.attestation_sha256&&descriptor.attestation_sha256===registration.attestation_sha256,'issuer_attestation_moved');
  need(Array.isArray(descriptor.original_evidence)&&descriptor.original_evidence.length>=2&&descriptor.original_evidence.every(x=>x.message_id&&x.path&&/^[a-f0-9]{64}$/.test(x.sha256)&&digest(fs.readFileSync(x.path))===x.sha256),'issuer_original_evidence_required');
  const acceptance=JSON.parse(git(repo,'show',`${ref.review_commit}:${ref.review_path}`));
  need(acceptance.kind==='wave-issuer-binding-review'&&acceptance.descriptor_commit===ref.commit&&acceptance.descriptor_path===ref.path&&acceptance.descriptor_sha256===digest(git(repo,'show',`${ref.commit}:${ref.path}`))&&acceptance.verdict==='passed'&&acceptance.reviewer!==issuer&&session(repo,ref.review_commit)===acceptance.reviewer,'issuer_descriptor_independent_review_required');
  // Operator-local issuance, not cryptographic human approval. Old attestation
  // reviewer labels are retained, never promoted to authenticated approval.
 }
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
 let custody=null,evidenceRepo=repo;
 if(ticket.schema===2){
  need(mainOnly(canonical),'main_only_policy_required');
  const privateDb=currentBinding.authority==='private-fixture'?currentBinding.private_session_db:null;
  custody=currentBinding.external_custody?externalCustody(repo,currentBinding.external_custody,entry):{producer:managedLocal(repo,entry.producer,entry.tip,privateDb,entry.branch),reviewer:managedLocal(repo,entry.reviewer,entry.review_commit,privateDb)};
  evidenceRepo=custody.producer.worktree;
 }
 need(fullProof(evidence,entry.tree,{ownerRepo:repo}).verified||verifyFocused(evidenceRepo,evidence,entry.tip).admission_verified,'source_evidence_required');
 // No caller-prose target settlement: existing resource/operation inspection must
 // be independently reviewed and committed for exact intended effect target.
 const target=JSON.parse(git(repo,'show',`${entry.review_commit}:${entry.target_path}`));
 need(target.schema===1&&target.kind==='recovery-target-inspection'&&target.main===ticket.expected_main&&target.action===phase&&target.tip===entry.tip&&target.target===canonical&&target.reviewer===entry.reviewer&&target.conflicts==='none'&&Array.isArray(target.artifacts)&&target.artifacts.length>0,'target_ownership_unknown');
 for(const a of target.artifacts){need(a.path&&/^[a-f0-9]{64}$/.test(a.sha256)&&digest(fs.readFileSync(a.path))===a.sha256,'target_evidence_moved');}
 need(!fs.existsSync(path.join(store,'freeze.json')),'closing_frozen');
 const consumption=path.join(store,'recovery-consumption.sqlite');
 if(reservation)need(!reservation.prepare('SELECT 1 FROM consumed WHERE nonce=?').get(entry.nonce),'already_consumed_or_uncertain');
 else if(fs.existsSync(consumption)){const db=new DatabaseSync(consumption,{readOnly:true});try{
  const used=db.prepare('SELECT binding FROM consumed WHERE nonce=?').get(entry.nonce);
  if(used&&reserved){const held=JSON.parse(used.binding);need(JSON.stringify(held)===JSON.stringify(reserved.reservation_binding)&&held.ticket_hash===digest(raw)&&held.ticket_commit===envelope.commit&&held.snapshot===snap.snapshot&&held.tip===entry.tip&&held.tree===entry.tree&&held.review_commit===entry.review_commit&&held.expected_main===ticket.expected_main,'reservation_binding_moved');}
  else need(!used,'already_consumed_or_uncertain');
 }finally{db.close();}}
 // Check never creates a consumption database or mutates the wave.
 return {ok:true,recovery_admitted:true,wave_verified:false,wave_id:ticket.wave,phase,...named,original_refusal,consumption:'not_consumed',nonce:entry.nonce,ticket_hash:digest(raw),ticket_commit:envelope.commit,delivery:entry.branch,tip:entry.tip,tree:entry.tree,review_commit:entry.review_commit,reviewer:entry.reviewer,expected_main:ticket.expected_main,snapshot:snap.snapshot,current_binding:currentBinding,custody,native_receipt:native?.receipt||null,native_child:native?.child||null,source_bound:source?{tip:source.tip,tree:source.tree,review_commit:source.review_commit,runtime:source.runtime}:null,note:'read-only remediation check; landing consumer must reserve separately'};
}
// Reservation is not effect success. Lost response remains uncertain forever;
// no prose settlement/retry endpoint exists.
export function consumeRecovery(repo,store,context,authority={}) {
 recoveryAdmission(repo,store,context,authority); // full fresh validation before any write
 const db=new DatabaseSync(path.join(store,'recovery-consumption.sqlite'));
 try {
  db.exec('PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS consumed(nonce TEXT PRIMARY KEY, binding TEXT NOT NULL, state TEXT NOT NULL)');
  db.exec('BEGIN IMMEDIATE');
  try {
   const checked=recoveryAdmission(repo,store,context,{...authority,reservation:db});
   db.prepare('INSERT INTO consumed VALUES(?,?,?)').run(checked.nonce,JSON.stringify(checked),'uncertain');
   db.exec('COMMIT');
   return {...checked,reservation_binding:checked,consumption:'uncertain',effect_authorized:false,note:'reservation only; consumer must hold target resource/CAS and revalidate before effect'};
  } catch(error){db.exec('ROLLBACK');throw error;}
 } finally {db.close();}
}
