import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';
const out='review-evidence/repair';fs.mkdirSync(out,{recursive:true});
fs.cpSync('ui',out+'/baseline-ui',{recursive:true});fs.writeFileSync(out+'/baseline-ui/app.js',spawnSync('git',['show','66296cf:ui/app.js'],{encoding:'utf8'}).stdout);
function run(name,args){const r=spawnSync(process.execPath,args,{encoding:'utf8',timeout:180000});fs.writeFileSync(out+'/'+name+'.log',(r.stdout||'')+(r.stderr||''));console.log(name+' exit='+r.status);console.log(r.stdout);}
run('baseline',['scripts/agent-benchmark-ui-observe.mjs','--ui',out+'/baseline-ui','--probe','review-evidence/child-probe.js','--out',out+'/baseline']);
const source=fs.readFileSync('scripts/test-final-answer-ui.js','utf8');fs.writeFileSync(out+'/original-ui-probe.js',source);
try{fs.writeFileSync('scripts/test-final-answer-ui.js',source.replace("check(childA.transcript.scrollTop===childPosition,","check(childA.transcript.scrollTop!==childPosition,"));const r=spawnSync('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File','scripts/test-ui.ps1'],{encoding:'utf8',timeout:180000});fs.writeFileSync(out+'/normal-mutation.log',(r.stdout||'')+(r.stderr||''));console.log('normal mutation exit='+r.status);console.log(r.stdout);}finally{fs.writeFileSync('scripts/test-final-answer-ui.js',source);}
run('native-pi',['scripts/test-openai-sub.cjs',path.join(process.env.LOCALAPPDATA,'wasm-agent/wa.exe')]);
