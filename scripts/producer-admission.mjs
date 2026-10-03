// Producer evidence is deliberately a different kind from a full combined-tree gate.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {deliveryFiles,runDeliveryProof,verifyDeliveryProof,skipped} from './lib/delivery-producer-proof.mjs';
import {fullProof} from './lib/full-gate-proof.mjs';
import {catalog} from './gate-checks.mjs';
import {executeChecks,hash,checkVerdict} from './gate-check.mjs';
function git(repo,...args) {
  const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true,maxBuffer:16*1024*1024});
  if(r.status!==0)throw Error(r.stderr||r.error?.message||'git failed');return r.stdout.trim();
}
// A declared case is a tracked local Node test, never an arbitrary shell command.
function definitions(repo,scope) {
  const all=catalog(repo);
  for(const c of scope?.cases||[]) {
    if(!/^scripts\/test-[A-Za-z0-9_-]+\.(mjs|cjs)$/.test(c.path)||c.id!==`case:${c.path}`||!['js','proof','counted','terminal'].includes(c.verdict)||all.some(d=>d.id===c.id))throw Error('invalid declared focused case');
    if(c.verdict==='proof'&&(!c.proof_kind||!Number.isInteger(c.minimum)||c.minimum<1))throw Error('declared case requires a counted verdict');
    if(c.verdict==='counted'&&(!/^[A-Za-z][A-Za-z0-9 _-]+ ok$/.test(c.terminal_prefix)||!Number.isSafeInteger(c.minimum)||c.minimum<1))throw Error('invalid declared counted verdict');
    if(c.verdict==='terminal'&&(typeof c.terminal_line!=='string'||!c.terminal_line||/[\r\n]/.test(c.terminal_line)))throw Error('invalid declared terminal verdict');
    git(repo,'cat-file','-e',`HEAD:${c.path}`);
    all.push({...c,command:[process.execPath,c.path]});
  }
  return all;
}
function focusedVerdict(check,exit,log) {
  if(check.verdict==='terminal')return {ok:exit===0&&String(log).split(/\r?\n/).filter(line=>line===check.terminal_line).length===1&&skipped(log)===0&&!/^\s*(?:FAIL(?:[:\s]|$)|ALL FAIL(?:[:\s]|$)|DEPENDENCY_MISSING)/m.test(log)};
  if(check.verdict!=='counted')return checkVerdict(check,exit,log);
  const lines=String(log).split(/\r?\n/),markers=lines.filter(line=>line.startsWith(check.terminal_prefix+' ('));
  const match=markers.length===1&&new RegExp('^'+check.terminal_prefix+' \\((\\d+) checks, 0 skipped(?:; [^\\r\\n]*)?\\)$').exec(markers[0]);
  return {ok:exit===0&&Boolean(match)&&Number(match[1])>=check.minimum&&skipped(log)===0&&!/^\s*(?:FAIL(?:[:\s]|$)|ALL FAIL(?:[:\s]|$)|DEPENDENCY_MISSING)/m.test(log)};
}
function artifact(ref) {
  const bytes=fs.readFileSync(ref.path);if(hash(bytes)!==ref.sha256)throw Error('focused artifact hash mismatch');return bytes;
}
// Import an independent source review's actual observations, without inventing a new run.
function reviewedObservations(repo,receipt,current) {
  const ref=current.focused_scope?.evidence,packet=JSON.parse(artifact(ref));
  if(packet.schema!==1||packet.kind!=='independent-focused-review-references'||packet.not_producer_execution_receipt!==true)throw Error('unsupported focused observation packet');
  const entry=packet.entries.find(e=>e.tip===ref.entry_tip);
  if(!entry||!entry.reviewer||entry.verdict!=='bounded source accepted'||entry.gate_verified!==false||entry.release_verified!==false||entry.routine_requires_combined_gate!==false||git(repo,'rev-parse',`${entry.tip}^{tree}`)!==entry.tree)throw Error('focused original source identity mismatch');
  artifact(entry.review_report);
  const available=definitions(repo,current.focused_scope),observations=[];
  if(entry.checks.length!==current.checks.length)throw Error('focused observation selection mismatch');
  for(const id of current.checks) {
    const row=entry.checks.find(c=>c.id===id),definition=available.find(c=>c.id===id);
    if(!row||!definition||row.path!==definition.path||row.tested_head!==entry.tip||row.exit!==0||row.skipped!==0||(row.ms!==null&&(!Number.isFinite(row.ms)||row.ms<0)))throw Error('invalid focused original execution facts');
    const source=spawnSync('git',['show',`${row.tested_head}:${row.path}`],{cwd:repo,windowsHide:true,maxBuffer:32*1024*1024});
    if(source.status!==0||hash(source.stdout)!==row.script_sha256)throw Error('focused original runner source mismatch');
    const raw=artifact(row.original_log),text=raw[0]===255&&raw[1]===254?raw.subarray(2).toString('utf16le'):raw.toString('utf8');
    if(row.decoded_log&&artifact(row.decoded_log).toString('utf8')!==text)throw Error('focused decoded log differs from original');
    if(!focusedVerdict(definition,row.exit,text).ok)throw Error('focused original terminal verdict invalid');
    observations.push({...row,tested_tree:entry.tree,execution_runner_identity:'tracked test script; executable/host not recorded',coverage:'original source only; current scope selected by independent reviewer'});
  }
  return {reviewer:entry.reviewer,observations,reference:ref};
}
export function plan(repo,tip='HEAD',base='origin/main',{mode='routine',focusedScope=null}={}) {
  if(!['routine','pre-release'].includes(mode))throw Error('unknown admission mode');
  const head=git(repo,'rev-parse',`${tip}^{commit}`),tree=git(repo,'rev-parse',`${tip}^{tree}`),baseHead=git(repo,'rev-parse',`${base}^{commit}`);
  const files=git(repo,'diff','--name-only',baseHead,head).split('\n').filter(Boolean),checks=new Set();
  const source={head,tree,base:baseHead,files,mode,full_required:false,requires_combined_gate:false};
  if(mode==='pre-release')return {...source,checks:['full'],full_required:true};
  if(focusedScope) {
    if(JSON.stringify(focusedScope.files)!==JSON.stringify(files)||!focusedScope.reason?.trim()||!Array.isArray(focusedScope.checks)||!focusedScope.checks.length||new Set(focusedScope.checks).size!==focusedScope.checks.length)throw Error('invalid focused scope declaration');
    const available=definitions(repo,focusedScope);
    if(focusedScope.checks.some(id=>id==='full'||!available.some(c=>c.id===id)))throw Error('unsupported declared focused check');
    return {...source,checks:focusedScope.checks,focused_scope:focusedScope};
  }
  if(files.length && files.every(f=>deliveryFiles.includes(f)))return {...source,checks:['delivery-subsystem']};
  let full=false;
  for(const file of files) {
    if(/^tests\/[^/]+\.js$/.test(file))checks.add(`js:${path.basename(file)}`);
    else if(/^ui\/(app|components)\.js$/.test(file)) {
      for(const c of catalog(repo).filter(c=>c.id.startsWith('js:')))checks.add(c.id);checks.add('ui-browser');
      const integration=catalog(repo).filter(c=>['selection-state','recovery-windows'].includes(c.id));
      if(integration.some(c=>c.available===false||(c.platform&&c.platform!==process.platform)))full=true;
      else for(const c of integration)checks.add(c.id);
    } else full=true;
  }
  if(full||!files.length)return {...source,checks:[],focused_scope_required:true};
  return {...source,checks:[...checks].sort()};
}
export function verifyFocused(repo,receipt,tip='HEAD') {
  try {
    const current=plan(repo,tip,'origin/main',{focusedScope:receipt?.focused_scope}),identity=hash(fs.readFileSync(fileURLToPath(import.meta.url)))+hash(fs.readFileSync(path.join(repo,'scripts/gate-checks.mjs')))+hash(fs.readFileSync(path.join(repo,'scripts/gate-check.mjs')));
    if(git(repo,'rev-parse','HEAD')!==current.head||git(repo,'status','--porcelain'))throw Error('producer source moved or dirty');
    if(current.checks[0]==='delivery-subsystem')return {...verifyDeliveryProof(repo,receipt,current),release_verified:false,requires_combined_gate:false};
    if(receipt?.schema===1&&receipt.kind==='reviewed-focused') {
      if(receipt.head!==current.head||receipt.tree!==current.tree||receipt.base!==current.base||JSON.stringify(receipt.checks)!==JSON.stringify(current.checks)||current.focused_scope_required)throw Error('reviewed focused candidate identity mismatch');
      const evidence=reviewedObservations(repo,receipt,current);
      return {admission_verified:true,gate_verified:false,release_verified:false,requires_combined_gate:false,head:current.head,tree:current.tree,checks:current.checks,focused_scope:current.focused_scope,original_evidence:evidence};
    }
    if(receipt.schema!==1||receipt.kind!=='producer-focused'||receipt.head!==current.head||receipt.base!==current.base||receipt.tree!==current.tree||receipt.passed!==true||receipt.runner_identity!==identity)throw Error('missing, stale or untrusted focused evidence');
    if(current.focused_scope_required||JSON.stringify(receipt.checks)!==JSON.stringify(current.checks))throw Error('coverage changed or focused scope declaration required');
    if(!Array.isArray(receipt.results)||receipt.results.length!==current.checks.length)throw Error('missing check results');
    const available=definitions(repo,receipt.focused_scope);
    for(const id of current.checks) {
      const result=receipt.results.find(r=>r.id===id);
      if(!result||result.passed!==true||result.exit!==0||result.skipped!==0||!Number.isFinite(result.ms)||result.ms<0||hash(fs.readFileSync(result.log))!==result.log_sha256||skipped(fs.readFileSync(result.log,'utf8'))!==0)throw Error(`invalid check evidence ${id}`);
      const definition=available.find(check=>check.id===id);
      if(!definition||!focusedVerdict(definition,result.exit,fs.readFileSync(result.log,'utf8')).ok)throw Error(`invalid terminal check verdict ${id}`);
    }
    return {admission_verified:true,gate_verified:false,release_verified:false,requires_combined_gate:false,head:current.head,tree:current.tree,checks:current.checks,focused_scope:current.focused_scope||null};
  } catch(error){return {admission_verified:false,gate_verified:false,release_verified:false,requires_combined_gate:false,error:error.message};}
}
// The reviewer owns the scope selection; bind it to their immutable Git artifact.
export function verifyReviewedFocused(repo,receipt,review,tip='HEAD',producer=null) {
  const proof=verifyFocused(repo,receipt,tip);
  if(!proof.admission_verified||!receipt.focused_scope)return proof;
  try {
    if(!review?.reviewer||review.reviewer===producer||!['passed','narrowed'].includes(review.verdict)||review.tip!==proof.head||review.tree!==proof.tree||JSON.stringify(review.focused_scope)!==JSON.stringify(receipt.focused_scope))throw Error('focused scope lacks independent exact-source review');
    if(proof.original_evidence&&proof.original_evidence.reviewer!==review.reviewer)throw Error('focused observation belongs to another reviewer');
    const body=git(repo,'show','--no-patch','--format=%B',`${review.commit}^{commit}`),trailer=body.trimEnd().split(/\r?\n/).pop();
    const sessions=[...trailer.matchAll(/(?:^|[ \t])session=([^ \t\r\n]+)(?=$|[ \t])/g)];
    if(!/^Agent:[ \t]*[^\s]+[ \t]/.test(trailer)||sessions.length!==1||sessions[0][1]!==review.reviewer)throw Error('focused scope reviewer provenance mismatch');
    const anchors=body.split(/\r?\n/).filter(line=>line.startsWith('Focused-Scope-SHA256:'));
    if(anchors.length!==1||anchors[0]!==`Focused-Scope-SHA256: ${hash(JSON.stringify(receipt.focused_scope))}`)throw Error('focused scope not bound to reviewer artifact');
    return proof;
  }catch(error){return {...proof,admission_verified:false,error:error.message};}
}
// Source paths never request a gate. Only the user's explicit pre-release mode does.
export function verifyProducer(repo,receipt,tip='HEAD',{mode='routine'}={}) {
  if(mode==='routine')return verifyFocused(repo,receipt,tip);
  try {
    const selection=plan(repo,tip,'origin/main',{mode});
    const proof=fullProof(receipt,selection.tree,{ownerRepo:repo});
    if(!proof.verified)throw Error(proof.reason);
    if((receipt.kind==='retained-full'?receipt.candidate_head:proof.head)!==selection.head)throw Error('full proof names another commit');
    const common=p=>fs.realpathSync(git(p,'rev-parse','--path-format=absolute','--git-common-dir'));
    if(common(proof.owner_repo)!==common(repo))throw Error('full proof belongs to another repository');
    if(git(repo,'rev-parse','HEAD')!==selection.head||git(repo,'status','--porcelain'))throw Error('producer source moved or dirty');
    return {admission_verified:true,gate_verified:true,release_verified:false,requires_combined_gate:false,head:selection.head,tree:selection.tree,full_proof:proof};
  }catch(error){return {admission_verified:false,gate_verified:false,release_verified:false,requires_combined_gate:false,error:error.message};}
}
export async function runFocused(repo,{jobs=1,output=null,focusedScope=null}={}) {
  const selection=plan(repo,'HEAD','origin/main',{focusedScope});
  if(git(repo,'status','--porcelain'))throw Error('focused admission requires a clean committed tree');
  if(selection.focused_scope_required)return {...selection,admission_verified:false,gate_verified:false,release_verified:false,error:'source paths require an independently reviewed focused scope declaration'};
  if(selection.checks[0]==='delivery-subsystem') {
    const receipt=runDeliveryProof(repo,selection,output),target=path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json'));
    fs.writeFileSync(target,JSON.stringify(receipt,null,2)+'\n');return {...verifyFocused(repo,receipt),receipt:target};
  }
  const declared=definitions(repo,selection.focused_scope).filter(c=>selection.checks.includes(c.id)&&c.id.startsWith('case:'));
  const catalogIds=selection.checks.filter(id=>!id.startsWith('case:'));
  const result=catalogIds.length?await executeChecks(repo,catalogIds,{jobs,output,emit:false}):{schema:1,results:[]};
  const logRoot=output||path.resolve(repo,git(repo,'rev-parse','--git-path','wa-focused-case-logs'));fs.mkdirSync(logRoot,{recursive:true});
  for(const c of declared) {
    const privateHome=fs.mkdtempSync(path.join(logRoot,'case-home-')),env={...process.env};
    for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(key))delete env[key];
    Object.assign(env,{USERPROFILE:privateHome,LOCALAPPDATA:path.join(privateHome,'LocalAppData'),APPDATA:path.join(privateHome,'AppData'),WASM_AGENT_HOME:privateHome,WASM_AGENT_MANAGED:'0',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only',HTTP_PROXY:'',HTTPS_PROXY:'',ALL_PROXY:'',NO_PROXY:'127.0.0.1,localhost,::1'});
    const started=performance.now(),r=spawnSync(process.execPath,[c.path],{cwd:repo,env,encoding:'utf8',windowsHide:true,maxBuffer:32*1024*1024,timeout:180000});
    const bytes=Buffer.from((r.stdout||'')+(r.stderr||'')),log=path.join(logRoot,c.id.replaceAll(/[^a-z0-9.-]/gi,'_')+'.log');fs.writeFileSync(log,bytes);
    result.results.push({id:c.id,exit:r.status,passed:focusedVerdict(c,r.status,String(bytes)).ok,skipped:skipped(String(bytes)),ms:performance.now()-started,log,log_sha256:hash(bytes)});
  }
  result.results=selection.checks.map(id=>result.results.find(r=>r.id===id));result.passed=result.results.every(r=>r.passed&&r.skipped===0);
  if(git(repo,'rev-parse','HEAD^{tree}')!==selection.tree||git(repo,'status','--porcelain'))throw Error('source moved while checking');
  const receipt={...result,...selection,kind:'producer-focused',runner_identity:hash(fs.readFileSync(fileURLToPath(import.meta.url)))+hash(fs.readFileSync(path.join(repo,'scripts/gate-checks.mjs')))+hash(fs.readFileSync(path.join(repo,'scripts/gate-check.mjs')))};
  const target=path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json'));
  fs.writeFileSync(target,JSON.stringify(receipt,null,2)+'\n');return {...verifyFocused(repo,receipt),receipt:target};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [mode,directory,tip,...args]=process.argv.slice(2),repo=path.resolve(directory||'.');
  try {
    let result;
    const scopeIndex=args.indexOf('--focused-scope'),focusedScope=scopeIndex<0?null:JSON.parse(fs.readFileSync(args[scopeIndex+1],'utf8'));
    if(mode==='check')result=plan(repo,tip||'HEAD','origin/main',{focusedScope});
    else if(mode==='run')result=await runFocused(repo,{jobs:Number(process.env.WA_CHECK_JOBS||1),focusedScope});
    else if(mode==='verify')result=verifyFocused(repo,JSON.parse(fs.readFileSync(path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json')),'utf8')),tip||'HEAD');
    else throw Error('usage: producer-admission.mjs check|run|verify <repo> [tip]');
    console.log(JSON.stringify(result,null,2));if(mode!=='check'&&!result.admission_verified)process.exitCode=2;
  } catch(error){console.error(error.stack);process.exitCode=4;}
}
