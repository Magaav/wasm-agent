// Explicit verification-only historical generation recovery. Never installs or edits records.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {sourceIdentity,processIdentities} from './sentinel-install-proof.mjs';
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const record=p=>Object.fromEntries(fs.readFileSync(p,'utf8').trim().split(/\r?\n/).map(line=>{const n=line.indexOf('=');if(n<1)throw Error('historical_record_invalid');return [line.slice(0,n),line.slice(n+1)];}));
function git(root,...args){const r=spawnSync('git',['-C',root,...args],{maxBuffer:8*1024*1024,windowsHide:true,timeout:60000});if(r.status!==0)throw Error('historical_git_failed:'+args[0]);return r.stdout;}
export function verifyHistorical(root,install,intent,binding,evidence,environment=process.env){
 if(environment.WASM_AGENT_IN_TURN==='1')throw Error('historical_requires_external_executor');
 if(!environment.WASM_AGENT_HOME)throw Error('explicit_runtime_home_required');
 const before=sourceIdentity(root),effect=read(path.join(evidence,'effect.json'));
 const installed=record(path.join(install,'installed.txt')),result=read(path.join(evidence,'result.json'));
 const originalFiles=[path.join(install,'installed.txt'),...['intent.json','binding.json','effect.json','result.json'].map(n=>path.join(evidence,n))].map(target=>({target,sha256:hash(fs.readFileSync(target))}));
 const fail=why=>{throw Error(why);};let checks=0;const check=(v,why)=>{if(!v)fail(why);checks++;};
 const stamp=v=>typeof v==='number'?v*1000:Date.parse(v),now=Date.now();
 check(/^[a-f0-9]{40}$/.test(intent.expected_sha)&&intent.id&&intent.session&&intent.owner,'historical_intent_invalid');
 check(binding.id===intent.id&&binding.parent===intent.session&&binding.owner===intent.owner&&JSON.stringify(binding.intent)===JSON.stringify(intent),'historical_binding_mismatch');
 check(effect.id===intent.id&&effect.expected_sha===intent.expected_sha&&effect.parent===binding.parent&&effect.owner===binding.owner,'historical_effect_mismatch');
 const tree=git(root,'rev-parse',intent.expected_sha+'^{tree}').toString().trim();
 check(tree===effect.tree&&tree===installed.tree,'historical_tree_mismatch');
 const ancestor=spawnSync('git',['-C',root,'merge-base','--is-ancestor',intent.expected_sha,before.resolved_commit],{windowsHide:true});check(ancestor.status===0,'historical_source_not_ancestor');
 check(installed.resolved_commit===intent.expected_sha&&installed.source_provenance==='clean-built-by-deploy'&&installed.record_role==='final'&&installed.dirty==='0','historical_installed_source_mismatch');
 check(result.ok===true&&result.request_id===intent.id&&result.expected_sha===intent.expected_sha,'historical_result_mismatch');
 check(Number.isFinite(stamp(installed.at))&&Number.isFinite(stamp(result.at))&&stamp(intent.queued_at)<=stamp(installed.at)&&stamp(installed.at)<=stamp(result.at)&&stamp(result.at)<=now,'historical_timestamps_invalid');
 const blob=rel=>git(root,'show',intent.expected_sha+':'+rel);
 check(hash(blob('scripts/deploy.sh'))===effect.script_sha256,'historical_deployer_hash_mismatch');
 const suffix=process.platform==='win32'?'.exe':'',node=path.join(install,'wa'+suffix),sentinel=path.join(install,'wa-sentinel'+suffix);
 const nodeHash=hash(fs.readFileSync(node)),sentinelHash=hash(fs.readFileSync(sentinel));
 check(nodeHash===installed.node_sha256&&nodeHash===installed.sha256&&nodeHash===result.node_sha256,'historical_node_hash_mismatch');
 check(sentinelHash===installed.sentinel_sha256&&sentinelHash===result.sentinel_sha256,'historical_sentinel_hash_mismatch');
 const names=JSON.parse(installed.script_files);check(Array.isArray(names)&&names.length>0&&new Set(names).size===names.length,'historical_manifest_invalid');
 const normalized=[],verifiedFiles=[];
 function sourceFile(rel,target){
  check(!rel.includes('..')&&!path.isAbsolute(rel),'historical_path_invalid');
  const a=blob(rel),b=fs.readFileSync(target);verifiedFiles.push({target,sha256:hash(b)});
  if(!a.equals(b)){
   // Historical Windows checkout copies sometimes used CRLF. Require exact
   // text equivalence AND the original recorded raw aggregate hash below.
   check(!a.includes(0)&&!b.includes(0)&&Buffer.from(a.toString('utf8').replaceAll('\r\n','\n')).equals(Buffer.from(b.toString('utf8').replaceAll('\r\n','\n'))),'historical_source_file_mismatch:'+rel);
   normalized.push(rel);
  }else checks++;
 }
 for(const n of names)sourceFile('scripts/'+n,path.join(install,'scripts',n));
 const digest=crypto.createHash('sha256').update(names.map(n=>`${n}\0${hash(fs.readFileSync(path.join(install,'scripts',n)))}\n`).join('')).digest('hex');
 check(digest===installed.scripts_sha256,'historical_scripts_digest_changed');
 const declared=/^UI_FILES="([^"]+)"$/m.exec(blob('scripts/upgrade.sh').toString());check(!!declared,'historical_ui_declaration_missing');
 const ui=declared[1].split(/\s+/).sort();for(const n of ui)sourceFile('ui/'+n,path.join(install,'ui',n));
 const uiDigest=crypto.createHash('sha256').update(ui.map(n=>`${n}\0${hash(fs.readFileSync(path.join(install,'ui',n)))}\n`).join('')).digest('hex');check(uiDigest===installed.ui_sha256,'historical_ui_digest_changed');
 const config=path.join(environment.WASM_AGENT_HOME,'.wasm-agent');
 for(const n of git(root,'ls-tree','-r','--name-only',intent.expected_sha,'skills').toString().trim().split('\n').filter(Boolean))sourceFile(n,path.join(config,n));
 const pids=[Number(fs.readFileSync(path.join(install,'serve.pid'),'utf8')),Number(fs.readFileSync(path.join(config,'sentinel/sentinel.pid'),'utf8'))];
 const processes=processIdentities(pids),same=(a,b)=>fs.realpathSync(a).toLowerCase()===fs.realpathSync(b).toLowerCase();
 check(same(processes[0].image,node)&&same(processes[1].image,sentinel),'historical_process_image_mismatch');
 check(processes.every(p=>p.created),'historical_process_creation_missing');
 const response=spawnSync('curl',['-s','--fail','-m','6',`http://127.0.0.1:${environment.WA_PORT||environment.WASM_AGENT_PORT}/health`],{encoding:'utf8',windowsHide:true});
 check(response.status===0&&JSON.parse(response.stdout).ok===true,'historical_health_not_ok');
 const after=sourceIdentity(root),afterProcesses=processIdentities(pids);
 check(JSON.stringify(after)===JSON.stringify(before)&&JSON.stringify(afterProcesses)===JSON.stringify(processes),'historical_identity_changed_during_verification');
 check(hash(fs.readFileSync(node))===nodeHash&&hash(fs.readFileSync(sentinel))===sentinelHash,'historical_artifact_changed_during_verification');
 for(const file of [...verifiedFiles,...originalFiles])check(hash(fs.readFileSync(file.target))===file.sha256,'historical_file_changed_during_verification');
 return {ok:true,suite:'verify-historical-install',checks,failed:0,skipped:0,request_id:intent.id,expected_sha:intent.expected_sha,tree,owner:binding.owner,parent:binding.parent,
  node_sha256:nodeHash,sentinel_sha256:sentinelHash,scripts_sha256:digest,ui_sha256:uiDigest,current_source:after.resolved_commit,
  listener_pid:pids[0],watcher_pid:pids[1],processes,original_processes:{listener_pid:installed.listener_pid,watcher_pid:installed.watcher_pid},
  normalized_text_files:normalized,at:new Date().toISOString(),effect_replayed:false,installed_record_unchanged:true,notification_outcome:'unchanged'};
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){try{const [root,install,intent,binding,evidence]=process.argv.slice(2);console.log(JSON.stringify(verifyHistorical(root,install,read(intent),read(binding),evidence)));}catch(e){console.error(e.stack);process.exitCode=1;}}
