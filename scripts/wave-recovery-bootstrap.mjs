#!/usr/bin/env node
// Read-only explicit source bootstrap, never an effect/lease bypass.
import fs from 'node:fs';import path from 'node:path';import {pathToFileURL,fileURLToPath} from 'node:url';import {verifyRecoverySource} from './lib/wave-recovery-source.mjs';
export async function bootstrap(repo,descriptor,context){
 const proof=verifyRecoverySource(repo,descriptor);
 const here=fs.realpathSync(fileURLToPath(import.meta.url));
 if(here!==fs.realpathSync(path.join(proof.root,'scripts/wave-recovery-bootstrap.mjs')))throw Error('recovery_source_runtime_path_mismatch');
 const entry=await import(pathToFileURL(path.join(proof.root,'scripts/wave-entry.mjs')).href);
 const result=entry.checkAdmission(repo,{...context,source:proof});
 return {...result,source:proof,effect_authorized:false};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))try{
 const [repo,sourceFile,contextFile,mode,channel]=process.argv.slice(2),descriptor=JSON.parse(fs.readFileSync(sourceFile)),context=JSON.parse(fs.readFileSync(contextFile));
 let result=await bootstrap(path.resolve(repo),descriptor,context);
 if(mode==='land'){
  if(!result.ok)throw Error(result.reason);
  if(result.source.schema!==2||!channel)throw Error('recovery_native_source_and_channel_required');
  const {connectNativeRecovery}=await import('./lib/wave-recovery-native.mjs'),{landRecovery}=await import('./wave-recovery-land.mjs');
  result=landRecovery(path.resolve(repo),context,connectNativeRecovery(channel,path.resolve(repo),descriptor));
 }else if(mode)throw Error('recovery_bootstrap_mode_unknown');
 console.log(JSON.stringify(result));if(!result.ok)process.exitCode=2;
}catch(e){console.log(JSON.stringify({ok:false,reason:e.message,effect_authorized:false}));process.exitCode=2;}
