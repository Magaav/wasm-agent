-- The raw code channel (WASM_AGENT_RAW_CODE, lua/core/raw_code.lua), through the real agent loop with a
-- stubbed provider stream: no network, no paid call.
--
-- Switch on: a ```js run block runs as the codemode call it stands for (same rows, same result view as a
-- codemode tool call), its observation reaches the next request, an ordinary code block is text, two
-- run blocks run the last and say so, a block the reply ended inside or an empty one is refused and
-- never runs, and a cut stream runs nothing. `stop`: the request carries the stop sequence and a reply
-- whose fence it ate still runs. Switch off: the same reply is plain text, the request has no stop
-- sequence and no guidance sentence.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local raw=nil
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='raw-code-fixture',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='6'}
host.getenv=function(k)
  if k=='WASM_AGENT_RAW_CODE' then return raw end
  if k=='WASM_AGENT_CODEMODE' then return nil end
  if overrides[k]~=nil then return overrides[k] end
  return real_getenv(k)
end
host.http=function() error('network forbidden in the raw-code fixture') end
local replies,requests={},{}
host.http_stream=function(_,_,_,body)
  requests[#requests+1]=json.decode(body)
  local r=table.remove(replies,1) or {content='fixture done'}
  return json.encode({status=200,content=r.content or '',stream_complete=r.stream_complete~=false,
    finish_reason=r.finish_reason or (r.stream_complete==false and json.null or 'stop'),
    usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls=r.tool_calls or {}})
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local original=dofile
dofile=function(p) if p=='lua/core/tools.lua' then return tools end return original(p) end
local agent=original('lua/core/agent.lua');dofile=original
local raw_code=dofile('lua/core/raw_code.lua')
local tool_output=dofile('lua/core/tool_output.lua')
local dispatched={}
local real_dispatch=tools.dispatch
tools.dispatch=function(m,name,args,role,ctx)
  if name=='codemode' then dispatched[#dispatched+1]=args.code end
  return real_dispatch(m,name,args,role,ctx)
end
local function guidance_in(text)
  local tool = text:find(raw_code.guidance_for('tool_call'), 1, true) ~= nil
  local block = text:find(raw_code.guidance_for('block'), 1, true) ~= nil
  return tool, block
end
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end

local runs=0
local function run(mode,script)
  raw=mode;replies=script;requests={};dispatched={};runs=runs+1
  local sid=memory.start_session('','raw-code-'..runs,{user_id='master',node_id='',title='raw-code-'..runs})
  local events={}
  local ok,reply=pcall(function()
    return agent.new(sid,function(event) events[#events+1]=event end,'master','master',''):run('compute it')
  end)
  local rows={}
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do rows[#rows+1]=row end
  local assistant,tool
  for _,row in ipairs(rows) do
    if row.role=='assistant' and type(row.tool_calls)=='table' and #row.tool_calls>0 then assistant=row end
    if row.role=='tool' then tool=row end
  end
  return {ok=ok,reply=reply,rows=rows,assistant=assistant,tool=tool,events=events,requests=requests,dispatched=dispatched}
end
local function tool_message(request,id)
  for _,m in ipairs(request.messages) do if m.role=='tool' and m.tool_call_id==id then return m end end
end
local function keys(t) local out={} for k in pairs(t or {}) do out[#out+1]=tostring(k) end table.sort(out) return table.concat(out,',') end

-- 1. switch on: a run block is a codemode call ---------------------------------------------------------
local on=run('1',{{content='Let me compute.\n```js run\nreturn 6*7;\n```'},{content='42 it is'}})
check(on.ok and on.reply=='42 it is','the run finished after the run block: '..tostring(on.reply))
-- rel r5: this branch has ONE guidance source per transport (raw_code.guidance_for), so this
-- assertion is stricter than main's: exactly one transport sentence, never both and never none.
local tool_line, block_line = guidance_in(on.requests[1].messages[1].content)
check((tool_line or block_line) and not (tool_line and block_line),
  'switch on: exactly one guidance sentence, the one its transport needs')
check(on.requests[1].stop==nil,'WASM_AGENT_RAW_CODE=1 sends no stop sequence (detection only)')
check(#on.dispatched==1 and on.dispatched[1]=='return 6*7;','the block ran once, as codemode, with exactly its code')
local call=on.assistant and on.assistant.tool_calls[1]
check(call and call['function'].name=='codemode' and json.decode(call['function'].arguments).code=='return 6*7;','the transcript holds a codemode call with {code=<block>}')
check(call.id:match('^call_raw_%x+$'),'the synthesized call id names the raw channel: '..tostring(call.id))
check(on.assistant.content=='Let me compute.','the stored step text is the thought, without the block: '..json.encode(on.assistant.content))
check(on.tool and on.tool.tool_name=='codemode' and on.tool.tool_call_id==call.id and on.tool.ok~=false and on.tool.ok~=0,'the tool row answers the synthesized call')
local seen=tool_message(on.requests[2],call.id)
check(seen and seen.content==on.tool.content,'the next request carries the observation, byte-identical to the stored result')
check(on.tool.content:find('42',1,true),'the observation holds the script value: '..on.tool.content:sub(1,200))
local emitted
for _,e in ipairs(on.events) do if e.type=='tool' and e.name=='codemode' then emitted=e end end
check(emitted and emitted.arguments.code=='return 6*7;','the UI gets the same codemode tool event')

-- the same step as a codemode tool call: the same shapes
local native=run('1',{{content='Let me compute.',finish_reason='tool_calls',tool_calls={{id='call_native1',type='function',
  ['function']={name='codemode',arguments=json.encode({code='return 6*7;'})}}}},{content='42 it is'}})
check(keys(native.assistant)==keys(on.assistant),'assistant row fields match a codemode call: '..keys(on.assistant)..' vs '..keys(native.assistant))
check(keys(native.assistant.tool_calls[1])==keys(call) and keys(native.assistant.tool_calls[1]['function'])==keys(call['function']),'tool call record fields match')
check(native.assistant.phase==on.assistant.phase,'the step is classified the same way (phase '..tostring(on.assistant.phase)..')')
check(keys(native.tool)==keys(on.tool),'tool row fields match')
local a,b=tool_output.parse_view(native.tool.content),tool_output.parse_view(on.tool.content)
check(a and b and keys(a)==keys(b) and a.ok==b.ok,'the result view has the codemode shape: '..keys(b))
check(not on.tool.content:find('[raw code]',1,true),'a clean single block adds no note')

-- 2. an ordinary code block is text -------------------------------------------------------------------
local text='Example:\n```js\nreturn 1;\n```\nThat is all.'
local plain=run('1',{{content=text}})
check(plain.ok and plain.reply==text and #plain.dispatched==0 and plain.tool==nil and #plain.requests==1,'a non-run code block does not execute; the turn ends as a plain answer')

-- 3. two run blocks: both run, in the order they were written, each result labelled (#D, 19/11) -------
-- The old rule ran only the last block and said so; the measurement was a model writing three blocks and
-- re-issuing two of them because they never ran, so every block is now an action of its own.
local two=run('1',{{content='a\n```js run\nreturn 1;\n```\nb\n```js run\nreturn 2;\n```\nOutput: 2'},{content='done'}})
check(#two.dispatched==2 and two.dispatched[1]=='return 1;' and two.dispatched[2]=='return 2;',
  'both run blocks ran, in the order the model wrote them: '..json.encode(two.dispatched))
check(#two.assistant.tool_calls==2,'the step formed one codemode call per run block')
check(two.tool.content:find('[raw code] run block 2 of 2',1,true),'the last result says which block it answers')
check(two.tool.content:find('dropped',1,true) and not two.assistant.content:find('Output',1,true),'text after the last run block is dropped and said so')
check(tool_message(two.requests[2],two.assistant.tool_calls[2].id).content==two.tool.content,'the note reaches the model with its own result')
local labelled={}
for _,row in ipairs(two.rows) do if row.role=='tool' and raw_code.is_raw(row.tool_call_id) then labelled[#labelled+1]=tostring(row.content) end end
check(#labelled==2 and labelled[1]:find('[raw code] run block 1 of 2',1,true) and labelled[2]:find('[raw code] run block 2 of 2',1,true),
  'the two results are labelled in the order they ran')

-- 4. unterminated block: refused, never executed -----------------------------------------------------
local cut=run('1',{{content='Writing.\n```js run\nawait tools.write({path:"x",content:"never"});'},{content='done'}})
check(#cut.dispatched==0,'an unterminated run block never runs')
check(cut.tool and cut.tool.tool_name=='codemode' and cut.tool.content:find('raw_code_unterminated',1,true),'it is answered as a failed codemode call: '..tostring(cut.tool and cut.tool.content):sub(1,200))
check(cut.tool.ok==false or cut.tool.ok==0,'the refused call is a failed tool row')

-- a cut stream inside a run block: the step's own cut path, nothing runs
local stream=run('1',{{content='```js run\nreturn 1;',stream_complete=false},{content='done'}})
check(#stream.dispatched==0 and stream.reply=='done','a stream cut inside a run block runs nothing; the step is re-driven')
local notice=stream.requests[2].messages[#stream.requests[2].messages].content
check(notice:find('were NOT executed',1,true),'the re-drive notice says the call was not executed')

-- 5. empty block: refused -------------------------------------------------------------------------------
local empty=run('1',{{content='```js run\n\n```'},{content='done'}})
check(#empty.dispatched==0 and empty.tool.content:find('raw_code_empty',1,true) and empty.tool.content:find('empty run block',1,true),'an empty run block is refused')

-- 6. stop mode: the stop sequence goes out; a reply whose fence it ate still runs -------------------
local stop=run('stop',{{content='```js run\nreturn 5;'},{content='five'}})
check(type(stop.requests[1].stop)=='table' and stop.requests[1].stop[1]=='\n```\n','WASM_AGENT_RAW_CODE=stop sends the stop sequence')
check(#stop.dispatched==1 and stop.dispatched[1]=='return 5;' and stop.reply=='five','a run block whose closing fence the stop sequence ate runs')
local fence=run('stop',{{content='see:\n```sh\nls'}})
check(fence.reply=='see:\n```sh\nls\n```' and #fence.dispatched==0,'an ordinary block the stop sequence cut gets its fence back and stays text')

-- 7. switch off: the same reply is plain text -------------------------------------------------------
local off=run('codemode',{{content='Let me compute.\n```js run\nreturn 6*7;\n```'}})
check(off.reply=='Let me compute.\n```js run\nreturn 6*7;\n```' and #off.dispatched==0 and off.tool==nil,'switch off: a run block is plain text and nothing runs')
check(off.requests[1].stop==nil and not off.requests[1].messages[1].content:find(raw_code.GUIDANCE,1,true),'switch off: no stop sequence, no guidance sentence')
check(not json.encode(off.requests[1]):find('js run',1,true),'switch off: the request never mentions run blocks')

-- 8. several blocks in one message run in order, and the batch stops at the first failure (#D, 19/11) --
-- A block after a failure is answered, not dropped (the protocol needs a result per call id) and never
-- run: running it on top of a failure is worse than not running it.
local boom=run('1',{{content='a\n```js run\nreturn 1;\n```\nb\n```js run\nthrow new Error("boom");\n```\nc\n```js run\nreturn 3;\n```'},{content='after'}})
check(#boom.dispatched==2 and boom.dispatched[1]=='return 1;' and boom.dispatched[2]:find('throw new Error',1,true),
  'the batch stopped at the failing block: '..json.encode(boom.dispatched))
local result_rows={}
for _,row in ipairs(boom.rows) do if row.role=='tool' then result_rows[#result_rows+1]=tostring(row.content) end end
check(#result_rows==3,'every call of the step has a result, in order ('..#result_rows..' rows)')
check(result_rows[3]:find('run_block_not_run',1,true) and result_rows[3]:find('run block 3 of 3',1,true),
  'the block after the failure says it did not run and why: '..result_rows[3]:sub(1,220))
-- Round 3, item 7: the mark is the block that FAILED, and the earliest one - `raw_failed_at =
-- raw_failed_at or raw_entry.index` in lua/core/agent.lua. Here only block 2 fails, so this pins the wiring;
-- the `or` itself is defensive (the batch stops at the first failure, so nothing later can move the mark).
check(result_rows[3]:find('run block 2 failed first',1,true),
  'the skipped block names the block that failed, not its own number: '..result_rows[3]:sub(1,260))
check(boom.reply=='after','the turn went on after the failed batch: '..tostring(boom.reply))

print(json.encode({ok=true,checks=checks,paid_calls=0}))
