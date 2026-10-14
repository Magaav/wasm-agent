// Offline adapters for native telemetry exports and Pi JSONL; metadata-only reports.
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{audit}=require('./lib/token-audit.cjs');
export const canonical=v=>Array.isArray(v)?'['+v.map(canonical).join(',')+']':v&&typeof v==='object'?'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}':JSON.stringify(v);
export const digest=v=>crypto.createHash('sha256').update(canonical(v)??'null').digest('hex');
const count=x=>Number.isSafeInteger(x)&&x>=0;
const money=x=>typeof x==='number'&&Number.isFinite(x)&&x>=0;
const timing=x=>money(x)?x:null;
const fields=['prompt_total','uncached_input','cache_read','cache_write','output','reasoning'];
export function normalizeUsage(raw,source) {
  if(!['pi','native'].includes(source))throw Error('unknown usage source');
  if(!raw)return Object.fromEntries([...fields,'reported_priced_cost','actual_cost'].map(k=>[k,null]));
  const hasTokens=source==='pi'||raw.known===true;
  const u=!hasTokens?{}:source==='pi'?{uncached_input:raw.input,cache_read:raw.cacheRead,cache_write:raw.cacheWrite,output:raw.output,reasoning:raw.reasoning}: {prompt_total:raw.prompt,uncached_input:raw.input,cache_read:raw.cacheRead,cache_write:raw.cacheWrite,output:raw.output,reasoning:raw.reasoning};
  for(const k of fields)if(u[k]!==undefined && u[k]!==null && !count(u[k]))throw Error('invalid token count: '+k);
  if(source==='native' && raw.cache_known!==true) {u.cache_read=null;u.cache_write=null;u.uncached_input=null;}
  if(source==='pi' && ['uncached_input','cache_read','cache_write'].every(k=>count(u[k])))u.prompt_total=u.uncached_input+u.cache_read+u.cache_write;
  if(u.prompt_total!=null&&!count(u.prompt_total))throw Error('token total overflow');
  const reportedTotal=hasTokens?(source==='pi'?raw.totalTokens:raw.total):null;
  if(reportedTotal!=null && !count(reportedTotal))throw Error('invalid reported total');
  if(reportedTotal!=null && count(u.prompt_total) && count(u.output) && reportedTotal!==u.prompt_total+u.output)throw Error('inconsistent reported total');
  if(count(u.prompt_total)&&['uncached_input','cache_read','cache_write'].every(k=>count(u[k])) && u.prompt_total!==u.uncached_input+u.cache_read+u.cache_write)throw Error('inconsistent prompt subsets');
  if(count(u.reasoning)&&count(u.output)&&u.reasoning>u.output)throw Error('reasoning is output subset');
  if(source==='native' && u.reasoning===0 && raw.reasoning_known!==true)u.reasoning=null;
  for(const k of fields)u[k]=u[k]??null;
  // Configured/catalogue prices are not billing. Preserve the reported price
  // separately; only an explicit actual billing receipt permits actual money.
  const reported=source==='native' && raw.cost_known===true?raw.cost:source==='pi'?raw.cost?.total:null;
  if(reported!==null && reported!==undefined && !money(reported))throw Error('invalid reported priced cost');u.reported_priced_cost=reported??null;
  const cost=raw.actualBilling?.priced===true && raw.actualBilling.currency==='USD' && /^[a-f0-9]{64}$/.test(raw.actualBilling.receipt_sha256||'')?raw.actualBilling.cost:null;
  if(cost!==null && cost!==undefined && !money(cost))throw Error('invalid actual cost');u.actual_cost=cost??null;return u;
}
export function aggregateAttempts(attempts) {
  for(const a of attempts) {
    for(const w of a.avoidable_work||[])if(!w || !Array.isArray(w.evidence_refs) || !w.evidence_refs.length || typeof w.adjudicator!=='string' || !w.adjudicator || typeof w.decision!=='string' || !w.decision || w.avoidable_tokens!=null&&!count(w.avoidable_tokens))throw Error('avoidable work needs adjudication and evidence');
    if(a.usage && Object.hasOwn(a.usage,'input'))throw Error('ambiguous input: normalize provider usage first');
    for(const k of fields)if(a.usage?.[k]!=null && !count(a.usage[k]))throw Error('invalid normalized token count');
    const u=a.usage||{};
    if(['prompt_total','uncached_input','cache_read','cache_write'].every(k=>count(u[k])) && u.prompt_total!==u.uncached_input+u.cache_read+u.cache_write)throw Error('inconsistent normalized subsets');
    if(count(u.reasoning)&&count(u.output)&&u.reasoning>u.output)throw Error('reasoning is output subset');
    if(u.actual_cost!=null&&!money(u.actual_cost) || u.reported_priced_cost!=null&&!money(u.reported_priced_cost))throw Error('invalid priced cost');
  }
  const sums={};for(const k of [...fields,'reported_priced_cost','actual_cost']) {
    const values=attempts.map(a=>a.usage?.[k]);sums[k]=values.length && values.every(v=>k==='actual_cost'||k==='reported_priced_cost'?money(v):count(v))?values.reduce((a,b)=>a+b,0):null;
    if(!['actual_cost','reported_priced_cost'].includes(k) && sums[k]!==null && !count(sums[k]))throw Error('token total overflow');
  }
  return {...sums,attempts:attempts.length,accounting_scope:'recorded-attempts-only',recorded_attempt_cost_complete:attempts.length>0&&sums.actual_cost!==null,complete_cost:false,worker_total_actual_cost:null,
    failed:attempts.filter(a=>a.failed===true).length,tokens_wasted:null,
    avoidable_work:attempts.flatMap(a=>a.avoidable_work||[]),attempt_evidence:attempts.map(a=>({id:a.id??null,kind:a.kind??null,failed:a.failed??null,incomplete:a.incomplete??null,usage:a.usage??null,usage_evidence:a.usage_evidence??null,evidence:a.evidence??null,raw_usage_hash:a.raw_usage_hash??null}))};
}
function unique(rows) {
  const seen=new Map(),out=[];for(const row of rows) {if(!row.id)throw Error('missing trace identity');const h=digest(row);if(seen.has(row.id)){if(seen.get(row.id)!==h)throw Error('conflicting duplicate');continue;}seen.set(row.id,h);out.push(row);}return out;
}
export function nativeTrace(input) {
  // Keep strict existing duplicate, span-boundary and telemetry validation.
  const validation=audit(input);const rows=unique(Array.isArray(input)?input:input.events).map(r=>({...r,payload:typeof r.payload==='string'?JSON.parse(r.payload):r.payload}));
  const spans=new Map();for(const r of rows)if(['model_call','summary','tool','run'].includes(r.kind)&&['start','end'].includes(r.phase)) {const key=canonical([r.session_id,r.kind,r.span_id]);const p=spans.get(key)||{};p[r.phase]=r;spans.set(key,p);}
  const attempts=[],timeline=[],prepared=[];let nested=null;
  for(const p of spans.values()) {
    const s=p.start,e=p.end,r=s||e,meta=e?.payload||{};
    timeline.push({id:digest([r.session_id,r.span_id,r.kind]),kind:r.kind,ms:timing(meta.ms),complete:!!s&&!!e,evidence:{start:s?.id??null,end:e?.id??null}});
    if(['model_call','summary'].includes(r.kind)) {
      const normalized=meta.normalized?{...meta.normalized,reasoning_known:meta.normalized.reasoning_known===true || typeof meta.usage?.completion_tokens_details?.reasoning_tokens==='number' || typeof meta.usage?.output_tokens_details?.reasoning_tokens==='number' || typeof meta.usage?.reasoning_tokens==='number'}:null;
      attempts.push({id:digest([r.session_id,r.kind,r.span_id]),kind:r.kind,failed:meta.ok===false,incomplete:!s||!e,evidence:{start:s?.id??null,end:e?.id??null},raw_usage_hash:meta.usage?digest(meta.usage):null,usage:normalizeUsage(normalized,'native')});
      const lost=meta.transport_failed_attempts;if(lost!==undefined && !count(lost))throw Error('invalid retry count');
      for(let i=0;i<(lost||0);i++)attempts.push({id:digest([r.session_id,r.kind,r.span_id,'lost',i]),kind:'transport-failed',failed:true,usage:normalizeUsage(null,'native'),evidence:{end:e?.id??null}});
      if(s?.payload?.prefix_audit)prepared.push({id:digest(s.id),audit:s.payload.prefix_audit,ttft_ms:timing(meta.ttft_ms)});
    }
    if(r.kind==='tool' && meta.nested_code_mode_calls!==undefined) {if(!count(meta.nested_code_mode_calls))throw Error('invalid nested call count');nested=(nested??0)+meta.nested_code_mode_calls;}
  }
  return {adapter:'native-harness-events-v1',accounting:aggregateAttempts(attempts),timeline,
    model_steps:[...spans.values()].some(p=>(p.start||p.end).kind==='model_call')&&[...spans.values()].filter(p=>(p.start||p.end).kind==='model_call').every(p=>count(p.start?.payload?.round))?new Set([...spans.values()].filter(p=>(p.start||p.end).kind==='model_call').map(p=>canonical([p.start.session_id,p.start.run_id,p.start.payload.round]))).size:null,model_attempts:attempts.filter(a=>a.kind==='model_call').length,summary_attempts:attempts.filter(a=>a.kind==='summary').length,
    tools:validation.tools,nested_code_mode_calls:nested,prefix_audit:prepared,validation,
    resource_observations:null,limitations:['no CPU or peak-memory observation unless separately collected','native request audit is not a provider cache guarantee']};
}
function piUsage(message) {
  const raw=message.usage;
  const zeros=raw && ['input','cacheRead','cacheWrite','output'].every(k=>raw[k]===0);
  // Pi initializes zero usage before transport. A zero-shaped session row alone
  // is not evidence that the provider reported zero usage (especially abort/error).
  const unproven=zeros&&!/^[a-f0-9]{64}$/.test(message.provider_usage_receipt_sha256||'');
  return {usage:normalizeUsage(unproven?{cost:raw.cost,actualBilling:raw.actualBilling}:raw,'pi'),usage_evidence:unproven?'unproven-SDK-zero-default':'session-normalized-report'};
}
export function piTrace(input) {
  const original=typeof input==='string'?input.trim().split(/\r?\n/).filter(Boolean).map(line=>JSON.parse(line)):input;
  const rows=unique(original.filter(r=>r.type==='message'||r.type==='compaction'));
  const attempts=[],tools=new Map(),results=new Set(),timeline=[];let compactions=0;
  for(const row of rows) {
    if(row.type==='compaction') {compactions++; // Standard Pi compaction records do not expose summary inference usage.
      attempts.push({id:digest(row.id),kind:'summary',...piUsage(row),evidence:{id:row.id},incomplete:!row.usage});continue;}
    const m=row.message||{};
    if(m.role==='assistant') {
      attempts.push({id:digest(row.id),kind:'model_call',failed:['error','aborted'].includes(m.stopReason),...piUsage(m),raw_usage_hash:m.usage?digest(m.usage):null,evidence:{id:row.id}});
      for(const part of m.content||[])if(part.type==='toolCall') {if(!part.id||tools.has(part.id))throw Error('duplicate/missing Pi tool call');tools.set(part.id,{name:part.name,row:row.id});}
    } else if(m.role==='toolResult') {
      if(!m.toolCallId||results.has(m.toolCallId))throw Error('duplicate/missing Pi tool result');results.add(m.toolCallId);
      // Pi result timestamps alone do not establish tool duration.
      timeline.push({id:digest(row.id),kind:'tool',ms:null,evidence:{id:row.id},failed:m.isError===true});
    }
  }
  const missing=[...tools.keys()].filter(id=>!results.has(id));const orphan=[...results].filter(id=>!tools.has(id));
  if(orphan.length)throw Error('unmatched Pi tool results');
  for(const id of missing)timeline.push({id:digest(id),kind:'tool',ms:null,incomplete:true});
  // Summaries/retries not present in JSONL cannot be assumed absent. The runner must
  // retain a complete provider-attempt journal and mark coverage separately.
  return {adapter:'pi-jsonl-v1',accounting:aggregateAttempts(attempts),timeline,model_steps:null,visible_model_messages:attempts.filter(a=>a.kind==='model_call').length,
    tool_calls:tools.size,unfinished_tool_calls:missing.length,compactions,nested_code_mode_calls:null,
    inference_coverage:'visible-session-records-only',complete_worker_cost:false,resource_observations:null,
    limitations:['Pi JSONL alone cannot prove all retry/summary attempts','Pi catalogue cost is unpriced unless actual billing receipt is supplied']};
}
export function observationTimeline(rows) {
  const allowed=['end_to_end','setup','build','index','test','model','tool','sandbox_startup'];
  const seen=new Set(),timeline=[];
  for(const r of rows) {
    if(!r.id || seen.has(r.id))throw Error('duplicate/missing observation');seen.add(r.id);
    if(!allowed.includes(r.phase) || !['monotonic','wall'].includes(r.clock) || !money(r.start_ms) || !money(r.end_ms) || r.end_ms<r.start_ms || !/^[a-f0-9]{64}$/.test(r.evidence_sha256||''))throw Error('invalid timeline observation');
    for(const k of ['cpu_ms','peak_memory_bytes'])if(r[k]!=null && !money(r[k]))throw Error('invalid observed resource');
    if(r.peak_memory_bytes!=null && !count(r.peak_memory_bytes))throw Error('invalid observed memory byte count');
    timeline.push({id:digest(r.id),phase:r.phase,clock:r.clock,ms:r.end_ms-r.start_ms,cpu_ms:r.cpu_ms??null,peak_memory_bytes:r.peak_memory_bytes??null,evidence_sha256:r.evidence_sha256});
  }
  return {timeline,phase_times_ms:Object.fromEntries(allowed.map(k=>{const selected=timeline.filter(x=>x.phase===k);return [k,selected.length?selected.reduce((n,x)=>n+x.ms,0):null];})),note:'Phase sums may overlap; they are not inferred end-to-end wall time or CPU.'};
}
// Implements native prefix_audit per-message prefix semantics using canonical
// actually-prepared request components, not a serialized whole-body startsWith.
export function preparedRequests(requests,{secrets=[]}={}) {
  const baselines=new Map(),out=[];
  for(const r of requests) {
    const body=r.body;
    if(!body || typeof body!=='object' || !Array.isArray(body.messages||body.input))throw Error('missing prepared message array');
    if(secrets.some(s=>typeof s==='string'&&s.length>0&&canonical([body,r.routing,r.scope,r.session,r.headers]).includes(s)))throw Error('secret exposure in prepared request');
    if(r.routing && Object.keys(r.routing).some(k=>/authorization|cookie|api.?key|auth.?token|credential/i.test(k)))throw Error('credential-bearing routing');
    if(typeof r.routing?.endpoint==='string' && /:\/\/[^/]*@|[?&](?:key|api_key|token|access_token)=/i.test(r.routing.endpoint))throw Error('credential-bearing endpoint');
    if(r.headers && Object.keys(r.headers).some(k=>/authorization|cookie|api.?key/i.test(k)))throw Error('credential-bearing capture must remain private, not adapter input');
    const enough=['scope','session','kind','routing'].every(k=>r[k]!=null && r[k]!=='' && (k!=='routing'||typeof r[k]==='object'&&typeof r[k].endpoint==='string'&&r[k].endpoint!=='')) && typeof body.model==='string' && body.model!=='';
    const key=digest([r.scope,r.session,r.kind]),oversize=(body.messages||body.input).length>8192;
    const prior=enough&&!oversize?baselines.get(key):null;
    const settings=Object.fromEntries(Object.entries(body).filter(([k])=>!['messages','input','tools'].includes(k)));
    const current={messages:(body.messages||body.input).map(digest),tools:digest(body.tools||[]),model:digest(body.model),routing:digest(r.routing),settings:digest(settings),instructions:digest(body.instructions??null),cache_routing_settings:digest({prompt_cache_key:body.prompt_cache_key??null})};
    const changes=[];let common=0,relation='unmeasured';
    if(prior) {
      while(common<Math.min(prior.messages.length,current.messages.length)&&prior.messages[common]===current.messages[common])common++;
      relation=common===prior.messages.length?(common===current.messages.length?'identical':'append_only'):common===current.messages.length?'shortened':'rewritten';
      if(['shortened','rewritten'].includes(relation))changes.push('messages');
      for(const k of ['tools','model','routing','instructions','cache_routing_settings'])if(prior[k]!==current[k])changes.push(k);
    }
    if(enough&&!oversize) {if(!baselines.has(key)&&baselines.size>=16)baselines.delete(baselines.keys().next().value);baselines.set(key,current);}else baselines.delete(key);
    const u=normalizeUsage(r.usage,r.usage_source||'native');
    out.push({id:r.id?digest(r.id):null,relation,reason:!enough?'missing-scope-or-routing':oversize?'message_budget':!prior?'baseline_missing':null,
      shared_messages:prior?common:null,first_changed_message:prior && common<Math.min(prior.messages.length,current.messages.length)?common+1:null,
      cache_relevant_changed:prior?changes.length>0:null,break_causes:changes,
      settings_changed:prior?prior.settings!==current.settings:null,request_hash:digest(body),schema_hash:current.tools,
      prompt_total:u.prompt_total,cache_read:u.cache_read,uncached_input:u.uncached_input,ttft_ms:timing(r.ttft_ms),
      cache_label:u.cache_read===null?'unknown':u.cache_read>0?'observed-cache-read':'observed-zero-cache-read',backend_kv_contents:'opaque'});
  }return out;
}
