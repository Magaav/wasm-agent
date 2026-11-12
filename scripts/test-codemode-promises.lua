-- Code mode's promises resolve naturally (#119, 11/11). The evidence this test pins: a script that
-- wrote `const all = searchTools("*")` and no `await` answered `undefined` with
-- `unexecuted ... script_finished_before_admission`, and `.map` on the pending value failed with a
-- TypeError that named nothing - four calls and thirteen seconds spent learning the shape of a call
-- the model had already made (session 570a0da0).
--
-- What is asserted, one requirement at a time (docs/CODEMODE.md, "Natural promises"):
--   1. a returned Promise, and Promises inside arrays/objects, are settled before the record is made;
--   2. calls still in flight when the body ends are admitted and awaited, never `unexecuted`;
--   3. `text`/`store`/`console` settle a pending value themselves, in the order the script wrote them;
--   4. a pending value used as if it had settled names the call and says to await, instead of
--      answering `undefined`;
--   5. `searchTools` answers a plain ARRAY, and `describeTool` documents that shape;
--   6. deliberate concurrency is preserved and measurable: `Promise.all`/`parallel` hand both calls to
--      the loop in ONE round, where two awaits hand one each.
--
-- The last check reads the sandbox's own event stream (`host.quickjs('start', …)`) rather than a clock:
-- the node dispatches admitted calls serially by contract, so wall time cannot distinguish "issued
-- together" from "issued one at a time" - the events can.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
-- The real sandbox, or the test says which fact it could not establish: every row here is about the
-- guest's JavaScript, which a stub cannot answer (a stub row would pass while testing nothing).
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no JavaScript ran and nothing here was measured')
local root=dofile('lua/core/paths.lua').data()..'/natural'
assert(host.write_file(root..'/a.txt','alpha'))
assert(host.write_file(root..'/b.txt','beta'))
local sid=memory.start_session('','codemode natural promises',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
-- How many calls the guest had already made when the sandbox handed control back the first time.
local start_calls={}
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx) end
local real_quickjs=host.quickjs
host.quickjs=function(action,payload)
 local answer=real_quickjs(action,payload)
 if action=='start' then
  local decoded=json.decode(answer) or {}
  local count=0
  for _,event in ipairs(decoded.events or {})do if event.type=='call' then count=count+1 end end
  start_calls[#start_calls+1]=count
 end
 return answer
end
local function run(code)
 local result=codemode.run(memory,{code=code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result,result and result.value and json.decode(result.value) or nil
end
local function a(path) return json.encode(root..'/'..path) end

-- 1. A returned Promise is settled before the value is reported: `return searchTools("*")` answers the
-- list, not `undefined` and not `{}`.
local listing,listed=run('return searchTools("*");')
check(listing.ok and type(listed)=='table' and #listed>0,'a returned Promise is settled into its value: '..tostring(listing.value):sub(1,120))
check(listed[1].name~=nil and listed[1].description~=nil,'searchTools answers a plain array of {name, description, …}, not an envelope of {tools=…}: '..json.encode(listed[1]):sub(1,160))
check(listed[1].schema==nil and listed[1].callable~=nil,'a listing entry carries callable/execution and no full schema (that is describeTool): '..json.encode(listed[1]):sub(1,200))

-- Promises nested in an object and in an array are settled too, one level at a time.
local nested,deep=run('return {list:[searchTools("*")], reads:[tools.read({path:'..a('a.txt')..'}),tools.read({path:'..a('b.txt')..'})], box:{one:tools.read({path:'..a('a.txt')..'})}};')
check(nested.ok and type(deep)=='table','a returned object of Promises is settled: '..tostring(nested.error))
check(type(deep.list)=='table' and deep.list[1][1].name~=nil,'an array inside the returned object is settled: '..json.encode(deep.list):sub(1,120))
check(deep.reads[1].content=='alpha' and deep.reads[2].content=='beta','an array of calls settles in order: '..json.encode(deep.reads):sub(1,200))
check(deep.box.one.content=='alpha','a nested object of calls settles too: '..json.encode(deep.box):sub(1,160))

-- 2. Calls still in flight when the body ends are awaited: the old answer was `unexecuted` and an
-- effect that the model had already asked for never ran.
local flight=run('const r=tools.read({path:'..a('a.txt')..'}); return "body finished with "+typeof r;')
check(flight.ok and json.decode(flight.value)=='body finished with object','a script may end with a call in flight')
check(#flight.calls==1 and #flight.unexecuted==0,'a call in flight at the end of the body is admitted, never reported unexecuted: '..json.encode(flight.unexecuted))
check(flight.attempts[1] and flight.attempts[1].admitted==true,'that call was really dispatched: '..json.encode(flight.attempts[1] or {}):sub(1,200))
-- `codemode`'s description now promises exactly this: "Calls are always fresh and run even if not
-- awaited". A READ being admitted is not enough evidence - a write is the case where it matters, so the
-- file the script never awaited is read back from outside the sandbox after the run returned. Measured
-- on this tree: calls=1, unexecuted=0, the file holds what the unawaited call wrote.
local fire_path=root..'/unawaited-effect.txt'
local fired=run('tools.write({path:'..a('unawaited-effect.txt')..',content:"written without await"}); return "body finished";')
check(fired.ok and json.decode(fired.value)=='body finished','a script may end with an unawaited write: '..tostring(fired.error))
check(#fired.calls==1 and #fired.unexecuted==0,'the unawaited call is admitted, never script_finished_before_admission: '..json.encode(fired.unexecuted))
check(host.read_file(fire_path)=='written without await','the unawaited call RAN and finished before the script returned: the file holds what it wrote')

-- 3. `text`/`store` settle a pending value themselves and keep the script's order.
local printed=run('const r=tools.read({path:'..a('b.txt')..'}); text("before"); text(r); return null;')
check(printed.ok and #printed.items==2 and printed.items[1].text=='before','text() before a pending value keeps its order: '..json.encode(printed.items):sub(1,200))
check(tostring(printed.items[2] and printed.items[2].text):find('beta',1,true)~=nil,'text(pendingCall) prints the settled value, never an empty promise: '..json.encode(printed.items[2] or {}):sub(1,200))
local stored=run('store("natural",tools.read({path:'..a('a.txt')..'})); return null;')
check(stored.ok,'store() accepts a pending value')
local loaded,value=run('return load("natural").content;')
check(loaded.ok and value=='alpha','a stored pending value is stored settled, not as an empty object: '..tostring(loaded.value):sub(1,120))

-- 4. Using a still-pending value names the call and says to await - the failure this issue is about
-- was `undefined`, which reads as "the tool answered nothing".
local mapped=run('const all=searchTools("*"); return all.map(function(t){return t.name;});')
check(not mapped.ok,'using a pending value as if it had settled fails loudly instead of guessing')
local message=tostring(mapped.error or '')
check(message:find('searchTools(',1,true)~=nil,'the error names the call it is about: '..message:sub(1,200))
check(message:find('await',1,true)~=nil,'the error says to await it: '..message:sub(1,200))
check(message:find('.map',1,true)~=nil,'the error names what was used on it: '..message:sub(1,200))
local property=run('const r=tools.read({path:'..a('a.txt')..'}); return r.content;')
local property_message=tostring(property.error or '')
check(not property.ok and property_message:find('tools.read(',1,true)~=nil and property_message:find('content',1,true)~=nil,'the same is true for a tool call: '..property_message:sub(1,200))

-- 5. The shapes are documented where the model asks: describeTool.
local help,help_value=run('return [describeTool("searchTools"),describeTool("results")];')
check(help.ok and type(help_value)=='table','describeTool("searchTools")/("results") answer instead of unknown_tool: '..tostring(help.value):sub(1,160))
check(tostring(help_value[1].description):find('plain ARRAY',1,true)~=nil,'the searchTools help says the answer is a plain array: '..tostring(help_value[1].description):sub(1,200))
check(tostring(help_value[2].description):find('results.get',1,true)~=nil,'the results help documents the reuse door: '..tostring(help_value[2].description):sub(1,200))

-- 6. Concurrency: both calls are handed to the loop in one round, and both results come back.
start_calls={}
local together,together_value=run('const [x,y]=await Promise.all([tools.read({path:'..a('a.txt')..'}),tools.read({path:'..a('b.txt')..'})]); return [x.content,y.content];')
check(together.ok and together_value[1]=='alpha' and together_value[2]=='beta','Promise.all returns both results: '..tostring(together.value):sub(1,160))
check(start_calls[1]==2,'Promise.all hands BOTH calls to the loop before either is answered (measured '..tostring(start_calls[1])..'): that is the concurrency the harness must not remove')
check(#together.unexecuted==0,'concurrent calls are never left unexecuted')
start_calls={}
local parallel_value=run('const [x,y]=await parallel([function(){return tools.read({path:'..a('a.txt')..'});},function(){return tools.read({path:'..a('b.txt')..'});}]); return [x.content,y.content];')
check(parallel_value.ok and json.encode(json.decode(parallel_value.value))=='["alpha","beta"]','parallel([...]) returns both results in order')
check(start_calls[1]==2,'parallel([...]) issues both calls in one round as well (measured '..tostring(start_calls[1])..')')
start_calls={}
local serial=run('const x=await tools.read({path:'..a('a.txt')..'}); const y=await tools.read({path:'..a('b.txt')..'}); return [x.content,y.content];')
check(serial.ok and #start_calls==1 and start_calls[1]==1,'two awaits issue one call at a time, so the measurement above can tell the two apart: '..json.encode(start_calls))

print('codemode natural promises ok ('..checks..' checks; real sandbox)')
