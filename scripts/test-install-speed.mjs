// Matched offline output/process-query measurements, not full update/outage proof.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';import {performance} from 'node:perf_hooks';import {pathToFileURL} from 'node:url';
const repo=path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')),'..');
const evidence=path.resolve(process.argv[2]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-install-speed-')));if(process.argv[2]){assert(!fs.existsSync(evidence));fs.mkdirSync(evidence,{recursive:true});}
const bash=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
const native=p=>p.replaceAll('\\','/');let checks=0;function check(v,why){assert(v,why);checks++;}
const current=fs.readFileSync(repo+'/scripts/verify-install.sh','utf8');const baseline=spawnSync('git',['-C',repo,'show','ac914944:scripts/verify-install.sh'],{encoding:'utf8'});assert.equal(baseline.status,0);
function segment(text){const escape=text.match(/json_escape\(\) \{[\s\S]*?\n\}/)?.[0]||text.match(/^json_escape\(\) \{.*$/m)?.[0];assert(escape);const start=text.lastIndexOf('if [ "$JSON" = "1" ]; then');const end=text.indexOf('\nelse\n',start);assert(start>0&&end>start);return {escape,body:text.slice(start,end)+'\nfi\n'};}
const b=segment(baseline.stdout),c=segment(current);
const escaped=s=>"$'"+s.replaceAll('\\','\\\\').replaceAll("'","\\'").replaceAll('\n','\\n').replaceAll('\r','\\r').replaceAll('\t','\\t').replaceAll('\b','\\b').replaceAll('\f','\\f')+"'";
function plan(label,s,details){const file=evidence+'/'+label+'.sh';fs.writeFileSync(file,'#!/usr/bin/env bash\nset -euo pipefail\nJSON=1\nchecks='+details.length+';failed=0;skipped=0\nresults=()\n'+s.escape+'\n'+details.map(d=>'results+=('+escaped('ok\tname "\\ Unicode Ω\t'+d)+')').join('\n')+'\n'+s.body);return file;}
const ordinary=Array.from({length:75},(_,i)=>'row'+i+' C:\\path "quoted" Ω');
const files={baseline:plan('baseline-output',b,ordinary),candidate:plan('candidate-output',c,ordinary)};
const timings={baseline:[],candidate:[]};let expected;
for(let sample=0;sample<3;sample++)for(const label of sample%2?['candidate','baseline']:['baseline','candidate']){
 const start=performance.now();const r=spawnSync(bash,[native(files[label])],{encoding:'utf8',timeout:60000});timings[label].push(Math.round((performance.now()-start)*1000)/1000);fs.writeFileSync(evidence+'/'+label+'-'+sample+'.stdout',r.stdout||'');fs.writeFileSync(evidence+'/'+label+'-'+sample+'.stderr',r.stderr||'');check(r.status===0,label+' output failed '+r.stderr);const value=JSON.parse(r.stdout);check(value.checks===75&&value.results.length===75,'counts drift');if(!expected)expected=value;else check(JSON.stringify(value)===JSON.stringify(expected),'ordinary JSON changed');
}
const exact=['embedded\ttab','line\nnext','CR\rnext','backspace\bformfeed\f','quotes" slash\\ Ω'];
const exactFile=plan('candidate-exact',c,exact);
// Git Bash igncr can strip CR while parsing ANSI-C array literals. Introduce
// that test byte at runtime, rather than mistaking parser loss for JSON loss.
fs.writeFileSync(exactFile,fs.readFileSync(exactFile,'utf8').replace('if [ "$JSON" = "1" ]; then',"printf -v results[2] '%b' 'ok\\tname \\\"\\\\ Unicode Ω\\tCR\\015next'\nif [ \"$JSON\" = \"1\" ]; then"));
const exactResult=spawnSync(bash,[native(exactFile)],{encoding:'utf8'});check(exactResult.status===0,exactResult.stderr);const result=JSON.parse(exactResult.stdout);check(result.results.every((row,i)=>row.detail===exact[i]),'detail bytes lost');
const cached=await import(pathToFileURL(repo+'/scripts/sentinel-install-proof.mjs').href);
const oldFile=evidence+'/baseline-proof.mjs';const old=spawnSync('git',['-C',repo,'show','ac914944:scripts/sentinel-install-proof.mjs'],{encoding:'utf8'});assert.equal(old.status,0);fs.writeFileSync(oldFile,old.stdout);const original=await import(pathToFileURL(oldFile).href);
const ids=[process.pid,process.ppid];const identityTimings={baseline:[],candidate:[]};for(let sample=0;sample<3;sample++)for(const label of sample%2?['candidate','baseline']:['baseline','candidate']){
 const start=performance.now();const value=label==='candidate'?cached.processIdentities(ids):ids.map(original.processIdentity);identityTimings[label].push(Math.round((performance.now()-start)*1000)/1000);check(value.length===2&&value.every((row,i)=>row.pid===ids[i]&&row.created&&row.image),'identity evidence missing');if(label==='baseline')expected=value;else if(expected)check(value.every((row,i)=>row.created===expected[i].created&&row.image===expected[i].image),'process query evidence changed');
}
check(!c.body.includes('cut -f')&&!c.escape.includes('sed '),'subprocess serialization remains');
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const receipt={ok:true,checks,skipped:0,samples:3,serialization_ms:timings,serialization_median_ms:{baseline:median(timings.baseline),candidate:median(timings.candidate)},process_pair_ms:identityTimings,process_pair_median_ms:{baseline:median(identityTimings.baseline),candidate:median(identityTimings.candidate)},structural:{verification_source_checks_before_after:'preserved',remote_queries_per_verify:2,prior_remote_queries_per_verify:4,powershell_queries_per_snapshot:1,prior_powershell_queries_per_snapshot:2,serialization_commands_per75checks:0,prior_serialization_commands_at_least:525},scope:'offline microbenchmarks; full update time/outage not measured',evidence};fs.writeFileSync(evidence+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
