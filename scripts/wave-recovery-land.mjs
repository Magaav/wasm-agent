// Explicit cooperative recovery consumer. Existing node target conflicts must
// be inspected separately; this lease does not settle historical claims.
import {spawnSync} from 'node:child_process';import {checkAdmission,location} from './wave-entry.mjs';import {consumeRecovery} from './lib/wave-recovery.mjs';import {withRecoveryLease} from './lib/wave-recovery-lease.mjs';
export function landRecovery(repo,context,identity){
 // Private executable contract only until native target-conflict integration
 // is verified. Never turn hashed historical observations into production lease.
 const remote=spawnSync('git',['-C',repo,'remote','get-url','origin'],{encoding:'utf8'});
 if(remote.status!==0||/^(https?:|ssh:|git@)/.test(remote.stdout.trim()))throw Error('recovery_native_target_conflict_integration_required');
 const store=location(repo);const git=(...a)=>{const r=spawnSync('git',['-C',repo,...a],{encoding:'utf8'});if(r.status!==0)throw Error('recovery_landing_git_refused');return r.stdout.trim();};
 return withRecoveryLease(store,identity,()=>{
  const before=checkAdmission(repo,context);if(!before.ok)throw Error(before.reason);
  if(git('status','--porcelain')||git('symbolic-ref','--short','HEAD')!=='main')throw Error('recovery_landing_clean_canonical_main_required');
  const expected=context.recovery.expected_main;if(git('rev-parse','HEAD')!==expected)throw Error('recovery_landing_main_moved');
  const merged=git('merge-tree','--write-tree',expected,context.recovery.tip);
  const reservation=consumeRecovery(repo,store,{...context,original_refusal:before.original_refusal,named:{activity:before.activity,convergence:before.convergence}});
  if(git('rev-parse','HEAD')!==expected||git('rev-parse',`refs/heads/${context.recovery.delivery}`)!==context.recovery.tip)throw Error('recovery_landing_generation_moved_uncertain');
  const result=git('commit-tree',merged,'-p',expected,'-p',context.recovery.tip,'-m',`recovery landing\n\nAgent: wasm-agent session=${identity.session}`);
  git('update-ref','refs/heads/main',result,expected);
  git('reset','--hard',result);
  return {ok:true,landing:result,consumption:reservation.consumption,convergence:before.convergence,original_refusal:before.original_refusal};
 });
}
