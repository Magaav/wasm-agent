const assert=require('node:assert/strict');
const {audit}=require('../scripts/lib/token-audit.cjs');
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
assert.throws(()=>audit([a,{...a,id:'different'}]),/ambiguous_span/);
assert.throws(()=>audit({events:[a,b],has_more:true}),/incomplete_export/);
assert.throws(()=>audit([{}]),/invalid_event/);
assert.equal(audit([]).usage.recorded_calls_cost_usd,null);
assert.equal(audit([]).usage.cached_input_share,null);

const summaryStart=event('s','summary','start',{}),summaryEnd=event('s','summary','end',b.payload);
r=audit([a,b,summaryStart,summaryEnd]);assert.equal(r.usage.summaries,1);
assert.equal(r.usage.recorded_calls_cost_usd,.02);assert.equal(r.prefix.comparisons,0);
const tool=(span,run)=>event(span,'tool','start',{name:'read',arguments_hash:h('f')},'a',run);
r=audit([tool('a','1'),tool('b','1'),tool('c','2')]);
assert.equal(r.tools.repeated_arguments_within_run,1);assert.equal(r.tools.pending,3);
assert.ok(r.limitations.includes('repeated_arguments_are_not_automatically_waste'));
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
  const run=spawnSync(process.execPath,[path.resolve(__dirname,'../scripts/audit-tokens.cjs'),fixture],{encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);assert.equal(JSON.parse(run.stdout).usage.completed_calls,1);
  assert.deepEqual(fs.readFileSync(fixture),before);
  fs.writeFileSync(fixture,'{"DO_NOT_PRINT": INVALID_SECRET}');
  const invalidRun=spawnSync(process.execPath,[path.resolve(__dirname,'../scripts/audit-tokens.cjs'),fixture],{encoding:'utf8'});
  assert.notEqual(invalidRun.status,0);assert.ok(!invalidRun.stderr.includes('INVALID_SECRET'));
} finally {fs.rmSync(scratch,{recursive:true,force:true});}
console.log('ALL PASS');
