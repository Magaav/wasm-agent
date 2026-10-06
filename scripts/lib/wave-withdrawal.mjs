// Explicit retirement of a migrated plan that never admitted a wave effect.
// Not execution settlement, convergence proof, or permission to replay effects.
import crypto from 'node:crypto';
const hash=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
const fail=reason=>{throw Error(reason);};
export function withdrawalSnapshot(db,row) {
  return {row,steps:db.prepare('SELECT * FROM steps WHERE wave=? ORDER BY position').all(row.id),
    events:db.prepare('SELECT * FROM events WHERE wave=? ORDER BY sequence').all(row.id)};
}
export function withdrawalProof(row) {
  if(row.state!=='withdrawn')return null;
  let proof;try{proof=JSON.parse(row.withdrawal);}catch{fail('wave_withdrawal_receipt_unverifiable');}
  const old=proof?.original?.row,steps=proof?.original?.steps,events=proof?.original?.events;
  if(!proof || typeof proof!=='object')fail('wave_withdrawal_receipt_unverifiable');
  let manifest;try{manifest=JSON.parse(old?.manifest);}catch{fail('wave_withdrawal_manifest_unverifiable');}
  if(hash(manifest)!==old?.manifest_hash || manifest.id!==row.id)fail('wave_withdrawal_manifest_unverifiable');
  if(proof.schema!==1 || proof.kind!=='never-admitted-wave-withdrawal' || proof.wave_id!==row.id ||
     !proof.actor?.trim() || !proof.evidence?.trim() || proof.convergence_verified!==false || proof.effects_replayed!==false ||
     !old || old.id!==row.id || old.state!=='pending' || !old.legacy || old.boot || old.pid || old.receipt ||
     proof.snapshot_sha256!==hash(proof.original))fail('wave_withdrawal_receipt_unverifiable');
  for(const key of Object.keys(old))if(!['state','updated_at','withdrawal'].includes(key) && JSON.stringify(old[key])!==JSON.stringify(row[key]))fail('wave_withdrawal_original_moved:'+key);
  if(!Array.isArray(steps)||steps.length!==3||steps.map(s=>s.name).join(',')!=='land,deploy,retire' ||
     steps.some(s=>s.state!=='pending'||s.attempts!==0||s.post_attempts!==0||s.operation_id||s.result||s.next_at!==0))fail('wave_withdrawal_effect_history_unverifiable');
  if(!Array.isArray(events)||!events.length || events.some(e=>!['created','resolution_observed','legacy_state_migrated'].includes(e.type)))fail('wave_withdrawal_effect_history_unverifiable');
  return proof;
}
export function validateWithdrawal(db,row) {
  const proof=withdrawalProof(row);if(!proof)return null;
  const current=withdrawalSnapshot(db,row);
  if(hash(current.steps)!==hash(proof.original.steps))fail('wave_withdrawal_steps_moved');
  const original=current.events.filter(e=>e.type!=='never_admitted_plan_withdrawn');
  const terminal=current.events.filter(e=>e.type==='never_admitted_plan_withdrawn');
  if(hash(original)!==hash(proof.original.events) || terminal.length!==1 || terminal[0].body!==JSON.stringify(proof))fail('wave_withdrawal_events_moved');
  return proof;
}
export function finishedWave(db,row) {
  if(row.state==='withdrawn'){validateWithdrawal(db,row);return true;}
  return row.state==='complete';
}
export function withdrawNeverAdmitted(db,id,input) {
  if(!input || !input.actor?.trim() || !input.evidence?.trim())fail('wave_withdrawal_actor_and_evidence_required');
  db.exec('PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; BEGIN IMMEDIATE');
  try {
    let row=db.prepare('SELECT * FROM waves WHERE id=?').get(id);if(!row)fail('wave_not_found');
    if(input.expected_manifest_hash!==row.manifest_hash)fail('wave_withdrawal_manifest_moved');
    if(row.state==='withdrawn'){const prior=validateWithdrawal(db,row);db.exec('COMMIT');return {ok:true,already_withdrawn:true,proof:prior,convergence_verified:false};}
    if(row.state!=='pending' || !row.legacy || row.boot || row.pid || row.receipt)fail('wave_withdrawal_only_never_admitted_legacy_plan');
    const original=withdrawalSnapshot(db,row);
    if(input.expected_snapshot_sha256!==hash(original))fail('wave_withdrawal_snapshot_moved');
    const proof={schema:1,kind:'never-admitted-wave-withdrawal',wave_id:id,actor:input.actor,evidence:input.evidence,
      at:Date.now(),snapshot_sha256:hash(original),original,convergence_verified:false,effects_replayed:false,
      scope:'Only this wave plan had no recorded admission. Historical operations/claims/workspaces are unchanged and remain fenced.'};
    // Validate before changing anything. The original row/steps/events travel intact.
    withdrawalProof({...row,state:'withdrawn',withdrawal:JSON.stringify(proof)});
    if(!db.prepare("SELECT name FROM pragma_table_info('waves') WHERE name='withdrawal'").get())db.exec('ALTER TABLE waves ADD COLUMN withdrawal TEXT');
    db.prepare("UPDATE waves SET state='withdrawn',withdrawal=?,updated_at=? WHERE id=?").run(JSON.stringify(proof),proof.at,id);
    db.prepare('INSERT INTO events(wave,at,type,body) VALUES(?,?,?,?)').run(id,proof.at,'never_admitted_plan_withdrawn',JSON.stringify(proof));
    row=db.prepare('SELECT * FROM waves WHERE id=?').get(id);validateWithdrawal(db,row);
    db.exec('COMMIT');return {ok:true,wave_id:id,state:'withdrawn',convergence_verified:false,effects_replayed:false,snapshot_sha256:proof.snapshot_sha256};
  }catch(e){db.exec('ROLLBACK');throw e;}
}
export function withdrawalPlan(db,id) {
  const row=db.prepare('SELECT * FROM waves WHERE id=?').get(id);if(!row)fail('wave_not_found');
  const snapshot=withdrawalSnapshot(db,row);
  return {wave_id:id,expected_manifest_hash:row.manifest_hash,expected_snapshot_sha256:hash(snapshot),state:row.state,steps:snapshot.steps};
}
