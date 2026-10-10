-- Adapter-side pending-output contract. Real native lifecycle covered by wa-operation tests.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(key) if key=='WASM_AGENT_SUBSCRIPTION_TRANSPORT' then return 'pi' end return getenv(key) end
local adapter=dofile('lua/core/openai_sub.lua')
local calls,reads,cancels=0,0,0
host.operation=function(action,encoded)
 local args=json.decode(encoded)
 if action=='start' then calls=calls+1;return json.encode({operation_id='op-fixture'}) end
 if action=='wait' then return json.encode({settled=reads>=2,ok=true}) end
 if action=='read' then
  reads=reads+1
  if reads==1 then return json.encode({operation_id='op-fixture',content='',next_offset=0,pending_output=true}) end
  if reads==2 then return json.encode({content=json.encode({type='result',result={content='same-operation answer',tool_calls={}}})..'\n',next_offset=100}) end
  return json.encode({content='',next_offset=args.offset})
 end
 if action=='cancel' then cancels=cancels+1;return json.encode({settled=true}) end
 error('unexpected operation action '..action)
end
local result=adapter.complete('fixture',{{role='user',content='test'}},nil,false,{}, {selected='off'})
assert(result.content=='same-operation answer','adapter completes through pending output')
assert(calls==1 and cancels==0,'pending output never relaunches/cancels inference')
assert(reads>=3,'same operation cursor remains observable')
print('subscription pending output ok (3 checks, no inference)')
