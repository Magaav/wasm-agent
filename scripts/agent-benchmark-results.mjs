// Generation-owned result sealing and cleanup. No benchmark solver inference or live-node access.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
import {spawn,spawnSync} from 'node:child_process';
import {writeFramedBundle,readFramedBundle,fileDigest} from './agent-benchmark-bundle.mjs';
const digest = b => crypto.createHash('sha256').update(b).digest('hex');
const json = x => Buffer.from(JSON.stringify(x));
export const requiredRecords = ['manifest','task','context','oracle','outputs','patches','traces','failed_attempts','receipts','accounting','cache','quality'];
function fail(s) { throw Error(s); }
function safeName(s) { if(typeof s !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$/.test(s)) fail('invalid generation/name'); return s; }
function inside(root,p) { const r=path.relative(root,p); return r!=='' && !r.startsWith('..') && !path.isAbsolute(r); }
function noLinks(p) {
  const abs=path.resolve(p); let cur=path.parse(abs).root;
  for(const bit of abs.slice(cur.length).split(path.sep).filter(Boolean)) {cur=path.join(cur,bit); if(fs.lstatSync(cur).isSymbolicLink()) fail('symlink/junction path');}
}
function inventory(root,{allowSnapshotGit=false}={}) {
  noLinks(root); const entries=[];
  function walk(dir) {
    for(const name of fs.readdirSync(dir).sort()) {
      const p=path.join(dir,name),s=fs.lstatSync(p);
      if(s.isSymbolicLink() || !s.isFile() && !s.isDirectory() || s.isFile() && s.nlink!==1) fail('linked or special resource');
      if(name==='.git' && !allowSnapshotGit) fail('git checkout requires exact snapshot registration');
      if(s.isDirectory()) walk(p); else entries.push({path:path.relative(root,p).split(path.sep).join('/'),bytes:s.size,sha256:digest(fs.readFileSync(p))});
    }
  } walk(root); return entries;
}
function identity(p) { const s=fs.lstatSync(p); return {dev:s.dev,ino:s.ino,birthtime:s.birthtimeMs}; }
function same(a,b) { return JSON.stringify(a)===JSON.stringify(b); }
function writeNew(p,bytes) {fs.writeFileSync(p,bytes,{flag:'wx',mode:0o600});}
// Root must be an explicitly selected fresh evidence root, never an existing tree.
export function createGeneration(root,generation) {
  root=path.resolve(root);safeName(generation);noLinks(path.dirname(root));
  fs.mkdirSync(root,{mode:0o700});
  fs.mkdirSync(path.join(root,'records'));fs.mkdirSync(path.join(root,'disposable'));
  const state={version:1,generation,nonce:crypto.randomUUID(),root,identity:identity(root),resources:[],processes:[],phase:'collecting'};
  writeNew(path.join(root,'owner.json'),json(state));return root;
}
function load(root) {
  root=path.resolve(root);noLinks(root);
  const state=JSON.parse(fs.readFileSync(path.join(root,'owner.json')));
  if(state.root!==root || !same(state.identity,identity(root))) fail('generation ownership drift');
  return state;
}
function save(s) {fs.writeFileSync(path.join(s.root,'owner.json'),json(s),{mode:0o600});}
export function record(root,kind,value) {
  if(!requiredRecords.includes(kind)) fail('unknown result record');const s=load(root);if(s.phase!=='collecting') fail('sealed generation');
  writeNew(path.join(root,'records',kind+'.json'),json(value));
}
export function disposable(root,name) {
  const s=load(root);if(s.phase!=='collecting') fail('sealed generation');safeName(name);
  const p=path.join(root,'disposable',name);noLinks(path.dirname(p));fs.mkdirSync(p);
  const marker={generation:s.generation,nonce:s.nonce,id:crypto.randomUUID()};writeNew(path.join(p,'.benchmark-owned.json'),json(marker));
  s.resources.push({path:p,identity:identity(p),marker});save(s);return p;
}
export function assertDisposable(root,dir) {
  const s=load(root),p=path.resolve(dir),r=s.resources.find(r=>r.path===p);noLinks(p);
  if(s.phase!=='collecting'||!r||!same(identity(p),r.identity)||!same(JSON.parse(fs.readFileSync(path.join(p,'.benchmark-owned.json'))),r.marker))fail('not an exact generation-owned disposable');return r;
}
function snapshotGitProof(dir) {
  const dot=path.join(dir,'.git');noLinks(dot);if(!fs.lstatSync(dot).isDirectory())fail('managed/linked Git worktree refused');
  for(const p of ['commondir','worktrees','objects/info/alternates'])if(fs.existsSync(path.join(dot,p)))fail('shared Git object/worktree store refused');
  const git=args=>{const r=spawnSync('git',['-C',dir,...args],{encoding:'utf8',timeout:15000});if(r.status!==0||r.error)fail('Git ownership inspection refused');return r.stdout.trim();};
  if(git(['remote'])!=='')fail('snapshot Git remotes refused');
  const top=path.resolve(git(['rev-parse','--show-toplevel'])),common=path.resolve(dir,git(['rev-parse','--git-common-dir']));
  if(top!==path.resolve(dir)||common!==path.resolve(dot))fail('Git root/common-dir escape');
  const worktrees=git(['worktree','list','--porcelain']).split(/\r?\n/).filter(s=>s.startsWith('worktree '));
  if(worktrees.length!==1||path.resolve(worktrees[0].slice(9))!==path.resolve(dir))fail('active/shared Git worktree refused');
  inventory(dir,{allowSnapshotGit:true});return {git_identity:identity(dot),top,common,standalone:true};
}
export function registerSnapshotGit(root,dir) {
  const s=load(root),r=s.resources.find(r=>r.path===path.resolve(dir));if(s.phase!=='collecting'||!r||!same(identity(dir),r.identity)||!same(JSON.parse(fs.readFileSync(path.join(dir,'.benchmark-owned.json'))),r.marker))fail('Git checkout not generation-owned');
  r.kind='snapshot-checkout';r.git_proof=snapshotGitProof(dir);save(s);return r.git_proof;
}
const active = new Map();
// Runner starts only its authorized local process here; callers decide which programs
// are authorized. The benchmark CLI never invokes this to start solver inference.
export function ownedProcess(root,exe,args,options={}) {
  const s=load(root);if(s.phase!=='collecting') fail('sealed generation');
  const id=crypto.randomUUID();s.processes.push({id,state:'reserved'});save(s);
  const child=spawn(exe,args,{...options,detached:false,stdio:['ignore','pipe','pipe']});
  active.set(id,child);let stdout=[],stderr=[];
  child.stdout.on('data',b=>stdout.push(b));child.stderr.on('data',b=>stderr.push(b));
  return new Promise(resolve=>{
    let error=null;child.on('error',e=>error=e.message);
    child.on('spawn',()=>{const a=load(root),p=a.processes.find(p=>p.id===id);p.pid=child.pid;p.state='running';save(a);});
    child.on('close',(code,signal)=>{
      const a=load(root),p=a.processes.find(p=>p.id===id);
      // A process closing does not prove arbitrary detached descendants drained.
      // Such programs must not be admitted; externally supervised trees need an
      // exact settled receipt through their own adapter before cleanup.
      p.state='closed';p.code=code;p.signal=signal;p.error=error;p.process_tree='unverified';save(a);active.delete(id);
      resolve({id,code,signal,error,stdout:Buffer.concat(stdout),stderr:Buffer.concat(stderr)});
    });
  });
}
// Production native supervisor owns the complete process tree; launch receipts are
// never accepted as settlement. This adapter records full raw output before sealing.
export async function containedProcess(root,binary,exe,args,{cwd,timeout_seconds=30,luaRoot}={}) {
  const s=load(root);if(s.phase!=='collecting')fail('sealed generation');
  const id=crypto.randomUUID(),dir=path.join(root,'records','p-'+id.slice(0,8));fs.mkdirSync(dir);
  fs.mkdirSync(path.join(dir,'.wasm-agent','operations'),{recursive:true});
  const script=path.join(dir,'supervisor.lua'),launcher=path.join(dir,'program.cjs');
  // Native script hosts have no task context; preserve the caller's cooperative
  // child/in-turn markers explicitly when their supervisor launches the program.
  const programEnv=isolatedEnvironment(dir);
  fs.writeFileSync(launcher,'const cp=require("node:child_process");const c=cp.spawn('+JSON.stringify(exe)+','+JSON.stringify(args)+',{cwd:'+JSON.stringify(cwd)+',env:'+JSON.stringify(programEnv)+',stdio:"inherit",detached:false});c.on("error",()=>process.exitCode=1);c.on("close",code=>process.exit(code===null?1:code));');
  const spec={program:process.execPath,args:[launcher],cwd,timeout_seconds,owner:s.generation};
  const quote=JSON.stringify;
  fs.writeFileSync(script,"local j=dofile('lua/vendor/json.lua');local r=j.decode(host.operation('start',"+quote(JSON.stringify(spec))+"));assert(r.operation_id,j.encode(r));local s=j.decode(host.operation('await',j.encode({id=r.operation_id,wait_for='settled'})));assert(s.settled and s.output_streams_closed,j.encode(s));print(j.encode(s))\n");
  const env=isolatedEnvironment(dir);
  const result=await ownedProcess(root,binary,['--db',path.join(dir,'supervisor.db')],{cwd:luaRoot,env:{...env,WASM_AGENT_HOME:dir,WASM_AGENT_LUA_ROOT:luaRoot,WA_SCRIPT:script,WASM_AGENT_MANAGED:'0',WA_GRAPH_WATCH:'0'}});
  fs.writeFileSync(path.join(dir,'wrapper.stdout'),result.stdout);fs.writeFileSync(path.join(dir,'wrapper.stderr'),result.stderr);
  if(result.code!==0)fail('native tree supervisor failed; unknown effects retained');
  const receipt=JSON.parse(result.stdout.toString().trim().split(/\r?\n/).pop());
  if(receipt.settled!==true || receipt.output_streams_closed!==true || receipt.containment!=='windows_job_object' && receipt.containment!=='process_group')fail('native containment settlement unproven');
  for(const stream of ['stdout','stderr'])fs.copyFileSync(receipt[stream+'_path'],path.join(dir,stream));
  const bytes=json(receipt);fs.writeFileSync(path.join(dir,'settlement.json'),bytes);
  const a=load(root),p=a.processes.find(p=>p.id===result.id);p.process_tree='settled';p.settlement={path:path.relative(root,path.join(dir,'settlement.json')),sha256:digest(bytes),operation_id:receipt.operation_id,binary_sha256:digest(fs.readFileSync(binary))};save(a);
  return {id:result.id,...receipt};
}
function verifyWorkspaceVolumes(s){
 const ids=new Set((s.docker_resources||[]).map(r=>r.workspace_volume).filter(Boolean));
 for(const id of ids){if(!/^[a-zA-Z0-9_.-]+$/.test(id))fail('invalid workspace volume identity');const proofPath=path.join(s.root,'records','volume-'+id+'.snapshot.json');noLinks(proofPath);const p=JSON.parse(fs.readFileSync(proofPath));if(p.volume!==id||p.complete!==true||p.provisional!==false||typeof p.path!=='string'||!p.path.startsWith('volume-'+id+'-')||!p.path.endsWith('.tar')||!/^[a-zA-Z0-9_.-]+$/.test(p.path))fail('workspace volume capture incomplete');const file=path.join(s.root,'records',p.path);noLinks(file);const bytes=fs.readFileSync(file);if(bytes.length!==p.bytes||digest(bytes)!==p.sha256)fail('workspace volume snapshot drift');}
}
export function seal(root,{formatVersion}={}) {
  const s=load(root);if(s.phase!=='collecting') fail('generation already sealed or uncertain');
  if(s.processes.some(p=>p.state!=='closed'||p.process_tree!=='settled') || s.docker_creation && s.docker_creation!=='settled' || (s.docker_resources||[]).some(r=>r.effect_state && r.effect_state!=='settled'))fail('cannot seal live/uncertain effects as complete results');
  verifyWorkspaceVolumes(s);
  const dir=path.join(root,'records');
  for(const r of s.resources) {
    if(r.kind==='snapshot-checkout'&&!same(snapshotGitProof(r.path),r.git_proof))fail('snapshot Git ownership drift');
    r.sealed_inventory=inventory(r.path,{allowSnapshotGit:r.kind==='snapshot-checkout'});
  }
  const inventoryFile=path.join(dir,'disposable-inventory.json'),inventoryBytes=json(s.resources.map(r=>({path:r.path,kind:r.kind||'directory',identity:r.identity,files:r.sealed_inventory,git_proof:r.git_proof??null})));
  if(fs.existsSync(inventoryFile)){if(!fs.readFileSync(inventoryFile).equals(inventoryBytes))fail('existing seal inventory changed; no overwrite');}else writeNew(inventoryFile,inventoryBytes);
  const entries=inventory(dir);
  for(const kind of requiredRecords) if(!entries.some(e=>e.path===kind+'.json')) fail('missing required record: '+kind);
  const framed=formatVersion===2||formatVersion===undefined&&entries.reduce((n,e)=>n+e.bytes,0)>32*1024*1024;
  if(formatVersion!==undefined&&![1,2].includes(formatVersion))fail('unsupported archive format');
  if(framed){writeFramedBundle(path.join(root,'results.json.gz'),{generation:s.generation,nonce:s.nonce,entries},dir);s.bundle_version=2;}
  else{const bundle={version:1,generation:s.generation,nonce:s.nonce,entries:entries.map(e=>({...e,base64:fs.readFileSync(path.join(dir,e.path)).toString('base64')}))};writeNew(path.join(root,'results.json.gz'),zlib.gzipSync(json(bundle),{level:9}));s.bundle_version=1;}
  s.bundle_sha256=fileDigest(path.join(root,'results.json.gz'));s.records=entries;s.phase='sealed';save(s);
  return verifyBundle(root);
}
function verifiedRecord(root,selected=null) {
  const s=load(root);if(!['sealed','cleaning','cleaned','uncertain'].includes(s.phase))fail('no sealed bundle');const file=path.join(root,'results.json.gz');if(fileDigest(file)!==s.bundle_sha256)fail('archive corruption');
  const names=new Set();for(const e of s.records||[]){if(typeof e.path!=='string'||!inside(path.resolve(root,'records'),path.resolve(root,'records',e.path))||names.has(e.path)||!Number.isSafeInteger(e.bytes)||e.bytes<0||!/^[a-f0-9]{64}$/.test(e.sha256))fail('archive escape/duplicate/metadata');names.add(e.path);}for(const kind of requiredRecords)if(!names.has(kind+'.json'))fail('missing archive record');if(selected!==null&&!names.has(selected))fail('archive record absent');
  let content;
  if(s.bundle_version===2){const read=readFramedBundle(file,s,selected);if(selected!==null)content=read;}
  else{if(s.bundle_version!==undefined&&s.bundle_version!==1)fail('unsupported archive version');const b=JSON.parse(zlib.gunzipSync(fs.readFileSync(file)));if(b.version!==1||b.generation!==s.generation||b.nonce!==s.nonce)fail('archive ownership/version');for(const e of b.entries){const raw=Buffer.from(e.base64,'base64');if(raw.length!==e.bytes||digest(raw)!==e.sha256)fail('archive entry corruption');if(e.path===selected)content=raw;}if(!same(b.entries.map(({base64,...e})=>e),s.records))fail('manifest mismatch');}
  if(fs.existsSync(path.join(root,'records'))&&!same(inventory(path.join(root,'records')),s.records))fail('original evidence drift');return {verdict:{generation:s.generation,sha256:s.bundle_sha256,entries:s.records.length,bytes:fs.statSync(file).size,lossless:true},content};
}
export function verifyBundle(root){return verifiedRecord(root).verdict;}
export function readSealedRecord(root,name){return verifiedRecord(root,name).content;}
export function reconcileFilesystem(root) {
  const s=load(root);const archive=verifyBundle(root),resources=[];
  for(const r of s.resources) {
    if(!inside(path.join(root,'disposable'),r.path))fail('reconciliation resource escape');
    let observation;
    if(!fs.existsSync(r.path))observation={path:r.path,status:'absent',ownership:'recorded-generation'};
    else {
      try {noLinks(r.path);const marker=JSON.parse(fs.readFileSync(path.join(r.path,'.benchmark-owned.json')));observation={path:r.path,status:'present',ownership:same(identity(r.path),r.identity)&&same(marker,r.marker)?'exact-owned':'drift'};}
      catch(e){observation={path:r.path,status:'uninspectable',ownership:'unknown',error:e.message};}
    }
    resources.push(observation);
  }
  const result={generation:s.generation,phase:s.phase,archive,resources,effects_replayed:false,finished_clean:s.phase==='cleaned'};
  writeNew(path.join(root,'reconciliation-'+crypto.randomUUID()+'.json'),json(result));return result;
}
export function cleanup(root) {
  const s=load(root);verifyBundle(root);
  if(s.phase==='cleaned') return JSON.parse(fs.readFileSync(path.join(root,'cleanup.json')));
  if(s.phase!=='sealed') fail('uncertain/crash cleanup needs reconciliation; never replay');
  if(s.docker_creation && s.docker_creation!=='settled' || (s.docker_resources||[]).some(r=>r.state!=='removed'))fail('Docker cleanup outstanding');
  for(const p of s.processes) {
    if(active.has(p.id) || p.state!=='closed' || p.process_tree!=='settled') fail('live or uncertain process/effects');
    if(!p.settlement || !inside(root,path.resolve(root,p.settlement.path)))fail('missing process settlement');
    const bytes=fs.readFileSync(path.join(root,p.settlement.path));if(digest(bytes)!==p.settlement.sha256)fail('process settlement drift');
    const r=JSON.parse(bytes);if(r.operation_id!==p.settlement.operation_id || r.settled!==true || r.output_streams_closed!==true)fail('process settlement incomplete');
  }
  for(const r of s.resources) {
    if(!inside(path.join(root,'disposable'),r.path)) fail('resource path escape');noLinks(r.path);
    if(!same(identity(r.path),r.identity) || !same(JSON.parse(fs.readFileSync(path.join(r.path,'.benchmark-owned.json'))),r.marker)) fail('resource ownership drift');
    if(r.kind==='snapshot-checkout'&&!same(snapshotGitProof(r.path),r.git_proof))fail('snapshot Git ownership drift');
    if(!same(inventory(r.path,{allowSnapshotGit:r.kind==='snapshot-checkout'}),r.sealed_inventory))fail('disposable changed after seal');
  }
  // Refuse unexpected resources, rather than sweeping a shared directory.
  if(fs.readdirSync(path.join(root,'disposable')).length!==s.resources.length) fail('unregistered/shared resource');
  s.phase='cleaning';save(s);const removed=[];
  try {
    for(const r of s.resources) {noLinks(r.path);if(!same(identity(r.path),r.identity)) fail('ownership race');fs.rmSync(r.path,{recursive:true});removed.push(r.path);}
    // Only redundant source copies after archive integrity verification.
    fs.rmSync(path.join(root,'records'),{recursive:true});s.phase='cleaned';save(s);
    const receipt={ok:true,generation:s.generation,bundle_sha256:s.bundle_sha256,removed,archive_preserved:true};writeNew(path.join(root,'cleanup.json'),json(receipt));return receipt;
  } catch(e) {s.phase='uncertain';s.cleanup_error=e.message;save(s);throw e;}
}
// Adapter-created Docker resources receive an unguessable generation ownership label.
// The adapter must implement inspect/create/remove using actual Docker receipts; tests
// The actual adapter and hermetic proof are separate from negative mocked controls.
export function dockerResource(root,kind,adapter) {
  const s=load(root);if(s.phase!=='collecting')fail('sealed generation');
  if(!['container','network','volume'].includes(kind))fail('unsupported Docker resource');
  s.docker_creation='reserved';save(s);
  const created=adapter.create({kind,generation:s.generation,owner_nonce:s.nonce});
  if(!created?.id)fail('Docker create outcome uncertain; preserve journal');
  const observed=adapter.inspect(created.id);
  if(observed.generation!==s.generation || observed.owner_nonce!==s.nonce || observed.kind!==kind)fail('Docker creation ownership unproven');
  (s.docker_resources??=[]).push({id:created.id,kind,state:'owned',...(created.workspace_volume?{workspace_volume:created.workspace_volume}:{})});s.docker_creation='settled';save(s);
  writeNew(path.join(root,'records','docker-'+safeName(created.id)+'.json'),json({created,observed}));return created.id;
}
export function reconcileDocker(root,adapter) {
  const s=load(root);verifyBundle(root);const observations=[];
  for(const r of s.docker_resources||[]) {
    const observed=adapter.inspect(r.id);observations.push(observed);
    if(['removing','uncertain'].includes(r.state) && observed.absent===true) {
      r.state='removed';r.receipt={id:r.id,settled:true,absent:true,reconciled:true};save(s);
    } else if(observed.absent!==true && (observed.generation!==s.generation || observed.owner_nonce!==s.nonce))fail('Docker reconciliation ownership drift');
  }
  writeNew(path.join(root,'reconciliation-'+crypto.randomUUID()+'.json'),json({generation:s.generation,observations,effects_replayed:false}));
  return {observations,effects_replayed:false,unresolved:(s.docker_resources||[]).filter(r=>r.state!=='removed').map(r=>r.id)};
}
export function cleanupDocker(root,adapter) {
  const s=load(root);verifyBundle(root);
  if(s.docker_creation && s.docker_creation!=='settled')fail('Docker creation uncertain');
  if(s.phase!=='sealed' || (s.docker_resources||[]).some(r=>r.state==='removing'||r.state==='uncertain'||r.effect_state && r.effect_state!=='settled'))fail('Docker cleanup uncertain; inspect/reconcile only, never replay');
  const resources=s.docker_resources||[],observations=resources.filter(r=>r.state!=='removed').map(r=>adapter.inspect(r.id));
  for(const x of observations)if(x.generation!==s.generation || x.owner_nonce!==s.nonce || x.shared!==false || x.running!==false || x.effects!=='settled' || !['container','network','volume'].includes(x.kind))fail('Docker ownership/drain refusal');
  const receipts=[];
  observations.sort((a,b)=>({container:0,network:1,volume:2}[a.kind]-{container:0,network:1,volume:2}[b.kind]));
  for(const x of observations) {
    const fresh=adapter.inspect(x.id);if(!same(fresh,x))fail('Docker drift');
    const r=resources.find(r=>r.id===x.id);r.state='removing';save(s);
    try {const receipt=adapter.remove(x.id);if(receipt?.settled!==true)fail('Docker deletion uncertain; never replay');r.state='removed';r.receipt=receipt;receipts.push(receipt);save(s);}
    catch(e) {r.state='uncertain';r.error=e.message;save(s);throw e;}
  }
  return receipts;
}
