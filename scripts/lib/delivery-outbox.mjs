import fs from 'node:fs';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value==='object') return `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}

export function eventIdentity(record,decision,subscription) {
  const generation={delivery:record.delivery,tip:decision.observed.tip,tree:decision.observed.tree,
    review:record.review,decision:decision.decision,caveats:decision.caveats,subscription};
  return `delivery:${crypto.createHash('sha256').update(canonicalJson(generation)).digest('hex')}`;
}
export function subscriber(command,id) {
  const run=spawnSync(command,['job','list'],{encoding:'utf8',windowsHide:true,timeout:15000});
  if (run.status!==0) throw Error(`subscription_observation_failed: ${run.error?.message || run.stderr}`);
  const job=JSON.parse(run.stdout).find(job=>job.id===id);
  if (!job || job.enabled!==true || job.trigger?.kind!=='event' || job.trigger?.topic!=='delivery.admitted') {
    throw Error(`subscription_unavailable: enabled delivery.admitted subscriber ${id} is required`);
  }
  return {id:job.id,revision:job.revision};
}
export function acknowledged({command,subscription,id,payloadFile,receiptDb}) {
  const payload=JSON.parse(fs.readFileSync(payloadFile,'utf8'));
  if (receiptDb) {
    // Temporary approved observation seam. Never creates or migrates jobs.db.
    // Missing columns are errors, never weaker acknowledgements.
    const db=new DatabaseSync(receiptDb,{readOnly:true});
    try {
      db.exec('BEGIN');
      const job=db.prepare('SELECT revision,enabled,definition FROM jobs WHERE id=?').get(subscription.id);
      const effect=db.prepare('SELECT id,state,payload FROM deliveries WHERE job_id=? AND revision=? AND event_id=?')
        .get(subscription.id,subscription.revision,id);
      const trigger=job && JSON.parse(job.definition).trigger;
      const matched=effect && canonicalJson(JSON.parse(effect.payload))===canonicalJson(payload);
      return {mechanism:'legacy_readonly_schema',acknowledged:Boolean(job?.enabled && job.revision===subscription.revision
        && trigger?.kind==='event' && trigger?.topic==='delivery.admitted' && matched && effect.state!=='cancelled'),
        job_id:subscription.id,revision:subscription.revision,event_id:id,effect_id:effect?.id ?? null};
    } finally { db.close(); }
  }
  const run=spawnSync(command,['job','receipt',subscription.id,String(subscription.revision),id,payloadFile],
    {encoding:'utf8',windowsHide:true,timeout:15000});
  if (run.status!==0) throw Error(`receipt_observation_failed: ${run.error?.message || run.stderr}`);
  const value=JSON.parse(run.stdout);
  if (value.job_id!==subscription.id || value.revision!==subscription.revision || value.event_id!==id
      || value.read_only!==true || value.trigger?.kind!=='event' || value.trigger?.topic!=='delivery.admitted') {
    throw Error('receipt_identity_mismatch');
  }
  return {mechanism:'job_receipt_api',acknowledged:value.receipt.acknowledged===true,
    job_id:value.job_id,revision:value.revision,event_id:value.event_id,effect_id:value.receipt.delivery_id ?? null};
}
