// A receipt is observation, not a transferable capability. This constructor
// connects only an owned direct Node child to its currently serving native parent.
import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
import {isDeepStrictEqual as equal} from 'node:util';
import {verifyRecoverySource} from './wave-recovery-source.mjs';
const live=new WeakSet();
const wait=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms);
const fail=s=>{throw Error('recovery_native_'+s);};
function lease(file){
 if(!fs.existsSync(file))fail('lease_missing');
 const db=new DatabaseSync(file);try{db.exec('PRAGMA busy_timeout=0');try{db.exec('BEGIN EXCLUSIVE');db.exec('ROLLBACK');fail('lease_released');}catch(e){if(e.code!=='ERR_SQLITE_ERROR'||!(/locked|busy/.test(e.message)))throw e;}}finally{db.close();}
}
function creation(pid,observer){
 if(!Number.isSafeInteger(pid)||pid<=0)fail('process_identity');
 if(process.platform==='win32'){
  const r=spawnSync(observer.path,['-NoProfile','-Command',`(Get-Process -Id ${pid}).StartTime.ToFileTimeUtc()`],{encoding:'utf8',windowsHide:true});
  if(r.status!==0)fail('creation_unavailable');return 'windows-filetime:'+r.stdout.trim();
 }
 if(process.platform==='linux'){const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8');return `linux:${fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()}:${stat.slice(stat.lastIndexOf(')')+1).trim().split(/\s+/)[19]}`;}
 fail('creation_unavailable');
}
export function connectNativeRecovery(channel,repo,descriptor){
 let parent;const deadline=Date.now()+10000;
 while(Date.now()<deadline){try{parent=JSON.parse(fs.readFileSync(channel+'.parent.json','utf8'));break;}catch{}wait(10);}
 if(!parent)fail('parent_channel_unavailable');
 const proof=verifyRecoverySource(repo,descriptor),receipt=parent.receipt;
 if(proof.schema!==2||parent.schema!==1||parent.kind!=='native-recovery-channel'||typeof parent.nonce!=='string'||parent.nonce.length<32)fail('channel_required');
 if(receipt?.schema!==1||receipt.kind!=='held-target-resource'||receipt.exclusion_scope!=='git-common-directory'||process.ppid!==receipt.process_id||parent.runtime.process_id!==receipt.process_id)fail('parent_mismatch');
 if(parent.runtime.binary_sha256!==proof.runtime.native.sha256||creation(receipt.process_id,proof.runtime.observer)!==receipt.creation_stamp||parent.source.tip!==proof.tip||parent.source.tree!==proof.tree)fail('source_or_creation_mismatch');
 let sequence=0,child=null;
 const control={receipt,proof,data:parent.data,operation_id:parent.operation_id,
  check(){
   // The parent ignores requester identity/scope: its own retained receipt is
   // rechecked by actual host.resource on the original admitted Lua thread.
   const request={nonce:parent.nonce,sequence:++sequence,verb:'check',child_process_id:process.pid};
   const requestFile=channel+`.request-${sequence}.json`,replyFile=channel+`.reply-${sequence}.json`;
   fs.writeFileSync(requestFile+'.tmp',JSON.stringify(request),{flag:'wx'});fs.renameSync(requestFile+'.tmp',requestFile);
   let answer;const deadline=Date.now()+10000;
   while(Date.now()<deadline){try{const value=JSON.parse(fs.readFileSync(replyFile,'utf8'));if(value.nonce===request.nonce&&value.sequence===sequence){answer=value;break;}}catch{}wait(10);}
   if(!answer)fail('parent_check_unavailable');
   const r=answer.result;
   if(r?.ok!==true||r.held!==true||!equal(r.receipt,receipt)||r.inventory?.complete!==true||r.inventory.identities_complete!==true||r.inventory.admissible!==true||r.inventory.conflicts?.length!==0)fail('check_refused');
   if(r.child?.process_id!==process.pid||r.child.parent_process_id!==receipt.process_id||r.child.parent_creation_stamp!==receipt.creation_stamp||r.child.creation_stamp!==creation(process.pid,proof.runtime.observer)||(child&&!equal(child,r.child)))fail('child_creation_changed');
   child=r.child;
   const resource=path.join(parent.data,'resources'),db=new DatabaseSync(path.join(resource,'claims.sqlite'),{readOnly:true});
   try{
    db.exec('BEGIN');const claim=db.prepare('SELECT * FROM claims WHERE key=?').get(receipt.key),raw=db.prepare('SELECT identity FROM claim_identity WHERE key=? AND boot=?').get(receipt.key,receipt.boot);
    const identity=raw&&JSON.parse(raw.identity),expected={...receipt,kind:'target'};
    if(!claim||claim.uncertain!==0||['principal','session','run','boot'].some(k=>claim[k]!==receipt[k])||!equal(identity,expected))fail('owner_replaced_or_uncertain');
    db.exec('COMMIT');
   }finally{db.close();}
   if(creation(receipt.process_id,proof.runtime.observer)!==receipt.creation_stamp)fail('creation_changed');
   lease(path.join(resource,receipt.boot+'.lease.sqlite'));lease(path.join(resource,'target-'+receipt.key.slice(7)+'.lease.sqlite'));
   if(verifyRecoverySource(repo,descriptor).tree!==proof.tree)fail('source_changed');
   return {receipt:r.receipt,child:r.child,inventory:r.inventory,source:proof,data:parent.data,operation_id:parent.operation_id};
  }};
 live.add(control);control.check();return Object.freeze(control);
}
export function requireNativeRecovery(control){if(!live.has(control))fail('control_required');return control.check();}
