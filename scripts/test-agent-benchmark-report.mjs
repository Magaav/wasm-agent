import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';
const out=process.env.WA_BENCHMARK_REPORT_ROOT;assert(out&&path.isAbsolute(out));fs.mkdirSync(out);
test('existing Python reporter uses strict Node adapters on actual native SQLite and realistic Pi JSONL',()=>{
 assert(process.env.WA_BENCHMARK_NATIVE_DB,'actual native mock-test DB required');fs.mkdirSync(path.join(out,'wasm'));fs.copyFileSync(process.env.WA_BENCHMARK_NATIVE_DB,path.join(out,'wasm','wa.db'));
 fs.mkdirSync(path.join(out,'pi','session'),{recursive:true});
 const pi=[{type:'session',id:'s',version:3,timestamp:'2026-10-01T00:00:00Z'},{type:'message',id:'one',parentId:null,message:{role:'assistant',content:[{type:'text',text:'private final output'}],api:'openai-responses',provider:'mock',model:'fixture',usage:{input:20,cacheRead:80,cacheWrite:0,output:10,totalTokens:110,cost:{total:0}},stopReason:'stop',timestamp:1790000000000}},{type:'compaction',id:'two',parentId:'one',summary:'private summary',firstKeptEntryId:'one',tokensBefore:110}];
 fs.writeFileSync(path.join(out,'pi','session','session.jsonl'),pi.map(JSON.stringify).join('\n'));
 fs.writeFileSync(path.join(out,'report.json'),JSON.stringify({fixture:'offline-only',source:'fixed',arms:{wasm:{exit:0,timedOut:false,oracle:{pass:true}},pi:{exit:124,timedOut:true,oracle:{pass:true}}},cleanup:{unknown:true}}));
 fs.writeFileSync(path.join(out,'fixture.json'),JSON.stringify({referenceRatesUsdPerMillion:{uncached_input:1,cache_read:1,cache_write:1,output:1}}));
 const r=spawnSync('python',['scripts/agent-benchmark-report.py',out,path.join(out,'fixture.json')],{encoding:'utf8',timeout:30000});fs.writeFileSync(path.join(out,'stdout'),r.stdout||'');fs.writeFileSync(path.join(out,'stderr'),r.stderr||'');assert.equal(r.status,0,r.stderr);
 const j=JSON.parse(r.stdout);assert.equal(j.arms.pi.accounting.actual_cost,null);assert.equal(j.arms.pi.hypotheticalReferenceCostUsd,null);assert.equal(j.arms.pi.finish,'oracle-pass-at-timeout');assert.equal(j.arms.wasm.finish,'normal-process-exit');assert.equal(j.arms.wasm.deliverableFinished,null);assert.equal(j.arms.wasm.accounting.complete_cost,false);assert(!r.stdout.includes('private final output'));assert(!r.stdout.includes('private summary'));
});
