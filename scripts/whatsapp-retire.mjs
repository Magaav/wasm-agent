// Exact-match, operator-run legacy job retirement. Never deletes history or replays effects.
import {spawnSync} from 'node:child_process';
import {readFileSync,writeFileSync,lstatSync} from 'node:fs';
import {isAbsolute,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
export const LEGACY_IDS=['whatsapp-copilot','whatsapp-events','whatsapp-wake-selftest','whatsapp-ingest','whatsapp-message','whatsapp-source','whatsapp-transcribe'];
const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
export const hash=value=>createHash('sha256').update(typeof value==='string'||Buffer.isBuffer(value)?value:JSON.stringify(canonical(value))).digest('hex');
export function definition(row){const copy={...row};for(const key of ['enabled','revision','source_status','pending','queued','running','last_delivery','last_outcome','last_at'])delete copy[key];return copy;}
export function plan(manifest,inventory){
 if(manifest.schema!==1||manifest.owner!=='wasm-agent-whatsapp'||!manifest.account||!Array.isArray(manifest.jobs)||!Array.isArray(inventory))throw Error('invalid_retirement_manifest');
 const jobs=[];
 for(const expected of manifest.jobs){
  if(!LEGACY_IDS.includes(expected.id)||!Number.isSafeInteger(expected.revision)||!/^[a-f0-9]{64}$/.test(expected.definition_sha256))throw Error('unowned_job_manifest');
  const actual=inventory.find(j=>j.id===expected.id);if(!actual)throw Error('job_absence_requires_new_manifest:'+expected.id);
  if(actual.revision!==expected.revision||hash(definition(actual))!==expected.definition_sha256)throw Error('job_ownership_revision_hash_mismatch:'+expected.id);
  if(actual.running>0)throw Error('running_delivery_requires_reconciliation:'+expected.id);
  jobs.push({id:actual.id,enabled:actual.enabled,revision:actual.revision});
 }
 for(const actual of inventory){if(LEGACY_IDS.includes(actual.id)&&!manifest.jobs.some(j=>j.id===actual.id))throw Error('unmapped_legacy_job:'+actual.id);}
 for(const file of manifest.files||[]){if(!isAbsolute(file.path)||file.owner!=='wasm-agent-whatsapp'||!/^[a-f0-9]{64}$/.test(file.sha256))throw Error('unowned_file_manifest');if(lstatSync(file.path).isSymbolicLink()||hash(readFileSync(file.path))!==file.sha256)throw Error('file_ownership_hash_mismatch');}
 return {jobs,blockers:manifest.blockers||['task_trigger_process_and_identity_verification_required'],preserved:['all ledgers','transcripts','drafts','browser profile','unknown sends','job histories']};
}
export async function retire(manifest,driver,apply=false){
 const before=await driver.list();const checked=plan(manifest,before);if(!apply)return {ok:true,dry_run:true,...checked};
 const changed=[];
 for(const job of checked.jobs){
  if(!job.enabled)continue;
  // Recheck the complete inventory before EACH irreversible supported-API call.
  const current=await driver.list();const expected=manifest.jobs.find(j=>j.id===job.id);const row=current.find(j=>j.id===job.id);
  if(!row||row.revision!==expected.revision||hash(definition(row))!==expected.definition_sha256)throw Error('retirement_inventory_changed');
  await driver.disable(job.id);changed.push(job.id);
  const after=(await driver.list()).find(j=>j.id===job.id);if(!after||after.enabled!==false)throw Error('disable_unverified_stop_and_inspect_no_replay');
 }
 return {ok:true,applied:changed,blockers:checked.blockers,activation_authorized:false,preserved:checked.preserved};
}
function cli(args){
 const at=name=>args[args.indexOf(name)+1];if(!args.includes('--manifest')||!args.includes('--sentinel'))throw Error('usage: --manifest PRIVATE.json --sentinel ABSOLUTE_EXE [--apply] [--out PRIVATE.json]');
 const exe=at('--sentinel');if(!isAbsolute(exe))throw Error('absolute_sentinel_required');
 const call=argv=>{const r=spawnSync(exe,['job',...argv],{encoding:'utf8',shell:false,timeout:30000,maxBuffer:8*1024*1024});if(r.status!==0)throw Error('supported_job_api_failed_inspect_before_retry');return JSON.parse(r.stdout)};
 const driver={list:()=>call(['list']),disable:id=>call(['disable',id])};
 return retire(JSON.parse(readFileSync(at('--manifest'),'utf8')),driver,args.includes('--apply')).then(result=>{if(args.includes('--out'))writeFileSync(at('--out'),JSON.stringify(result,null,2),{flag:'wx',mode:0o600});console.log(JSON.stringify(result));});
}
if(import.meta.url===pathToFileURL(resolve(process.argv[1]||'')).href)cli(process.argv.slice(2)).catch(error=>{console.error(error.message);process.exitCode=1;});
