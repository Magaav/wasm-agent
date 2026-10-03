// Producer evidence is deliberately a different kind from a full combined-tree gate.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {deliveryFiles,runDeliveryProof,verifyDeliveryProof} from './lib/delivery-producer-proof.mjs';
import {fullProof} from './lib/full-gate-proof.mjs';
import {catalog} from './gate-checks.mjs';
import {executeChecks,hash,checkVerdict} from './gate-check.mjs';
function git(repo,...args) {
  const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true,maxBuffer:16*1024*1024});
  if(r.status!==0)throw Error(r.stderr||r.error?.message||'git failed');return r.stdout.trim();
}
export function plan(repo,tip='HEAD',base='origin/main') {
  const head=git(repo,'rev-parse',`${tip}^{commit}`),tree=git(repo,'rev-parse',`${tip}^{tree}`),baseHead=git(repo,'rev-parse',`${base}^{commit}`);
  const files=git(repo,'diff','--name-only',baseHead,head).split('\n').filter(Boolean),checks=new Set();
  if(files.length && files.every(f=>deliveryFiles.includes(f)))return {head,tree,base:baseHead,files,checks:['delivery-subsystem'],full_required:false,requires_combined_gate:true};
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
  if(full||!files.length)return {head,tree,base:baseHead,files,checks:['full'],full_required:true,requires_combined_gate:true};
  return {head,tree,base:baseHead,files,checks:[...checks].sort(),full_required:false,requires_combined_gate:true};
}
export function verifyFocused(repo,receipt,tip='HEAD') {
  try {
    const current=plan(repo,tip),identity=hash(fs.readFileSync(fileURLToPath(import.meta.url)))+hash(fs.readFileSync(path.join(repo,'scripts/gate-checks.mjs')))+hash(fs.readFileSync(path.join(repo,'scripts/gate-check.mjs')));
    if(current.checks[0]==='delivery-subsystem')return verifyDeliveryProof(repo,receipt,current);
    if(receipt.schema!==1||receipt.kind!=='producer-focused'||receipt.tree!==current.tree||receipt.passed!==true||receipt.runner_identity!==identity)throw Error('missing, stale or untrusted focused evidence');
    if(current.full_required||JSON.stringify(receipt.checks)!==JSON.stringify(current.checks))throw Error('coverage changed or full gate required');
    if(!Array.isArray(receipt.results)||receipt.results.length!==current.checks.length)throw Error('missing check results');
    const definitions=catalog(repo);
    for(const id of current.checks) {
      const result=receipt.results.find(r=>r.id===id);
      if(!result||result.passed!==true||result.exit!==0||result.skipped!==0||!Number.isFinite(result.ms)||result.ms<0||hash(fs.readFileSync(result.log))!==result.log_sha256)throw Error(`invalid check evidence ${id}`);
      const definition=definitions.find(check=>check.id===id);
      if(!definition||!checkVerdict(definition,result.exit,fs.readFileSync(result.log,'utf8')).ok)throw Error(`invalid terminal check verdict ${id}`);
    }
    return {admission_verified:true,gate_verified:false,requires_combined_gate:true,tree:current.tree,checks:current.checks};
  } catch(error){return {admission_verified:false,gate_verified:false,requires_combined_gate:true,error:error.message};}
}
// Ordinary broad-source admission consumes genuine full proof; it never runs a release gate.
export function verifyProducer(repo,receipt,tip='HEAD') {
  const selection=plan(repo,tip);
  if(!selection.full_required)return verifyFocused(repo,receipt,tip);
  try {
    const proof=fullProof(receipt,selection.tree,{ownerRepo:repo});
    if(!proof.verified)throw Error(proof.reason);
    if(proof.head!==selection.head)throw Error('full proof names another commit');
    const common=p=>fs.realpathSync(git(p,'rev-parse','--path-format=absolute','--git-common-dir'));
    if(common(proof.owner_repo)!==common(repo))throw Error('full proof belongs to another repository');
    if(git(repo,'rev-parse','HEAD')!==selection.head||git(repo,'status','--porcelain'))throw Error('producer source moved or dirty');
    return {admission_verified:true,gate_verified:true,requires_combined_gate:true,head:selection.head,tree:selection.tree,full_proof:proof};
  }catch(error){return {admission_verified:false,gate_verified:false,requires_combined_gate:true,error:error.message};}
}
export async function runFocused(repo,{jobs=1,output=null}={}) {
  const selection=plan(repo);
  if(git(repo,'status','--porcelain'))throw Error('focused admission requires a clean committed tree');
  if(selection.full_required)return {...selection,admission_verified:false,gate_verified:false,error:'unknown/shared paths require finish.mjs gate'};
  if(selection.checks[0]==='delivery-subsystem') {
    const receipt=runDeliveryProof(repo,selection,output),target=path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json'));
    fs.writeFileSync(target,JSON.stringify(receipt,null,2)+'\n');return {...verifyFocused(repo,receipt),receipt:target};
  }
  const result=await executeChecks(repo,selection.checks,{jobs,output,emit:false});
  if(git(repo,'rev-parse','HEAD^{tree}')!==selection.tree||git(repo,'status','--porcelain'))throw Error('source moved while checking');
  const receipt={...result,...selection,kind:'producer-focused',runner_identity:hash(fs.readFileSync(fileURLToPath(import.meta.url)))+hash(fs.readFileSync(path.join(repo,'scripts/gate-checks.mjs')))+hash(fs.readFileSync(path.join(repo,'scripts/gate-check.mjs')))};
  const target=path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json'));
  fs.writeFileSync(target,JSON.stringify(receipt,null,2)+'\n');return {...verifyFocused(repo,receipt),receipt:target};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [mode,directory,tip]=process.argv.slice(2),repo=path.resolve(directory||'.');
  try {
    let result;
    if(mode==='check')result=plan(repo,tip||'HEAD');
    else if(mode==='run')result=await runFocused(repo,{jobs:Number(process.env.WA_CHECK_JOBS||1)});
    else if(mode==='verify')result=verifyFocused(repo,JSON.parse(fs.readFileSync(path.resolve(repo,git(repo,'rev-parse','--git-path','wa-producer-check.json')),'utf8')),tip||'HEAD');
    else throw Error('usage: producer-admission.mjs check|run|verify <repo> [tip]');
    console.log(JSON.stringify(result,null,2));if(mode!=='check'&&!result.admission_verified)process.exitCode=2;
  } catch(error){console.error(error.stack);process.exitCode=4;}
}
