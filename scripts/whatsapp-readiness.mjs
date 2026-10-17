// One-shot, read-only live readiness check. Never pairs, activates, sends or changes bindings.
import {readBinding} from './whatsapp-mcp-client.mjs';
import {connectorRequest} from './mcp-whatsapp.mjs';
const args=process.argv.slice(2);
try {
 if(args.length!==2||args[0]!=='--profile-file')throw Error('usage');
 const b=readBinding({profile_file:args[1]});
 const s=await connectorRequest(b,'status');
 const identity=await connectorRequest(b,'lookup_self');
 const checks={api:s.ok===true,account:s.config?.account===b.account,generation:s.config?.generation===b.generation,paired:identity.ok===true&&identity.account===b.account&&identity.generation===b.generation,all_chats:s.config?.all_chats===true,pt:s.config?.language==='pt',requested_on:s.config?.requested_on===true,connected:s.connection==='connected',authenticated:s.session_observation?.authentication==='authenticated_event_observed',no_gap:s.source_state?.persistence_gap===false,no_unknown_sends:s.unknown_sends===0};
 const ready=Object.values(checks).every(Boolean);
 const c=s.coverage_status;const warnings=[];if(!c)warnings.push('coverage_unavailable');if(c?.unobserved_titles>0)warnings.push('observed_names_partial');if(c?.held_chats>0)warnings.push('mutation_holds_present');if(c?.historical_reason_only_holds>0)warnings.push('historical_holds_need_item_proof');
 console.log(JSON.stringify({ok:ready,readiness_scope:'transport_and_policy_only_not_full_coverage',coverage_status:c??null,warnings,checks,connection:s.connection,audio:s.audio,unknown_sends:s.unknown_sends,snapshot_at:s.snapshot_at,whisper:'unverified: run offline worker --check on service host; warm-process/real-audio proof is separate',coverage:'partial; this check does not certify complete history, delivery or service ownership'}));
 if(!ready)process.exitCode=1;
} catch {console.log(JSON.stringify({ok:false,error:'readiness_unavailable_check_binding_transport_and_service'}));process.exitCode=1;}
