-- Qualification of the narrow benchmark-only fixture API adapter, no real RPC.
local json=dofile('lua/vendor/json.lua')
local n=0
host.http=function(method,url,headers,body)
 local request=json.decode(body);assert(request.op=='fixture_api');n=n+1
 return json.encode({status=200,body=json.encode({ok=true,value={marker='isolated-mock'}})})
end
local schema={['function']={name='fixture_api',description='mock',parameters={type='object',properties={op={type='string',enum={'list'}}},required={'op'},additionalProperties=false}},type='function'}
local adapter=assert(load(assert(host.read_file('benchmarks/codemode/sandbox-client.lua')),'screen-adapter'))().install('http://127.0.0.1:12345/abcd',schema)
local tools=adapter.tools;local ctx={session_id='fixture-test'}
local r=tools.dispatch(nil,'fixture_api',{op='list'},'guest',ctx);assert(r.error=='fixture_scope_refused' and n==0)
r=tools.dispatch(nil,'fixture_api',{op='list'},'master',{session_id='fixture-test',subagent={allowed={fixture_api=true}}});assert(r.error=='fixture_scope_refused' and n==0)
r=tools.dispatch(nil,'fixture_api',{op='wrong'},'master',ctx);assert(r.error and n==0)
r=tools.dispatch(nil,'fixture_api',{op='list',extra=true},'master',ctx);assert(r.error and n==0)
r=tools.dispatch(nil,'fixture_api',{op='list'},'master',{});assert(r.error=='fixture_scope_refused' and n==0)
r=tools.dispatch(nil,'fixture_api',{op='list'},'master',ctx);assert(r.marker=='isolated-mock' and n==1)
local names={};for _,s in ipairs(tools.all('master'))do names[s['function'].name]=true end
assert(names.fixture_api and names.bash and names.read_many and names.write_many and names.edit_many)
for _,s in ipairs(tools.all('guest'))do assert(s['function'].name~='fixture_api')end
print(json.encode({ok=true,checks=8,rpc_calls=n,paid_solver_calls=0,external_effects=0}))
