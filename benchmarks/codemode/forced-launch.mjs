// Reference VM host lives inside this arm's EXISTING supervised actor tree,
// never in the shared route/controller event loop. CPU loops cannot stall peers'
// admission/deadline/capture clocks. No V2 invocation uses this launcher.
import fs from 'node:fs';import cp from 'node:child_process';import assert from 'node:assert/strict';
import {createReferenceServer} from './reference-server.mjs';
const [exe,rawArgs,file]=process.argv.slice(2),config=JSON.parse(fs.readFileSync(file));assert(config.forced&&config.arm!=='rust-v2'&&config.reference_assets&&!config.reference_url,'explicit adapted Node VM arm only');
const reference=await createReferenceServer({assets:config.reference_assets,key:config.reference_key});await new Promise(r=>reference.server.listen(0,'127.0.0.1',r));config.reference_url='http://127.0.0.1:'+reference.server.address().port+'/quickjs';fs.writeFileSync(file,JSON.stringify(config));
let exit=1;
try{const child=cp.spawn(exe,JSON.parse(rawArgs),{cwd:process.cwd(),env:process.env,stdio:'inherit',detached:false});exit=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',code=>resolve(code??1));});}
finally{reference.dispose();await new Promise(r=>reference.server.close(r));}
process.exit(exit);
