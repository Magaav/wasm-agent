const assert=require('node:assert/strict');
const {audit}=require('./lib/token-audit.cjs');
const h=c=>c.repeat(64);let seq=0;
const event=(span,kind,phase,payload,session='a',run='r')=>({id:'e'+(++seq),seq,session_id:session,run_id:run,span_id:span,kind,phase,payload});
const start=(span,extra={},session='a')=>event(span,'model_call','start',{
  system_hash:h('a'),schema_hash:h('b'),model:'fixture',provider:'local',settings:{reasoning:'high'},
  attribution:{host:'localhost'},runtime:{source_hash:h('c')},context:{summary_watermark:0},
  prompt_shape:{schema_bytes:100,assistant_bytes:900,reasoning_source_bytes:300},...extra},session);
const end=(span,extra={},session='a')=>event(span,'model_call','end',{
  ok:true,ms:10,ttft_ms:2,normalized:{known:true,cache_known:true,cost_known:true,prompt:100,output:20,
    total:120,reasoning:5,input:20,cacheRead:80,cacheWrite:0,cost:.01},...extra},session);
let r=audit({events:[start('1'),end('1'),start('2'),end('2')]});
assert.equal(r.usage.cached_input_share,.8);assert.equal(r.usage.request_cache_hit_share,1);
assert.equal(r.usage.observed_output_tokens,40); // Reasoning is not added twice.
assert.equal(r.usage.recorded_calls_cost_usd,.02);assert.equal(r.prefix.stable_recorded_components,1);
assert.equal(r.average_request_bytes.reasoning_source_bytes.mean,300);
assert.equal(r.verified_task_efficiency,null);

const changed=start('3',{schema_hash:h('c'),context:{summary_watermark:20}});
r=audit([start('1'),end('1'),changed,end('3')]);
assert.equal(r.prefix.changed_fields.schema_hash,1);assert.equal(r.prefix.changed_fields.summary_watermark,1);
assert.equal(r.prefix.stable_recorded_components,0);
// Interleaving sessions must not compare unrelated prefixes.
r=audit([start('1'),start('2',{system_hash:h('d')},'b'),end('2',{},'b'),end('1'),start('3'),end('3')]);
assert.equal(r.prefix.comparisons,1);assert.equal(r.prefix.stable_recorded_components,1);
const zero=end('2');zero.payload.normalized={...zero.payload.normalized,input:100,cacheRead:0};
const zeroRows=[start('1'),end('1'),start('2'),zero];zero.seq=++seq;
r=audit(zeroRows);
assert.equal(r.prefix.stable_components_zero_cache_calls,1);
assert.equal(r.usage.request_cache_hit_share,.5);
assert.ok(r.limitations.includes('cache_cause_not_inferred'));

const missing=end('2',{ok:false,normalized:{known:false,cache_known:false,cost_known:false}});
const missingRows=[start('1'),end('1'),start('2'),missing,start('3')];missing.seq=++seq;
r=audit(missingRows);
assert.equal(r.usage.missing_usage,1);assert.equal(r.usage.pending_calls,1);
assert.equal(r.usage.observed_priced_cost_usd,.01);assert.equal(r.usage.recorded_calls_cost_usd,null);
assert.equal(r.usage.failed_calls,1);assert.equal(r.usage.average_prompt_tokens,100);
assert.equal(r.usage.cached_input_share,.8); // Same population in numerator and denominator.
const orphan=end('orphan');r=audit([orphan]);assert.equal(r.usage.unmatched_ends,1);
assert.equal(r.usage.recorded_calls_cost_usd,null);

const invalid=end('1');invalid.payload.normalized.cacheRead=200;
const invalidStart=start('1');invalid.seq=++seq;
r=audit([invalidStart,invalid]);assert.equal(r.usage.missing_cache,1);
assert.equal(r.usage.cached_input_share,null);assert.equal(r.usage.recorded_calls_cost_usd,null);
const badReason=end('x');badReason.payload.normalized.reasoning=1000;
const badStart=start('x');badReason.seq=++seq;
r=audit([badStart,badReason]);assert.equal(r.usage.invalid_usage,1);
assert.equal(r.usage.observed_output_tokens,0);
const unknown=start('2');delete unknown.payload.schema_hash;
r=audit([start('1'),unknown]);assert.equal(r.prefix.incomplete_metadata_pairs,1);
assert.equal(r.prefix.stable_recorded_components,0);

