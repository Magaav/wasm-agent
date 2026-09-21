// Offline analysis of existing metadata exports. Never changes the runtime or prints payload text.
const crypto = require('node:crypto');
const count = n => Number.isSafeInteger(n) && n >= 0;
const number = n => typeof n === 'number' && Number.isFinite(n) && n >= 0;
const canonical = v => Array.isArray(v) ? '[' + v.map(canonical).join(',') + ']'
  : v && typeof v === 'object' ? '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}'
  : JSON.stringify(v);
const digest = v => crypto.createHash('sha256').update(canonical(v)).digest('hex');
const hash = s => typeof s === 'string' && /^[a-f0-9]{64}$/i.test(s);
const percentile = (a, p) => a.length ? [...a].sort((x,y) => x-y)[Math.ceil(a.length*p)-1] : null;
const total = values => values.reduce((sum,value) => sum + value, 0);
const timingSummary = values => ({samples:values.length,total_ms:values.length?total(values):0,
  mean_ms:values.length?total(values)/values.length:null,p50_ms:percentile(values,.5),
  p95_ms:percentile(values,.95),max_ms:values.length?Math.max(...values):null});
// Built-in names are public capabilities. Unknown/plugin names are aggregated so an
// offline metadata report cannot disclose a private integration merely by naming it.
const PUBLIC_TOOL_NAMES = new Set(['remember','recall','memories','skill','capabilities','sessions','session',
  'search_messages','resume_session','search_ledger','conversation','list_conversations','forget','bash',
  'operation','read','read_many','write','edit','ls','grep','diagnose','client','shell','spell_save','spell_run',
  'spell_list','spell_get','spell_forget','spell_export','remote','nodes','session_debug','session_fixture','tool_result']);
const publicToolName = name => typeof name === 'string' && PUBLIC_TOOL_NAMES.has(name) ? name : 'other';
const OPERATION_PHASES=['setup_ms','accepted_record_ms','spawn_ms','execution_ms','drain_cleanup_ms','output_sync_ms'];
const runKey = event => event && event.run_id ? JSON.stringify([event.session_id,event.run_id]) : null;

