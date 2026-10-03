// Current execution observation, never global registry admission or a transferable receipt.
import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';import {isDeepStrictEqual as equal} from 'node:util';
import {verifyRecoverySource} from './wave-recovery-source.mjs';
const live=new WeakSet(),wait=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms);
const need=(v,s)=>{if(!v)throw Error('current_source_native_'+s);};
function stamp(pid,observer){
 if(process.platform==='win32'){const r=spawnSync(observer.path,['-NoProfile','-Command',`(Get-Process -Id ${pid}).StartTime.ToFileTimeUtc()`],{encoding:'utf8',windowsHide:true});need(r.status===0,'creation_unavailable');return 'windows-filetime:'+r.stdout.trim();}
 need(process.platform==='linux','platform_unavailable');const raw=fs.readFileSync(`/proc/${pid}/stat`,'utf8');return `linux:${fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()}:${raw.slice(raw.lastIndexOf(')')+1).trim().split(/\s+/)[19]}`;
}
export function connectCurrentSource(channel,repo,descriptor){
 let parent;const until=Date.now()+10000;while(Date.now()<until){try{parent=JSON.parse(fs.readFileSync(channel+'.parent.json'));break;}catch{}wait(10);}
 need(parent?.kind==='current-source-native-channel'&&parent.nonce?.length>=64,'channel');
 const proof=verifyRecoverySource(repo,descriptor),initial=parent.observation;
 need(proof.schema===2&&proof.runtime.current_ref_driver==='scripts/wave-current-ref-driver.lua'&&proof.runtime.current_ref_consumer==='scripts/wave-current-ref-bootstrap.mjs','reviewed_adapter');
 need(initial?.kind==='current-native-executor-observation'&&initial.ok&&initial.production_registry_admission===false&&initial.global_identity_safety===false,'observation');
 need(process.ppid===initial.process_id&&parent.runtime.process_id===initial.process_id&&parent.runtime.binary_sha256===proof.runtime.native.sha256,'actual_parent');
 need(stamp(initial.process_id,proof.runtime.observer)===initial.creation_stamp,'parent_generation');
 let sequence=0,child;
 const control={proof,check(){
  const request={nonce:parent.nonce,sequence:++sequence,verb:'current-check',child_process_id:process.pid};
  // Exclusive immutable sequence file. The trusted reader ignores incomplete
  // JSON and advances only after complete nonce/sequence/verb validation; avoid
  // Windows rename contention with that reader's polling handle.
  const file=channel+`.request-${sequence}.json`;fs.writeFileSync(file,JSON.stringify(request),{flag:'wx'});
  let reply;const until=Date.now()+10000;while(Date.now()<until){try{const r=JSON.parse(fs.readFileSync(channel+`.reply-${sequence}.json`));if(r.nonce===request.nonce&&r.sequence===sequence){reply=r.result;break;}}catch{}wait(10);}
  need(reply?.ok&&equal(reply.context,initial.context)&&reply.process_id===initial.process_id&&reply.creation_stamp===initial.creation_stamp&&reply.resource_root===initial.resource_root,'retained_owner');
  need(reply.child?.operation_id===parent.operation_id&&reply.child.process_id===process.pid&&reply.child.parent_process_id===process.ppid&&reply.child.parent_creation_stamp===initial.creation_stamp&&reply.child.creation_stamp===stamp(process.pid,proof.runtime.observer)&&(!child||equal(child,reply.child)),'direct_child_generation');child=reply.child;
  const db=new DatabaseSync(path.join(initial.resource_root,'claims.sqlite'),{readOnly:true});try{
   db.exec('BEGIN');const own=initial.context,row=db.prepare('SELECT * FROM claims WHERE key=?').get('session:'+own.session),identity=db.prepare('SELECT identity FROM claim_identity WHERE key=? AND boot=?').get('session:'+own.session,own.boot);
   need(row&&row.uncertain===0&&['principal','session','run','boot'].every(k=>row[k]===own[k])&&JSON.parse(identity?.identity||'null')?.claim_id===own.claim_id,'current_claim_generation');db.exec('COMMIT');
  }finally{db.close();}
  const lease=new DatabaseSync(path.join(initial.resource_root,initial.context.boot+'.lease.sqlite'),{readOnly:true});try{try{lease.exec('BEGIN EXCLUSIVE');lease.exec('ROLLBACK');throw Error('current_source_native_boot_released');}catch(e){need(/locked|busy/.test(e.message),'boot_lease');}}finally{lease.close();}
  need(stamp(initial.process_id,proof.runtime.observer)===initial.creation_stamp&&verifyRecoverySource(repo,descriptor).tree===proof.tree,'source_or_parent_changed');
  return {...reply,source:proof,operation_id:parent.operation_id};
 }};live.add(control);control.check();return Object.freeze(control);
}
export function requireCurrentSource(control){need(live.has(control),'retained_control_required');return control.check();}