const a=start('1'),b=end('1');r=audit([a,b,a,b]);
assert.equal(r.events,2);assert.equal(r.duplicate_events,2);assert.equal(r.usage.completed_calls,1);
assert.throws(()=>audit([a,{...a,payload:{different:true}}]),/conflicting_duplicate/);
assert.throws(()=>audit([a,{...a,session_id:'different'}]),/conflicting_duplicate/);
assert.throws(()=>audit([a,{...a,id:'different'}]),/ambiguous_span/);
assert.throws(()=>audit({events:[a,b],has_more:true}),/incomplete_export/);
assert.throws(()=>audit([{}]),/invalid_event/);
assert.equal(audit([]).usage.recorded_calls_cost_usd,null);
assert.equal(audit([]).usage.cached_input_share,null);
// Real Lua telemetry encodes an empty payload table as [], including run starts.
const emptyRun=event('empty-run','run','start',[]),endedRun=event('empty-run','run','end',{ms:7});
assert.equal(audit([emptyRun,endedRun]).timing.run_ms.p50,7);
assert.equal(audit([{...emptyRun,payload:'[]'},endedRun]).events,2);
assert.throws(()=>audit([{...emptyRun,payload:[{unexpected:true}]}]),/invalid_event_payload/);
r=audit([event('empty-model','model_call','start',[]),event('empty-model','model_call','end',[])]);
assert.equal(r.usage.missing_usage,1);assert.equal(r.usage.recorded_calls_cost_usd,null);

const summaryStart=event('s','summary','start',{}),summaryEnd=event('s','summary','end',b.payload);
r=audit([a,b,summaryStart,summaryEnd]);assert.equal(r.usage.summaries,1);
assert.equal(r.usage.recorded_calls_cost_usd,.02);assert.equal(r.prefix.comparisons,0);
const tool=(span,run,name='read',session='a')=>event(span,'tool','start',{name,arguments_hash:h('f')},session,run);
const toolEnd=(span,run,name,ms,ok=true,clock='monotonic',session='a')=>event(span,'tool','end',{name,ms,ok,clock},session,run);
r=audit([tool('a','1'),tool('b','1'),tool('c','2')]);
assert.equal(r.tools.repeated_arguments_within_run,1);assert.equal(r.tools.pending,3);
assert.ok(r.limitations.includes('repeated_arguments_are_not_automatically_waste'));

// Tool elapsed time is attributed without exposing arguments or private plugin names.
const elapsedRows=[];
elapsedRows.push(event('run-time','run','start',{},'a','timed'));
elapsedRows.push(event('model-time','model_call','start',{},'a','timed'));
elapsedRows.push(event('model-time','model_call','end',{ok:true,ms:1500,clock:'monotonic',normalized:{known:false}},'a','timed'));
elapsedRows.push(tool('read-time','timed','read'),toolEnd('read-time','timed','read',100));
const timedBashStart=tool('bash-fast','timed','bash');
const timedBashEnd=toolEnd('bash-fast','timed','bash',1000);
timedBashEnd.payload.execution_timing={schema_version:1,clock:'monotonic',complete:true,
  setup_ms:10,accepted_record_ms:5,spawn_ms:20,execution_ms:800,drain_cleanup_ms:5,output_sync_ms:10,
  measured_ms:850,unattributed_ms:50,total_ms:900,final_state_record_excluded:true};
elapsedRows.push(timedBashStart,timedBashEnd);
elapsedRows.push(tool('bash-slow','timed','bash'),toolEnd('bash-slow','timed','bash',9000,false));
elapsedRows.push(event('run-time','run','end',{ms:12000,clock:'monotonic'},'a','timed'));
elapsedRows.push(tool('pending-bash','pending','bash'));
elapsedRows.push(tool('private-tool','private','private_customer_plugin'),
  toolEnd('private-tool','private','private_customer_plugin',25));
