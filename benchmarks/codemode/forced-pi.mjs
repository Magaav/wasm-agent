import fs from 'node:fs';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';import path from 'node:path';
import {codemodeFunction} from './forced-contract.mjs';
export async function forcedPiTool(config,definitions){
 const {validateToolArguments}=await import(pathToFileURL(path.resolve(config.pi_package,'../pi-ai/dist/utils/validation.js')));
 const descriptors=definitions.map(t=>({name:t.name,jsName:t.name,description:t.description}));
 let seq=0,invocation=0,busy=false,store={};const fd=fs.openSync(config.vm_journal,'wx',0o600);
 function record(row){fs.writeFileSync(fd,JSON.stringify({...row,seq:++seq,arm:config.arm,binding:config.binding})+'\n');fs.fsyncSync(fd);}
 async function control(action,args){const r=await fetch(config.reference_url,{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+config.reference_key},body:JSON.stringify({action,args})});assert(r.status===200,'VM transport failed; no replay');const result=await r.json();record({type:'host',invocation,action,args,result});return result;}
 const tool={...codemodeFunction,label:'Code mode',async execute(callId,args,signal){
  assert(!busy,'single writer VM');busy=true;invocation++;const current=invocation;const owner=crypto.createHash('sha256').update(config.binding).digest('hex');const items=[];let vm,result;
  record({type:'outer',invocation:current,name:'codemode',session:config.binding,args});
  try{
   validateToolArguments(tool,{name:'codemode',arguments:args});
   let response=await control('start',{owner,code:args.code,tools:descriptors,globals:[{name:'searchTools',spread:true},{name:'describeTool',spread:false}],store,timeout_ms:args.timeout_ms??30000});assert(response.ok,response.error);vm=response.id;
   let done;const pending=[];const consume=events=>{for(const e of events??[]){if(e.type==='call')pending.push(e);else if(e.type==='output')items.push(e.item);else if(e.type==='done')done=e;else throw Error('VM protocol');}};consume(response.events);
   while(!done){assert(!signal?.aborted,'aborted');const admission=await control('admit',{id:vm,owner});assert(admission.ok,admission.error);const call=pending.shift();assert(call,'VM stalled');let value,ok=true;
    if(call.target==='global'){
     const params=JSON.parse(call.args);if(call.name==='describeTool'){const name=typeof params==='string'?params:params[0];const t=definitions.find(t=>t.name===name);value=t?{name:t.name,description:t.description,parameters:t.parameters}:null;}
     else if(call.name==='searchTools'){value=definitions.filter(t=>(t.name+' '+t.description).toLowerCase().includes(String(params[0]).toLowerCase())).map(t=>({name:t.name,description:t.description,parameters:t.parameters}));}
     else throw Error('global refused');
    }else{
     const target=definitions.find(t=>t.name===call.name);assert(call.target==='tool'&&target,'nested target refused');
     const parameters=JSON.parse(call.args);validateToolArguments(target,{name:call.name,arguments:parameters});
     record({type:'nested_start',invocation:current,name:call.name,arguments:call.args});
     try{value=await target.execute('vm-'+current+'-'+call.id,parameters,signal);}
     catch(e){await fetch(config.sandbox+'/halt',{method:'POST',body:'{}'});record({type:'nested_end',invocation:current,name:call.name,ok:false,result:{error:e.message,effect:'unknown'}});throw e;}
     record({type:'nested_end',invocation:current,name:call.name,ok:true,result:value});
    }
    response=await control('deliver',{id:vm,owner,call_id:call.id,ok,payload:JSON.stringify(value??null)});consume(response.events);assert(response.ok,response.error);
   }
   if(done.ok&&done.writes&&done.writes!=='undefined')for(const [k,v]of JSON.parse(done.writes))store[k]=v;
   result={ok:done.ok===true,items,error:done.error};return {content:[{type:'text',text:JSON.stringify(result)}],details:result};
  }catch(e){result={ok:false,error:e.message};throw e;}
  finally{try{if(vm)await control('close',{id:vm,owner});}finally{record({type:'outer_end',invocation:current,result});busy=false;}}
 }};
 return {tool,close(){fs.fsyncSync(fd);fs.closeSync(fd);}};
}
