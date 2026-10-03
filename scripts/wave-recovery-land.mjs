// Local canonical publication only. Remote observation and release/publication
// by the sanctioned merge lane remain separate facts, never inferred here.
import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {spawnSync} from 'node:child_process';
import {checkAdmission,location} from './wave-entry.mjs';import {consumeRecovery,recoveryAdmission} from './lib/wave-recovery.mjs';
import {withRecoveryLease} from './lib/wave-recovery-lease.mjs';import {requireNativeRecovery} from './lib/wave-recovery-native.mjs';
export function landRecovery(repo,context,control){
 let native=requireNativeRecovery(control);
 if(native.source.schema!==2||fs.realpathSync(fileURLToPath(import.meta.url))!==fs.realpathSync(path.join(native.source.root,'scripts/wave-recovery-land.mjs')))throw Error('recovery_landing_verified_source_required');
 const store=location(repo),git=(...a)=>{const r=spawnSync(native.source.runtime.git.path,['-C',repo,...a],{encoding:'utf8',windowsHide:true,maxBuffer:32*1024*1024});if(r.status!==0)throw Error('recovery_landing_git_refused:'+String(r.stderr||r.error));return r.stdout.trim();};
 return withRecoveryLease(store,native.receipt,()=>{
  native=requireNativeRecovery(control);
  const before=checkAdmission(repo,{...context,source:native.source,native});
  if(!before.ok)throw Error(before.reason);
  const binding=before.current_binding;
  if(!binding||binding.effect!=='canonical-local-main-cas')throw Error('recovery_landing_current_authority_required');
  if(git('remote','get-url','origin')!==binding.origin_url)throw Error('recovery_landing_remote_binding_changed');
  const expected=context.recovery.expected_main;
  const remote=()=>{const rows=git('ls-remote','--heads','origin').split('\n').filter(Boolean);if(rows.length!==1||rows[0]!==expected+'\trefs/heads/main')throw Error('recovery_landing_remote_main_changed');return {url:binding.origin_url,main:expected,published:false};};
  const clean=()=>{if(fs.realpathSync(repo)!==binding.repo||git('symbolic-ref','--short','HEAD')!=='main'||git('status','--porcelain','--untracked-files=all'))throw Error('recovery_landing_clean_canonical_main_required');};
  clean();remote();if(git('rev-parse','HEAD')!==expected)throw Error('recovery_landing_main_moved');
  const merged=git('merge-tree','--write-tree',expected,context.recovery.tip);
  native=requireNativeRecovery(control);
  const authority={native,source:native.source};
  const checkedContext={...context,original_refusal:before.original_refusal,named:{activity:before.activity,convergence:before.convergence}};
  const reservation=consumeRecovery(repo,store,checkedContext,authority);
  native=requireNativeRecovery(control);
  recoveryAdmission(repo,store,checkedContext,{native,source:native.source,reserved:reservation});
  clean();remote();
  if(git('rev-parse','HEAD')!==expected||git('rev-parse',`refs/heads/${context.recovery.delivery}`)!==context.recovery.tip)throw Error('recovery_landing_generation_moved_uncertain');
  const result=git('commit-tree',merged,'-p',expected,'-p',context.recovery.tip,'-m',`recovery landing ${context.recovery.delivery}\n\nAgent: wasm-agent session=${native.receipt.session}`);
  requireNativeRecovery(control);
  git('update-ref','refs/heads/main',result,expected);
  // Two-tree checkout checks index/worktree changes. No reset, force checkout or
  // deletion of untracked content; a partial effect is preserved as uncertain.
  if(git('diff','--name-only',expected)||git('ls-files','--others','--exclude-standard'))throw Error('recovery_landing_worktree_changed_after_ref_uncertain');
  git('read-tree','-u','-m',expected,result);
  if(git('rev-parse','HEAD')!==result||git('write-tree')!==merged||git('status','--porcelain','--untracked-files=all'))throw Error('recovery_landing_readback_uncertain');
  const observedRemote=remote();const final=requireNativeRecovery(control);
  return {ok:true,landing:result,tree:merged,publication_scope:'canonical-local',remote:observedRemote,consumption:reservation.consumption,
   convergence:before.convergence,wave_verified:false,original_refusal:before.original_refusal,source:final.source,custody:before.custody,
   native_receipt:final.receipt,native_operation_id:final.operation_id,ticket_commit:reservation.ticket_commit,nonce:reservation.nonce,
   canonical_readback:{main:result,index_tree:merged,clean:true},note:'canonical local CAS and synchronization observed; remote publication, historical settlement and wave convergence are not claimed'};
 });
}
