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
    {name='chat_read',description='Read a chat',parameters={type='object',properties={chat={type='string'}}},effect='read'},
    {name='chat_send',description='Send',parameters={type='object',properties={}},effect='write'}}} end
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
check(names['peer_openclaw__chat_read'] and names['peer_openclaw__chat_read']:find('on peer openclaw',1,true),'the peer tool is listed under the peer name')
check(federation.is_read('peer_openclaw__chat_read') and not federation.is_read('peer_openclaw__chat_send'),'the peer-approved tier travels')
local answer=federation.call('peer_openclaw__chat_read',{chat='x'})
check(answer.ok and answer.ran_on=='peer-1' and answer.tool=='chat_read' and answer.args.chat=='x','a call runs on the peer that holds it')
check(federation.call('peer_nobody__thing',{}).error=='federation_tool_unknown','an unknown peer tool is refused locally')
check(#federation.local_name(string.rep('n',40),string.rep('t',40))<=64,'names stay within the 64-character limit')

-- Listing never waits on the network while the cache is fresh.
local before=#calls; federation.schemas(); check(#calls==before,'a fresh cache answers without asking peers')

-- A refresh is bounded: a peer the relay reports as not attached is not asked (a relayed call to it waits
-- out the relay hold), and once the budget is spent the rest wait for the next refresh.
nodes.reachable=function(node) if node.node_id=='peer-2' then return false,'not_attached' end return true end
before=#calls; cache=federation.refresh()
local asked={}; for i=before+1,#calls do asked[calls[i].id]=true end
check(asked['peer-1'] and not asked['peer-2'],'a peer that is not relay-attached is not asked')
check(cache.peers['peer-2'] and cache.peers['peer-2'].error=='not_attached','the skipped peer is recorded with why')
local budget=federation.BUDGET; federation.BUDGET=-1
before=#calls; cache=federation.refresh(); federation.BUDGET=budget
check(#calls==before and cache.peers['peer-1'].error=='refresh_budget_spent','a spent budget asks no more peers and says so')
nodes.reachable=nil; cache=federation.refresh()

-- The tool layer exposes and routes them for a master only.
dofile=real_dofile
local tools=dofile('lua/core/tools.lua')
check(tools.dispatch(memory,'peer_openclaw__chat_read',{},'guest',{}).error:find('forbidden_for_role',1,true),'a guest cannot use federated tools')
check(tools.has_effect('peer_openclaw__chat_send') and not tools.has_effect('peer_openclaw__chat_read'),'effects follow the peer tier')
-- Operator-directed send: exported only where configs and the CLI exist; profile and chat scope enforced.
local paths=dofile('lua/core/paths.lua')
local opdir=paths.data()..'/operator-fixture'
assert(host.write_file(opdir..'/operator-management-laura-1.json',json.encode({kind='whatsapp-operator-v1',generation=2,
  conversations={'5500000000001@s.whatsapp.net'},dispatch_token_file='/nonexistent/d',approval_token_file='/nonexistent/a'})))
assert(host.write_file(opdir..'/operator-read-1.json','{"kind":"other"}'))
local scripts=paths.data()..'/op-scripts'
local mcp=dofile('lua/core/mcp.lua')
for _,file in ipairs(mcp.RUNTIME) do assert(host.write_file(scripts..'/'..file,'// fixture\n')) end
assert(host.write_file(scripts..'/whatsapp-operator.mjs','// fixture\n'))
local env=host.getenv
host.getenv=function(k) if k=='WA_WHATSAPP_OPERATOR_DIR' then return opdir end if k=='WA_MCP_SCRIPT_DIR' then return scripts end return env(k) end
local profiles=federation.operator_profiles()
check(profiles['laura-1'] and profiles['read-1']==nil,'only operator-management configs are profiles')
local exported={};for _,t in ipairs(federation.exported()) do exported[t.name]=t end
check(exported.whatsapp_operator and exported.whatsapp_operator.effect=='write','the operator send is exported as a write')
check(exported.whatsapp_operator.description:find('5500000000001@s.whatsapp.net',1,true),'the description names each profile scope')
check(federation.operator_call({action='prepare',profile='nobody',request={}}).error=='operator_profile_unknown','an unknown profile refuses')
check(federation.operator_call({action='delete',profile='laura-1',request={conversation_id='5500000000001@s.whatsapp.net'}}).error=='operator_action_unsupported','only the four actions')
check(federation.operator_call({action='prepare',profile='laura-1',request={conversation_id='5599999999999@s.whatsapp.net',body='x'}}).error=='operator_conversation_outside_profile','a chat outside the profile refuses before the CLI runs')
local called
check(federation.serve({action='call',name='whatsapp_operator',args={action='status',profile='nobody'}},{role='master'},function() called=true end).error=='operator_profile_unknown' and not called,'served through the operator path, never the generic dispatch')
host.getenv=env

-- Peers in the code-mode hint, from the cache only (29/10).
local policy=dofile('lua/core/codemode_policy.lua')
check(policy.prompt({}):find('Peers seen online at the last refresh',1,true) and policy.prompt({}):find('openclaw',1,true),'the hint names cached peers')
check(not table.concat(federation.cached_peers(),','):find('old-build',1,true),'a peer that did not answer is not advertised')
check(policy.guidance:find('search_messages({query, node})',1,true) and policy.guidance:find('capability:"batch", calls:[',1,true),'the hint teaches peer history and the read batch')

-- History on a peer and the read-only remote batch, against stubbed peers (29/10).
local sent={}
nodes.find=function(sel) for _,n in ipairs(nodes.list()) do if n.name==sel or n.node_id==sel then return n end end end
nodes.operator_status=function() return {operator_of_peer=true} end
nodes.remote_call=function(id,capability,args)
  local named=nodes.find(id);id=named and named.node_id or id
  sent[#sent+1]={id=id,capability=capability,args=args}
  if capability=='batch' then
    if id=='peer-2' then return {error='plugin_not_found:batch'} end
    local results={};for i,e in ipairs(args.calls) do results[i]={ok=true,ran=e.capability} end
    return {batch=1,results=results}
  end
  if capability=='sessions' and id=='peer-2' then return {sessions={}} end
  return {ok=true,ran=capability,on=id,args=args,filter=capability=='sessions' and {} or nil}
end
dofile=function(path) if path=='lua/core/nodes.lua' then return nodes end return real_dofile(path) end
local ptools=dofile('lua/core/tools.lua')
dofile=real_dofile
local mctx={user_id='master'}
local hit=ptools.dispatch(memory,'search_messages',{query='app',node='openclaw'},'master',mctx)
check(hit.ok and hit.on=='peer-1' and hit.ran=='search_messages' and hit.args.node==nil and hit.args.query=='app','search_messages node= runs on the peer, node not forwarded: '..json.encode(hit))
check(ptools.dispatch(memory,'sessions',{node='openclaw'},'guest',{user_id='g'}).error:find('forbidden_for_role',1,true),'a guest cannot route history to a peer')
check(ptools.dispatch(memory,'search_messages',{query='x',node='openclaw'},'master',{user_id='master',peer_call=true}).error=='history_node_not_forwarded','a peer never forwards a history read')
local old=ptools.dispatch(memory,'sessions',{node='old-build',all_owners=true,path='/repo'},'master',mctx)
check(old.filter_ignored and old.note:find('search_messages',1,true),'an older peer that ignores the filter is named, with the fallback')
local n0=#sent
local batch=ptools.dispatch(memory,'remote',{node='openclaw',capability='batch',calls={{capability='read',path='/a'},{capability='bash',command='git log -1',cwd='/r'},{capability='sessions',all_owners=true}}},'master',mctx)
check(batch.ok and batch.round_trips==1 and #batch.results==3 and #sent==n0+1 and sent[#sent].capability=='batch','three reads, one round trip: '..json.encode(batch))
check(sent[#sent].args.calls[2].args.command=='git log -1' and sent[#sent].args.calls[2].args.cwd=='/r','flat entry params travel as args')
local eff=ptools.dispatch(memory,'remote',{node='openclaw',capability='batch',calls={{capability='read',path='/a'},{capability='bash',command='rm -rf /x'}}},'master',mctx)
check(eff.error=='remote_effect_outside_codemode' and eff.index==2 and #sent==n0+1,'an effect in a batch refuses the whole batch before anything is sent')
check(ptools.dispatch(memory,'remote',{node='openclaw',capability='batch',calls={{capability='write',path='/a',content='x'}}},'master',mctx).error=='remote_effect_outside_codemode','write is never batched')
local fb=ptools.dispatch(memory,'remote',{node='old-build',capability='batch',calls={{capability='read',path='/a'},{capability='ls',path='/'}}},'master',mctx)
check(fb.ok and fb.round_trips==3 and fb.fallback:find('peer_has_no_batch',1,true) and fb.results[2].ran=='ls','an older peer gets the same reads one call each, said')
-- Inside a script (codemode_nested) remote reads pass and effects are refused with the route.
local nested={user_id='master',codemode_nested=true}
check(ptools.dispatch(memory,'remote',{node='openclaw',capability='read',path='/a'},'master',nested).ran=='read','a nested remote read runs')
check(ptools.dispatch(memory,'remote',{node='openclaw',capability='bash',command='git status --short',cwd='/r'},'master',nested).ran=='bash','a nested read-only bash runs')
local w=ptools.dispatch(memory,'remote',{node='openclaw',capability='edit',path='/a'},'master',nested)
check(w.error=='remote_effect_outside_codemode' and w.note:find('outside code mode',1,true),'a nested remote edit names its route')
check(ptools.dispatch(memory,'remote',{node='openclaw',capability='bash',command='git status > /tmp/x'},'master',nested).error=='remote_effect_outside_codemode','redirection is an effect')
check(ptools.dispatch(memory,'remote',{node='openclaw',capability='bash',command='touch /x'},'master',{user_id='master'}).ran=='bash','outside a script remote keeps its effects')

-- Peer side: `batch` reruns the fence under the peer's own rules.
check(ptools.remote_read_refusal('search_messages_many',{})==nil and ptools.remote_read_refusal('client',{})~=nil,'the read set is explicit')

-- "Last agent session on that repo": bound worktree or recorded file changes under the path.
local a=memory.start_session('','repo work',{user_id='peer-agent'})
memory.set_session_workspace(a,{worktree='/local/projects/app/.wt/a',state='allocated'})
local b=memory.start_session('','edit only',{user_id='peer-agent'})
memory.append_turn(b,{role='assistant',content='edited',changes={files={{path='/local/projects/app/src/x.js',added=1,removed=0}}}})
local c=memory.start_session('','sibling repo',{user_id='peer-agent'})
memory.append_turn(c,{role='assistant',content='edited',changes={files={{path='/local/projects/app-old/y.js',added=1,removed=0}}}})
local listed=ptools.dispatch(memory,'sessions',{all_owners=true,path='/local/projects/app/'},'master',{user_id='master'})
local ids={};for _,row in ipairs(listed.sessions) do ids[row.id]=true end
check(ids[a] and ids[b] and not ids[c] and listed.filter.path=='/local/projects/app/','path filter: worktree and changes match, a sibling prefix does not: '..json.encode(listed.filter))
check(#ptools.dispatch(memory,'sessions',{path='/local/projects/app'},'master',{user_id='master'}).sessions==0,'without all_owners only your own sessions')
check(ptools.dispatch(memory,'sessions',{all_owners=true},'guest',{user_id='g'}).error,'all_owners is master only')
print(json.encode({ok=true,checks=checks}))
