// Caller-attested exact source/build receipt, not binary introspection or publication authority.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function sources(repo){
 const result={};
 for(const directory of ['rust','lua','ui']) {
  function walk(relative){for(const entry of fs.readdirSync(path.join(repo,relative),{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name))){
   if(entry.name==='target')continue;
   const file=relative+'/'+entry.name;
   if(entry.isDirectory())walk(file);else if(/\.(rs|c|h|lua|toml|lock|js|css|html|wasm)$/.test(entry.name))result[file]=hash(path.join(repo,file));
  }}walk(directory);
 }
 for(const file of ['scripts/native-child-build-proof.cjs','scripts/test-native-child-browser.cjs','scripts/fixture-native-job.ps1','scripts/test-recovery-two-window.cjs','scripts/test-ui.ps1','scripts/gate-check.mjs','scripts/gate-checks.mjs'])result[file]=hash(path.join(repo,file));
 return result;
}
function verify(repo,binary,receipt){const proof=JSON.parse(fs.readFileSync(receipt));
 if(JSON.stringify(proof.sources)!==JSON.stringify(sources(repo))||proof.binary_sha256!==hash(binary))throw Error('native_child_source_binary_binding_mismatch');return proof;
}
module.exports={sources,verify};
if(require.main===module){const [mode,repoArg,binaryArg,receiptArg]=process.argv.slice(2),repo=path.resolve(repoArg),binary=path.resolve(binaryArg),receipt=path.resolve(receiptArg);
 if(mode==='verify'){verify(repo,binary,receipt);console.log('native source/binary binding verified');}
 else if(mode==='build'){
  const before=sources(repo),args=['build','--offline','--manifest-path',path.join(repo,'rust','Cargo.toml'),'-p','wa-host','--target-dir',path.dirname(path.dirname(binary))];
  if(path.basename(path.dirname(binary))==='release')args.push('--release');
  const result=spawnSync('cargo',args,{cwd:repo,env:{...process.env,CARGO_BUILD_JOBS:'2'},stdio:'inherit',windowsHide:true});
  if(result.status!==0)process.exit(result.status||1);
  if(JSON.stringify(before)!==JSON.stringify(sources(repo)))throw Error('source_changed_during_native_build');
  fs.mkdirSync(path.dirname(receipt),{recursive:true});fs.writeFileSync(receipt,JSON.stringify({schema:1,kind:'caller-attested-cargo-build',repo,binary,jobs:2,command:['cargo',...args],sources:before,binary_sha256:hash(binary),at:new Date().toISOString()},null,2)+'\n');
 }else throw Error('usage build|verify repo binary receipt');
}
