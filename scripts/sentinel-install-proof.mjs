// Request-bound post-install proof validator. No effect, provider, or cached-success authority.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
export function installVerdict(intent,result,installed,proof,now=Date.now()) {
 const fail=detail=>({ok:false,detail});
 const time=v=>typeof v==='number'?v*1000:Date.parse(v);
 const stamp=v=>Number.isFinite(time(v))&&time(v)>0&&time(v)<=now;
 const sha=/^[a-f0-9]{40}$/;
 if(!sha.test(intent?.expected_sha||'')||!intent.id||!intent.owner||!intent.session||!stamp(intent.queued_at))return fail('intent_invalid');
 if(result?.request_id!==intent.id||result?.expected_sha!==intent.expected_sha||result?.ok!==true||!stamp(result.at)||time(result.at)<time(intent.queued_at))return fail('outcome_unattributed_or_stale');
 if(installed?.resolved_commit!==intent.expected_sha||!sha.test(installed.resolved_commit)||installed.source_provenance!=='clean-built-by-deploy'||installed.record_role!=='final'||!['0',0,false].includes(installed.dirty)||!stamp(installed.at)||time(installed.at)<time(intent.queued_at)||time(installed.at)>time(result.at))return fail('installed_source_unverified');
 if(proof?.request_id!==intent.id||proof?.expected_sha!==intent.expected_sha||proof?.owner!==intent.owner||proof?.parent!==intent.session||proof?.suite!=='verify-install'||proof?.ok!==true||proof?.exit!==0||proof?.failed!==0||proof?.skipped!==0||!Number.isInteger(proof.checks)||proof.checks<1||!stamp(proof.at)||time(proof.at)<time(result.at)||now-time(proof.at)>5000)return fail('verification_not_fresh_exact');
 if(!sha.test(proof.tree||'')||!sha.test(installed.tree||'')||proof.tree!==installed.tree)return fail('tree_identity_mismatch');
 for(const key of ['node_sha256','sentinel_sha256','scripts_sha256','ui_sha256'])if(!/^[a-f0-9]{64}$/.test(proof[key]||'')||proof[key]!==installed[key])return fail('artifact_identity_mismatch:'+key);
 if(!Number.isInteger(proof.listener_pid)||proof.listener_pid!==installed.listener_pid||!Number.isInteger(proof.watcher_pid)||proof.watcher_pid!==installed.watcher_pid)return fail('process_identity_mismatch');
 return {ok:true,detail:'I am updated'};
}

