-- Model-free host diagnostics: no native task tools, file effects or model calls.
local json=dofile('lua/vendor/json.lua')
if host.getenv('WA_DIAGNOSTIC_REFERENCE')=='1' then
 local client=assert(load(assert(host.read_file('benchmarks/codemode/reference-client.lua')),'reference-client'))()
 client.install({url=host.getenv('WA_CODEMODE_CONTROLLER_URL'),key=host.getenv('WA_CODEMODE_CONTROLLER_KEY')})
end
local owner=string.rep('a',64)
local function invoke(action,args)
 local t=host.monotonic_ms();local raw=host.quickjs(action,json.encode(args));return json.decode(raw),host.monotonic_ms()-t
end
local info=invoke('info',{owner=owner})
assert(info.ok,'host identity required')
local cases={
 {name='processing',code='const a=Array.from({length:2000},(_,i)=>({k:i%7,v:i})); return a.filter(x=>x.k===3).reduce((s,x)=>s+x.v,0);',value='286143'},
 {name='broker-chain',code='let s=0; for(let i=0;i<20;i++) s+=(await tools.mock({index:i})).value; return s;',value='190',calls=20},
 {name='guest-error',code='text("retained"); throw new Error("diagnostic-known-error");',error='diagnostic-known-error',text='retained'},
 {name='serialization',code='return {empty:{},list:[],nil:null,unicode:"雪",escaped:"a\\nb"};',value='{"empty":{},"list":[],"nil":null,"unicode":"雪","escaped":"a\\nb"}'},
 {name='large-output',code='text("雪".repeat(30000)); return 90000;',value='90000',bytes=90000},
 {name='broker-refusal',code='try { await tools.mock({index:1}); } catch(e) { return String(e).includes("known-refusal"); } return false;',value='true',refusal=true,calls=1}
}
local rows={};local all=true
for round=1,3 do for index,c in ipairs(cases) do
 local r,start_ms=invoke('start',{owner=owner,code=c.code,tools={{name='mock',jsName='mock',description='isolated deterministic mock'}},globals={},store={},timeout_ms=30000})
 local row={round=round,name=c.name,temperature=(round==1 and index==1) and 'first-guest-in-fresh-host' or 'warm-host-fresh-guest',start_ms=start_ms,admit_ms=0,deliver_ms=0,close_ms=0,calls=0,events={},code_sha256=host.sha256(c.code)}
 local id=r.id;local done=nil;local texts={};local good=r.ok and id~=nil
 while good do
  local queued={}
  for _,e in ipairs(r.events or {}) do
   row.events[#row.events+1]=e
   if e.type=='call' then queued[#queued+1]=e elseif e.type=='done' then done=e elseif e.type=='output' then texts[#texts+1]=e.item.text end
  end
  if done then break end
  if #queued~=1 then good=false;break end
  local e=queued[1];local args=json.decode(e.args);local admitted,ms=invoke('admit',{id=id,owner=owner});row.admit_ms=row.admit_ms+ms
  if not admitted.ok then good=false;break end
  row.calls=row.calls+1
  r,ms=invoke('deliver',{id=id,owner=owner,call_id=e.id,ok=not c.refusal,payload=c.refusal and 'known-refusal' or json.encode({value=args.index})});row.deliver_ms=row.deliver_ms+ms
  if not r.ok then good=false;break end
 end
 if id then local closed,ms=invoke('close',{id=id,owner=owner});row.close_ms=ms;good=good and closed.ok end
 row.output_bytes=#table.concat(texts)
 row.pass=not not (good and done and row.calls==(c.calls or 0) and ((c.error and not done.ok and tostring(done.error):find(c.error,1,true)) or (not c.error and done.ok and done.value==c.value)) and (not c.text or texts[1]==c.text) and (not c.bytes or row.output_bytes==c.bytes))
 -- Do not duplicate large output in summary; retain its exact hash and length.
 row.output_sha256=host.sha256(table.concat(texts));row.events=nil;row.done=done
 rows[#rows+1]=row;all=all and row.pass
end end
print(json.encode({ok=all,info=info,rows=rows,paid_solver_calls=0,native_tools_dispatched=0}))
assert(all,'equal-workload correctness failed')