r=audit(elapsedRows);
assert.equal(r.tools.completed,4);assert.equal(r.tools.pending,1);assert.equal(r.tools.failed,1);
assert.equal(r.tools.measured_elapsed,4);assert.equal(r.tools.unmeasured_elapsed,0);
assert.equal(r.tools.elapsed.total_ms,10125);assert.equal(r.tools.elapsed.by_clock.monotonic.total_ms,10125);
assert.equal(r.tools.by_name.bash.completed,2);assert.equal(r.tools.by_name.bash.elapsed.total_ms,10000);
assert.equal(r.tools.by_name.bash.elapsed.p50_ms,1000);assert.equal(r.tools.by_name.bash.elapsed.p95_ms,9000);
assert.equal(r.tools.by_name.bash.elapsed.failed_ms,9000);
assert.equal(r.tools.by_name.bash.duration_buckets['1s_to_10s'].calls,2);
assert.equal(r.tools.by_name.bash.duration_buckets['1s_to_10s'].total_ms,10000);
assert.equal(r.tools.by_name.bash.share_of_measured_tool_ms,10000/10125);
assert.equal(r.tools.execution_phases.reported,1);assert.equal(r.tools.execution_phases.complete,1);
assert.equal(r.tools.execution_phases.tool_ms,1000);assert.equal(r.tools.execution_phases.execution_ms,800);
assert.equal(r.tools.execution_phases.executor_overhead_ms,200);assert.equal(r.tools.execution_phases.phase_totals_ms.wrapper_ms,100);
assert.equal(r.tools.execution_phases.phase_timing.execution_ms.p50_ms,800);
assert.equal(r.tools.execution_phases.execution_share,.8);assert.equal(r.tools.execution_phases.by_name.bash.samples,1);
assert.equal(r.tools.by_name.other.completed,1);
const incompleteTimingStart=tool('incomplete-timing','phase-errors','bash');
const incompleteTimingEnd=toolEnd('incomplete-timing','phase-errors','bash',10);
incompleteTimingEnd.payload.execution_timing={schema_version:1,clock:'monotonic',complete:false};
const invalidTimingStart=tool('invalid-timing','phase-errors','bash');
const invalidTimingEnd=toolEnd('invalid-timing','phase-errors','bash',10);
invalidTimingEnd.payload.execution_timing={schema_version:1,clock:'monotonic',complete:true,
  setup_ms:1,accepted_record_ms:1,spawn_ms:1,execution_ms:1,drain_cleanup_ms:1,output_sync_ms:1,
  measured_ms:99,unattributed_ms:1,total_ms:7};
const phaseErrors=audit([incompleteTimingStart,incompleteTimingEnd,invalidTimingStart,invalidTimingEnd]);
assert.equal(phaseErrors.tools.execution_phases.reported,2);assert.equal(phaseErrors.tools.execution_phases.complete,0);
assert.equal(phaseErrors.tools.execution_phases.incomplete,1);assert.equal(phaseErrors.tools.execution_phases.invalid,1);
const slowAStart=tool('slow-a','slow','bash'),slowAEnd=toolEnd('slow-a','slow','bash',60000);
const slowBStart=tool('slow-b','slow','bash'),slowBEnd=toolEnd('slow-b','slow','bash',120000,false);
slowBEnd.payload.error='deadline_exceeded';
const slowCStart=tool('slow-c','slow','bash');slowCStart.payload.arguments_hash=h('e');
const slowCEnd=toolEnd('slow-c','slow','bash',70000);
const slowAudit=audit([slowAStart,slowAEnd,slowBStart,slowBEnd,slowCStart,slowCEnd]);
assert.equal(slowAudit.tools.by_name.bash.duration_buckets.gte_60s.calls,3);
assert.equal(slowAudit.tools.by_name.bash.duration_buckets.gte_60s.total_ms,250000);
assert.equal(slowAudit.tools.by_name.bash.duration_buckets.gte_60s.failed_ms,120000);
assert.equal(slowAudit.tools.by_name.bash.duration_buckets.gte_60s.deadline_exceeded,1);
assert.equal(slowAudit.tools.by_name.bash.duration_buckets.gte_60s.deadline_exceeded_ms,120000);
assert.equal(slowAudit.tools.slow_bash_argument_groups.calls,3);
assert.equal(slowAudit.tools.slow_bash_argument_groups.distinct_groups,2);
assert.equal(slowAudit.tools.slow_bash_argument_groups.repeated_groups,1);
assert.equal(slowAudit.tools.slow_bash_argument_groups.largest_group_calls,2);
assert.ok(!JSON.stringify(r).includes('private_customer_plugin'));
assert.equal(r.run_timing.completed_runs,1);assert.equal(r.run_timing.decomposed_runs,1);
assert.equal(r.run_timing.decomposed_run_ms,12000);assert.equal(r.run_timing.model_ms,1500);
assert.equal(r.run_timing.tool_ms,10100);assert.equal(r.run_timing.bash_ms,10000);
assert.equal(r.run_timing.unclassified_ms,400);
assert.equal(r.run_timing.bash_share_of_decomposed_run_ms,10000/12000);
assert.equal(r.run_timing.non_monotonic_clock_runs,0);
assert.ok(r.limitations.includes('summed_span_time_is_not_global_wall_clock'));

