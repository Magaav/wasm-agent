// Comparison-only controller for the actual pinned Pi VM. No tools are dispatched
// here: queued calls return to the unchanged native Lua authorization pipeline.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath,pathToFileURL} from 'node:url';
const WASM='d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9';
const PRELUDE='57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281';
const DRIVER='279c77a80ac3d6bc1f883b02a28d892608ff43cc0b7e91dbfa3aece218c7c47b';
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const backend='node-quickjs-wasi-reference';
export async function createReferenceServer({assets,key}) {
 assert(path.isAbsolute(assets)&&/^[a-f0-9]{64}$/.test(key),'explicit assets and controller nonce required');
 process.env.TZ='UTC';
 const pkg=path.join(assets,'node_modules/@earendil-works/pi-codemode');
 const manifest=JSON.parse(fs.readFileSync(path.join(pkg,'package.json')));
 assert(manifest.name==='@earendil-works/pi-codemode'&&manifest.version==='1.2.0','Pi pin');
 assert(sha(fs.readFileSync(path.join(pkg,'dist/runtime/vm.js')))===DRIVER,'VM driver pin');
 const wasm=fs.readFileSync(path.join(assets,'quickjs.wasm'));assert(sha(wasm)===WASM,'guest pin');
 assert(sha(fs.readFileSync(path.join(assets,'prelude.js')))===PRELUDE,'prelude pin');
 const licenses=['pi-MIT.txt','quickjs-wasi-MIT.txt'].map(n=>fs.readFileSync(path.join(assets,n),'utf8')).join('\n');
 const {startVm}=await import(pathToFileURL(path.join(pkg,'dist/runtime/vm.js')));
 const sessions=new Map();
 function checkRecord(args){const record=sessions.get(args.id);assert(record,'sandbox unavailable');assert(args.owner===record.owner,'sandbox owner mismatch');return record;}
 function take(record){const events=record.events;record.events=[];return events;}
 const response=(record,extra={})=>({ok:true,backend,node_required:true,events:take(record),...extra});
 async function control(action,args){
  if(action==='info')return {ok:true,backend,node_required:true,licenses,wasm_sha256:WASM,prelude_sha256:PRELUDE};
  if(action==='start'){
   assert(sessions.size<4,'sandbox session capacity');assert(/^[a-f0-9]{64}$/i.test(args.owner),'invalid owner scope');assert(typeof args.code==='string','code required');
   assert(!args.deterministic,'restart replay is not enabled in this comparison');
   for(const [field,pin] of [['wasm_path',WASM],['prelude_path',PRELUDE]])if(args[field]!==undefined)assert(sha(fs.readFileSync(args[field]))===pin,field+' hash mismatch');
   const timeout=args.timeout_ms??30000;assert(Number.isInteger(timeout)&&timeout>=1&&timeout<=300000,'timeout bound');
   const record={owner:args.owner,events:[],pending:new Set(),bytes:0,items:0,deadline:performance.now()+timeout,disposed:false,session:null};
   const id=crypto.randomUUID();sessions.set(id,record);
   const post=message=>{
    // The native facade preserves a successful undefined as the literal text
    // "undefined"; normalize only this absent-value protocol distinction.
    if(message.type==='done'&&message.ok&&message.value===undefined)message={...message,value:'undefined'};
    if(message.type==='call'){assert(Number.isSafeInteger(message.id)&&message.id>=1&&!record.pending.has(message.id),'duplicate/invalid call');record.pending.add(message.id);}
    if(message.type==='output')assert(message.item.type==='text','image output not enabled');
    record.bytes+=Buffer.byteLength(JSON.stringify(message));assert(record.bytes<=16*1024*1024&&++record.items<=100000,'sandbox output bound');
    if(message.type==='crash')record.crash=message.message;else record.events.push(message);
   };
   try{
    record.session=await startVm({data:{code:args.code,tools:args.tools,globals:args.globals,store:args.store,memoryLimitBytes:64*1024*1024},wasm,maxStackSize:512*1024,shouldInterrupt:()=>record.disposed||performance.now()>record.deadline,post});
    if(record.crash)throw Error(record.crash);
    return response(record,{id});
   }catch(error){record.disposed=true;record.session?.dispose();sessions.delete(id);return {ok:false,backend,error:'codemode_sandbox: '+error.message,events:take(record),effect:'none'};}
  }
  const record=checkRecord(args);
  if(action==='close'){record.disposed=true;record.session.dispose();sessions.delete(args.id);return {ok:true};}
  if(action==='admit'){assert(performance.now()<=record.deadline&&!record.disposed,'sandbox deadline or cancellation before admission');return {ok:true};}
  assert(action==='deliver','unknown sandbox action');
  assert(Number.isSafeInteger(args.call_id)&&record.pending.has(args.call_id),'unknown or already settled call');
  assert(typeof args.ok==='boolean'&&typeof args.payload==='string','result payload shape');
  assert(Buffer.byteLength(args.payload)<=16*1024*1024,'sandbox input bound');record.pending.delete(args.call_id);
  record.session.deliver({id:args.call_id,ok:args.ok,payload:args.payload});
  if(record.crash)return {ok:false,backend,error:'codemode_sandbox: '+record.crash,events:take(record)};
  return response(record);
 }
 const server=http.createServer(async(req,res)=>{
  const reply=(status,value)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));};
  if(req.method!=='POST'||req.url!=='/quickjs')return reply(404,{ok:false,error:'route denied',effect:'none'});
  const auth=Buffer.from(req.headers.authorization??'');const expected=Buffer.from('Bearer '+key);
  if(auth.length!==expected.length||!crypto.timingSafeEqual(auth,expected))return reply(401,{ok:false,error:'controller denied',effect:'none'});
  const chunks=[];let bytes=0;
  try{for await(const chunk of req){bytes+=chunk.length;assert(bytes<=32*1024*1024,'controller body bound');chunks.push(chunk);}
   const input=JSON.parse(Buffer.concat(chunks).toString('utf8'));assert(input&&typeof input==='object'&&!Array.isArray(input)&&typeof input.action==='string','controller shape');
   assert(input.args&&typeof input.args==='object'&&!Array.isArray(input.args),'argument object required');
   reply(200,await control(input.action,input.args));
  }catch(error){reply(200,{ok:false,backend,error:'codemode_sandbox: '+error.message});}
 });
 const dispose=()=>{for(const record of sessions.values()){record.disposed=true;record.session?.dispose();}sessions.clear();};
 server.on('close',dispose);
 return {server,dispose,active:()=>sessions.size};
}
if(process.argv[1]&&fileURLToPath(import.meta.url)===path.resolve(process.argv[1])){
 const controller=await createReferenceServer({assets:process.env.WA_QJS_ASSETS,key:process.env.WA_CODEMODE_CONTROLLER_KEY});
 controller.server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({ok:true,port:controller.server.address().port,backend,node_required:true})));
}
