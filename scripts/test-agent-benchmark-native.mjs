#!/usr/bin/env node
// Actual source provider/serializer + mock HTTP + native prefix-audit parity proof.
import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
import {nativeTrace,preparedRequests,digest} from './agent-benchmark-telemetry.mjs';
const [binary,out]=process.argv.slice(2);if(!binary||!out||fs.existsSync(out))throw Error('<native-binary> <fresh-evidence>');fs.mkdirSync(out,{recursive:true});fs.mkdirSync(path.join(out,'.wasm-agent','operations'),{recursive:true});
const root=process.cwd();const source=fs.readFileSync('scripts/test-observability.lua','utf8');
const suffix="\nlocal prepared={};for i,body in ipairs(sent)do prepared[i]={id='actual-prepared-'..i,scope='hermetic-test',session=run,kind='model_call',routing={endpoint='mock-opencode',session=run},body=body}end;assert(host.write_file("+JSON.stringify(path.resolve(out,'prepared.json'))+",json.encode(prepared)));assert(host.write_file("+JSON.stringify(path.resolve(out,'events.json'))+",host.sql_query('SELECT id,session_id,run_id,span_id,seq,kind,phase,at,payload FROM harness_events ORDER BY seq','[]')))\n";
fs.writeFileSync(path.join(out,'oracle.lua'),source+suffix);
const env=isolatedEnvironment(path.resolve(out));
const r=spawnSync(binary,['--db',path.resolve(out,'native.db')],{cwd:root,env:{...env,WASM_AGENT_HOME:path.resolve(out),WASM_AGENT_LUA_ROOT:root,WA_SCRIPT:path.resolve(out,'oracle.lua'),WASM_AGENT_ENVELOPE_MODE:'full',WASM_AGENT_MANAGED:'0',WA_GRAPH_WATCH:'0'},encoding:'utf8',timeout:120000,maxBuffer:8388608});
for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(out,stream),r[stream]||'');if(r.status!==0)throw Error('native mock source proof failed: '+r.stderr);
const prepared=JSON.parse(fs.readFileSync(path.join(out,'prepared.json'),'utf8')),events=JSON.parse(fs.readFileSync(path.join(out,'events.json'),'utf8'));
const observed=preparedRequests(prepared),native=events.map(e=>({...e,payload:JSON.parse(e.payload)})).filter(e=>e.kind==='model_call'&&e.phase==='start'&&e.payload.prefix_audit?.relation==='append_only');
if(observed[1]?.relation!=='append_only'||native.length<1||observed[1].cache_relevant_changed!==false)throw Error('native per-message prefix parity failed');
const report=nativeTrace({events,has_more:false});if(report.accounting.complete_cost!==false)throw Error('lost/pending/summary usage must prevent complete cost');
const receipt={ok:true,benchmark_solver_inference_calls:0,real_provider_calls:0,measurement:'actual-native-source-loop-with-mock-provider',native_assertions:r.stdout.trim(),prepared_relation:observed[1].relation,events:events.length,adapter_attempts:report.accounting.attempts,raw_hashes:{events:digest(events),prepared:digest(prepared)}};
fs.writeFileSync(path.join(out,'adapter-report.json'),JSON.stringify(report,null,2));fs.writeFileSync(path.join(out,'prefix-report.json'),JSON.stringify(observed,null,2));fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
