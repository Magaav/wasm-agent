-- A tool call never loses its name; when it does, the harness repairs it.
--
-- Measured on this node: 11/11 session 50f2c555 and 13/11 session 400c7145 both had steps whose calls
-- arrived from the provider with an empty `function.name`. Nothing ran (the refusal was
-- `plugin_not_found:` / `tool_call_name_missing`) and the model, told to "send {name,arguments}",
-- wrapped the payload *inside* its arguments - fourteen refused calls in a row, the whole run dead.
--
-- Two things are proven here, model-free and without a provider:
--   1. the stream assembly keeps a name that arrived in ANY delta (the host side of it is the Rust
--      `tool_call_assembly_tests`, over recorded opencode-go streams);
--   2. a call that still arrives nameless is REPAIRED from its arguments when they fit exactly one
--      tool - it runs, its result carries one sentence saying which tool it became - and otherwise it
--      is refused once, not retryable, with a fix that names the shape that works and never the
--      wrapping that caused the second half of the outage.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='fixture-only',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='4'}
host.getenv=function(k) if overrides[k]~=nil then return overrides[k] end return real_getenv(k) end
host.http=function() error('unexpected network in toolname fixture') end
host.http_stream=function() error('no stream was stubbed for this step') end
local tools=dofile('lua/core/tools.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local agent=dofile('lua/core/agent.lua')
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end

-- ---- 1. the assembly's own guarantee, on the wire shapes that were measured --------------------
-- A nameless call is what the host's reader must never *make*; these are the delta shapes it must
-- keep the name out of. The Rust tests run the same recorded bytes; this is the Lua half of the one
-- fact both loops rely on: a name that arrived is text, and an empty later delta is not a name.
local function assemble(deltas)
  -- The rule `rust/wa-capabilities` implements (`ToolCallAssembly::absorb` + `merge_name`), over the
  -- same delta list, so a change on either side has to be made twice on purpose.
  local calls={}
  for _,body in ipairs(deltas)do
    for _,call in ipairs(((body.choices or {})[1] or {}).delta.tool_calls or {})do
      local index=call.index or 0
      local slot=calls[index]
      if not slot then slot={id='',['function']={name='',arguments=''}};calls[index]=slot end
      if call.id and call.id~='' then slot.id=call.id end
      local name=(call['function'] or {}).name
      if name and name~='' then
        local had=slot['function'].name
        if had=='' or not had:find(name,1,true) then slot['function'].name=had..name end
        if name:find(had,1,true)==1 and #name>#had then slot['function'].name=name end
      end
      local fragment=(call['function'] or {}).arguments
      if fragment and fragment~='' then slot['function'].arguments=slot['function'].arguments..fragment end
    end
  end
  return calls
end
local function chunk(tool_calls)
  return {choices={{index=0,delta={tool_calls=tool_calls}}}}
end
local kept=assemble({
  chunk({{index=0,id='call_a',['function']={name='codemode',arguments=''}}}),
  chunk({{index=0,['function']={name='',arguments='{"code":'}}}),
  chunk({{index=0,['function']={name='',arguments='"return 1"}'}}}),
})
check(kept[0]['function'].name=='codemode','an empty name in a later delta keeps the name that arrived')
check(kept[0]['function'].arguments=='{"code":"return 1"}','arguments still assemble across deltas')
local split=assemble({
  chunk({{index=0,id='call_b',['function']={name='co',arguments=''}}}),
  chunk({{index=0,['function']={name='demode',arguments='{"code":"1"}'}}}),
})
check(split[0]['function'].name=='codemode','a name split across deltas is assembled, not replaced')

-- ---- 2. the repair: the arguments identify exactly one tool -----------------------------------
local shown=tools.envelope('master',{session_id='fixture',user_id='master',role='master'})
local function call(name,args)
  local id=(type(name)=='string' and name~='') and name or 'none'
  return {id='call_'..id,type='function',['function']={name=name,arguments=json.encode(args)}}
end
local calls,repairs=provider.repair_calls({call('',{code='return 1'})},shown,tools.all('master'))
check(calls[1]['function'].name=='codemode','{code} is repaired to codemode')
check(repairs['call_none'].named=='codemode' and repairs['call_none'].name_missing,'the repair is recorded as a recovered name')
calls,repairs=provider.repair_calls({call('',{command='echo ok'})},shown,tools.all('master'))
check(calls[1]['function'].name=='bash','{command} is repaired to bash, the tool this turn showed')
calls=provider.repair_calls({call('',{command='echo ok',timeout_seconds=5})},shown,tools.all('master'))
check(calls[1]['function'].name=='bash','optional keys a tool declares do not break the match')
-- the model's wrapped form: {name,arguments} sent as the arguments themselves
calls,repairs=provider.repair_calls({call('',{name='bash',arguments={command='echo wrapped'}})},shown,tools.all('master'))
check(calls[1]['function'].name=='bash','the wrapped form is unwrapped to its own tool')
check(calls[1]['function'].arguments=='{"command":"echo wrapped"}','the wrapper is gone and the inner arguments are kept')
check(repairs['call_none'].how=='wrapped','the wrapped form is recorded as such')
-- The wrapper cannot smuggle in a tool this turn never offered: the envelope stays the boundary.
calls,repairs=provider.repair_calls({call('',{name='integrate',arguments={}})} ,shown,tools.all('master'))
check(calls[1]['function'].name==provider.UNNAMED_CALL,'a wrapped name the turn did not offer is not run')
calls,repairs=provider.repair_calls({call('',{name='no_such_tool_anywhere',arguments={}})},shown,tools.all('master'))
check(calls[1]['function'].name==provider.UNNAMED_CALL,'a wrapped name no tool has is not run')
-- a name nothing identifies is NOT guessed
calls,repairs=provider.repair_calls({call('',{query='Laura'})},shown,tools.all('master'))
check(calls[1]['function'].name==provider.UNNAMED_CALL and repairs['call_none'].named==nil,
  'arguments several tools accept identify nothing and are refused')
calls,repairs=provider.repair_calls({call('',{path='/etc/hostname',offset=1,limit=10})},shown,tools.all('master'))
check(calls[1]['function'].name=='read','{path,offset,limit} fits read alone and is repaired')
-- the empty object fits twenty-odd schemas: no guess, and no crash
calls,repairs=provider.repair_calls({call('',{})},shown,tools.all('master'))
check(calls[1]['function'].name==provider.UNNAMED_CALL,'{} identifies nothing')
-- a call that already has a name is untouched
calls,repairs=provider.repair_calls({call('bash',{command='echo ok'})},shown,tools.all('master'))
check(calls[1]['function'].name=='bash' and next(repairs)==nil,'a named call is not repaired at all')
-- a replay that passes no tool list keeps the pure boundary behaviour
calls=provider.repair_calls({call('',{code='return 1'})})
check(calls[1]['function'].name==provider.UNNAMED_CALL,'without a tool list nothing is inferred')

-- ---- 3. the refusal says what to do, once, and is not retryable -------------------------------
local refusal=dofile('lua/core/refusal.lua')
local _,unnamed=provider.repair_calls({call('',{query='Laura'})},shown,tools.all('master'))
local error_result=refusal.finalize(provider.malformed_call_error(unnamed['call_none']),
  {tool=provider.UNNAMED_CALL,role='master',input='{"query":"Laura"}',site='the tool loop'})
check(error_result.error=='tool_call_name_missing','the refusal keeps its code')
check(error_result.retryable==false,'the refusal is not retryable: re-issuing the same nameless call cannot help')
check(not tostring(error_result.fix):lower():find('arguments:{',1,true)
  and not tostring(error_result.fix):find('{name:',1,true),
  'the fix never suggests wrapping {name,arguments} inside the arguments: '..tostring(error_result.fix))
check(tostring(error_result.fix):find('in the tool call itself',1,true)~=nil,
  'the fix says the tool is named in the call itself: '..tostring(error_result.fix))
check(tostring(error_result.fix):find('codemode',1,true)~=nil
  and tostring(error_result.fix):find('{"code":"..."}',1,true)~=nil,
  'the fix carries a concrete example: '..tostring(error_result.fix))

-- ---- 4. the loop: a repaired call RUNS, its result says which tool it became -------------------
local function run_loop(kind,answer_calls)
  local step=0
  host.http_stream=function()
    step=step+1
    if step==1 then
      return json.encode({status=200,content='',stream_complete=true,finish_reason='tool_calls',
        usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls=answer_calls})
    end
    return json.encode({status=200,content='fixture finished',stream_complete=true,finish_reason='stop',
      usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls={}})
  end
  local sid=memory.start_session('','toolname-'..kind,{user_id='master',node_id='',title='toolname-'..kind})
  local events={}
  local reply=agent.new(sid,function(event) events[#events+1]=event end,'master','master','')
    :run('run the fixture call')
  local rows={}
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do rows[#rows+1]=row end
  return reply,rows,events
end
local reply,rows=run_loop('bash',{call('',{command='echo toolname-repaired'})})
check(reply=='fixture finished','the run finished after a repaired call')
local assistant_row,tool_row
for _,row in ipairs(rows) do
  if row.role=='assistant' and type(row.tool_calls)=='table' and #row.tool_calls>0 then assistant_row=row end
  if row.role=='tool' then tool_row=row end
end
check(assistant_row~=nil and assistant_row.tool_calls[1]['function'].name=='bash',
  'the stored call carries the recovered name, not the unnamed placeholder')
check(tool_row~=nil and tool_row.tool_name=='bash','the repaired call ran as bash')
local tool_result=json.decode(tool_row.content)
check(tostring(tool_result.stdout):find('toolname-repaired',1,true)~=nil,'the command really ran')
check(tool_result.normalized=='repaired: the tool name was missing; the arguments fit only bash',
  'the result carries the one-line note: '..tostring(tool_result.normalized))

local reply2,rows2=run_loop('wrapped',{call('',{name='bash',arguments={command='echo wrapped-form'}})})
check(reply2=='fixture finished','the run finished after a wrapped call')
local wrapped_result
for _,row in ipairs(rows2) do
  if row.role=='tool' then wrapped_result=json.decode(row.content) end
end
check(tostring(wrapped_result.stdout):find('wrapped-form',1,true)~=nil,'the unwrapped arguments ran')
check(wrapped_result.normalized=='repaired: the tool name was missing; the arguments fit only bash',
  'the wrapped call carries the same note')

local reply3,rows3=run_loop('refused',{call('',{query='Laura'})})
local refused_result,refused_name
for _,row in ipairs(rows3) do
  if row.role=='tool' then refused_result=json.decode(row.content);refused_name=row.tool_name end
end
check(reply3=='fixture finished','the run continues after one refusal and the model answers')
check(refused_name==provider.UNNAMED_CALL and refused_result.error=='tool_call_name_missing',
  'a call nothing identifies is still refused by name')
check(refused_result.retryable==false,'and that refusal is not retryable')

print(string.format('toolname repair: %d checks, 0 failed, 0 skipped',checks))
