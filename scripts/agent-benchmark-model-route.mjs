// Common four-arm Responses route. This factory is model-free/loopback ONLY;
// the paid runner remains refused until native-owner admission and isolation exist.
import http from 'node:http';import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const integer=n=>Number.isSafeInteger(n)&&n>=0;
export function responseUsage(value){
 const usage=value?.usage;if(!usage||!integer(usage.input_tokens)||!integer(usage.output_tokens))return null;
 const cached=usage.input_tokens_details?.cached_tokens;const reasoning=usage.output_tokens_details?.reasoning_tokens;
 if(cached!==undefined&&(!integer(cached)||cached>usage.input_tokens))return null;
 if(reasoning!==undefined&&(!integer(reasoning)||reasoning>usage.output_tokens))return null;
 return {prompt_total:usage.input_tokens,cache_read:cached??null,uncached_input:cached===undefined?null:usage.input_tokens-cached,output:usage.output_tokens,reasoning:reasoning??null,cache_write:null};
}
export function createSharedModelRoute({mode,upstream,credential,model,reasoning,root,arms}){
 assert(mode==='model-free','paid model-route admission is not implemented');
 const target=new URL(upstream);assert(target.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(target.hostname),'model-free upstream must be loopback');
 assert(path.isAbsolute(root)&&!fs.existsSync(root),'fresh private route evidence required');fs.mkdirSync(root,{recursive:true,mode:0o700});
 assert(typeof credential==='string'&&credential&&typeof model==='string'&&model&&typeof reasoning==='string'&&reasoning,'explicit mock transport pins required');
 const scopes=new Map();for(const arm of arms){
  assert(/^[a-f0-9]{64}$/.test(arm.handle)&&!scopes.has(arm.handle),'unique arm route handle');
  assert(integer(arm.maxRequests)&&arm.maxRequests>0&&integer(arm.maxPromptTotal)&&arm.maxPromptTotal>0&&integer(arm.maxOutputTotal)&&arm.maxOutputTotal>0&&integer(arm.maxMilliseconds)&&arm.maxMilliseconds>0,'experimental controls required');
  scopes.set(arm.handle,{...arm,requests:0,prompt_total:0,output:0,unknown_usage:0,inflight:false,halted:false,started:performance.now(),attempts:[]});
 }
 let serial=0;
 const events=[];const log=value=>{events.push(value);fs.appendFileSync(path.join(root,'events.jsonl'),JSON.stringify(value)+'\n',{mode:0o600});};
 const persist=(name,bytes)=>{fs.writeFileSync(path.join(root,name),bytes,{flag:'wx',mode:0o600});return {name,bytes:bytes.length,sha256:sha(bytes)};};
 function inspect(){return [...scopes.values()].map(s=>({arm:s.arm,requests:s.requests,prompt_total:s.prompt_total,output:s.output,unknown_usage:s.unknown_usage,inflight:s.inflight,halted:s.halted,attempts:s.attempts,actual_cost:null}));}
 const server=http.createServer(async(req,res)=>{
  const send=(status,error)=>{log({phase:'refused',id:String(++serial).padStart(4,'0'),status,error,arm:null});res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify({error:{code:error,message:error}}));};
  const matched=/^\/arms\/([a-f0-9]{64})\/(status|openai-sub\/codex\/responses)$/.exec(req.url??'');const scope=matched&&scopes.get(matched[1]);
  if(!scope)return send(404,'benchmark_route_denied');
  if(matched[2]==='status'&&req.method==='GET'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({providers:{'openai-sub':{configured:true,enabled:!scope.halted,account_id:'model-free-placeholder'}}}));return;}
  if(matched[2]!=='openai-sub/codex/responses'||req.method!=='POST')return send(404,'benchmark_route_denied');
  if(scope.inflight)return send(409,'benchmark_arm_request_inflight');
  if(scope.halted||scope.requests>=scope.maxRequests||scope.prompt_total>=scope.maxPromptTotal||scope.output>=scope.maxOutputTotal||performance.now()-scope.started>=scope.maxMilliseconds)return send(429,'benchmark_budget_or_unknown_usage');
  const chunks=[];let length=0;let parsed,clientBytes,decodedBytes;
  try{for await(const chunk of req){length+=chunk.length;assert(length<=8*1024*1024,'request byte bound');chunks.push(chunk);}clientBytes=Buffer.concat(chunks);const encoding=req.headers['content-encoding'];
   assert(!encoding||encoding==='zstd','unsupported content encoding');
   decodedBytes=encoding==='zstd'?zlib.zstdDecompressSync(clientBytes,{maxOutputLength:8*1024*1024}):clientBytes;
   parsed=JSON.parse(decodedBytes.toString('utf8'));
   assert(parsed&&typeof parsed==='object'&&!Array.isArray(parsed),'request object');
   assert(parsed.model===model&&parsed.reasoning?.effort===reasoning&&parsed.stream===true,'model/reasoning/stream pin');
   assert(Array.isArray(parsed.input)&&(!parsed.tools||Array.isArray(parsed.tools)),'input/tool shape');
   assert(parsed.previous_response_id===undefined,'provider-side conversation continuation refused');
   assert(!decodedBytes.includes(Buffer.from(credential)),'mock credential exposure');
  }catch(error){const rejected=clientBytes&&persist(String(++serial).padStart(4,'0')+'.refused.json',clientBytes);log({phase:'validation_refused',arm:scope.arm,reason:error.message,client:rejected??null,requested_model:parsed?.model??null,requested_reasoning:parsed?.reasoning?.effort??null,requested_stream:parsed?.stream??null});return send(400,'benchmark_request_pin_refused');}
  scope.inflight=true;scope.requests++;const id=String(++serial).padStart(4,'0');
  const clientRef=persist(id+'.client.json',decodedBytes);const wireRef=persist(id+'.client.wire',clientBytes);
  // Route/cache scope is controlled by the harness, not by solver-provided keys.
  const routing=sha(Buffer.from(scope.handle));const wire=Buffer.from(JSON.stringify({...parsed,prompt_cache_key:routing}));const preparedRef=persist(id+'.upstream.json',wire);
  const started=performance.now();log({phase:'start',id,arm:scope.arm,model,reasoning,client:clientRef,client_wire:wireRef,content_encoding:req.headers['content-encoding']??null,prepared:preparedRef,routing_scope_hash:routing});
  const attempt={id,arm:scope.arm,status:null,usage:null,response:null,first_byte_ms:null,elapsed_ms:null,termination:null};scope.attempts.push(attempt);
  const upstreamRequest=http.request(target,{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+credential,'content-length':wire.length,'session_id':routing}},reply=>{
   attempt.status=reply.statusCode;res.writeHead(reply.statusCode??502,{'content-type':reply.headers['content-type']??'application/octet-stream'});
   const body=[];let bytes=0;let ended=false;let text='';const decoder=new StringDecoder('utf8');const terminals=[];
   const parseFrames=()=>{for(;;){const frameEnd=/\r?\n\r?\n/.exec(text);if(!frameEnd)break;const frame=text.slice(0,frameEnd.index);text=text.slice(frameEnd.index+frameEnd[0].length);const data=frame.split(/\r?\n/).filter(s=>s.startsWith('data:')).map(s=>s.slice(5).trimStart()).join('\n');if(!data||data==='[DONE]')continue;try{const event=JSON.parse(data);if(event.type==='response.completed'&&event.response)terminals.push(event.response);}catch{}}};
   const finish=termination=>{if(ended)return;ended=true;attempt.termination=termination;attempt.elapsed_ms=performance.now()-started;attempt.response=persist(id+'.response',Buffer.concat(body));
    const terminal=terminals.length===1?terminals[0]:null;
    attempt.usage=['eof','terminal_complete'].includes(termination)&&attempt.status===200?responseUsage(terminal):null;
    if(attempt.usage){scope.prompt_total+=attempt.usage.prompt_total;scope.output+=attempt.usage.output;}
    else {scope.unknown_usage++;scope.halted=true;}
    scope.inflight=false;log({phase:'end',...attempt});if(!res.writableEnded)res.end();
   };
   reply.on('data',chunk=>{if(attempt.first_byte_ms===null)attempt.first_byte_ms=performance.now()-started;bytes+=chunk.length;
    if(bytes>32*1024*1024){body.push(chunk);reply.destroy(Error('response byte bound'));return;}
    body.push(chunk);text+=decoder.write(chunk);parseFrames();if(!res.destroyed)res.write(chunk);
    if(terminals.length){finish('terminal_complete');reply.destroy();}
   });reply.on('end',()=>finish('eof'));reply.on('error',()=>finish('read_failed'));reply.on('aborted',()=>finish('aborted'));
  });
  upstreamRequest.setTimeout(Math.max(1,scope.maxMilliseconds-(performance.now()-scope.started)),()=>upstreamRequest.destroy(Error('experiment deadline')));
  upstreamRequest.on('error',error=>{if(attempt.termination)return;attempt.termination='request_failed';attempt.elapsed_ms=performance.now()-started;scope.unknown_usage++;scope.halted=true;scope.inflight=false;log({phase:'end',...attempt,error_code:error.code??null});if(!res.headersSent)send(502,'benchmark_upstream_failed');else res.end();});
  req.on('aborted',()=>upstreamRequest.destroy());res.on('close',()=>{if(!res.writableFinished)upstreamRequest.destroy(Error('downstream abandoned'));});
  upstreamRequest.end(wire);
 });
 return {server,inspect,events,mode:'model-free',paid_ready:false};
}
