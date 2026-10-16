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
function git(root,...args){const r=cp.spawnSync('git',['-C',root,...args],{encoding:'utf8',windowsHide:true});requireValue(r.status===0,'git_failed:'+r.stderr);return r.stdout.trim();}
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
export function preflight(root,dir=assetPath(root)){
 const assets=verifyAssets(root,dir);
 requireValue(fs.existsSync(path.join(root,'scripts/check-embedded-runtime.lua')),'embedded_checker_missing');
 requireValue(fs.existsSync(path.join(root,'rust/Cargo.toml')),'cargo_manifest_missing');
 const cargo=cp.spawnSync('cargo',['--version'],{encoding:'utf8',windowsHide:true});
 requireValue(cargo.status===0,'cargo_unavailable:'+String(cargo.error||cargo.stderr));
 const rg=cp.spawnSync('rg',['--version'],{encoding:'utf8',windowsHide:true});
 requireValue(rg.status===0,'ripgrep_unavailable:prepare_offline_before_build');
 return {ok:true,root:fs.realpathSync(root),source_commit:git(root,'rev-parse','HEAD'),source_tree:git(root,'rev-parse','HEAD^{tree}'),source_dirty:git(root,'status','--porcelain')!=='',cargo:cargo.stdout.trim(),assets};
}
export function build(root,dir=assetPath(root)){
 const before=preflight(root,dir);
 const evidence=fs.mkdtempSync(path.join(git(root,'rev-parse','--path-format=absolute','--git-dir'),'codemode-build-'));
 const snapshot=path.join(evidence,'assets');fs.mkdirSync(snapshot);
 const receipt={...before,ok:false,evidence,build_assets:snapshot};
 // Do not reuse mutable prepared files or an ambient env: Cargo sees this exact verified snapshot.
 try{
  for(const f of before.assets.files)fs.copyFileSync(path.join(dir,f.name),path.join(snapshot,f.name),fs.constants.COPYFILE_EXCL);
  receipt.snapshot=verifyAssets(root,snapshot);
  const env={...process.env,WA_CODEMODE_BUILD_ASSETS:fs.realpathSync(snapshot),CARGO_TARGET_DIR:path.join(root,'rust/target')};
  const args=['build','--release','--offline','--locked','-p','wa-host'];
  receipt.cargo_args=args;receipt.cargo_env={WA_CODEMODE_BUILD_ASSETS:env.WA_CODEMODE_BUILD_ASSETS,CARGO_TARGET_DIR:env.CARGO_TARGET_DIR};
  const result=cp.spawnSync('cargo',args,{cwd:path.join(root,'rust'),env,encoding:'utf8',windowsHide:true,timeout:1800000,maxBuffer:32*1024*1024});
  for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(evidence,'cargo.'+stream),result[stream]||'');
  requireValue(result.status===0,'cargo_failed:'+String(result.error||result.stderr));
  const binary=path.join(root,'rust/target/release',process.platform==='win32'?'wa.exe':'wa');
  const home=path.join(evidence,'runtime-home');fs.mkdirSync(home);
  const runtimeEnv=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
  Object.assign(runtimeEnv,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:'',WASM_AGENT_CODEMODE_ASSETS:'',WA_EMBEDDED_SOURCE_ROOT:root,WA_SCRIPT:path.join(root,'scripts/check-embedded-runtime.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0'});
  const runtime=cp.spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:home,env:runtimeEnv,encoding:'utf8',windowsHide:true,timeout:60000,maxBuffer:8*1024*1024});
  for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(evidence,'embedded.'+stream),runtime[stream]||'');
  requireValue(runtime.status===0&&runtime.stdout.includes('embedded native codemode ok'),'embedded_candidate_failed:'+String(runtime.error||runtime.stdout+runtime.stderr));
  verifyAssets(root,snapshot); // changed snapshot never earns a ready receipt
  requireValue(git(root,'rev-parse','HEAD')===before.source_commit&&git(root,'rev-parse','HEAD^{tree}')===before.source_tree,'source_changed_during_build');
  receipt.binary=binary;receipt.binary_sha256=sha(fs.readFileSync(binary));receipt.ok=true;
 }catch(error){receipt.error=String(error);throw Object.assign(error,{evidence});}
 finally{
  receipt.logs=Object.fromEntries(['cargo.stdout','cargo.stderr','embedded.stdout','embedded.stderr'].filter(name=>fs.existsSync(path.join(evidence,name))).map(name=>[name,sha(fs.readFileSync(path.join(evidence,name)))]));
  fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
 }
 return receipt;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{
  const [action,root,...extra]=process.argv.slice(2);requireValue(root&&path.isAbsolute(root),'absolute_source_root_required');
  if(action==='assets-path'){requireValue(extra.length===0,'usage');console.log(assetPath(root));}
  else if(action==='prepare'){requireValue(extra.length===1&&path.isAbsolute(extra[0]),'absolute_prepared_input_required');console.log(JSON.stringify(prepare(root,extra[0])));}
  else if(action==='preflight'||action==='build'){
   requireValue(extra.length===0||extra.length===2&&extra[0]==='--assets'&&path.isAbsolute(extra[1]),'usage');
   const result=action==='preflight'?preflight(root,extra[1]):build(root,extra[1]);if(action==='preflight')console.log(JSON.stringify(result));
  }else throw Error('usage: codemode-build.mjs assets-path|prepare|preflight|build <absolute-root> [prepare-input | --assets <private-build-input>]');
 }catch(error){console.error(String(error)+(error.evidence?' evidence='+error.evidence:''));process.exitCode=1;}
}
