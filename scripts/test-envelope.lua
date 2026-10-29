local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local envelope=dofile('lua/core/envelope.lua')
local agent=dofile('lua/core/agent.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function session(title)return memory.start_session('',title,{user_id='master',node_id='',title=title})end
local sid=session('empty');local ctx={session_id=sid,user_id='master',role='master'}
local all=tools.all('master');local bootstrap,mode=tools.envelope('master',ctx)
check(mode=='progressive','empty session progressive')
check(#bootstrap==14 and #all>#bootstrap,'lean bootstrap with all capabilities retained')
local before=json.encode(bootstrap)
local unknown=tools.dispatch(memory,'tool_call',{name='web_searchd',arguments={}},'master',ctx)
check(unknown.error:find('tool_not_available',1,true)==1 and unknown.error:find('web_search',1,true)~=nil,'an unknown name refuses and lists the closest permitted name')
-- Discovery is a convenience, not a precondition: a name the model already knows routes directly.
local known=tools.dispatch(memory,'tool_call',{name='memories',arguments={}},'master',ctx)
check(type(known)=='table' and known.error==nil,'a known name is callable without discovery')
local found=tools.dispatch(memory,'tool_search',{query='web search read',limit=2},'master',ctx)
check(found.loaded==2 and found.tools[1].schema~=nil,'exact definitions load on demand')
local names={};for _,r in ipairs(found.tools)do names[r.name]=true end
check(names.web_search and names.web_read,'web fixture discovery reaches both tools')
check(json.encode(tools.envelope('master',ctx))==before,'schema prefix does not expand')
local first=agent.new(sid,function()end,'master','master',''):build_context()[1].content
check(first:find('Additional capabilities',1,true)~=nil,'model instructed about discovery')
check(not first:find('web_search -',1,true),'no full optional tool index')
local second=agent.new(sid,function()end,'master','master',''):build_context()[1].content
check(first==second,'stable system before/after discovery')
local persisted=dofile('lua/core/envelope.lua')
check(persisted.resolve(all,'web_read',ctx)~=nil,'definitions survive module restart')
local other={session_id=session('other'),user_id='master',role='master'}
local fresh,_=persisted.resolve(all,'web_read',other);check(fresh~=nil,'a permitted definition resolves without a prior load in a fresh session')
local guest={session_id=session('guest'),user_id='guest',role='guest'}
local denied=tools.dispatch(memory,'tool_search',{query='web_search',limit=1},'guest',guest)
check(denied.loaded==0,'guest cannot discover operator web tools')
check(tools.dispatch(memory,'tool_call',{name='web_search',arguments={query='x'}},'guest',guest).error:find('tool_not_available',1,true)==1,'guest cannot route privileged tools')
local hidden=tools.dispatch(memory,'tool_search',{query='integrate',limit=1},'master',ctx)
check(hidden.loaded==0,'parent cannot load a task-owner-only tool')
local child={session_id=sid,user_id='master',role='master',subagent={allowed={tool_call=true,tool_search=true,web_read=true}}}
check(tools.dispatch(memory,'tool_call',{name='web_search',arguments={query='x'}},'master',child).error:find('tool_not_available',1,true)==1,'profile ceiling rechecked on target')
check(tools.dispatch(memory,'tool_search',{query='',limit=1},'master',ctx).error=='tool_search_query_required','invalid discovery visible')
check(tools.dispatch(memory,'tool_search',{query='read',limit=99},'master',ctx).error=='invalid_tool_search_limit','discovery bound')
check(envelope.argument_fragment('{"name":"echo","arguments":{"x":[null,{},[]],"s":"\\\"}\\\""}}')=='{"x":[null,{},[]],"s":"\\\"}\\\""}','raw argument null/array/object and quotes preserved')
local loaded=tools.dispatch(memory,'tool_search',{query='capabilities',limit=1},'master',ctx)
check(loaded.loaded==1,'load ordinary capability')
local routed=tools.dispatch(memory,'tool_call',{name='capabilities',arguments={}},'master',ctx)
check(#routed.capabilities==#all,'full catalogue remains reachable')
check(not pcall(envelope.argument_fragment,'{"arguments":{},"arguments":{"different":true}}'),'duplicate routed arguments refused')
check(tools.dispatch(memory,'tool_call',{name='tool_call',arguments={}},'master',ctx).error=='invalid_routed_tool','no recursive facade')
local boundary_root=dofile('lua/core/paths.lua').data()..'/envelope-scope'
assert(host.write_file(boundary_root..'/inside.txt','inside'))
local bound={session_workspace=function()return {required=true,state='allocated',worktree=boundary_root}end}
check(tools.dispatch(memory,'tool_search',{query='write',limit=1},'master',ctx).loaded==1,'write definition reachable without execution')
local outside=dofile('lua/core/paths.lua').data()..'/outside-envelope.txt'
local blocked=tools.dispatch(bound,'tool_call',{name='write',arguments={path=outside,content='forbidden'}},'master',ctx)
check(blocked.error~=nil and host.read_file(outside)==nil,'routed writes retain required-workspace fence')
local corecount=0;for _,item in ipairs(all)do local name=item['function'].name;if name~='tool_call' and name~='tool_search' then
 local s=tools.dispatch(memory,'tool_search',{query=name,limit=1},'master',ctx);check(s.tools[1] and s.tools[1].name==name,'every permitted native definition discoverable: '..name);corecount=corecount+1 end end
check(corecount==#all-2,'complete catalogue reached without invoking effects')
local copy={};for _,item in ipairs(all)do if item['function'].name=='web_read' then item['function'].description=item['function'].description..' changed' end;copy[#copy+1]=item end
local _,changed=envelope.resolve(copy,'web_read',ctx);check(changed:find('definition_changed',1,true)~=nil,'schema/definition change requires rediscovery')
local legacy=session('legacy');memory.append_turn(legacy,{role='assistant',content='historical answer'})
local _,legacyMode=tools.envelope('master',{session_id=legacy,user_id='master',role='master'})
check(legacyMode=='full','existing conversation retains full surface')
check(envelope.mode({session_id=legacy,subagent={}})=='full','child exact declarations unchanged')
print('envelope ok ('..checks..' checks)')