const missingMs=[tool('missing-ms','missing','bash'),toolEnd('missing-ms','missing','bash',undefined)];
r=audit(missingMs);assert.equal(r.tools.unmeasured_elapsed,1);assert.equal(r.tools.elapsed.samples,0);
const mismatchStart=tool('mismatch','mismatch','read'),mismatchEnd=toolEnd('mismatch','mismatch','bash',1);
assert.throws(()=>audit([mismatchStart,mismatchEnd]),/inconsistent_tool_name/);
r=audit([tool('wall-clock','wall','read'),toolEnd('wall-clock','wall','read',7,true,'wall-fallback')]);
assert.equal(r.tools.elapsed.by_clock.wall_fallback.total_ms,7);
const incompleteRun=[event('incomplete-run','run','start',{},'a','incomplete'),tool('unfinished','incomplete','bash'),
  event('incomplete-run','run','end',{ms:20,clock:'monotonic'},'a','incomplete')];
r=audit(incompleteRun);assert.equal(r.run_timing.incomplete_child_timing_runs,1);assert.equal(r.run_timing.decomposed_runs,0);
const inconsistentRun=[event('short-run','run','start',{},'a','short'),tool('long-tool','short','bash'),
  toolEnd('long-tool','short','bash',11),event('short-run','run','end',{ms:10,clock:'monotonic'},'a','short')];
r=audit(inconsistentRun);assert.equal(r.run_timing.inconsistent_runs,1);assert.equal(r.run_timing.decomposed_runs,0);
const hugeToolA=tool('huge-tool-a','huge-a','bash'),hugeToolAEnd=toolEnd('huge-tool-a','huge-a','bash',Number.MAX_SAFE_INTEGER);
const hugeToolB=tool('huge-tool-b','huge-b','bash'),hugeToolBEnd=toolEnd('huge-tool-b','huge-b','bash',1);
assert.throws(()=>audit([hugeToolA,hugeToolAEnd,hugeToolB,hugeToolBEnd]),/tool_time_total_exceeds_safe_integer/);
const measured=start('measured',{prefix_audit_ms:2,prefix_audit:{schema_version:1,relation:'rewritten',first_changed_message:2,tools_changed:true,settings_changed:false,routing_changed:true}});
r=audit([measured,end('measured')]);assert.equal(r.prepared_prefix.measured,1);
assert.equal(r.timing.prefix_audit_ms.p50,2);assert.equal(r.prepared_prefix.rewritten,1);assert.equal(r.prepared_prefix.tools_changed,1);
assert.equal(r.prepared_prefix.routing_changed,1);assert.equal(r.prepared_prefix.settings_changed,0);
assert.equal(audit([start('old'),end('old')]).prepared_prefix.unmeasured,1);
const privateEvent=start('private',{system_hash:h('e'),arbitrary_secret:'DO_NOT_PRINT',settings:{secret:'DO_NOT_PRINT'}});
assert.ok(!JSON.stringify(audit([privateEvent,end('private')])).includes('DO_NOT_PRINT'));
const huge=end('huge');huge.payload.normalized={known:true,cache_known:false,cost_known:false,prompt:Number.MAX_SAFE_INTEGER,output:0};
assert.throws(()=>audit([end('small'),huge]),/safe_integer/);
const reversedStart=start('reverse'),reversedEnd=end('reverse');
assert.throws(()=>audit([{...reversedStart,seq:reversedEnd.seq+1},reversedEnd]),/inconsistent_span/);
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'wa-audit-test-'));
try {
  const fixture=path.join(scratch,'export.json');
  fs.writeFileSync(fixture,JSON.stringify({events:[a,b]}));
  const before=fs.readFileSync(fixture);
  const run=spawnSync(process.execPath,[path.resolve(__dirname,'audit-tokens.cjs'),fixture],{encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);assert.equal(JSON.parse(run.stdout).usage.completed_calls,1);
  assert.deepEqual(fs.readFileSync(fixture),before);
  fs.writeFileSync(fixture,'{"DO_NOT_PRINT": INVALID_SECRET}');
  const invalidRun=spawnSync(process.execPath,[path.resolve(__dirname,'audit-tokens.cjs'),fixture],{encoding:'utf8'});
  assert.notEqual(invalidRun.status,0);assert.ok(!invalidRun.stderr.includes('INVALID_SECRET'));
} finally {fs.rmSync(scratch,{recursive:true,force:true});}
console.log('ALL PASS');
