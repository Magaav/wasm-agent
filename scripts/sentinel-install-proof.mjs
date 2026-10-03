// Request-bound post-install proof validator. No effect, provider, or cached-success authority.
export function installVerdict(intent,result,installed,proof,now=Date.now()) {
 const fail=detail=>({ok:false,detail});
 const time=v=>typeof v==='number'?v*1000:Date.parse(v);
 const stamp=v=>Number.isFinite(time(v))&&time(v)>0&&time(v)<=now;
 const sha=/^[a-f0-9]{40}$/;
 if(!sha.test(intent?.expected_sha||'')||!intent.id||!intent.owner||!intent.session||!stamp(intent.queued_at))return fail('intent_invalid');
 if(result?.request_id!==intent.id||result?.expected_sha!==intent.expected_sha||result?.ok!==true||!stamp(result.at)||time(result.at)<time(intent.queued_at))return fail('outcome_unattributed_or_stale');
 if(installed?.resolved_commit!==intent.expected_sha||!sha.test(installed.resolved_commit)||installed.source_provenance!=='clean-built-by-deploy'||installed.record_role!=='final'||!['0',0,false].includes(installed.dirty)||!stamp(installed.at)||time(installed.at)>time(result.at))return fail('installed_source_unverified');
 if(proof?.request_id!==intent.id||proof?.expected_sha!==intent.expected_sha||proof?.owner!==intent.owner||proof?.parent!==intent.session||proof?.suite!=='verify-install'||proof?.ok!==true||proof?.exit!==0||proof?.failed!==0||proof?.skipped!==0||!Number.isInteger(proof.checks)||proof.checks<1||!stamp(proof.at)||time(proof.at)<time(result.at)||now-time(proof.at)>5000)return fail('verification_not_fresh_exact');
 if(!sha.test(proof.tree||'')||!sha.test(installed.tree||'')||proof.tree!==installed.tree)return fail('tree_identity_mismatch');
 for(const key of ['node_sha256','sentinel_sha256','scripts_sha256','ui_sha256'])if(!/^[a-f0-9]{64}$/.test(proof[key]||'')||proof[key]!==installed[key])return fail('artifact_identity_mismatch:'+key);
 if(!Number.isInteger(proof.listener_pid)||proof.listener_pid!==installed.listener_pid||!Number.isInteger(proof.watcher_pid)||proof.watcher_pid!==installed.watcher_pid)return fail('process_identity_mismatch');
 return {ok:true,detail:'I am updated'};
}
