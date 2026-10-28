-- Connector federation (lua/core/federation.lua) without a second machine: the peer side is exercised
-- directly, the network (nodes.list / nodes.remote_call) is a stub that answers as the peer would.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua'); memory.setup()
local checks=0
local function check(v,label) checks=checks+1; if not v then error('FEDERATION CHECK FAILED: '..label) end end

local federation=dofile('lua/core/federation.lua')

-- Peer side: only a master may list or call; only exported names are callable.
check(federation.serve({action='catalog'},{role='guest'}).error=='federation_requires_master','a guest caller is refused')
local catalog=federation.serve({action='catalog'},{role='master'})
check(catalog.ok and type(catalog.tools)=='table','a master gets the catalog')
local refused=federation.serve({action='call',name='bash',args={command='id'}},{role='master'},function() error('must not dispatch') end)
check(refused.error=='federation_tool_not_exported','a tool that is not an exported connector is never run: '..json.encode(refused))

-- Local side, against a stubbed peer `openclaw` exporting one read and one write tool.
local nodes=dofile('lua/core/nodes.lua')
local calls={}
nodes.list=function() return {
  {node_id='self',name='here',local_node=true,online=true},
  {node_id='peer-1',name='openclaw',online=true},
  {node_id='peer-2',name='old-build',online=true},
  {node_id='peer-3',name='down',online=false}} end
nodes.remote_call=function(id,capability,args)
  calls[#calls+1]={id=id,capability=capability,args=args}
  if id=='peer-2' then return {error='plugin_not_found:federation'} end
  if args.action=='catalog' then return {ok=true,tools={
    {name='whatsapp_read',description='Read a chat',parameters={type='object',properties={chat={type='string'}}},effect='read'},
    {name='whatsapp_send',description='Send',parameters={type='object',properties={}},effect='write'}}} end
  if args.action=='call' then return {ok=true,ran_on=id,tool=args.name,args=args.args} end
end
package.loaded=package.loaded or {}
local real_dofile=dofile
dofile=function(path) if path=='lua/core/nodes.lua' then return nodes end return real_dofile(path) end

local cache=federation.refresh()
check(cache.peers['peer-1'] and #cache.peers['peer-1'].tools==2,'the online peer catalog is kept')
check(cache.peers['peer-2'] and cache.peers['peer-2'].error,'an older peer is recorded with its reason, not dropped silently')
check(cache.peers['peer-3']==nil,'an offline peer is not asked')
local names={}; for _,s in ipairs(federation.schemas()) do names[s['function'].name]=s['function'].description end
check(names['peer_openclaw__whatsapp_read'] and names['peer_openclaw__whatsapp_read']:find('on peer openclaw',1,true),'the peer tool is listed under the peer name')
check(federation.is_read('peer_openclaw__whatsapp_read') and not federation.is_read('peer_openclaw__whatsapp_send'),'the peer-approved tier travels')
local answer=federation.call('peer_openclaw__whatsapp_read',{chat='x'})
check(answer.ok and answer.ran_on=='peer-1' and answer.tool=='whatsapp_read' and answer.args.chat=='x','a call runs on the peer that holds it')
check(federation.call('peer_nobody__thing',{}).error=='federation_tool_unknown','an unknown peer tool is refused locally')
check(#federation.local_name(string.rep('n',40),string.rep('t',40))<=64,'names stay within the 64-character limit')

-- Listing never waits on the network while the cache is fresh.
local before=#calls; federation.schemas(); check(#calls==before,'a fresh cache answers without asking peers')

-- The tool layer exposes and routes them for a master only.
dofile=real_dofile
local tools=dofile('lua/core/tools.lua')
check(tools.dispatch(memory,'peer_openclaw__whatsapp_read',{},'guest',{}).error:find('forbidden_for_role',1,true),'a guest cannot use federated tools')
check(tools.has_effect('peer_openclaw__whatsapp_send') and not tools.has_effect('peer_openclaw__whatsapp_read'),'effects follow the peer tier')
print(json.encode({ok=true,checks=checks}))
