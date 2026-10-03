// Called only by the independently source-sealed trusted native driver.
import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';
import {connectCurrentSource} from './lib/wave-current-source-native.mjs';import {landCurrentSource} from './lib/wave-current-source.mjs';
const [repo,sourceFile,grantFile,channel]=process.argv.slice(2);
try{
 const descriptor=JSON.parse(fs.readFileSync(sourceFile)),grant=JSON.parse(fs.readFileSync(grantFile));
 if(fs.realpathSync(fileURLToPath(import.meta.url))!==fs.realpathSync(path.join(descriptor.root,'scripts/wave-current-ref-bootstrap.mjs')))throw Error('current_source_consumer_path');
 const result=await landCurrentSource(path.resolve(repo),descriptor,grant,connectCurrentSource(channel,path.resolve(repo),descriptor));
 console.log(JSON.stringify(result));if(!result.ok)process.exitCode=2;
}catch(error){console.log(JSON.stringify({ok:false,error:error.message,global_identity_safety:false,production_registry_admission:false}));process.exitCode=2;}
