// Explicit opt-in current source decision. Historical unknown effects stay unknown.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {spawn,spawnSync} from 'node:child_process';import {once} from 'node:events';import {DatabaseSync} from 'node:sqlite';import {isDeepStrictEqual as equal} from 'node:util';
import {digest} from './wave-recovery.mjs';import {verifyRecoverySource} from './wave-recovery-source.mjs';import {externalCustody} from './wave-recovery-custody.mjs';import {fullProof} from './full-gate-proof.mjs';import * as producerEvidence from '../producer-admission.mjs';import {mainOnly} from './delivery-local.mjs';import {requireCurrentSource} from './wave-current-source-native.mjs';
const need=(v,s)=>{if(!v)throw Error('current_source_'+s);};
const real=p=>fs.realpathSync(p),norm=p=>{const input=p.replaceAll('\\','/').replace(/^\/\/\?\/unc\//i,'//').replace(/^\/\/\?\//,'');const r=real(input).replaceAll('\\','/').replace(/^\/\/\?\//,'');return process.platform==='win32'?r.toLowerCase():r;};
const hex=x=>/^[0-9a-f]{40}$/.test(x||'');
function git(repo,...args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true,maxBuffer:128*1024*1024});need(r.status===0,'git_refused:'+String(r.stderr||r.error));return r.stdout.trim();}
function raw(repo,ref){need(ref&&hex(ref.commit)&&/^[a-zA-Z0-9._/-]+$/.test(ref.path||'')&&!ref.path.split('/').includes('..'),'immutable_anchor');const r=spawnSync('git',['-C',repo,'show',ref.commit+':'+ref.path],{windowsHide:true,maxBuffer:128*1024*1024});need(r.status===0,'anchor_missing');return r.stdout;}
function actor(repo,commit){const last=git(repo,'show','-s','--format=%B',commit).split(/\r?\n/).pop(),matches=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];need(last.startsWith('Agent:')&&matches.length===1,'actor_anchor');return matches[0][1];}
function artifact(a){need(a?.path&&/^[a-f0-9]{64}$/.test(a.sha256||''),'artifact_required');const bytes=fs.readFileSync(a.path);need(digest(bytes)===a.sha256,'artifact_changed');return bytes;}
export function readCurrentUserRecord(file,line,expected){
 need(Number.isSafeInteger(line)&&line>0&&/^[a-f0-9]{64}$/.test(expected||''),'user_record_reference');
 const fileBytes=fs.readFileSync(file);let start=0;
 for(let n=1;n<line;n++){const end=fileBytes.indexOf(10,start);need(end>=0,'user_record_line_missing');start=end+1;}
 need(start<fileBytes.length,'user_record_line_missing');const newline=fileBytes.indexOf(10,start),end=newline<0?fileBytes.length:newline+1,raw=fileBytes.subarray(start,end);
 let content=raw;if(content.at(-1)===10){content=content.subarray(0,-1);if(content.at(-1)===13)content=content.subarray(0,-1);}
 // Both historical capture conventions are explicit original byte slices;
 // never rehash/rewrite an artifact to substitute our preferred convention.
 const matched=digest(raw)===expected?raw:digest(content)===expected?content:null;
 need(matched,'user_record_raw_bytes_mismatch');
 return {record:JSON.parse(content.toString('utf8')),bytes:matched,terminator_included:matched.length===raw.length&&raw.length!==content.length};
}
export function validateCurrentGrant(repo,descriptor,envelope,native){
 // Shared ordinary proof readers resolve `git`; reject a shadow runner rather
 // than letting PATH/cwd substitute unreviewed executable bytes.
 const filename=process.platform==='win32'?'git.exe':'git';
 const candidates=[process.cwd(),repo,descriptor.root,...(process.env.PATH||'').split(path.delimiter)].map(dir=>path.join(dir,filename));
 const selected=candidates.find(file=>fs.existsSync(file));need(selected&&norm(selected)===norm(descriptor.runtime.git.path),'git_runner_shadowed');
 const source=verifyRecoverySource(repo,descriptor),bytes=raw(repo,envelope),grant=JSON.parse(bytes),review=JSON.parse(raw(repo,envelope.review));
 need(digest(bytes)===envelope.sha256&&grant.schema===1&&grant.kind==='wave-current-ref-source-grant','typed_grant');
 need(review.kind==='wave-current-ref-source-grant-review'&&review.verdict==='passed'&&review.descriptor_commit===envelope.commit&&review.descriptor_path===envelope.path&&review.descriptor_sha256===envelope.sha256&&review.reviewer!==grant.actor?.session&&actor(repo,envelope.review.commit)===review.reviewer&&actor(repo,envelope.commit)===grant.actor.session,'independent_current_grant_review');
 need(grant.actor.role==='delegated-operator'&&['operator-delegated','private-fixture'].includes(grant.authority)&&grant.effect==='canonical-current-ref-source-cas'&&grant.publication==='canonical-local-only'&&grant.global_identity_safety===false&&grant.production_registry_admission===false&&grant.historical_effects==='unknown-preserved'&&grant.risk_contract==='current-ref-only-unclassified-effects-remain-possible','scope_contract');
 need(grant.source_tip===source.tip&&grant.source_tree===source.tree&&grant.source_review_commit===source.review_commit&&grant.source_review_path===source.review_path&&grant.authority===(source.authority==='private-fixture'?'private-fixture':'operator-delegated'),'source_binding');
 need(native?.kind==='current-native-executor-observation'&&native.global_identity_safety===false&&native.production_registry_admission===false&&equal(grant.executor,{context:native.context,process_id:native.process_id,creation_stamp:native.creation_stamp,resource_root:native.resource_root}),'native_owner_binding');
 need(grant.child_policy==='owned-direct-native-child'&&native.child?.process_id===process.pid&&native.child.parent_process_id===native.process_id,'native_child_binding');
 const user=JSON.parse(artifact(grant.user_task));need(user.kind==='current-user-task-source-evidence'&&user.role==='user'&&user.source_session===grant.actor.source_user_session&&Number.isSafeInteger(user.source_line)&&user.source_line>0,'current_user_source');
 need(equal(source.runtime.current_user_task,{source_session:user.source_session,source_record_sha256:user.source_record_sha256})&&grant.task_contract==='original-deliveries-then-root-chatfix-then-clean-deploy','reviewed_current_task_contract');
 need(user.source_record_sha256===grant.user_record_sha256,'current_user_raw_record');const event=readCurrentUserRecord(user.source_path,user.source_line,user.source_record_sha256).record;need(event.type==='response_item'&&event.payload?.type==='message'&&event.payload.role==='user'&&event.payload.content.filter(c=>c.type==='input_text').map(c=>c.text).join('\n')===user.text,'current_user_record_identity');
 const gate=JSON.parse(artifact(grant.user_gate_decision));
 need(gate.schema===1&&gate.kind==='current-user-gate-decision-source'&&gate.source_session===user.source_session&&gate.gate_policy==='pre-release-only'&&Array.isArray(gate.records)&&gate.records.length>0,'current_user_gate_decision');
 need(equal(source.runtime.current_user_gate_decision,{source_session:gate.source_session,records:gate.records.map(r=>({source_line:r.source_line,source_record_sha256:r.source_record_sha256})),gate_policy:gate.gate_policy}),'reviewed_gate_decision_binding');
 for(const statement of gate.records){need(statement.role==='user','gate_user_raw_record');const parsed=readCurrentUserRecord(statement.source_path,statement.source_line,statement.source_record_sha256).record;need(parsed.type==='response_item'&&parsed.payload?.type==='message'&&parsed.payload.role==='user'&&parsed.payload.content.filter(c=>c.type==='input_text').map(c=>c.text).join('\n')===statement.text,'gate_user_record_identity');}
 if(grant.authority==='private-fixture'){const temp=norm(os.tmpdir());need([repo,user.source_path,grant.user_task.path,grant.legacy_snapshot.path].every(p=>norm(p).startsWith(temp+'/'))&&grant.fixture_label==='private-current-source-grant','private_fixture_scope');}
 const legacy=JSON.parse(artifact(grant.legacy_snapshot));need(legacy.kind==='registered-target-observation'&&legacy.read_only===true&&legacy.complete===true&&legacy.admissible===false&&legacy.effect_authorized===false&&Array.isArray(legacy.claims)&&legacy.scope.ref==='refs/heads/main'&&norm(legacy.scope.git_common_dir)===norm(grant.git_common_dir),'complete_legacy_raw_snapshot');
 need(norm(repo)===norm(grant.repo)&&norm(git(repo,'rev-parse','--path-format=absolute','--git-common-dir'))===norm(grant.git_common_dir)&&grant.ref==='refs/heads/main','canonical_scope');
 need(mainOnly(repo)&&git(repo,'symbolic-ref','--short','HEAD')==='main','canonical_policy');
 const symbolic=spawnSync('git',['-C',repo,'symbolic-ref','-q','refs/heads/main'],{encoding:'utf8',windowsHide:true});need(symbolic.status===1,'symbolic_main_forbidden');
 need(hex(grant.expected_main)&&git(repo,'rev-parse','HEAD')===grant.expected_main&&git(repo,'rev-parse','refs/remotes/origin/main')===grant.expected_main,'main_generation');
 need(git(repo,'remote','get-url','origin')===grant.origin_url&&git(repo,'ls-remote','--heads','origin')===grant.expected_main+'\trefs/heads/main','exact_origin');
 need(Number.isSafeInteger(grant.expires)&&grant.expires>Date.now()&&grant.expires<=Date.now()+86400000&&/^[a-f0-9]{32}$/.test(grant.nonce||''),'expiry_nonce');
 const delivery=grant.delivery;need(hex(delivery?.tip)&&hex(delivery.tree)&&hex(grant.candidate_head)&&hex(grant.candidate_tree)&&git(repo,'rev-parse',delivery.tip+'^{tree}')===delivery.tree&&git(repo,'rev-parse','refs/heads/'+delivery.branch)===delivery.tip,'delivery_generation');
 need(delivery.producer!==delivery.reviewer&&actor(repo,delivery.tip)===delivery.producer&&actor(repo,delivery.review.commit)===delivery.reviewer,'delivery_actors');
 const decision=JSON.parse(raw(repo,delivery.review));need(decision.scope==='full-delivery'&&['passed','narrowed'].includes(decision.verdict)&&decision.tip===delivery.tip&&decision.tree===delivery.tree&&decision.producer===delivery.producer&&decision.reviewer===delivery.reviewer&&!decision.findings?.some(f=>f.status==='unresolved'&&f.class==='summary_exceeds_code'),'delivery_review');
 const custody=externalCustody(repo,grant.custody,{...delivery,review_commit:delivery.review.commit});
 const evidence=JSON.parse(raw(repo,delivery.evidence));
 let focused;
 if(evidence.focused_scope){
  need(typeof producerEvidence.verifyReviewedFocused==='function','routine_reader_dependency_required');
  focused=producerEvidence.verifyReviewedFocused(custody.producer.worktree,evidence,{...decision,commit:delivery.review.commit},delivery.tip,delivery.producer);
 }else focused=producerEvidence.verifyFocused(custody.producer.worktree,evidence,delivery.tip);
 // The ordinary reader owns routine/release policy and verifies the actual
 // original source/runner/log bytes. This consumer neither fabricates a full
 // proof nor broadens that reader's supported focused scope.
 need(fullProof(evidence,delivery.tree,{ownerRepo:repo}).verified||focused.admission_verified,'genuine_producer_proof');
 need(git(repo,'rev-parse',grant.candidate_head+'^{tree}')===grant.candidate_tree&&git(repo,'show','-s','--format=%P',grant.candidate_head)===grant.expected_main+' '+delivery.tip&&git(repo,'merge-tree','--write-tree',grant.expected_main,delivery.tip)===grant.candidate_tree&&actor(repo,grant.candidate_head)===grant.actor.session,'exact_candidate');
 need(!git(repo,'status','--porcelain','--untracked-files=all')&&git(repo,'write-tree')===git(repo,'rev-parse',grant.expected_main+'^{tree}'),'clean_index_worktree');
 return {grant,source,custody,binding:digest(bytes)};
}
export async function landCurrentSource(repo,descriptor,envelope,control){
 let native=requireCurrentSource(control),checked=validateCurrentGrant(repo,descriptor,envelope,native);
 const store=path.join(checked.grant.git_common_dir,'wa-waves');fs.mkdirSync(store,{recursive:true});
 const publication=new DatabaseSync(path.join(store,'recovery-target-lease.sqlite'));let transaction,requests,reserved=false,committed=false,output='',stderr='';
 try{
  publication.exec('PRAGMA busy_timeout=0;CREATE TABLE IF NOT EXISTS lease(id INTEGER PRIMARY KEY,identity TEXT);BEGIN IMMEDIATE');
  const grant=checked.grant;
  transaction=spawn(checked.source.runtime.git.path,['-C',repo,'update-ref','--stdin'],{stdio:['pipe','pipe','pipe'],windowsHide:true});const exited=once(transaction,'exit');transaction.stdout.on('data',b=>output+=b);transaction.stderr.on('data',b=>stderr+=b);
  const acknowledgement=async marker=>{const deadline=Date.now()+10000;while(!output.includes(marker)){need(transaction.exitCode===null&&Date.now()<deadline,'prepared_transaction_lost:'+stderr);await new Promise(r=>setTimeout(r,10));}};
  transaction.stdin.write(`start\nupdate refs/heads/main ${grant.candidate_head} ${grant.expected_main}\nprepare\n`);await acknowledgement('prepare: ok');
  native=requireCurrentSource(control);checked=validateCurrentGrant(repo,descriptor,envelope,native);
  requests=new DatabaseSync(path.join(store,'current-source-consumption.sqlite'));requests.exec('PRAGMA synchronous=FULL;CREATE TABLE IF NOT EXISTS requests(nonce TEXT PRIMARY KEY,binding TEXT NOT NULL,state TEXT NOT NULL);BEGIN IMMEDIATE');
  need(!requests.prepare('SELECT 1 FROM requests WHERE nonce=?').get(grant.nonce),'nonce_consumed_or_uncertain');requests.prepare('INSERT INTO requests VALUES(?,?,?)').run(grant.nonce,checked.binding,'uncertain');requests.exec('COMMIT');reserved=true;
  requireCurrentSource(control);need(validateCurrentGrant(repo,descriptor,envelope,requireCurrentSource(control)).binding===checked.binding,'grant_changed_after_reservation');
  transaction.stdin.write('commit\n');transaction.stdin.end();await exited;need(transaction.exitCode===0&&output.includes('commit: ok'),'commit_unknown:'+stderr);committed=true;
  // Acquire a prepared verify transaction for synchronization/readback. Any
  // writer in the small handoff gap changes the expected generation and refuses.
  output='';stderr='';transaction=spawn(checked.source.runtime.git.path,['-C',repo,'update-ref','--stdin'],{stdio:['pipe','pipe','pipe'],windowsHide:true});
  transaction.stdout.on('data',b=>output+=b);transaction.stderr.on('data',b=>stderr+=b);
  transaction.stdin.write(`start\nverify refs/heads/main ${grant.candidate_head}\nprepare\n`);await acknowledgement('prepare: ok');
  // Dirty bytes are never discarded; failed two-tree synchronization leaves the
  // fresh nonce uncertain, and cannot be retried as another source effect.
  need(!git(repo,'diff','--name-only',grant.expected_main)&&!git(repo,'ls-files','--others','--exclude-standard'),'post_cas_dirty_uncertain');
  git(repo,'read-tree','-u','-m',grant.expected_main,grant.candidate_head);
  need(git(repo,'rev-parse','HEAD')===grant.candidate_head&&git(repo,'write-tree')===grant.candidate_tree&&!git(repo,'status','--porcelain','--untracked-files=all'),'readback_uncertain');
  need(git(repo,'remote','get-url','origin')===grant.origin_url&&git(repo,'ls-remote','--heads','origin')===grant.expected_main+'\trefs/heads/main','remote_readback_uncertain');requireCurrentSource(control);artifact(grant.legacy_snapshot);
  need(git(repo,'rev-parse','HEAD')===grant.candidate_head&&git(repo,'write-tree')===grant.candidate_tree&&!git(repo,'status','--porcelain','--untracked-files=all'),'final_readback_uncertain');
  requests.prepare('UPDATE requests SET state=? WHERE nonce=? AND binding=?').run('observed-local',grant.nonce,checked.binding);
  return {ok:true,kind:'current-source-local-readback',landing:grant.candidate_head,tree:grant.candidate_tree,nonce:grant.nonce,grant_binding:checked.binding,global_identity_safety:false,production_registry_admission:false,remote:{main:grant.expected_main,published:false},native,legacy_preserved:true,publication_scope:'canonical-local',wave_verified:false};
 }catch(error){return {ok:false,error:error.message,reserved,committed,uncertain:reserved,global_identity_safety:false,production_registry_admission:false};}
 finally{if(transaction&&transaction.exitCode===null){const done=once(transaction,'exit');transaction.stdin.destroy();transaction.kill();await done;}if(requests)requests.close();try{publication.exec('ROLLBACK');}catch{}publication.close();}
}
