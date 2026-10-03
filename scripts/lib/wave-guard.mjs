import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
export function checkWaveAdmission(repo,{phase='produce',recovery=null}={}) {
  try {
    const r=spawnSync('git',['rev-parse','--path-format=absolute','--git-common-dir'],{cwd:repo,encoding:'utf8',windowsHide:true});
    if(r.status!==0)throw Error(r.stderr||r.error?.message||'shared Git directory unavailable');
    const common=fs.realpathSync(r.stdout.trim()),registration=path.join(common,'wa-waves','registration.json');
    let registered=false;
    try {registered=fs.lstatSync(registration).isFile();if(!registered)throw Error('registration is not a file');}
    catch(error){if(error.code!=='ENOENT')throw Error('wave registration unavailable: '+error.message);}
    const entry=path.join(repo,'scripts','wave-entry.mjs');
    if(!fs.existsSync(entry))return registered?{ok:false,wave_verified:false,reason:'registered wave entry module missing'}
      :{ok:true,wave_verified:false,reason:'unregistered legacy/bootstrap or isolated fixture; no store created'};
    const program="import {pathToFileURL} from 'node:url';const m=await import(pathToFileURL(process.argv[1]).href);const r=await m.checkAdmission(process.argv[2],{phase:process.argv[3],recovery:JSON.parse(process.argv[4])});console.log(JSON.stringify(r));";
    const result=spawnSync(process.execPath,['--input-type=module','-e',program,entry,path.resolve(repo),phase,JSON.stringify(recovery)],{encoding:'utf8',windowsHide:true,timeout:15000});
    if(result.status!==0)throw Error(result.stderr||result.error?.message||'wave entry returned nonzero');
    const proof=JSON.parse(result.stdout.trim());
    if(typeof proof.ok!=='boolean')throw Error('wave admission did not return a typed verdict');
    return proof;
  } catch(error){return {ok:false,wave_verified:false,reason:'wave_admission_unverifiable: '+error.message};}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const proof=checkWaveAdmission(path.resolve(process.argv[2]||'.'),{phase:process.argv[3]||'produce'});
  console.log(JSON.stringify(proof));if(!proof.ok)process.exitCode=2;
}
