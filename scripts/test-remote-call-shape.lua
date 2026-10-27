-- Model-free contracts for the call shapes weaker models get wrong: remote mis-nesting, the
-- tool_call wrapper, truncated argument JSON, and the commentary preamble. Evidence: a DeepSeek
-- session where 49 of 114 routed calls failed on shape alone (38 mis-nested remote, 6 truncated
-- JSON, 5 non-object arguments). No network, no paid model call.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='fixture-key',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='3',WASM_AGENT_ENVELOPE_MODE='full'}
host.getenv=function(k) if overrides[k]~=nil then return overrides[k] or nil end return real_getenv(k) end
host.http=function() error('network forbidden in this fixture') end
host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local routed=dofile('lua/core/routed_calls.lua')
local contract=dofile('lua/core/json_contract.lua')
local agent=dofile('lua/core/agent.lua')
local nodes=dofile('lua/core/nodes.lua')
local checks=0;local function check(v,why)assert(v,why);checks=checks+1 end
local me=nodes.node_name()
local root=dofile('lua/core/paths.lua').data()..'/remote-shape/'
local file=root..'note.txt';assert(host.write_file(file,'remote-ok\n'))
local sid=memory.start_session('','remote shape',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local function call(name,args,raw)ctx.tool_arguments_json=raw;local r=tools.dispatch(memory,name,args,'master',ctx);ctx.tool_arguments_json=nil;return r end

-- 1. The remote surface: flat, nested (legacy) and the evidence's mis-nested shape.
local remote_schema
for _,s in ipairs(tools.all('master'))do if s['function'].name=='remote' then remote_schema=s['function'] end end
check(remote_schema.parameters.properties.command and remote_schema.parameters.properties.path,'remote schema advertises capability params at the top level')
check(remote_schema.description:find('flat',1,true),'remote description shows the flat form')
local a=assert(tools.remote_arguments({node='n1',capability='bash',command='ls'}))
check(a.node=='n1' and a.capability=='bash' and a.args.command=='ls' and not a.hoisted,'flat form')
a=assert(tools.remote_arguments({node='n1',capability='bash',args={command='ls'}}))
check(a.args.command=='ls' and not a.hoisted,'legacy nested form unchanged')
a=assert(tools.remote_arguments({args={command='select a, b from t',capability='bash',node='openclaw'}},{}))
check(a.node=='openclaw' and a.capability=='bash' and a.args.command=='select a, b from t' and a.args.node==nil and a.args.capability==nil,'evidence mis-nesting hoisted')
check(a.hoisted and #a.hoisted==2,'hoist is reported')
a=assert(tools.remote_arguments({node='n1',args={args={command='ls'},capability='bash'}},{}))
check(a.capability=='bash' and a.args.command=='ls','emptied args.args collapses one level')
a=assert(tools.remote_arguments({node='n1',capability='bash',args='{"command":"ls"}'}))
check(a.args.command=='ls','args sent as a JSON string is parsed')

-- 2. Never guess: ambiguity and conflicts refuse, with the reason.
local _,r=tools.remote_arguments({capability='bash',args={node='a',args={node='b',command='ls'}}},{})
check(r and r.error=='remote_node_ambiguous' and #r.found_in==2,'node found in two places refuses')
local catalog={{type='function',['function']={name='probe',parameters={type='object',properties={node={type='string'}}}}}}
_,r=tools.remote_arguments({capability='probe',args={node='x'}},catalog)
check(r and r.error=='remote_node_ambiguous' and r.found_in=='args','key the capability owns is never hoisted')
_,r=tools.remote_arguments({capability='bash',args={node='x'}},function() error('catalog down') end)
check(r and r.error=='remote_node_ambiguous','unreadable catalogue cannot prove the hoist safe')
_,r=tools.remote_arguments({node='n1',capability='bash',command='ls',args={command='rm -rf /'}})
check(r and r.error=='remote_argument_conflict' and r.key=='command','conflicting duplicate refuses')
check(not json.encode(r):find('rm -rf',1,true),'refusal does not echo the payload')

-- 3. Errors that teach.
r=call('remote',{args={command='ls'}})
check(r.error=='remote_node_required','precise missing-node error, not unknown_node:nil')
check(r.received.top_level_keys[1]=='args' and r.received.args_keys[1]=='command','received keys named, not values')
check(r.example:find('"node"',1,true) and r.note:find('top level',1,true),'minimal correct example given')
local listed=false;for _,n in ipairs(r.online_nodes)do if n==me then listed=true end end
check(listed,'online nodes listed')
r=call('remote',{node='no-such-node',capability='bash',command='true'})
check(r.error=='unknown_node:no-such-node' and type(r.online_nodes)=='table' and r.note,'unknown node keeps its code and lists the online nodes')
r=call('remote',{node=me})
check(r.error=='remote_capability_required','missing capability named')

-- 4. End to end through tool_call, with the evidence's exact mis-nested shape (local node).
local raw='{"arguments":{"args":{"path":'..json.encode(file)..',"capability":"read","node":'..json.encode(me)..'}},"name":"remote"}'
r=call('tool_call',json.decode(raw),raw)
check(r.content=='remote-ok\n','mis-nested remote call now succeeds via hoisting')
check(type(r.normalized)=='string' and r.normalized:find('node from args',1,true),'the repair is reported to the model')
raw='{"name":"remote","arguments":{"node":'..json.encode(me)..',"capability":"read","path":'..json.encode(file)..'}}'
r=call('tool_call',json.decode(raw),raw)
check(r.content=='remote-ok\n' and r.normalized==nil,'flat remote through tool_call, nothing to report')

-- 5. tool_call wrapper normalization.
local readargs=json.encode({path=file})
r=call('tool_call',{name='read',arguments=readargs})
check(r.content=='remote-ok\n' and r.normalized:find('JSON string',1,true),'arguments as a JSON string parsed')
r=call('tool_call',{name='read',path=file})
check(r.content=='remote-ok\n' and r.normalized:find('moved path',1,true),'params beside name moved into arguments')
r=call('tool_call',{name='remote',arguments={capability='read',path=file},node=me})
check(r.content=='remote-ok\n','remote node beside name merged')
r=call('tool_call',{arguments={name='read',arguments={path=file}}})
check(r.content=='remote-ok\n' and r.normalized:find('unwrapped',1,true),'doubled wrapper unwrapped')
r=call('tool_call',{name='tool_call',arguments={name='read',arguments={path=file}}})
check(r.content=='remote-ok\n','tool_call wrapping tool_call unwrapped')
r=call('tool_call',{name='read',arguments={path=file},path='/other'})
check(r.error=='tool_call_arguments_ambiguous' and r.key=='path','same key in both places with different values refuses')
r=call('tool_call',{name='read',arguments='not json'})
check(r.error=='tool_arguments_object_required' and r.received.arguments.type=='string' and r.example,'non-object string: type named, example given')
r=call('tool_call',{name='read',arguments='[1,2]'})
check(r.error=='tool_arguments_object_required','JSON array string is not an object')
r=call('tool_call',{name='read',arguments={1,2}})
check(r.error=='tool_arguments_object_required' and r.received.arguments.type=='array' and r.problem:find('array',1,true),'array arguments named')
r=call('tool_call',{arguments={path=file}})
check(r.error=='tool_arguments_object_required' and r.problem:find('name',1,true),'missing name named')
check(routed.normalize({name='read',arguments={path='x'}}).arguments.path=='x','canonical call passes through untouched')
r=call('tool_call',{name='read',arguments={},calls={}})
check(r.error=='tool_call_forms_are_exclusive','batch forms are not normalized')

-- 6. Truncated JSON: balanced closers only, schema-validated.
check(contract.close_truncated('{"command":"ls"')=='{"command":"ls"}','one missing closer')
check(select(2,contract.close_truncated('{"a":{"b":[1,2'))==']}}','closers in nesting order')
for _,bad in ipairs({'{"command":"ls','{"a":1,','{"a":','{"a":{','{"a":[}','{"a":1}','{broken json'})do
  check(not contract.close_truncated(bad),'refused: '..bad)
end
local list=tools.all('master')
local args,err,completed,note=agent.parse_tool_arguments('tool_call','{"name":"remote","arguments":{"node":"n1","capability":"bash","command":"ls"}',list,'master')
check(args and args.arguments.command=='ls' and completed:sub(-2)=='}}' and note:find('}',1,true),'truncated tool_call repaired when target schema validates')
args,err=agent.parse_tool_arguments('tool_call','{"name":"no_such_tool","arguments":{"x":1}',list,'master')
check(not args and err.error=='invalid_tool_arguments_json','unknown target: no repair')
args,err=agent.parse_tool_arguments('tool_call','{"name":"remote","arguments":{"command":"ls"}',list,'master')
check(not args and err.error=='invalid_tool_arguments_json','repaired object failing the target schema is refused')
args=agent.parse_tool_arguments('read','{"path":"x"',list,'master')
check(args and args.path=='x','direct tool repaired')
args,err=agent.parse_tool_arguments('read','{"path":7',list,'master')
check(not args,'schema mismatch after completion refused')
args,err=agent.parse_tool_arguments('tool_call','{"name":"remote","arguments":{"node":"n1"',list,'master')
check(not args and err.unclosed_braces==2 and err.example:find('"arguments"',1,true) and err.problem,'teaching refusal: problem, unclosed count, example')
overrides.WASM_AGENT_ARGUMENT_REPAIR='0'
args=agent.parse_tool_arguments('read','{"path":"x"',list,'master')
check(not args,'knob disables the repair');overrides.WASM_AGENT_ARGUMENT_REPAIR=nil

-- 7. Prompt: the preamble rule and the flat remote hint are present.
local full=agent.system_prompt('master',nil,nil,list,'full')
check(full:find(agent.PREAMBLE_GUIDELINE,1,true),'preamble guideline in the full prompt')
local progressive=agent.system_prompt('master',nil,nil,tools.envelope('master',ctx),'progressive')
check(progressive:find(agent.PREAMBLE_GUIDELINE,1,true),'preamble guideline in the progressive prompt')
check(progressive:find('tool_call(name="remote", arguments={"node":',1,true),'flat remote shape in the progressive tools section')
check(not agent.system_prompt('master',nil,nil,{},'full'):find(agent.PREAMBLE_GUIDELINE,1,true),'no tools, no preamble rule')

-- 8. Agent loop: OpenAI-chat-style content + tool_calls is stored and emitted as commentary, and a
-- truncated call runs once completed.
local step,sent=0,{}
host.http_stream=function(_,_,_,body)
  step=step+1;sent[step]=json.decode(body)
  if step==1 then return json.encode({status=200,content='Reading the note to confirm the fixture.',stream_complete=true,
    finish_reason='tool_calls',usage={prompt_tokens=10,completion_tokens=5,total_tokens=15},
    tool_calls={{id='trunc',type='function',['function']={name='read',arguments='{"path":'..json.encode(file)}}}}) end
  return json.encode({status=200,content='done',stream_complete=true,finish_reason='stop',usage={prompt_tokens=10,completion_tokens=5,total_tokens=15},tool_calls={}})
end
local run=memory.start_session('','commentary',{user_id='master',node_id='',title='commentary'})
local events={}
check(agent.new(run,function(e)events[#events+1]=e end,'master','master',''):run('read it')=='done','loop finished')
local step_row,tool_row
for _,row in ipairs(memory.session_messages(run,{all=true}))do
  if row.role=='assistant' and row.phase=='commentary' then step_row=row end
  if row.role=='tool' then tool_row=row end
end
check(step_row and step_row.content=='Reading the note to confirm the fixture.','chat-style preamble stored as commentary content')
local phased=false;for _,e in ipairs(events)do if e.type=='step_phase' and e.phase=='commentary' and e.text==step_row.content then phased=true end end
check(phased,'preamble emitted live as commentary')
local replayed=false;for _,m in ipairs(sent[2].messages)do if m.role=='assistant' and m.content=='Reading the note to confirm the fixture.' then replayed=true end end
check(replayed,'preamble replayed to the provider, not dropped')
local out=json.decode(tool_row.content)
check(out.content=='remote-ok\n' and out.normalized:find('appended }',1,true),'truncated call ran once completed, and says so')
print('remote call shape ok ('..checks..' checks, 0 skipped)')
