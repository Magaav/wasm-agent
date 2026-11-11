-- Code-mode parity for tool_search by exact name (07/11): searchTools({names=[...]}) and the
-- one-string spelling searchTools("select:a,b,c") are the same request as tool_search, over the
-- guest's own ceiling, and they load and admit nothing. When this node has real code-mode assets the
-- guest runs in the real sandbox; otherwise the transport is a stub that routes the same guest call
-- through the same Lua branch, and the test says so.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return 'native' end;return env(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
-- A real sandbox if this build embedded one; otherwise the stub below stands in for the transport.
-- Decided before any tool surface is built, because the surface caches the run's pinned policy.
local real=host.quickjs;local real_ready=false
if type(real)=='function' then
 local ok,raw=pcall(real,'ready','{}')
 if ok then local decoded=json.decode(raw);real_ready=type(decoded)=='table' and decoded.ok==true end
end
local transport=real_ready and 'real' or 'stub'
-- Stub transport: it delivers exactly the guest call the prelude would (the argument list as JSON),
-- and records the value the script received. It neither evaluates JavaScript nor adds authority.
local pending_args,captured=nil,nil
if not real_ready then
 host.quickjs=function(action,payload)
  local args=json.decode(payload or '{}')
  if action=='ready' then return json.encode({ok=true,backend='stub-transport'})
  elseif action=='start' then
   return json.encode({ok=true,id='stub-sandbox',backend='stub-transport',
    events={{type='call',id='stub-call-1',name='searchTools',target='global',args=json.encode(pending_args)}}})
  elseif action=='admit' then return json.encode({ok=true})
  elseif action=='deliver' then
   captured=json.decode(json.decode(payload).payload)
   return json.encode({ok=true,events={{type='output',item={selected=false}},{type='done',ok=true,value='null'}}})
  elseif action=='close' then return json.encode({ok=true}) end
  error('stub_transport_unknown_action:'..tostring(action))
 end
end
local sid=memory.start_session('','codemode names',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local all=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params,raw)return tools.dispatch(memory,name,params,'master',ctx) end
-- One guest call per script: argument = the single argument the model passed to searchTools.
local function run(arg,catalog)
 catalog=catalog or all
 if real_ready then
  local code='const v=await searchTools('..json.encode(arg)..'); return JSON.stringify(v);'
  local result=codemode.run(memory,{code=code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
  local value=result and result.value
  for _=1,2 do if type(value)=='string' then value=json.decode(value) end end
  return type(value)=='table' and value or {},result
 end
 pending_args={arg};captured=nil
 local result=codemode.run(memory,{code='stub'},'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return captured or {},result
end
local function names_of(value)
 local list={};for _,entry in ipairs(value.tools or {})do list[#list+1]=entry.name end;return list
end
-- A refusal is a value on the stub transport and a thrown Error on the real one: `settle` rejects the
-- guest promise when the tool answers success=false, and the Error's message carries the refusal JSON.
-- Read both shapes, so the assertion measures the refusal code and not the transport's delivery style
-- (this build embeds QuickJS, so the real transport is the one that runs here).
local function refusal(value,result)
 if type(value)=='table' and value.error then return value.error end
 local raw=result and result.error
 if type(raw)=='string' then
  local ok,err=pcall(json.decode,raw)
  if ok and type(err)=='table' and type(err.message)=='string' then
   local ok2,body=pcall(json.decode,err.message)
   if ok2 and type(body)=='table' then return body.error end
  end
 end
 return nil
end

-- 1. An exact batch returns exactly those definitions, in order, and admits no call.
local batch,batch_result=run({names={'read','grep','ls','write'}})
check(batch.error==nil,'a guest named batch is accepted: '..json.encode(batch):sub(1,240))
check(table.concat(names_of(batch),',')=='read,grep,ls,write','the guest batch returns the named definitions in order')
check(batch.matches==4 and batch.requested==4,'the guest batch reports all four as matched')
check(batch.missing and #batch.missing==0,'the guest batch has nothing missing')
for _,entry in ipairs(batch.tools)do check(entry.callable==true and entry.schema and entry.schema['function'],'each guest entry carries its schema and is callable') end
check(#(batch_result.calls or {})==0,'a guest batch admits no tool call: it is metadata only')

-- 2. Mixed known and unknown: the known name is there, the unknown one is in missing with suggestions.
local mixed=run({names={'read','reed'}})
check(table.concat(names_of(mixed),',')=='read','the known half of a guest batch is returned')
check(#mixed.missing==1 and mixed.missing[1].name=='reed','the unknown name is reported in missing')
check(table.concat(mixed.missing[1].suggestions,','):find('read',1,true)~=nil,'missing carries the nearest permitted names')

-- 3. The one-string spelling is the same batch.
local selected=run('select:read, grep')
check(table.concat(names_of(selected),',')=='read,grep','searchTools("select:a,b,c") loads the same batch')

-- 4. Refusals match the outer facade.
local exclusive,exclusive_result=run({query='read',names={'grep'}})
check(refusal(exclusive,exclusive_result)=='tool_search_arguments_exclusive','query and names are mutually exclusive in a script')
local nine={};for i=1,9 do nine[i]='read'..i end
local nine_value,nine_result=run({names=nine})
check(refusal(nine_value,nine_result)=='invalid_tool_search_names','more than 8 names is refused in a script')
local empty_value,empty_result=run({names={}})
check(refusal(empty_value,empty_result)=='invalid_tool_search_names','an empty guest batch is refused')

-- 5. Inside the guest, "not callable here" is disclosed with its route, not hidden: parity with the
-- existing searchTools contract, and different from a name outside the ceiling.
local outside=run({names={'subagent'}})
check(outside.tools[1] and outside.tools[1].name=='subagent' and outside.tools[1].callable==false,'an outside tool is returned with callable:false')
check(tostring(outside.tools[1].route):find('Direct call only',1,true)~=nil and #(outside.missing or {})==0,'an outside tool keeps its route instead of reading as missing')

-- 6. A name outside the caller's ceiling is never disclosed as a suggestion.
local narrow={};for _,item in ipairs(all)do
 local name=item['function'].name
 if name~='web_search' and name~='web_read' then narrow[#narrow+1]=item end
end
local hidden=run({names={'web_search'}},narrow)
check(#(hidden.missing or {})==1 and hidden.missing[1].name=='web_search','a name outside the guest catalogue is reported as missing')
local leaked=false
for _,name in ipairs(hidden.missing[1].suggestions)do if name=='web_search' or name=='web_read' then leaked=true end end
check(not leaked,'a name outside the guest catalogue is never suggested back')

-- 7. Keyword discovery and the paged listing are unchanged.
local keywords=run({query='read',limit=2})
check(#(keywords.tools or {})==2 and type(keywords.matches)=='number','keyword search still honours its limit')
local listing=run('*')
check((listing.matches or 0)>0 and #(listing.tools or {})>0,'the catalogue listing still works')

print('tool_search names codemode ok ('..checks..' checks; transport='..transport..')')
