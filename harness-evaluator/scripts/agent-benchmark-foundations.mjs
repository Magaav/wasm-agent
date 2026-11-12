// Model-free reporting contracts. Effects live in the generation-owned results adapter.
import crypto from 'node:crypto';
import {aggregateAttempts,preparedRequests} from './agent-benchmark-telemetry.mjs';
export const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
export const arms = ['pi', 'wasm-current', 'quickjs-wasi-node', 'quickjs-wasi-rust-wasmtime'];
export const rubric = Object.freeze({ correctness: 35, completeness: 25, safety_scope: 20, verification: 15, clarity: 5 });
const finite = x => typeof x === 'number' && Number.isFinite(x) && x >= 0;
export function total(values) { return values.length && values.every(finite) ? values.reduce((a,b)=>a+b,0) : null; }
export const accounting=aggregateAttempts;
export const cacheContinuity=preparedRequests;
export function qualityNotes(outputId,dimensions=null) {
  const notes=Object.fromEntries(Object.entries(rubric).map(([name,max])=>[name,{max,score:null,note:null,evidence:[]} ]));
  if(dimensions)for(const [name,max] of Object.entries(rubric)) {
    const d=dimensions[name];if(!d || !Number.isInteger(d.score) || d.score<0 || d.score>max || typeof d.note!=='string' || !d.note.trim() || !Array.isArray(d.evidence) || !d.evidence.length)throw Error('quality score requires bounded score, reasoning and evidence');
    notes[name]={max,score:d.score,note:d.note,evidence:d.evidence};
  }
  return {output_id:outputId,subjective:true,dimensions:notes,score:dimensions?Object.values(notes).reduce((n,d)=>n+d.score,0):null,behavioral_acceptance_is_separate:true};
}
export function anonymizedOutputId(bytes,privateSalt) {
  if(typeof privateSalt!=='string'||privateSalt.length<32)throw Error('private grading salt required');return hash(Buffer.concat([Buffer.from(privateSalt),Buffer.from(bytes)]));
}
export function readiness(plan) {
  const required=['operator_enabled','native_task_owner','non_ui_oracle_proven','runtime_pins_proven','isolated_shared_route_proven','trace_completeness_proven','sealed_cleanup_proven','token_quota_cap_declared','time_cap_declared','model_reasoning_pinned'];
  return { ready:false, declared_prerequisites_complete:required.every(k=>plan[k]===true), refusals:[...required.filter(k=>plan[k]!==true),'paid-run-integration-not-proven'] };
}
export function report(attempt) {
  const timings=['end_to_end','setup','build','index','test','model','tool','sandbox_startup'];
  const counters=['tool_calls','nested_code_mode_calls','model_steps','cpu_ms','peak_memory_bytes','retries','compactions','redundant_calls','human_interventions'];
  return { output_id:attempt.output_id??null,oracle_pass:attempt.oracle_pass??null,timed_out:attempt.timed_out??null,finished:attempt.finished??null, finish:attempt.finished===true ? 'finished' : attempt.timed_out===true && attempt.oracle_pass===true ? 'oracle-pass-at-timeout' : 'incomplete',
    times_ms:Object.fromEntries(timings.map(k=>[k,attempt.times_ms?.[k] ?? null])),
    counters:Object.fromEntries(counters.map(k=>[k,attempt.counters?.[k] ?? null])),
    quality:{ rubric, scores:null, notes:[], evidence:[], subjective:true },
    pins:attempt.pins || {}, accounting:accounting(attempt.attempts || []) };
}
// Deprecated boolean-only API is not an authorization boundary.
export function cleanupPlan() {throw Error('use generation-owned seal/verifyBundle/cleanup adapter; boolean cleanup plans are unsupported');}