const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const record=file=>Object.fromEntries(fs.readFileSync(file,'utf8').trim().split(/\r?\n/).map(line=>{const n=line.indexOf('=');if(n<1)throw Error('invalid install record');return [line.slice(0,n),line.slice(n+1)];}));
function run(program,args,opts={}) {
 const r=spawnSync(program,args,{encoding:'utf8',windowsHide:true,timeout:60000,...opts});
 if(r.status!==0)throw Error(`${program} exited ${r.status}: ${r.stderr}`);
 return r.stdout.trim();
}
function files(dir,prefix='') {
 return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name),prefix+e.name+'/'):[prefix+e.name]).sort();
}
function digest(root,names) {return crypto.createHash('sha256').update(names.map(n=>`${n}\0${hash(path.join(root,n))}\n`).join('')).digest('hex');}
export function sourceIdentity(root,expected) {
 const git=(...args)=>run('git',['-C',root,...args]);
 const head=git('rev-parse','HEAD');
 if(expected && head!==expected)throw Error('source_head_mismatch');
 if(git('status','--porcelain'))throw Error('source_dirty');
 if(git('symbolic-ref','--short','HEAD')!=='main'||git('rev-parse','origin/main')!==head||git('ls-remote','origin','refs/heads/main').split(/\s/)[0]!==head)throw Error('source_main_mismatch');
 return {resolved_commit:head,tree:git('rev-parse','HEAD^{tree}')};
}
export function processIdentities(pids) {
 if(!Array.isArray(pids)||pids.length===0||pids.some(pid=>!Number.isInteger(pid)||pid<=0))throw Error('invalid process pid');
 if(process.platform==='win32') {
  // One fresh native query for the pair, not two interpreter launches.
  const value=JSON.parse(run('powershell.exe',['-NoProfile','-Command',`@(${pids.join(',')}) | ForEach-Object { $p=Get-Process -Id $_ -ErrorAction Stop; @{pid=$p.Id; image=$p.Path; created=$p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()} } | ConvertTo-Json -Compress`]));
  const rows=Array.isArray(value)?value:[value];
  if(rows.length!==pids.length||rows.some((row,index)=>row.pid!==pids[index]))throw Error('process_identity_response_mismatch');
  return rows;
 }
 return pids.map(pid=>{const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8').split(') ').at(-1).split(' ');
  return {pid,image:fs.readlinkSync(`/proc/${pid}/exe`),created:stat[19]};});
}
export function processIdentity(pid) {return processIdentities([pid])[0];}
export function snapshot(root,install,manifest,environment=process.env) {
 return snapshotWithIdentity(root,install,manifest,environment,sourceIdentity(root));
}
function snapshotWithIdentity(root,install,manifest,environment,identity) {
 const suffix=process.platform==='win32'?'.exe':'';
 const nodeFile=path.join(install,'wa'+suffix),sentFile=path.join(install,'wa-sentinel'+suffix);
 if(hash(nodeFile)!==hash(path.join(root,'rust/target/release/wa'+suffix))||hash(sentFile)!==hash(path.join(root,'rust/wa-sentinel/target/release/wa-sentinel'+suffix)))throw Error('built_artifact_mismatch');
 // The installer deliberately excludes ui/test-fixtures.js. Derive the served asset set from
 // its actual declaration, and allow only its named recovery backups as additional installed files.
 const declared=/^UI_FILES="([^"]+)"$/m.exec(fs.readFileSync(path.join(root,'scripts/upgrade.sh'),'utf8'));
 if(!declared)throw Error('ui_asset_declaration_missing');
 const uiFiles=declared[1].split(/\s+/).sort();
 if(uiFiles.some(n=>!/^[-A-Za-z0-9._]+$/.test(n))||!uiFiles.includes('index.html')||files(path.join(install,'ui')).some(n=>!uiFiles.includes(n)&&!uiFiles.some(asset=>n===asset+'.pre-upgrade'))||digest(path.join(root,'ui'),uiFiles)!==digest(path.join(install,'ui'),uiFiles))throw Error('ui_mismatch');
 const scriptFiles=manifest || files(path.join(install,'scripts')).filter(n=>fs.existsSync(path.join(root,'scripts',n))&&fs.statSync(path.join(root,'scripts',n)).isFile());
 for(const name of ['deploy.sh','upgrade.sh','verify-install.sh','lib/service-target.sh','sentinel-install-proof.mjs','sentinel-return-prepare.sh'])if(!scriptFiles.includes(name))throw Error('required_script_missing:'+name);
 for(const name of scriptFiles)if(hash(path.join(root,'scripts',name))!==hash(path.join(install,'scripts',name)))throw Error('script_mismatch:'+name);
 if(!environment.WASM_AGENT_HOME)throw Error('explicit_runtime_home_required');
 const config=path.join(environment.WASM_AGENT_HOME,'.wasm-agent');
 const listener_pid=Number(fs.readFileSync(path.join(install,'serve.pid'),'utf8').trim());
 const watcher_pid=Number(fs.readFileSync(path.join(config,'sentinel/sentinel.pid'),'utf8').trim());
 const [listener,watcher]=processIdentities([listener_pid,watcher_pid]);
 const same=(a,b)=>fs.realpathSync(a).toLowerCase()===fs.realpathSync(b).toLowerCase();
 if(!same(listener.image,nodeFile)||!same(watcher.image,sentFile))throw Error('process_image_mismatch');
 return {...identity,node_sha256:hash(nodeFile),sentinel_sha256:hash(sentFile),scripts_sha256:digest(path.join(install,'scripts'),scriptFiles),ui_sha256:digest(path.join(install,'ui'),uiFiles),listener_pid,watcher_pid,listener_created:listener.created,watcher_created:watcher.created,script_files:scriptFiles};
}
export function finalizeRecord(root,install) {
 const file=path.join(install,'installed.txt'),prior=record(file),facts=snapshot(root,install);
 const additional={...facts,node_sha256:facts.node_sha256,script_files:JSON.stringify(facts.script_files)};
 const merged={...prior,...additional};
 fs.writeFileSync(file+'.proof.tmp',Object.entries(merged).map(([k,v])=>`${k}=${v}`).join('\n')+'\n');fs.renameSync(file+'.proof.tmp',file);
 return facts;
}
export function verifyActual(root,install,intent,binding,evidence,environment=process.env) {
 if(binding.id!==intent.id||JSON.stringify(binding.intent)!==JSON.stringify(intent)||binding.owner!==intent.owner||binding.parent!==intent.session)throw Error('binding_mismatch');
 const initialIdentity=sourceIdentity(root,intent.expected_sha);
 const effect=read(path.join(evidence,'effect.json'));
 if(effect.id!==intent.id||effect.expected_sha!==intent.expected_sha||effect.owner!==binding.owner||effect.parent!==binding.parent||effect.tree!==initialIdentity.tree||effect.script_sha256!==hash(path.join(root,'scripts/deploy.sh')))throw Error('effect_generation_mismatch');
 const installed=record(path.join(install,'installed.txt'));
 for(const k of ['listener_pid','watcher_pid'])installed[k]=Number(installed[k]);
 const actual=snapshotWithIdentity(root,install,JSON.parse(installed.script_files),environment,initialIdentity);
 if(actual.listener_created!==installed.listener_created||actual.watcher_created!==installed.watcher_created)throw Error('process_creation_mismatch');
 const result=read(path.join(evidence,'result.json'));
 const script=path.join(root,'scripts/verify-install.sh');
 const bash=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
 const r=spawnSync(bash,[script.replaceAll('\\','/'),'--json'],{encoding:'utf8',windowsHide:true,timeout:120000,env:{...environment,WA_DEPLOY_ROOT:root,WA_INSTALL_DIR:install}});
 fs.mkdirSync(evidence,{recursive:true});
 const nonce=Date.now()+'-'+process.pid;
 fs.writeFileSync(path.join(evidence,`verify-${nonce}.stdout`),r.stdout||'');fs.writeFileSync(path.join(evidence,`verify-${nonce}.stderr`),r.stderr||'');
 const raw=JSON.parse(r.stdout);
 const health=JSON.parse(run('curl',['-s','--fail','-m','6',`http://127.0.0.1:${environment.WA_PORT||environment.WASM_AGENT_PORT}/health`],{env:environment}));
 if(health.ok!==true)throw Error('health_not_ok');
 const proof={...actual,...raw,exit:r.status,request_id:intent.id,expected_sha:intent.expected_sha,owner:binding.owner,parent:binding.parent,at:new Date().toISOString(),raw_stdout:`verify-${nonce}.stdout`,raw_stderr:`verify-${nonce}.stderr`};
 // Fresh native identities are sampled after the verifier, never normalized from expected values.
 // Bracket the full verification with source checks; avoid identical inner
 // git/remote checks while retaining independently observed before/after roots.
 Object.assign(proof,snapshotWithIdentity(root,install,JSON.parse(installed.script_files),environment,sourceIdentity(root,intent.expected_sha)));
 if(proof.listener_created!==installed.listener_created||proof.watcher_created!==installed.watcher_created)throw Error('process_creation_mismatch');
 proof.at=new Date().toISOString();
 const verdict=installVerdict(intent,result,installed,proof);
 if(!verdict.ok)throw Error(verdict.detail);
 fs.writeFileSync(path.join(evidence,`verification-${nonce}.json`),JSON.stringify(proof,null,2));
 return proof;
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url) {
 try {
  const [mode,root,install,intentFile,bindingFile,evidence]=process.argv.slice(2);
  const value=mode==='record'?finalizeRecord(root,install):mode==='verify'?verifyActual(root,install,read(intentFile),read(bindingFile),evidence):(()=>{throw Error('invalid mode');})();
  console.log(JSON.stringify(value));
 }catch(error){console.error(error.stack);process.exitCode=1;}
}
