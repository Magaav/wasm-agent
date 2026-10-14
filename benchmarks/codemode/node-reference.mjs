// Benchmark-only Node host for Pi1.2's actual VM driver. Never a production fallback.
import fs from 'node:fs';
import readline from 'node:readline';
import {pathToFileURL} from 'node:url';
import crypto from 'node:crypto';
process.env.TZ='UTC'; // Match native guest timezone without exposing environment.
const dir=process.env.WA_PI_CODEMODE_PACKAGE;
if(!dir)throw Error('pinned Pi package path required');
const meta=JSON.parse(fs.readFileSync(dir+'/package.json'));if(meta.name!=='@earendil-works/pi-codemode'||meta.version!=='1.2.0')throw Error('Pi package pin mismatch');
const wasm=fs.readFileSync(process.env.WA_QJS_ASSETS+'/quickjs.wasm');if(crypto.createHash('sha256').update(wasm).digest('hex')!=='d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9')throw Error('guest artifact mismatch');
const {startVm}=await import(pathToFileURL(dir+'/dist/runtime/vm.js'));
let session,started=false,stopped=false,outputBytes=0;const pending=new Set();
const post=message=>{if(message.type==='call'){if(!Number.isSafeInteger(message.id)||message.id<1||pending.has(message.id))throw Error('invalid/duplicate guest call');pending.add(message.id);}const line=JSON.stringify(message)+'\n';outputBytes+=Buffer.byteLength(line);if(outputBytes>16*1024*1024)throw Error('sandbox output bound');process.stdout.write(line);};
const input=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
for await(const line of input){const message=JSON.parse(line);
 if(message.type==='start'){if(started)throw Error('duplicate start');started=true;const deadline=performance.now()+Math.min(300000,Math.max(1,message.data.timeout_ms??30000));session=await startVm({data:{...message.data,memoryLimitBytes:64*1024*1024},maxStackSize:512*1024,wasm,shouldInterrupt:()=>stopped||performance.now()>deadline,post});post({type:'ready'});}
 else if(message.type==='deliver'){if(!session)throw Error('VM not started');if(!pending.delete(message.data.id))throw Error('unknown or already settled result');session.deliver(message.data);}
 else if(message.type==='close'){stopped=true;session?.dispose();input.close();break;}
 else throw Error('unknown control message');
}
session?.dispose();
