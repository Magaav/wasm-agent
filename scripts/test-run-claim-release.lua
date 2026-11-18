-- Item 5 of the harness-fixes mission (18/11): a settled run releases its claim, and a stale claim left by
-- a run that is gone is reclaimed with an audit line naming the run that held it.
--
-- Measured: `wa chat --resume <id> --once "<note>"` right after a failed session was answered
-- `run_resource_refused` for claim key `session:<id>`, because the release was skipped when marking the
-- run uncertain failed.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='claim-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return 'codemode' end
  if k=='WASM_AGENT_CODEMODE' then return nil end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the claim fixture') end
-- The resource store, as the host implements it: one owner per key, a claim refused while the owner is
-- alive, and a reconcile that frees a dead owner's key.
local held={}
local actions={}
local uncertain_fails=false
host.resource=function(action,args_json)
  local args=json.decode(args_json) or {}
  actions[#actions+1]=action
  if action=='claim' then
    for _,key in ipairs(args.keys or {}) do
      local owner=held[key]
      if owner and not (owner.run==args.run and owner.principal==args.principal) then
        return json.encode({ok=false,error='resource_busy',claim={key=key,principal=owner.principal,run=owner.run}})
      end
    end
    for _,key in ipairs(args.keys or {}) do held[key]={principal=args.principal,run=args.run} end
    return json.encode({ok=true,keys=args.keys})
  elseif action=='reconcile' then
    if type(args.evidence)~='string' or args.evidence=='' then return json.encode({ok=false,error='evidence_required'}) end
    held[tostring(args.key)]=nil
    return json.encode({ok=true,key=args.key})
  elseif action=='finish' then
    local released={}
    for key,owner in pairs(held) do
      if owner.run==args.run and owner.principal==args.principal then held[key]=nil;released[#released+1]=key end
    end
    return json.encode({ok=true,released=released})
  elseif action=='uncertain' then
    if uncertain_fails then return json.encode({ok=false,error='resource_store_failed'}) end
    return json.encode({ok=true})
  end
  return json.encode({ok=true})
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local resources=dofile('lua/core/resources.lua')
local provider=dofile('lua/core/provider.lua')
local original=dofile
dofile=function(p) if p=='lua/core/provider.lua' then return provider end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local function clear() for key in pairs(held) do held[key]=nil end end

-- 1. a stale claim from a run that is gone is reclaimed, with an audit line ---------------------------
clear()
local sid=memory.start_session('','claim-stale',{user_id='master',node_id='',title='stale'})
held['session:'..sid]={principal='master',run='run-that-is-gone'}
local claimed=resources.begin({session_id=sid,user_id='master',run_id='run-new'})
check(claimed.ok==true,'ITEM 5: a new run takes a session claim left by a run that is gone: '..json.encode(claimed))
check(tostring(claimed.audit):find('run lock reclaimed',1,true)~=nil,
  'ITEM 5: and says so in an audit line: '..tostring(claimed.audit))
check(tostring(claimed.audit):find('run-that-is-gone',1,true)~=nil,
  'ITEM 5: the audit line names the run that held it: '..tostring(claimed.audit))
check(tostring(claimed.audit):find('no effect was replayed',1,true)~=nil,
  'ITEM 5: and that nothing was replayed: '..tostring(claimed.audit))
resources.finish({session_id=sid,user_id='master',run_id='run-new'})

-- 2. a settled run releases its claim ---------------------------------------------------------------
clear()
local done=memory.start_session('','claim-settled',{user_id='master',node_id='',title='settled'})
host.http_stream=function() return json.encode({status=200,content='TOOLS_OK',stream_complete=true,
  finish_reason='stop',usage={prompt_tokens=10,completion_tokens=2,total_tokens=12},tool_calls={}}) end
local ok_settled=pcall(function() return agent.new(done,function() end,'master','master',''):run('answer') end)
check(ok_settled,'ITEM 5: the settled run answered')
check(held['session:'..done]==nil,'ITEM 5: a settled run holds no session claim: '..json.encode(held['session:'..done]))

-- 3. a FAILED run releases it too, even when marking the run uncertain fails ---------------------------
clear();actions={};uncertain_fails=true
local failed_sid=memory.start_session('','claim-failed',{user_id='master',node_id='',title='failed'})
local failed_events={}
host.http_stream=function() error('fixture provider down') end
local ran,failure=pcall(function()
  return agent.new(failed_sid,function(event) failed_events[#failed_events+1]=event end,'master','master',''):run('work')
end)
check(not ran,'ITEM 5: the run that could not reach its provider failed: '..tostring(failure):sub(1,120))
-- Review of 18/11, item 5: with the release succeeding, the failed uncertainty mark used to be heard by
-- nobody - the claim was deleted and the fact that nobody recorded WHY the run was uncertain went with it.
local uncertain_heard=nil
for _,event in ipairs(failed_events) do
  if tostring(event.error or ''):find('resource_uncertain_failed',1,true)~=nil then uncertain_heard=event.error end
end
check(uncertain_heard~=nil,
  'ITEM 5: a failed uncertainty mark is reported on its own, not only when the release fails too: '..
  json.encode(failed_events):sub(1,300))
check(held['session:'..failed_sid]==nil,
  'ITEM 5: a failed run leaves no claim behind, even when its uncertainty write failed: '..json.encode(held['session:'..failed_sid]))
check(table.concat(actions,','):find('finish',1,true)~=nil,'ITEM 5: the release was asked for: '..table.concat(actions,','))
uncertain_fails=false

print(json.encode({ok=true,checks=checks}))