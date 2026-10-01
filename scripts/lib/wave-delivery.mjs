import {spawnSync} from 'node:child_process';
import {evaluate} from '../delivery-admission.mjs';
export function verifyDelivered(repo,record,main) {
  const git=(...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error(`delivery_git_unverifiable:${args.join(' ')}`);return r.stdout.trim();};
  try {
    if(!record.delivery || !record.producer || !record.tip || !record.tree || !record.review || !record.admission?.by || record.admission.by===record.producer)throw Error('delivery_identity_review_admission_required');
    const tip=git('rev-parse',`${record.tip}^{commit}`),tree=git('rev-parse',`${tip}^{tree}`);
    if(tree!==record.tree || git('rev-parse',`${record.review.tip}^{tree}`)!==tree || record.review.tree!==tree)throw Error('delivery_review_tip_tree_mismatch');
    if(record.admission.tip!==tip || record.admission.tree!==tree || !['admitted','admitted_with_caveat'].includes(record.admission.state))throw Error('delivery_admission_binding_mismatch');
    const decision=evaluate({repo,record,tipRef:tip,phase:'observe'}); // Read-only immutable closure, not new admission.
    if(decision.decision==='refused')throw Error(decision.condition);
    const landing=git('rev-parse',`${record.landing?.sha}^{commit}`);
    git('merge-base','--is-ancestor',tip,landing);
    git('merge-base','--is-ancestor',landing,main);
    git('merge-base','--is-ancestor',tip,main);
    return {ok:true,tip,tree,landing,review:decision.review};
  }catch(e){return {ok:false,reason:e.message,delivery:record.delivery};}
}
