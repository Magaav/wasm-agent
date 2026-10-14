// Loopback-only common-route proof, no solver/provider inference.
import fs from 'node:fs';import path from 'node:path';import http from 'node:http';import crypto from 'node:crypto';import assert from 'node:assert/strict';
import {createSharedModelRoute,responseUsage} from './agent-benchmark-model-route.mjs';
const [out]=process.argv.slice(2);assert(out&&path.isAbsolute(out)&&!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});let checks=0;const check=(v,m)=>{assert(v,m);checks++;};const secret='MOCK_ONLY_CREDENTIAL_DO_NOT_FORWARD_TO_SOLVER';const observed=[];
const upstream=http.createServer(async(req,res)=>{const chunks=[];for await(const b of req)chunks.push(b);const body=JSON.parse(Buffer.concat(chunks));observed.push({headers:req.headers,body});
 if(body.input[0]?.content==='unknown'){res.writeHead(503,{'content-type':'application/json'});res.end(JSON.stringify({error:{code:'server_error'}}));return;}
 res.writeHead(200,{'content-type':'text/event-stream'});const event={type:'response.completed',response:{id:'response-'+observed.length,status:'completed',output:[{type:'message',role:'assistant',content:[{type:'output_text',text:'ação 🙂'}]}],usage:{input_tokens:100,output_tokens:20,input_tokens_details:{cached_tokens:40},output_tokens_details:{reasoning_tokens:5}}}};
 const wire=Buffer.from('data: '+JSON.stringify(event)+'\n\n');const at=wire.indexOf(Buffer.from('🙂'))+1;res.write(wire.subarray(0,at));setTimeout(()=>{res.write(wire.subarray(at));/* intentionally open after terminal */},5);
});await new Promise(r=>upstream.listen(0,'127.0.0.1',r));
const handles=['pi','wasm-current','node-v1','rust-v2'].map(arm=>({arm,handle:crypto.randomBytes(32).toString('hex'),maxRequests:2,maxPromptTotal:1000,maxOutputTotal:1000,maxMilliseconds:30000}));
const relay=createSharedModelRoute({mode:'model-free',upstream:'http://127.0.0.1:'+upstream.address().port+'/responses',credential:secret,model:'gpt-6.1-sol',reasoning:'low',root:path.join(out,'wire'),arms:handles});await new Promise(r=>relay.server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+relay.server.address().port;const body={model:'gpt-6.1-sol',reasoning:{effort:'low'},stream:true,input:[{role:'user',content:'mock prompt'}],tools:[],prompt_cache_key:'solver-owned-key'};
const send=(arm,data=body)=>fetch(base+'/arms/'+arm.handle+'/openai-sub/codex/responses',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer SOLVER_PLACEHOLDER',cookie:'must not pass','chatgpt-account-id':'must not pass'},body:JSON.stringify(data)});
try{
 for(const arm of handles){const status=await fetch(base+'/arms/'+arm.handle+'/status');check(status.status===200,'vault-compatible presence');const response=await send(arm);const text=await response.text();check(response.status===200&&text.includes('ação 🙂')&&!text.includes(secret),'complete streaming terminal and UTF8 preserved');}
 check(observed.length===4,'four arms use the one mock upstream');check(observed.every(x=>x.headers.authorization==='Bearer '+secret&&!x.headers.cookie&&!x.headers['chatgpt-account-id']),'owned credential replacement and header isolation');
 check(new Set(observed.map(x=>x.body.prompt_cache_key)).size===4&&observed.every(x=>x.body.prompt_cache_key!=='solver-owned-key'),'cache routing is arm-scoped, not solver-controlled');
 const rejected=await send(handles[0],{...body,model:'different'});check(rejected.status===400&&observed.length===4,'model drift cannot reach upstream');
 const reason=await send(handles[0],{...body,reasoning:{effort:'high'}});check(reason.status===400&&observed.length===4,'reasoning drift cannot reach upstream');
 const unknown=await send(handles[1],{...body,input:[{role:'user',content:'unknown'}]});check(unknown.status===503,'unknown failed usage retained');await unknown.text();
 const blocked=await send(handles[1]);check(blocked.status===429&&observed.length===5,'unknown usage stops that arm without replay');
 await (await send(handles[0])).text();const capped=await send(handles[0]);check(capped.status===429&&observed.length===6,'reported request control is enforced');
 const totals=relay.inspect();check(totals.find(x=>x.arm==='pi').prompt_total===200&&totals.find(x=>x.arm==='pi').output===40,'reported totals use prompt plus output without cache/reasoning double count');
 check(totals.find(x=>x.arm==='wasm-current').unknown_usage===1,'failed usage is unknown, not zero');
 check(totals.every(x=>x.actual_cost===null),'subscription/mock costs are not invented');
 check(responseUsage({usage:{input_tokens:10,output_tokens:2,input_tokens_details:{cached_tokens:11}}})===null,'inconsistent cache counts refuse');
 check(responseUsage({usage:{input_tokens:10,output_tokens:2,output_tokens_details:{reasoning_tokens:3}}})===null,'reasoning is an output subset');
 check(responseUsage({usage:{input_tokens:10,output_tokens:2}}).cache_read===null,'absent cache usage remains unknown');
 check(!fs.readFileSync(path.join(out,'wire/events.jsonl'),'utf8').includes(secret),'metadata contains no credential');
 const records=fs.readdirSync(path.join(out,'wire')).filter(n=>n.endsWith('.client.json'));check(records.length===6,'complete admitted client bodies retained');
 check(relay.paid_ready===false,'mock protocol proof never grants paid admission');
 fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({ok:true,checks,paid_calls:0,totals,model:'gpt-6.1-sol',reasoning:'low',actual_provider_acceptance:false},null,2));console.log(JSON.stringify({ok:true,checks,paid_calls:0,evidence:out}));
}finally{relay.server.closeAllConnections();await new Promise(r=>relay.server.close(r));upstream.closeAllConnections();await new Promise(r=>upstream.close(r));}
