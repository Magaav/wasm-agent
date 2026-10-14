-- Actual native dispatcher/MCP/SQLite; upstream HTTP responses are labelled fixtures.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup();local tools=dofile('lua/core/tools.lua');local mcp=dofile('lua/core/mcp.lua');local paths=dofile('lua/core/paths.lua')
local checks=0;local function check(v,s)assert(v,s);checks=checks+1 end
local phase=host.getenv('WEB_HTTP_PHASE');local state_path=paths.data()..'/http-state.json'
local ctx
if phase=='restart' then ctx=json.decode(assert(host.read_file(state_path))).ctx else ctx={session_id=memory.start_session('','web HTTP state',{user_id='master'}),user_id='master',role='master'}end
local function call(args)
 local wrapped={name='web_read',arguments=args,checked=true};ctx.tool_arguments_json=json.encode(wrapped)
 local result=tools.dispatch(memory,'tool_call',wrapped,'master',ctx);ctx.tool_arguments_json=nil;return result
end
if phase=='restart' then
 local saved=json.decode(assert(host.read_file(state_path)));local final=call({pending_ref=saved.pending_ref})
 check(final.ok and final.state=='complete' and final.content=='FINAL_ASYNC_RESULT','native reconstruction reads monitor result')
 local original=call({ref=saved.response_ref});check(original.ok and original.content=='accepted','original accepted response retained after reconstruction')
 check(call({pending_ref=saved.response_ref}).error~=nil,'HTTP evidence cannot impersonate pending handle')
else
 check(tools.dispatch(memory,'tool_search',{query='web_read',limit=1},'master',ctx).loaded==1,'exact new read contract discovered')
 local challenge=call({url='https://fixture.test/challenge'})
 check(challenge.state=='needs_user_action' and challenge.handoff.action=='solve_challenge_in_browser' and challenge.ok==false,'native recoverable human handoff')
 local raw=call({ref=challenge.response_ref});check(raw.content:find('challenge-form',1,true)~=nil,'native raw challenge evidence retrieval')
 local pending=call({url='https://fixture.test/start'});check(pending.state=='pending' and pending.pending_ref,'native 202 pending handle')
 check(host.write_file(state_path,json.encode({ctx=ctx,pending_ref=pending.pending_ref,response_ref=pending.response_ref})),'context/handle retained for native restart')
 check(tools.dispatch(memory,'web_read',{url='https://fixture.test/start'},'guest',ctx).error~=nil,'guest authority unchanged')
end
for _,r in ipairs(mcp.close_read_sessions())do check(r.settled and r.settled.settled,'owned MCP process drained')end
print('web HTTP native '..phase..' ok ('..checks..' checks, 0 skipped; mock upstream only)')