function audit(input) {
  const rows = Array.isArray(input) ? input : input?.events;
  if (!Array.isArray(rows)) throw Error('expected_event_array_or_export');
  if (!Array.isArray(input) && input.has_more === true) throw Error('incomplete_export_fetch_remaining_pages');
  const events = [], seen = new Map(), spans = new Map();
  let duplicates = 0;
  for (const row of rows) {
    if (!row || typeof row.id !== 'string' || !row.id || typeof row.session_id !== 'string' || typeof row.run_id !== 'string'
        || !count(row.seq) || typeof row.kind !== 'string' || typeof row.phase !== 'string') {
      throw Error('invalid_event_envelope');
    }
    let payload = row.payload;
    if (typeof payload === 'string') { try { payload = JSON.parse(payload); } catch { throw Error('invalid_event_payload'); } }
    // Lua's empty table serializes as []; it is a valid fieldless payload, not missing usage = zero.
    if (Array.isArray(payload) && payload.length === 0) payload = {};
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw Error('invalid_event_payload');
    const event = {...row, payload}, identity = row.id;
    const fingerprint = digest(event);
    if (seen.has(identity)) {
      if (seen.get(identity) !== fingerprint) throw Error('conflicting_duplicate_event');
      duplicates++; continue;
    }
    seen.set(identity, fingerprint); events.push(event);
    if (!['model_call','summary','tool','run'].includes(row.kind) || !['start','end'].includes(row.phase)) continue;
    if (typeof row.span_id !== 'string' || !row.span_id) throw Error('missing_span_identity');
    const key = JSON.stringify([row.session_id,row.kind,row.span_id]);
    const pair = spans.get(key) || {kind:row.kind};
    if (pair[row.phase]) throw Error('ambiguous_span_phase');
    pair[row.phase] = event; spans.set(key,pair);
  }
  events.sort((a,b) => a.seq-b.seq);
  const usage = {completed_calls:0, summaries:0, failed_calls:0, missing_usage:0, missing_cache:0,
    unpriced_calls:0, invalid_usage:0, pending_calls:0, unmatched_ends:0,
    observed_prompt_tokens:0, observed_output_tokens:0, observed_cache_read_tokens:0,
    observed_cache_write_tokens:0, observed_uncached_tokens:0, observed_priced_cost_usd:0};
  const timing = {model_ms:[],ttft_ms:[],run_ms:[],prefix_audit_ms:[]};
  const tools = {completed:0,failed:0,pending:0,repeated_arguments_within_run:0};
  const toolBuckets = new Map(), toolTimes = [], toolTimesByClock = new Map();
  const executionTimings=[];let executionTimingReported=0,executionTimingIncomplete=0,executionTimingInvalid=0;
  const runParts = new Map(), completedRuns = [];
  const bucketFor = name => {
    name=publicToolName(name);
    if(!toolBuckets.has(name)) toolBuckets.set(name,{completed:0,failed:0,pending:0,times:[],failedTimes:[],clocks:{}});
    return toolBuckets.get(name);
  };
  const partsFor = event => {
    const key=runKey(event); if(!key) return null;
    if(!runParts.has(key)) runParts.set(key,{inference_ms:0,summary_ms:0,tool_ms:0,bash_ms:0,unmeasured:0,clocks:{}});
    return runParts.get(key);
  };
  const addPart = (event,field,ms,clock) => {
    const parts=partsFor(event); if(!parts) return;
    if(!number(ms)) { parts.unmeasured++; return; }
    parts[field]+=ms;
    const clockName=clock==='monotonic'?'monotonic':clock==='wall-fallback'?'wall_fallback':'unknown';
    parts.clocks[clockName]=(parts.clocks[clockName]||0)+1;
  };
  let cachePrompt = 0, cacheCalls = 0, cacheHitCalls = 0;
  const usable = new Map();
  for (const [key,pair] of spans) {
    const end = pair.end?.payload;
    if (pair.start && pair.end && (pair.start.seq >= pair.end.seq || pair.start.run_id !== pair.end.run_id)) {
      throw Error('inconsistent_span_boundaries');
    }
    if (pair.kind === 'run') {
      if (number(end?.ms)) timing.run_ms.push(end.ms);
      if(end) completedRuns.push({event:pair.end,paired:!!pair.start,ms:end.ms,clock:end.clock});
      continue;
    }
    if (pair.kind === 'tool') {
      const startName=pair.start?.payload?.name,endName=end?.name;
      if(typeof startName==='string'&&typeof endName==='string'&&startName!==endName) throw Error('inconsistent_tool_name');
      const name=startName||endName,bucket=bucketFor(name),event=pair.start||pair.end;
      if (!end) {
        tools.pending++;bucket.pending++;const parts=partsFor(event);if(parts) parts.unmeasured++;
      } else {
        tools.completed++;bucket.completed++;
        if (end.ok === false) {tools.failed++;bucket.failed++;}
        if(end.execution_timing!==undefined) {
          executionTimingReported++;
          const t=end.execution_timing;
          const values=OPERATION_PHASES.map(field=>t?.[field]);
          const measured=values.every(count)&&count(t?.unattributed_ms)&&count(t?.total_ms)&&count(t?.measured_ms);
          const phaseTotal=measured?total(values):0;
          if(t?.schema_version!==1||t?.clock!=='monotonic'||t?.complete!==true||!measured) executionTimingIncomplete++;
          else if(phaseTotal!==t.measured_ms||phaseTotal+t.unattributed_ms!==t.total_ms||!number(end.ms)||t.total_ms>end.ms) executionTimingInvalid++;
          else executionTimings.push({...t,name:publicToolName(name),tool_ms:end.ms,wrapper_ms:end.ms-t.total_ms});
        }
        if(number(end.ms)&&pair.start) {
          const clockName=end.clock==='monotonic'?'monotonic':end.clock==='wall-fallback'?'wall_fallback':'unknown';
          toolTimes.push(end.ms);bucket.times.push(end.ms);bucket.clocks[clockName]=(bucket.clocks[clockName]||0)+1;
          if(!toolTimesByClock.has(clockName)) toolTimesByClock.set(clockName,[]);
          toolTimesByClock.get(clockName).push(end.ms);
          if(end.ok===false) bucket.failedTimes.push(end.ms);
          addPart(event,'tool_ms',end.ms,end.clock);
          if(name==='bash'||name==='shell') addPart(event,'bash_ms',end.ms,end.clock);
        } else {
          const parts=partsFor(event);if(parts) parts.unmeasured++;
        }
      }
      continue;
    }
    if (!end) {
      usage.pending_calls++;
      const parts=partsFor(pair.start);if(parts) parts.unmeasured++;
      continue;
    }
    usage.completed_calls++; if (pair.kind === 'summary') usage.summaries++;
    if (!pair.start) usage.unmatched_ends++;
    if (end.ok === false) usage.failed_calls++;
    if (number(end.ms)) timing.model_ms.push(end.ms);
    if(pair.start) addPart(pair.start,pair.kind==='summary'?'summary_ms':'inference_ms',end.ms,end.clock);
    else {const parts=partsFor(pair.end);if(parts) parts.unmeasured++;}
    if (number(end.ttft_ms)) timing.ttft_ms.push(end.ttft_ms);
    const u = end.normalized || {};
    const valid = u.known === true && count(u.prompt) && count(u.output)
      && (u.reasoning == null || (count(u.reasoning) && u.reasoning <= u.output))
      && (u.total == null || u.total === u.prompt + u.output) && !u.issue;
    const cached = valid && u.cache_known === true && [u.input,u.cacheRead,u.cacheWrite].every(count)
      && u.input + u.cacheRead + u.cacheWrite === u.prompt;
    if (!valid) { usage.missing_usage++; if (u.known === true) usage.invalid_usage++; }
    else { usage.observed_prompt_tokens+=u.prompt; usage.observed_output_tokens+=u.output; }
    if (!cached) usage.missing_cache++;
    else {
      cacheCalls++; cachePrompt+=u.prompt; if (u.cacheRead>0) cacheHitCalls++;
      usage.observed_cache_read_tokens+=u.cacheRead;
      usage.observed_cache_write_tokens+=u.cacheWrite;
      usage.observed_uncached_tokens+=u.input;
    }
    if (valid && cached && u.cost_known === true && number(u.cost)) usage.observed_priced_cost_usd+=u.cost;
    else usage.unpriced_calls++;
    usable.set(key,{valid,cached,u});
  }
  for (const key of ['observed_prompt_tokens','observed_output_tokens','observed_cache_read_tokens',
    'observed_cache_write_tokens','observed_uncached_tokens']) {
    if (!count(usage[key])) throw Error('token_total_exceeds_safe_integer');
  }
  if (!count(cachePrompt) || !number(usage.observed_priced_cost_usd)) throw Error('accounting_total_overflow');
  usage.cache_measured_calls = cacheCalls;
  usage.cached_input_share = cachePrompt ? usage.observed_cache_read_tokens/cachePrompt : null;
  usage.request_cache_hit_share = cacheCalls ? cacheHitCalls/cacheCalls : null;
  usage.average_prompt_tokens = usage.completed_calls>usage.missing_usage
    ? usage.observed_prompt_tokens/(usage.completed_calls-usage.missing_usage) : null;
  // This is only the observed export, not an invoice, verified task score, or full-session guarantee.
  usage.recorded_calls_cost_usd = usage.completed_calls && !usage.pending_calls && !usage.unpriced_calls
    && !usage.unmatched_ends ? usage.observed_priced_cost_usd : null;
  const prefix = {comparisons:0,stable_recorded_components:0,changed_recorded_components:0,
    incomplete_metadata_pairs:0,stable_components_zero_cache_calls:0,changed_fields:{}};
  const fields = ['system_hash','schema_hash','model','provider','settings','attribution','runtime','summary_watermark'];
  const prepared = {measured:0,unmeasured:0,append_only:0,identical:0,rewritten:0,shortened:0,
    tools_changed:0,settings_changed:0,routing_changed:0};
  const previous = new Map(), repeated = new Set();
  const shape = {}, shapeSamples = {};
  for (const row of events) {
    const p = row.payload;
    if (row.kind === 'tool' && row.phase === 'start' && row.run_id && hash(p.arguments_hash) && typeof p.name === 'string') {
      const key = JSON.stringify([row.session_id,row.run_id,p.name,p.arguments_hash]);
      if (repeated.has(key)) tools.repeated_arguments_within_run++;
      repeated.add(key);
    }
    if (row.kind !== 'model_call' || row.phase !== 'start') continue;
    if(number(p.prefix_audit_ms)) timing.prefix_audit_ms.push(p.prefix_audit_ms);
    const comparison=p.prefix_audit;
    if (comparison?.schema_version===1 && ['append_only','identical','rewritten','shortened'].includes(comparison.relation)) {
      prepared.measured++;prepared[comparison.relation]++;
      for (const field of ['tools_changed','settings_changed','routing_changed']) if(comparison[field]===true) prepared[field]++;
    } else prepared.unmeasured++;
    for (const name of ['system_bytes','schema_bytes','user_bytes','assistant_bytes','tool_result_bytes',
      'reasoning_source_bytes','tool_arguments_source_bytes']) {
      if (count(p.prompt_shape?.[name])) {
        shape[name]=(shape[name]||0)+p.prompt_shape[name]; shapeSamples[name]=(shapeSamples[name]||0)+1;
      }
    }
    // Compare only recorded metadata. Context estimates naturally grow; only the summary watermark
    // marks a history boundary. No per-message hashes exist, so exact prefix length is unknowable here.
    const values = {...p, summary_watermark:p.context?.summary_watermark};
    const prior = previous.get(row.session_id); previous.set(row.session_id,values);
    if (!prior) continue;
    prefix.comparisons++;
    if (!hash(prior.system_hash) || !hash(values.system_hash) || !hash(prior.schema_hash)
        || !hash(values.schema_hash) || fields.some(f => prior[f] === undefined || values[f] === undefined)) {
      prefix.incomplete_metadata_pairs++; continue;
    }
    const changed = fields.filter(f => canonical(prior[f]) !== canonical(values[f]));
    if (changed.length) {
      prefix.changed_recorded_components++;
      for (const f of changed) prefix.changed_fields[f]=(prefix.changed_fields[f]||0)+1;
    } else {
      prefix.stable_recorded_components++;
      const u = usable.get(JSON.stringify([row.session_id,row.kind,row.span_id]));
      if (u?.cached && u.u.prompt>0 && u.u.cacheRead===0) prefix.stable_components_zero_cache_calls++;
    }
  }
  if (Object.values(shape).some(n=>!count(n))) throw Error('byte_total_exceeds_safe_integer');
  const toolTotal=total(toolTimes);
  if(!Number.isSafeInteger(toolTotal)) throw Error('tool_time_total_exceeds_safe_integer');
  tools.measured_elapsed=toolTimes.length;
  tools.unmeasured_elapsed=tools.completed-toolTimes.length;
  tools.elapsed=timingSummary(toolTimes);
  tools.elapsed.by_clock=Object.fromEntries([...toolTimesByClock].sort(([a],[b])=>a.localeCompare(b))
    .map(([clock,values])=>[clock,timingSummary(values)]));
  tools.by_name=Object.fromEntries([...toolBuckets].sort(([a],[b])=>a.localeCompare(b)).map(([name,bucket])=>{
    const summary={completed:bucket.completed,failed:bucket.failed,pending:bucket.pending,
      elapsed:{...timingSummary(bucket.times),failed_ms:total(bucket.failedTimes),clock_samples:bucket.clocks},
      share_of_measured_tool_ms:toolTotal?total(bucket.times)/toolTotal:null};
    return [name,summary];
  }));
  const executionToolMs=total(executionTimings.map(t=>t.tool_ms));
  const executionMs=total(executionTimings.map(t=>t.execution_ms));
  const executionFields=[...OPERATION_PHASES,'unattributed_ms','wrapper_ms'];
  const executionTotals=Object.fromEntries(executionFields.map(field=>[field,total(executionTimings.map(t=>t[field]))]));
  const executionDistributions=Object.fromEntries(executionFields.map(field=>[field,timingSummary(executionTimings.map(t=>t[field]))]));
  const executionByName={};
  for(const item of executionTimings) {
    const bucket=executionByName[item.name]||(executionByName[item.name]={samples:0,tool_ms:0,execution_ms:0,executor_overhead_ms:0});
    bucket.samples++;bucket.tool_ms+=item.tool_ms;bucket.execution_ms+=item.execution_ms;
    bucket.executor_overhead_ms+=item.tool_ms-item.execution_ms;
  }
  for(const bucket of Object.values(executionByName)) bucket.execution_share=bucket.tool_ms?bucket.execution_ms/bucket.tool_ms:null;
  tools.execution_phases={reported:executionTimingReported,complete:executionTimings.length,
    incomplete:executionTimingIncomplete,invalid:executionTimingInvalid,tool_ms:executionToolMs,
    execution_ms:executionMs,executor_overhead_ms:executionToolMs-executionMs,
    execution_share:executionToolMs?executionMs/executionToolMs:null,
    phase_totals_ms:executionTotals,phase_timing:executionDistributions,
    by_name:Object.fromEntries(Object.entries(executionByName).sort(([a],[b])=>a.localeCompare(b))),
    scope:'operation total excludes its final state record; wrapper includes that record plus host adapter and tool projection'};
  for(const value of [executionToolMs,executionMs,...Object.values(executionTotals),
    ...Object.values(executionByName).flatMap(bucket=>[bucket.samples,bucket.tool_ms,bucket.execution_ms,bucket.executor_overhead_ms])])
    if(!Number.isSafeInteger(value)) throw Error('execution_time_total_exceeds_safe_integer');

  const runTiming={completed_runs:completedRuns.length,measured_runs:0,decomposed_runs:0,
    unmeasured_runs:0,incomplete_child_timing_runs:0,inconsistent_runs:0,non_monotonic_clock_runs:0,
    decomposed_run_ms:0,inference_ms:0,summary_ms:0,model_ms:0,tool_ms:0,bash_ms:0,unclassified_ms:0};
  const perRunBashShares=[];
  for(const run of completedRuns) {
    if(!number(run.ms)||!run.paired) {runTiming.unmeasured_runs++;continue;}
    runTiming.measured_runs++;
    const parts=runParts.get(runKey(run.event))||{inference_ms:0,summary_ms:0,tool_ms:0,bash_ms:0,unmeasured:0,clocks:{}};
    if(parts.unmeasured) {runTiming.incomplete_child_timing_runs++;continue;}
    const child=parts.inference_ms+parts.summary_ms+parts.tool_ms;
    if(child>run.ms) {runTiming.inconsistent_runs++;continue;}
    runTiming.decomposed_runs++;
    runTiming.decomposed_run_ms+=run.ms;runTiming.inference_ms+=parts.inference_ms;
    runTiming.summary_ms+=parts.summary_ms;runTiming.tool_ms+=parts.tool_ms;runTiming.bash_ms+=parts.bash_ms;
    runTiming.unclassified_ms+=run.ms-child;
    if(run.clock!=='monotonic'||Object.keys(parts.clocks).some(clock=>clock!=='monotonic')) runTiming.non_monotonic_clock_runs++;
    if(run.ms>0) perRunBashShares.push(parts.bash_ms/run.ms);
  }
  runTiming.model_ms=runTiming.inference_ms+runTiming.summary_ms;
  for(const key of ['decomposed_run_ms','inference_ms','summary_ms','model_ms','tool_ms','bash_ms','unclassified_ms'])
    if(!Number.isSafeInteger(runTiming[key])) throw Error('run_time_total_exceeds_safe_integer');
  runTiming.model_share_of_decomposed_run_ms=runTiming.decomposed_run_ms?runTiming.model_ms/runTiming.decomposed_run_ms:null;
  runTiming.tool_share_of_decomposed_run_ms=runTiming.decomposed_run_ms?runTiming.tool_ms/runTiming.decomposed_run_ms:null;
  runTiming.bash_share_of_decomposed_run_ms=runTiming.decomposed_run_ms?runTiming.bash_ms/runTiming.decomposed_run_ms:null;
  runTiming.per_run_bash_share={samples:perRunBashShares.length,p50:percentile(perRunBashShares,.5),p95:percentile(perRunBashShares,.95)};
  runTiming.scope='summed completed-run spans; concurrent runs can overlap, so this is not global wall-clock share';

  return {schema:'wasm-agent.token-audit/v1',events:events.length,duplicate_events:duplicates,
    usage,tools,run_timing:runTiming,prefix,prepared_prefix:prepared,
    timing:Object.fromEntries(Object.entries(timing).map(([name,values])=>[name,
      {samples:values.length,p50:percentile(values,.5),p95:percentile(values,.95)}])),
    average_request_bytes:Object.fromEntries(Object.keys(shape).map(k=>[k,{mean:shape[k]/shapeSamples[k],samples:shapeSamples[k]}])),
    verified_task_efficiency:null,
    limitations:['metadata_only_not_exact_prefix_proof','cache_cause_not_inferred','prepared_prefix_is_not_proof_of_provider_acceptance_or_cache_retention',
      'reasoning_and_arguments_are_byte_subsets_not_additional_tokens','repeated_arguments_are_not_automatically_waste',
      'tool_elapsed_includes_dispatch_and_projection_not_process_cpu','summed_span_time_is_not_global_wall_clock',
      'unknown_and_plugin_tool_names_are_aggregated_as_other','observed_cost_is_not_an_invoice_or_complete_task_cost',
      'task_quality_requires_independent_verification']};
}
module.exports = {audit};
