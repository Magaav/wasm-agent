local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local view=dofile('lua/core/session_view.lua')
local sid=memory.start_session('','projection',{user_id='owner'})
local calls={{id='call-original',type='function',['function']={name='symbol_source_many',arguments='{"requests":[{"path":"lua/core/whatsapp.lua","name":"send_tool","line":438}]}'}}}
local id=host.uuid();memory.append_turn(sid,{id=id,role='assistant',content='surrounding prose',phase='commentary',reasoning_items=string.rep('encrypted-fixture-',6000),tool_calls=calls,trace={{kind='model_call',ok=false,error='original failure'}},debug=true})
local before=json.encode(memory.message(id))
local projection=view.get(memory,sid,{message_id=id,view='tool_calls'})
assert(not projection.error and projection.message.tool_calls[1]['function'].arguments==calls[1]['function'].arguments,'exact arguments')
assert(not json.encode(projection):find('encrypted%-fixture') and not projection.message.content,'explicit projection omits opaque reasoning/prose')
assert(projection.message.phase=='commentary' and projection.message.evidence.view=='full','phase and full original')
assert(#json.encode(projection)<2000 and #before>80000,'one bounded call replaces opaque paging')
local selected=memory.message(id,{view='tool_calls'});assert(selected.reasoning_items==nil and selected.trace==nil,'SQL does not load opaque columns')
for _,args in ipairs({{limit=1},{around_seq=1,before=0,after=0},{message_ids={id}}})do
 args.view='tool_calls';args.byte_limit=3000;local p=view.get(memory,sid,args);assert(not p.error and p.messages[1].tool_calls[1].id=='call-original','page/window/batch parity')
end
local paged=view.get(memory,sid,{message_id=id,view='tool_calls',byte_offset=1,byte_limit=512});assert(paged.encoding=='tool_calls_message_json','projection encoding')
assert(view.get(memory,sid,{message_id=id,view='tool_calls',byte_offset=1,message_version='stale'}).error=='message_changed','stale projection refused')
assert(view.get(memory,'foreign',{message_id=id,view='tool_calls'}).error=='unknown_message','session boundary')
assert(json.encode(memory.message(id))==before,'original unchanged')
local tools=dofile('lua/core/tools.lua');local ctx={user_id='owner',session_id=sid}
local batch=tools.dispatch(memory,'session_many',{requests={{session_id=sid,message_ids={id},view='tool_calls'},{session_id=sid,message_id=id,view='tool_calls'}}},'master',ctx)
assert(batch.ok and batch.results[1].messages[1].tool_calls[1].id=='call-original' and batch.results[2].message.tool_calls[1]['function'].arguments==calls[1]['function'].arguments,'actual batch dispatch')
local tid=host.uuid();local outcome='{"ok":false,"error":"preserved exact outcome","required_revision":9}'
memory.append_turn(sid,{id=tid,role='tool',tool_call_id='call-original',tool_name='symbol_source_many',content=outcome,ok=false,ms=37})
local toolrow=view.get(memory,sid,{message_id=tid,view='tool_calls'}).message
assert(toolrow.content==outcome and toolrow.ok==0 and toolrow.ms==37 and toolrow.tool_call_id=='call-original','exact outcomes/IDs/status/timing')
local runtime=host.subagent;host.subagent=function(action,raw)local p=json.decode(raw);if p.id=='owned-fixture' and p.owner_user=='owner' then return json.encode({subagent_id=p.id,session_id=sid,state='completed',settled=true,profile='fixture'}) end;return '{"error":"unknown_subagent"}' end
local child=tools.dispatch(memory,'subagent',{action='session',id='owned-fixture',message_id=id,view='tool_calls'},'master',ctx)
assert(child.message.tool_calls[1].id=='call-original' and child.message.evidence.tool=='subagent' and child.message.evidence.id=='owned-fixture','actual owned child route and evidence')
assert(tools.dispatch(memory,'subagent',{action='session',id='foreign-fixture',message_id=id,view='tool_calls'},'master',ctx).error=='unknown_subagent','child ownership boundary')
host.subagent=runtime
local huge=host.uuid();memory.append_turn(sid,{id=huge,role='assistant',content='prose must remain separate',tool_calls={{id='huge-arguments',['function']={name='fixture',arguments=string.rep('é',20000)}}}})
local bounded=view.get(memory,sid,{message_ids={huge},view='tool_calls',byte_limit=2048});assert(bounded.messages[1].omitted and bounded.messages[1].evidence.view=='tool_calls','oversized arguments point to projected paging, not opaque original')
local selected_page=view.get(memory,sid,{message_id=huge,view='tool_calls',byte_offset=1,byte_limit=512});assert(selected_page.encoding=='tool_calls_message_json' and selected_page.next_offset>1,'oversized projection can be paged')
print('tool-call projection ok (18 checks; original '..#before..' bytes, projection '..#json.encode(projection)..' bytes)')
