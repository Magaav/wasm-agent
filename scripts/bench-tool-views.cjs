#!/usr/bin/env node
// Retained-output contract probe, not a paid-model A/B benchmark.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawnSync}=require('node:child_process');
const mode=process.argv[2];
if (!['read','tail'].includes(mode) || process.argv.length!==3) {
  console.error('Usage: node scripts/bench-tool-views.cjs read|tail\nThe old runs-per-arm and TOOL_BUDGET benchmark is retired; no model is called.');
  process.exit(2);
}
const repo=path.resolve(__dirname,'..');
let binary=path.resolve(process.env.WA_BIN||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
if(process.platform==='win32'&&!fs.existsSync(binary)&&fs.existsSync(binary+'.exe')) binary+='.exe';
if (!fs.existsSync(binary)) {console.error('Candidate binary missing; build rust/Cargo.toml first or set WA_BIN.');process.exit(1);}
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-view-probe-'));
const env={...process.env};
for(const key of Object.keys(env)) if(/^(WASM_AGENT_|WA_)/.test(key)) delete env[key];
Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(repo,'scripts/bench-tool-views.lua'),WA_VIEW_PROBE:mode});
const result=spawnSync(binary,['--db',path.join(root,'fixture.db')],{cwd:root,env,encoding:'utf8',timeout:30000,maxBuffer:1024*1024,windowsHide:true});
try {
  if(result.status!==0) throw Error('fixture process failed or timed out');
  const report=JSON.parse(result.stdout.trim());
  if(report.schema!=='wasm-agent.tool-view-probe/v1'||report.distinct_payloads!==true
      ||report.exact_original_roundtrip!==true||report.model_calls!==0) throw Error('invalid fixture receipt');
  console.log(JSON.stringify(report,null,2));
  fs.rmSync(root,{recursive:true});
} catch(error) {
  fs.writeFileSync(path.join(root,'stdout.log'),result.stdout||'');
  fs.writeFileSync(path.join(root,'stderr.log'),result.stderr||'');
  console.error('tool view probe failed: '+error.message+'; evidence: '+root);
  process.exitCode=1;
}
