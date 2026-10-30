// Offline shipping build contract. No installer, downloader, npm or runtime fallback.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import cp from 'node:child_process';
import {fileURLToPath} from 'node:url';
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const WASM='d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9';
const PRELUDE='57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281';
const packages=[
 {name:'@earendil-works/pi-codemode',version:'1.2.0',file:'_earendil-works_pi-codemode.tgz',sha256:'0ae49bbd62d812d7309d53c420c1bd96e03687ea07ae301b649ab6bad99af5dd'},
 {name:'quickjs-wasi',version:'3.6.2',file:'quickjs-wasi.tgz',sha256:'f1f4349f19a2d849e33ea0ae9bec2e7062b8839f4eceb17c9051ddbaa2720982'}
];
function requireValue(v,label){if(!v)throw Error('codemode_build:'+label);return v;}
function git(root,...args){const r=cp.spawnSync('git',['-C',root,...args],{encoding:'utf8',windowsHide:true});requireValue(r.status===0,'git_failed:'+JSON.stringify({status:r.status,error:r.error?{code:r.error.code,message:r.error.message}:null,stderr:r.stderr}));return r.stdout.trim();}
export function assetPath(root){return path.join(git(root,'rev-parse','--path-format=absolute','--git-common-dir'),'codemode-assets','pi-1.2.0-quickjs-3.6.2');}
export function verifyAssets(root,dir){
 const receipt=JSON.parse(fs.readFileSync(path.join(dir,'receipt.json')));
 requireValue(receipt.ok===true&&receipt.wasm_sha256===WASM&&receipt.prelude_sha256===PRELUDE,'asset_receipt_identity');
 const expected={'quickjs.wasm':WASM,'prelude.js':PRELUDE};
 for(const p of packages){const r=receipt.packages?.find(r=>r.name===p.name);requireValue(r?.version===p.version&&r.tarball_sha256===p.sha256,'package_receipt_identity:'+p.name);expected[p.file]=p.sha256;}
 for(const name of ['pi-MIT.txt','quickjs-wasi-MIT.txt'])expected[name]=sha(fs.readFileSync(path.join(root,'licenses',name)));
 const files=[];
 for(const [name,hash]of Object.entries(expected)){const bytes=fs.readFileSync(path.join(dir,name));requireValue(sha(bytes)===hash,'asset_hash_mismatch:'+name);files.push({name,sha256:hash});}
 files.push({name:'receipt.json',sha256:sha(fs.readFileSync(path.join(dir,'receipt.json')))});
 return {directory:fs.realpathSync(dir),files,wasm_sha256:WASM,prelude_sha256:PRELUDE};
}
export function prepare(root,from){
 const verified=verifyAssets(root,from),target=assetPath(root);
 requireValue(!fs.existsSync(target),'prepared_location_exists:verify_with_preflight');
 fs.mkdirSync(path.dirname(target),{recursive:true});
 const stage=fs.mkdtempSync(target+'.prepare-'); // failed generations remain inspectable
 for(const f of verified.files)fs.copyFileSync(path.join(from,f.name),path.join(stage,f.name),fs.constants.COPYFILE_EXCL);
 verifyAssets(root,stage);fs.renameSync(stage,target);
 return {ok:true,prepared:target,assets:verifyAssets(root,target)};
}
// Match the host's existing resolve_home + ripgrep::ensure contract, without
// provisioning. rg is an offline STARTUP dependency, not a Cargo/Lua dependency.
export function resolveRipgrep(env=process.env,spawn=cp.spawnSync){
 const get=name=>Object.entries(env).find(([k])=>k.toLowerCase()===name.toLowerCase())?.[1];
 const home=get('WASM_AGENT_HOME')||(process.platform==='win32'?(get('USERPROFILE')||(get('HOMEDRIVE')&&get('HOMEPATH')?get('HOMEDRIVE')+get('HOMEPATH'):get('HOME'))):get('HOME'));
 const name=process.platform==='win32'?'rg.exe':'rg';const candidates=[];
 if(home&&path.isAbsolute(home))candidates.push(path.join(home,'.wasm-agent/bin',name));
 for(const entry of (get('PATH')||'').split(path.delimiter))if(path.isAbsolute(entry))candidates.push(path.join(entry,name));
 const attempts=[];
 for(const candidate of [...new Set(candidates)]){
  const r=spawn(candidate,['--version'],{encoding:'utf8',windowsHide:true,timeout:10000});
  if(r.status===0&&r.stdout?.startsWith('ripgrep '))return {path:fs.realpathSync(candidate),sha256:sha(fs.readFileSync(candidate)),version:r.stdout.trim(),attempts};
  attempts.push({path:candidate,status:r.status,signal:r.signal,error:r.error?{code:r.error.code,message:r.error.message}:null,stderr:r.stderr||'',stdout:r.stdout||''});
 }
 throw Error('codemode_build:ripgrep_offline_startup_unavailable:'+JSON.stringify(attempts));
}
// A cross target (30/10): a static Linux bundle for another architecture or libc, built with cargo-zigbuild on
// any Linux host. The candidate still runs before it earns a receipt - natively, or through the host's binfmt
// emulation for a foreign architecture - so a cross build is proven by execution, never by trust.
export const CROSS_TARGETS={'aarch64-unknown-linux-musl':0xb7,'x86_64-unknown-linux-musl':0x3e,'aarch64-unknown-linux-gnu':0xb7,'x86_64-unknown-linux-gnu':0x3e};
export function preflight(root,dir=assetPath(root),target=null){
 const assets=verifyAssets(root,dir);
 requireValue(fs.existsSync(path.join(root,'scripts/check-embedded-runtime.lua')),'embedded_checker_missing');
 requireValue(fs.existsSync(path.join(root,'rust/Cargo.toml')),'cargo_manifest_missing');
 const cargo=cp.spawnSync('cargo',['--version'],{encoding:'utf8',windowsHide:true});
 requireValue(cargo.status===0,'cargo_unavailable:'+String(cargo.error||cargo.stderr));
 if(target){
  requireValue(Object.hasOwn(CROSS_TARGETS,target),'cross_target_unsupported:'+target);
  const zig=cp.spawnSync('cargo-zigbuild',['--version'],{encoding:'utf8',windowsHide:true});
  requireValue(zig.status===0,'cargo_zigbuild_unavailable:'+String(zig.error||zig.stderr));
 }
 const ripgrep=resolveRipgrep();
 return {ok:true,ripgrep,root:fs.realpathSync(root),source_commit:git(root,'rev-parse','HEAD'),source_tree:git(root,'rev-parse','HEAD^{tree}'),source_dirty:git(root,'status','--porcelain')!=='',cargo:cargo.stdout.trim(),assets};
}
function waveChecker(root,evidence,commit,tree,generation){
 const file=path.join(evidence,'wave-native-check.lua');
 const prefix=`do local j=dofile('lua/vendor/json.lua');local i=j.decode(host.runtime_info());assert(i.build_source_commit==${JSON.stringify(commit)},'native compiled source mismatch');assert(i.build_source_tree==${JSON.stringify(tree)},'native compiled tree mismatch');assert(i.build_wave_generation==${JSON.stringify(generation||'')},'native compiled generation mismatch');print('native compiled source/tree/wave identity ok') end\n`;
 fs.writeFileSync(file,prefix+fs.readFileSync(path.join(root,'scripts/check-embedded-runtime.lua'),'utf8'));return file;
}
export function build(root,dir=assetPath(root),waveGeneration=null,target=null){
 const before=preflight(root,dir,target);
 const evidence=fs.mkdtempSync(path.join(git(root,'rev-parse','--path-format=absolute','--git-dir'),'codemode-build-'));
 const snapshot=path.join(evidence,'assets');fs.mkdirSync(snapshot);
 const receipt={...before,build_schema:1,kind:'codemode-offline-build',source_common:git(root,'rev-parse','--path-format=absolute','--git-common-dir'),platform:process.platform,arch:process.arch,wave_generation:waveGeneration,started_at:Date.now()/1000,ok:false,evidence,build_assets:snapshot};
 // Do not reuse mutable prepared files or an ambient env: Cargo sees this exact verified snapshot.
 try{
  for(const f of before.assets.files)fs.copyFileSync(path.join(dir,f.name),path.join(snapshot,f.name),fs.constants.COPYFILE_EXCL);
  receipt.snapshot=verifyAssets(root,snapshot);
  const env={...process.env,WA_CODEMODE_BUILD_ASSETS:fs.realpathSync(snapshot),CARGO_TARGET_DIR:path.join(root,'rust/target'),WA_BUILD_SOURCE_COMMIT:before.source_commit,WA_BUILD_SOURCE_TREE:before.source_tree,WA_BUILD_WAVE_GENERATION:waveGeneration||''};
  const args=target?['zigbuild','--release','--offline','--locked','-p','wa-host','--target',target]:['build','--release','--offline','--locked','-p','wa-host'];
  receipt.target=target;receipt.cargo_args=args;receipt.cargo_env={WA_CODEMODE_BUILD_ASSETS:env.WA_CODEMODE_BUILD_ASSETS,CARGO_TARGET_DIR:env.CARGO_TARGET_DIR};
  // WA_BUILD_CARGO_LOG (29/10): cargo's stderr goes to that file as it is written, so deploy.sh can draw
  // `Compiling <crate>` live; it is read back afterwards, so the evidence below is the same bytes.
  const live=process.env.WA_BUILD_CARGO_LOG,liveFd=live?fs.openSync(live,'w'):null;
  const result=cp.spawnSync('cargo',args,{cwd:path.join(root,'rust'),env,encoding:'utf8',windowsHide:true,timeout:1800000,maxBuffer:32*1024*1024,stdio:['ignore','pipe',liveFd??'pipe']});
  if(liveFd!==null){fs.closeSync(liveFd);result.stderr=fs.readFileSync(live,'utf8');}
  for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(evidence,'cargo.'+stream),result[stream]||'');
  requireValue(result.status===0,'cargo_failed:'+String(result.error||result.stderr));
  const binary=target?path.join(root,'rust/target',target,'release','wa'):path.join(root,'rust/target/release',process.platform==='win32'?'wa.exe':'wa');
  if(target){
   const head=fs.readFileSync(binary).subarray(0,20);
   requireValue(head.subarray(0,4).equals(Buffer.from([127,69,76,70]))&&head.readUInt16LE(18)===CROSS_TARGETS[target],'cross_candidate_wrong_machine:'+target);
   const hostMachine={arm64:0xb7,x64:0x3e}[process.arch];
   receipt.cross_runner=hostMachine===CROSS_TARGETS[target]?'native':'binfmt';
  }
  const home=path.join(evidence,'runtime-home');fs.mkdirSync(home);
  const rg=path.join(home,'.wasm-agent/bin',process.platform==='win32'?'rg.exe':'rg');
  fs.mkdirSync(path.dirname(rg),{recursive:true});fs.copyFileSync(before.ripgrep.path,rg,fs.constants.COPYFILE_EXCL);
  requireValue(sha(fs.readFileSync(rg))===before.ripgrep.sha256,'ripgrep_changed_during_staging');
  if(process.platform!=='win32')fs.chmodSync(rg,0o755);
  const staged=cp.spawnSync(rg,['--version'],{encoding:'utf8',windowsHide:true,timeout:10000});
  requireValue(staged.status===0&&staged.stdout?.startsWith('ripgrep '),'private_ripgrep_execution_failed:'+JSON.stringify({status:staged.status,error:staged.error?{code:staged.error.code,message:staged.error.message}:null,stderr:staged.stderr}));
  receipt.runtime_ripgrep={path:rg,sha256:before.ripgrep.sha256,version:staged.stdout.trim()};
  const runtimeEnv=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
  for(const [k,v]of Object.entries(process.env))if(/^(WASM_AGENT_(IN_TURN|PROVENANCE|RUN_ID|SESSION_ID)|WA_JOB_)/i.test(k))runtimeEnv[k]=v;
  Object.assign(runtimeEnv,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:'',WASM_AGENT_CODEMODE_ASSETS:'',WA_EMBEDDED_SOURCE_ROOT:root,WA_EMBEDDED_EXPECT_COMMIT:before.source_commit,WA_EMBEDDED_EXPECT_TREE:before.source_tree,WA_EMBEDDED_EXPECT_GENERATION:waveGeneration||'',WA_SCRIPT:path.join(root,'scripts/check-embedded-runtime.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0'});
  const runtime=cp.spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:home,env:{...runtimeEnv,WA_SCRIPT:waveChecker(root,evidence,before.source_commit,before.source_tree,waveGeneration)},encoding:'utf8',windowsHide:true,timeout:60000,maxBuffer:8*1024*1024});
  for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(evidence,'embedded.'+stream),runtime[stream]||'');
  if(target&&runtime.error?.code==='ENOEXEC')requireValue(false,'cross_candidate_cannot_run:'+target+' needs binfmt emulation on this host (qemu-user registered with the F flag), not a skipped proof');
  requireValue(runtime.status===0&&runtime.stdout.includes('embedded native codemode ok'),'embedded_candidate_failed:'+String(runtime.error||runtime.stdout+runtime.stderr));
  requireValue(!/ripgrep missing; installing|ripgrep_unavailable:/.test(runtime.stderr||''),'unexpected_ripgrep_provisioning_or_failure');
  verifyAssets(root,snapshot); // changed snapshot never earns a ready receipt
  requireValue(git(root,'rev-parse','HEAD')===before.source_commit&&git(root,'rev-parse','HEAD^{tree}')===before.source_tree,'source_changed_during_build');
  receipt.binary=binary;receipt.binary_sha256=sha(fs.readFileSync(binary));receipt.finished_at=Date.now()/1000;receipt.native_checked=true;receipt.ok=true;
 }catch(error){receipt.error=String(error);throw Object.assign(error,{evidence});}
 finally{
  receipt.logs=Object.fromEntries(['cargo.stdout','cargo.stderr','embedded.stdout','embedded.stderr'].filter(name=>fs.existsSync(path.join(evidence,name))).map(name=>[name,sha(fs.readFileSync(path.join(evidence,name)))]));
  let published=false;
  if(receipt.ok&&!receipt.target&&!receipt.source_dirty&&process.env.WA_JOB_EVENT_FILE===undefined&&process.env.WA_JOB_DELIVERY_ID===undefined){
   try{published=git(root,'status','--porcelain')===''&&git(root,'branch','--show-current')==='main'
    &&git(root,'rev-parse','HEAD')===before.source_commit&&git(root,'rev-parse','origin/main')===before.source_commit
    &&git(root,'ls-remote','origin','refs/heads/main').split(/\s+/)[0]===before.source_commit;}
   catch(error){receipt.readiness_not_published=String(error);} // build success is not conditional on publication
  }
  const receiptFile=path.join(evidence,'receipt.json');fs.writeFileSync(receiptFile,JSON.stringify(receipt,null,2));
  // Index the ORIGINAL receipt only when ordinary publication facts exist.
  // An unpublished/development build remains a build, not a failed extra gate.
  if(published){
   const ready=path.join(git(root,'rev-parse','--path-format=absolute','--git-dir'),'codemode-build-ready.json');
   const temp=ready+'.'+process.pid+'.tmp';fs.writeFileSync(temp,JSON.stringify({schema:1,receipt:receiptFile,receipt_sha256:sha(fs.readFileSync(receiptFile)),source_commit:before.source_commit,source_tree:before.source_tree,binary_sha256:receipt.binary_sha256}));fs.renameSync(temp,ready);
  }
  console.log(JSON.stringify(receipt));
 }
 return receipt;
}
// Lightweight consumption of the ordinary build's already-verified facts.
// Never rebuild, execute the candidate, run a test suite or create verification jobs.
export function qualifyWave(root,receiptFile,generation,openedAt,installedBinary){
 const pointer=JSON.parse(fs.readFileSync(path.join(git(root,'rev-parse','--path-format=absolute','--git-dir'),'codemode-build-ready.json')));
 const same=(a,b)=>{const x=fs.realpathSync(a),y=fs.realpathSync(b);return process.platform==='win32'?x.toLowerCase()===y.toLowerCase():x===y;};
 if(receiptFile==='@latest')receiptFile=pointer.receipt;
 requireValue(pointer.schema===1&&same(receiptFile,pointer.receipt),'wave_build_receipt_not_current');
 const raw=fs.readFileSync(receiptFile),r=JSON.parse(raw),now=Date.now()/1000;
 requireValue(sha(raw)===pointer.receipt_sha256&&pointer.binary_sha256===r.binary_sha256,'wave_build_receipt_not_current');
 requireValue(r.build_schema===1&&r.kind==='codemode-offline-build'&&r.ok===true&&r.source_dirty===false,'wave_build_receipt_required');
 requireValue(typeof generation==='string'&&generation.length>0&&(!r.wave_generation||r.wave_generation===generation),'wave_build_generation_mismatch');
 requireValue(Number.isFinite(openedAt)&&r.started_at>=openedAt&&r.finished_at>=r.started_at&&r.finished_at<=now,'wave_build_time_mismatch');
 requireValue(r.platform===process.platform&&r.arch===process.arch,'wave_candidate_target_mismatch');
 requireValue(same(root,r.root)&&same(r.source_common,git(root,'rev-parse','--path-format=absolute','--git-common-dir')),'wave_build_repository_mismatch');
 requireValue(git(root,'status','--porcelain')===''&&git(root,'branch','--show-current')==='main','wave_build_clean_main_required');
 requireValue(r.source_commit===git(root,'rev-parse','HEAD')&&r.source_tree===git(root,'rev-parse','HEAD^{tree}')&&r.source_commit===git(root,'rev-parse','origin/main')&&r.source_commit===git(root,'ls-remote','origin','refs/heads/main').split(/\s+/)[0],'wave_build_source_mismatch');
 const binary=path.join(root,'rust/target/release',process.platform==='win32'?'wa.exe':'wa');
 requireValue(same(binary,r.binary),'wave_candidate_path_mismatch');
 const bytes=fs.readFileSync(binary),digest=sha(bytes),installed=sha(fs.readFileSync(installedBinary));
 requireValue(digest===r.binary_sha256&&digest!==installed,'wave_candidate_missing_corrupt_or_unchanged');
 if(process.platform==='win32'){
  requireValue(bytes.length>128&&bytes.toString('ascii',0,2)==='MZ','wave_candidate_not_native');
  const pe=bytes.readUInt32LE(60);requireValue(pe+6<bytes.length&&bytes.toString('ascii',pe,pe+4)==='PE\0\0'&&bytes.readUInt16LE(pe+4)===(process.arch==='x64'?0x8664:0xaa64),'wave_candidate_target_mismatch');
 }else requireValue(bytes.subarray(0,4).equals(Buffer.from([127,69,76,70])),'wave_candidate_not_native');
 for(const name of ['cargo.stdout','cargo.stderr','embedded.stdout','embedded.stderr'])requireValue(r.logs?.[name]&&sha(fs.readFileSync(path.join(r.evidence,name)))===r.logs[name],'wave_build_original_log_mismatch:'+name);
 requireValue(fs.readFileSync(path.join(r.evidence,'embedded.stdout'),'utf8').includes('embedded native codemode ok')&&fs.readFileSync(path.join(r.evidence,'embedded.stdout'),'utf8').includes('native compiled source/tree/wave identity ok'),'wave_build_native_proof_missing');
 verifyAssets(root,r.build_assets);
 requireValue(r.native_checked===true,'wave_build_native_proof_missing');
 requireValue(sha(fs.readFileSync(binary))===digest&&sha(fs.readFileSync(receiptFile))===sha(raw),'wave_candidate_changed_during_inspection');
 return {ok:true,binary:fs.realpathSync(binary),binary_sha256:digest,installed_sha256:installed,receipt:fs.realpathSync(receiptFile),receipt_sha256:sha(raw),source_commit:r.source_commit,source_tree:r.source_tree,platform:process.platform,arch:process.arch,generation,build_generation:r.wave_generation,evidence:r.evidence,inspection:'existing verified build receipt + physical bytes; no runtime tests'};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{
  const [action,root,...extra]=process.argv.slice(2);requireValue(root&&path.isAbsolute(root),'absolute_source_root_required');
  if(action==='assets-path'){requireValue(extra.length===0,'usage');console.log(assetPath(root));}
  else if(action==='prepare'){requireValue(extra.length===1&&path.isAbsolute(extra[0]),'absolute_prepared_input_required');console.log(JSON.stringify(prepare(root,extra[0])));}
  else if(action==='qualify-wave'){
   requireValue(extra.length===8&&extra[0]==='--receipt'&&extra[2]==='--generation'&&extra[4]==='--opened-at'&&extra[6]==='--installed-binary','usage');
   console.log(JSON.stringify(qualifyWave(root,extra[1],extra[3],Number(extra[5]),extra[7])));
  }
  else if(action==='preflight'||action==='build'){
   let generation=null;const gi=extra.indexOf('--wave-generation');if(gi>=0){requireValue(action==='build'&&gi+1<extra.length,'wave_generation_required');generation=extra[gi+1];extra.splice(gi,2);}
   let target=null;const ti=extra.indexOf('--target');if(ti>=0){requireValue(ti+1<extra.length,'target_required');target=extra[ti+1];extra.splice(ti,2);requireValue(generation===null,'cross_target_is_not_a_wave_candidate');}
   requireValue(extra.length===0||extra.length===2&&extra[0]==='--assets'&&path.isAbsolute(extra[1]),'usage');
   const result=action==='preflight'?preflight(root,extra[1],target):build(root,extra[1],generation,target);if(action==='preflight')console.log(JSON.stringify(result));
  }else throw Error('usage: codemode-build.mjs assets-path|prepare|preflight|build <absolute-root> [prepare-input | --assets <private-build-input>] [--target <triple>]');
 }catch(error){console.error(String(error)+(error.evidence?' evidence='+error.evidence:''));process.exitCode=1;}
}
