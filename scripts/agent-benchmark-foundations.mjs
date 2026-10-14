// Model-free contracts shared by benchmark adapters. No provider or cleanup effects.
import crypto from 'node:crypto';
export const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
export const arms = ['pi', 'wasm-current', 'quickjs-wasi-node', 'quickjs-wasi-rust-wasmtime'];
export const rubric = Object.freeze({ correctness: 35, completeness: 25, safety_scope: 20, verification: 15, clarity: 5 });
const finite = x => typeof x === 'number' && Number.isFinite(x) && x >= 0;
export function total(values) { return values.length && values.every(finite) ? values.reduce((a,b)=>a+b,0) : null; }
export function accounting(attempts) {
  // Input is raw provider prompt, cache read/write are subsets, reasoning is output subset.
  const fields = ['input','cache_read','cache_write','output','reasoning','actual_cost'];
  const sums = Object.fromEntries(fields.map(k=>[k,total(attempts.map(a=>a.usage?.[k]))]));
  for (const a of attempts) {
    const u = a.usage || {};
    if (finite(u.input) && finite(u.cache_read) && finite(u.cache_write) && u.cache_read + u.cache_write > u.input) throw Error('overlapping input accounting');
    if (finite(u.reasoning) && finite(u.output) && u.reasoning > u.output) throw Error('reasoning is output subset');
  }
  return { attempts: attempts.length, ...sums, uncached_input: sums.input === null || sums.cache_read === null || sums.cache_write === null ? null : sums.input-sums.cache_read-sums.cache_write,
    complete_cost: attempts.length > 0 && sums.actual_cost !== null,
    tokens_wasted: null, avoidable_work: attempts.flatMap(a=>a.avoidable_work || []), raw_attempts: attempts };
}
export function cacheContinuity(requests) {
  return requests.map((r,i)=>{
    const p=requests[i-1], causes=[];
    if(p) for(const k of ['scope','session','model','routing','tools_hash','instructions_hash']) if(p[k]!==r[k] || r[k] == null) causes.push(k);
    const observed=typeof r.prepared_prefix==='string' && typeof p?.prepared_prefix==='string';
    if(p && observed && !r.prepared_prefix.startsWith(p.prepared_prefix)) causes.push('prepared-prefix');
    return { id:r.id, continuity:!p || !observed ? null : causes.length===0,
      break_causes:causes, cache_label:r.cache_evidence ? r.cache_evidence.label : 'unknown',
      cache_evidence:r.cache_evidence || null, input:r.usage?.input ?? null,
      cache_read:r.usage?.cache_read ?? null, uncached_input:r.usage?.input != null && r.usage?.cache_read != null && r.usage?.cache_write != null ? r.usage.input-r.usage.cache_read-r.usage.cache_write : null,
      ttft_ms:r.ttft_ms ?? null, backend_kv_contents:'opaque' };
  });
}
export function readiness(plan) {
  const required=['operator_enabled','native_task_owner','non_ui_oracle_proven','runtime_pins_proven','isolated_shared_route_proven','trace_completeness_proven','sealed_cleanup_proven','token_quota_cap_declared','time_cap_declared','model_reasoning_pinned'];
  return { ready:required.every(k=>plan[k]===true), refusals:required.filter(k=>plan[k]!==true) };
}
export function report(attempt) {
  const timings=['end_to_end','setup','build','index','test','model','tool','sandbox_startup'];
  const counters=['tool_calls','nested_code_mode_calls','model_steps','cpu_ms','peak_memory_bytes','retries','compactions','redundant_calls','human_interventions'];
  return { ...attempt, finish:attempt.finished===true ? 'finished' : attempt.timed_out===true && attempt.oracle_pass===true ? 'oracle-pass-at-timeout' : 'incomplete',
    times_ms:Object.fromEntries(timings.map(k=>[k,attempt.times_ms?.[k] ?? null])),
    counters:Object.fromEntries(counters.map(k=>[k,attempt.counters?.[k] ?? null])),
    quality:{ rubric, scores:null, notes:[], evidence:[], subjective:true },
    pins:attempt.pins || {}, accounting:accounting(attempt.attempts || []) };
}
// This returns an authorization plan only. A caller must additionally validate actual
// ownership/process settlement at effect time; it must never replay uncertain effects.
export function cleanupPlan(bundle, resources, generation) {
  if(!bundle?.sealed || !bundle?.integrity_verified || !bundle?.lossless || !bundle?.required_records_complete) throw Error('archive not verified');
  const permitted=['container','volume','network','checkout','temp-build','solver-home'];
  for(const r of resources) if(r.generation!==generation || r.owner_verified!==true || r.drained!==true || r.effects_known!==true || r.shared!==false || r.active!==false || !permitted.includes(r.kind) || r.path_escape!==false) throw Error('unsafe cleanup resource');
  return resources.map(r=>({id:r.id,kind:r.kind,generation}));
}
