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
  let cachePrompt = 0, cacheCalls = 0, cacheHitCalls = 0;
  const usable = new Map();
  for (const [key,pair] of spans) {
    const end = pair.end?.payload;
    if (pair.start && pair.end && (pair.start.seq >= pair.end.seq || pair.start.run_id !== pair.end.run_id)) {
      throw Error('inconsistent_span_boundaries');
    }
    if (pair.kind === 'run') { if (number(end?.ms)) timing.run_ms.push(end.ms); continue; }
    if (pair.kind === 'tool') {
      if (!end) tools.pending++;
      else { tools.completed++; if (end.ok === false) tools.failed++; }
      continue;
    }
    if (!end) { usage.pending_calls++; continue; }
    usage.completed_calls++; if (pair.kind === 'summary') usage.summaries++;
    if (!pair.start) usage.unmatched_ends++;
    if (end.ok === false) usage.failed_calls++;
    if (number(end.ms)) timing.model_ms.push(end.ms);
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
  return {schema:'wasm-agent.token-audit/v1',events:events.length,duplicate_events:duplicates,
    usage,tools,prefix,prepared_prefix:prepared,
    timing:Object.fromEntries(Object.entries(timing).map(([name,values])=>[name,
      {samples:values.length,p50:percentile(values,.5),p95:percentile(values,.95)}])),
    average_request_bytes:Object.fromEntries(Object.keys(shape).map(k=>[k,{mean:shape[k]/shapeSamples[k],samples:shapeSamples[k]}])),
    verified_task_efficiency:null,
    limitations:['metadata_only_not_exact_prefix_proof','cache_cause_not_inferred','prepared_prefix_is_not_proof_of_provider_acceptance_or_cache_retention',
      'reasoning_and_arguments_are_byte_subsets_not_additional_tokens','repeated_arguments_are_not_automatically_waste',
      'observed_cost_is_not_an_invoice_or_complete_task_cost','task_quality_requires_independent_verification']};
}
module.exports = {audit};
