-- Exact pre-fix module + exact pre-fix actual agent, private native Git/SQLite.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local native=dofile;local getenv=host.getenv
host.getenv=function(k)
 if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture' end
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 if k=='WASM_AGENT_CODEMODE' then return 'off' end
 return getenv(k)
end
host.http=function()error('network forbidden')end;host.http_stream=host.http
local nodes=native('lua/core/nodes.lua');local provider=native('lua/core/provider.lua')
local wave=assert(load(assert(host.read_file(host.getenv('WA_REPORT_OLD_WAVE'))),'@baseline-wave'))()
local sid=memory.start_session('','chat',{user_id='master',node_id=nodes.identity().node_id})
local root=host.getenv('WA_REPORT_MAIN');local own=host.getenv('WA_REPORT_OWN')
memory.set_session_worktree(sid,root)
local child=memory.start_session('','subagent',{user_id='master',parent_session_id=sid})
memory.set_session_workspace(child,{worktree=own,required=true,state='allocated'})
host.subagent=function(action)
 assert(action=='list')
 return json.encode({subagents={{subagent_id='private-active',session_id=child,parent_session_id=sid,
  profile='orchestration-worker',run_origin='cli',state='running',settled=false}}})
end
local ctx={session_id=sid,user_id='master',role='master'}
assert(wave.control({action='enable',revision=0},ctx).ok)
local observed=wave.finalize(ctx)
assert(observed.held and observed.error:find('wave_required_child_active',1,true),'exact baseline turns real active child into Lua error')
local finalize_calls,queue_calls=0,0;local finalize=wave.finalize
wave.finalize=function(c)finalize_calls=finalize_calls+1;return finalize(c)end
dofile=function(p)
 if p=='lua/core/provider.lua' then return provider end
 if p=='lua/core/wave_autoflush.lua' then return wave end
 if p=='lua/core/update.lua' then local u=native(p);u.request_bound=function()queue_calls=queue_calls+1;error('queue forbidden')end;return u end
 return native(p)
end
local agent=assert(load(assert(host.read_file(host.getenv('WA_REPORT_OLD_AGENT'))),'@baseline-agent'))()
provider.complete_with=function()return {content='Ordinary active-worker status.',finish_reason='stop',usage={prompt_tokens=1,completion_tokens=1,total_tokens=2}}end
local reply=agent.new(sid,function()end,'master','master',''):run('private baseline status')
assert(reply:find('[Wave installation closure:',1,true) and reply:find('wave_required_child_active',1,true),'exact old actual-agent raw error leak reproduced')
assert(finalize_calls==1 and queue_calls==0,'one hook, zero queue effects')
print(json.encode({ok=true,negative_control='exact old native module and actual agent reproduce real active-worker raw leak',finalize_calls=finalize_calls,queue_calls=queue_calls,error=observed.error,reply=reply,paid_calls=0,live_installation=false}))
