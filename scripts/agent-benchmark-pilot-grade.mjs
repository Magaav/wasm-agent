// Untrusted candidate Lua executes only in a fresh networkless tool container.
// The grader is added AFTER the contestant has settled; never to its live box.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import cp from 'node:child_process';import {fileURLToPath} from 'node:url';import {createToolSandbox} from './agent-benchmark-sandbox.mjs';import {prepareGradeOracle} from './agent-benchmark-binding.mjs';
export function gradePilotCandidate(generation,taskRoot,{imageId,evidence,restartLoss=false}){
 const oracle=prepareGradeOracle(taskRoot,evidence),sandbox=createToolSandbox(generation,{imageId});const privateDir='.grade-'+crypto.randomBytes(12).toString('hex'),prefix='/tmp/work/'+privateDir;const results=[];
 try{
  const repository=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
  const schema=cp.spawnSync('git',['-C',repository,'show','dc11c4626358438514624afa05c20bacb68cdbe7:lua/core/schema.sql'],{encoding:'utf8',timeout:15000});if(schema.status!==0)throw Error('pinned original SQL schema unavailable');
  const oracleText="EMBEDDED['lua/core/schema.sql']="+JSON.stringify(schema.stdout)+'\n'+fs.readFileSync(oracle,'utf8');
  sandbox.importTask(taskRoot);sandbox.call('write_file',[privateDir+'/hidden-oracle.lua',oracleText]);
  for(const phase of ['seed','restart']){
   if(phase==='restart'&&restartLoss)sandbox.call('exec',['rm -f '+prefix+'/grade.db','',10]);
   const started=performance.now();const command='mkdir -p '+prefix+'/home && env WA_SCRIPT='+prefix+'/hidden-oracle.lua WASM_AGENT_LUA_ROOT=/tmp/work WASM_AGENT_HOME='+prefix+'/home WA_BINDING_PHASE='+phase+' WA_GRAPH_WATCH=0 WASM_AGENT_MANAGED=0 /usr/local/bin/wa --db '+prefix+'/grade.db';
   const r=JSON.parse(sandbox.call('exec',[command,'',120]));let summary=null;try{summary=JSON.parse(r.stdout.trim());}catch{}
   fs.writeFileSync(path.join(evidence,phase+'.stdout'),r.stdout);fs.writeFileSync(path.join(evidence,phase+'.stderr'),r.stderr);results.push({phase,exit:r.code,summary,elapsed_ms:performance.now()-started});if(r.code!==0)break;
  }
  return {pass:results.length===2&&results.every(r=>r.exit===0&&r.summary?.ok&&r.summary.provider_calls===0&&r.summary.planner_client_calls===0),results,imageId,sql_schema_sha256:crypto.createHash('sha256').update(schema.stdout).digest('hex'),executed_oracle_sha256:crypto.createHash('sha256').update(oracleText).digest('hex'),oracle_sha256:crypto.createHash('sha256').update(fs.readFileSync(oracle)).digest('hex'),isolation:'fresh networkless container; no solver process remains',cost:null};
 }finally{sandbox.stop();}
}
