-- Review r3, B6 (REGRESSION): a wait_s:0 POLL of a running operation with no output must still be
-- stopped by the guard, exactly as it is on main. This is the hot-loop twin of test-rel-native-poll.
--
-- On the branch the guard never stopped it: `changed` was true every round because a codemode call
-- counts as an effect (tools.has_effect), the stable digest still moved (nested results are
-- {bytes,path,sha256} of a raw answer that carries elapsed_ms), and the wait budget was always 0
-- because codemode_pending strips wait_s before the call, so waited_long could never fire.
--
-- Measured 19/11 on avell (which runs the BASE binary), out.log ~16590-16610 (run 8acc22c3, 212
-- rounds, 118m): round after round the model replied with a js run block containing a nested
-- await on an operation, and the block answered a PENDING operation whose log line is mostly a
-- timer. On the third identical round the guard stopped the turn with guard_repeated_calls and
-- killed a legitimate build.
--
-- It runs through the RAW CODE channel (lua/core/raw_code.lua), which is how the measured session
-- worked: this node is raw-code-only, and a codemode TOOL call is refused there. A first version
-- sent codemode tool_calls and measured codemode_only, not the guard - the shape never ran.
--
-- A REAL supervised operation backs it (a sleep that outlives the loop), so nothing is stubbed in
-- the operation path: same tool, same nesting, same pending answer.
--
-- Scratch node only. Refuses the node's own home.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='rel-replay-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return '1' end
  if k=='WASM_AGENT_CODEMODE' then return nil end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the rel-native replay fixture') end

do
  local home=tostring(real_getenv('WASM_AGENT_HOME') or '')
  local trimmed=home:gsub('[/\\\\]+$','')
  local scratch=trimmed:find('scratch',1,true)~=nil or trimmed:find('tmp',1,true)~=nil
    or trimmed:find('temp',1,true)~=nil or trimmed:find('TMP',1,true)~=nil
    or trimmed:match('^/var/folders/')~=nil
  local real_node=trimmed:match('[/\\\\]%.wasm%-agent$')~=nil
  if home=='' or not scratch or real_node then
    print('refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node home (got '..home..')')
    os.exit(2)
  end
end

local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local original=dofile
dofile=function(p) if p=='lua/core/tools.lua' then return tools end return original(p) end
local agent=dofile('lua/core/agent.lua')
dofile=original
local platform=dofile('lua/core/platform.lua')

local checks,failed=0,0
local function ok(condition,label)
  checks=checks+1
  if not condition then failed=failed+1;print('FAIL rel-native-poll: '..label) end
end

local user='rel-native-poll'
local sid=memory.start_session('','rel-native-poll',{user_id=user,node_id='',title='rel replay'})
local shell=tostring(platform.shell() or ''):lower()
local command=shell:find('cmd',1,true) and 'ping -n 45 127.0.0.1 >NUL' or 'sleep 45 >/dev/null 2>&1'
local ctx={session_id=sid,user_id=user,run_id=host.uuid()}
local started=tools.dispatch(memory,'operation',{action='start',command=command,timeout_seconds=120},'master',ctx)
ok(type(started)=='table' and type(started.operation_id)=='string','a real supervised operation started')
local op=type(started)=='table' and started.operation_id or nil
if not op then
  print(string.format('ok rel-native-poll: %d checks, %d failed',checks,failed))
  os.exit(1)
end

local FENCE='```'
local function script_block()
  local a='const a = await tools.operation({action:"await", id:"'..op..'", wait_s:0});'
  local b='const l = await tools.operation({action:"status", id:"'..op..'"});'
  local c='return {state:a.state, log:l.output_bytes};'
  return a..'\n'..b..'\n'..c
end

local reply_text='Still queued. Waiting.\n'..FENCE..'js run\n'..script_block()..'\n'..FENCE

local rounds=0
host.http_stream=function()
  rounds=rounds+1
  if rounds>30 then
    return json.encode({status=200,content='the build finished',stream_complete=true,
      finish_reason='stop',usage={prompt_tokens=10,completion_tokens=5,total_tokens=15}})
  end
  return json.encode({status=200,content=reply_text,stream_complete=true,
    finish_reason='stop',usage={prompt_tokens=10,completion_tokens=5,total_tokens=15}})
end

local handle=agent.new(sid,function() end,'master',user,'')
local ran,result=pcall(handle.run,handle,'wait for that build')
local stopped_by_guard=tostring(result):find('guard_repeated_calls',1,true)~=nil
pcall(tools.dispatch,memory,'operation',{action='cancel',id=op},'master',ctx)

ok(rounds>=3 and rounds<12,'the hot loop was stopped near the repeat limit (ran '..rounds..')')
ok(stopped_by_guard,
  'a wait_s:0 poll still trips guard_repeated_calls (ended with: '..tostring(result):sub(1,200)..')')

print(string.format('ok rel-native-poll: %d checks, %d failed',checks,failed))
if failed>0 then os.exit(1) end