-- The observed nested SSE error must reach the actual agent's overflow recovery.
-- No inference/network/tool effects: replay through the native transport seam.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local getenv=host.getenv
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_LLM_MODEL='gpt-6.1-sol',
  WASM_AGENT_SUBSCRIPTION_TRANSPORT='native',WASM_AGENT_CONTEXT_BUDGET='0',
  WASM_AGENT_PROVIDER_RETRIES='0',WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0',
  WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/overflow-fixture/credentials.json'}
host.getenv=function(key) if env[key]~=nil then return env[key] end return getenv(key) end
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode({version=1,
  provider='openai-codex',type='oauth',access='private-fixture',refresh='private-fixture',
  expires=host.now()*1000+3600000,account_id='fixture-account'})))
host.http=function() error('unexpected network') end
host.operation=function() error('unexpected tool effect') end
local memory=dofile('lua/core/memory.lua'); memory.setup()
local provider=dofile('lua/core/provider.lua')
local original=dofile
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original(path) end
local agent=original('lua/core/agent.lua'); dofile=original
provider.budget=function() return {context=100000,reserve=16384,keep=1000,output=10000,source='fixture'} end
local checks=0
local function check(ok,label) assert(ok,label); checks=checks+1 end
local fixture=assert(host.read_file('tests/fixtures/subscription/codex-context-error-sse.txt'))
local function run_case(code,repeat_failure)
  local sid=memory.start_session('','native overflow',{user_id='master'})
  for i=1,40 do
    memory.append_turn(sid,{role=i%2==1 and 'user' or 'assistant',
      content='ROW_'..i..' '..string.rep('work ',100)})
  end
  local bot=agent.new(sid,function() end,'master','master','')
  bot.context_tokens=function() return 80000,'fixture' end
  local task_calls,summary_calls=0,0
  local function response(line,text)
    local function send(event) line('data: '..json.encode(event)); line('') end
    send({type='response.created',response={id='fixture'}})
    send({type='response.output_item.added',output_index=0,
      item={type='message',id='message',phase='final_answer'}})
    send({type='response.output_text.delta',output_index=0,delta=text})
    send({type='response.output_item.done',output_index=0,
      item={type='message',id='message',phase='final_answer',content={{type='output_text',text=text}}}})
    send({type='response.completed',response={id='fixture',status='completed',
      usage={input_tokens=1000,output_tokens=20,total_tokens=1020}}})
  end
  host.http_sse=function(_,_,_,body,line)
    local request=json.decode(body)
    if not request.tools or #request.tools==0 then
      summary_calls=summary_calls+1
      response(line,'Checkpoint preserving prior work and the pending request.')
    else
      task_calls=task_calls+1
      if task_calls==1 or repeat_failure then
        local payload=code=='context_length_exceeded' and fixture or
          ('data: '..json.encode({type='error',error={code=code,message='Provider refused request'}})..'\n\n')
        -- Real host.http_sse catches a callback exception and returns this envelope.
        local ok,problem=pcall(function()
          for text in (payload..'\n'):gmatch('([^\n]*)\n') do line(text) end
        end)
        check(not ok,'error event must stop the read')
        return json.encode({status=200,error=tostring(problem),termination='line_callback_failed',lines=9})
      end
      response(line,'Recovered answer.')
    end
    return json.encode({status=200,termination='eof',lines=10})
  end
  local ok,result=pcall(bot.run,bot,'please continue')
  if code=='context_length_exceeded' then
    check(task_calls==2 and summary_calls==1,'one compaction and one retry, no loop')
    check(memory.session(sid).summarized_until>0,'checkpoint applied durably')
    if repeat_failure then
      check(not ok and tostring(result):find(code,1,true),'second rejection is visible')
    else
      check(ok and result=='Recovered answer.','native parser recovers through actual agent')
    end
  else
    check(not ok and tostring(result):find(code,1,true),'non-overflow refusal is visible')
    check(task_calls==1 and summary_calls==0,'non-overflow refusal does not compact or replay')
    check((memory.session(sid).summarized_until or 0)==0,'non-overflow preserves transcript watermark')
  end
end
run_case('context_length_exceeded',false)
run_case('context_length_exceeded',true)
run_case('rate_limit_exceeded',false)
run_case('invalid_api_key',false)
print('native overflow recovery ok ('..checks..' checks)')
