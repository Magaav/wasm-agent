-- Model-free test of candidate-1 planning instructions and actual loop grouping.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local overrides={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='fixture-only',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_BATCHING_GUIDANCE='0',WASM_AGENT_MAX_TOOL_ROUNDS='3'}
host.getenv=function(k) if overrides[k]~=nil then return overrides[k] end return real_getenv(k) end
host.http=function() error('unexpected network in batching fixture') end
host.http_stream=host.http
local tools=dofile('lua/core/tools.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local agent=dofile('lua/core/agent.lua')
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local list=tools.all('master')
local original_schemas=json.encode(list)
local bot={subagent={id='fixture',instructions='',limits={}},role='master'}
local control=agent.system_prompt('master',nil,nil,list)
local control_child=agent.subagent_system_prompt(bot,list)
local mark='Batching candidate 1:'
check(not control:find(mark,1,true) and not control_child:find(mark,1,true),'control prompt unchanged without switch')
overrides.WASM_AGENT_BATCHING_GUIDANCE='1'
local treatment=agent.system_prompt('master',nil,nil,list)
local treatment_child=agent.subagent_system_prompt(bot,list)
check(treatment:find(mark,1,true) and treatment_child:find(mark,1,true),'treatment reaches both prompt builders without launching children')
check(treatment:find('one read_many (up to eight ranges)',1,true),'prefer existing ranged read tool')
check(treatment:find('interpreting a result',1,true),'dependent reads stay sequential')
check(treatment:find('Keep writes, dependent commands',1,true),'writes and dependent commands stay ordered')
check(treatment:find('not permission to overlap arbitrary shell commands',1,true),'no unsafe executor authority')
check(treatment:find('per-file errors',1,true) and treatment:find('continuation/version addresses',1,true),'exact evidence and failures retained')
check(treatment:find('never recursively inventory retained solver worktrees',1,true),'discovery noise is scoped out')
check(not treatment:find('When multiple tool actions are independent',1,true),'old and new batching guidance not duplicated')
local read_only=agent.system_prompt('master',nil,nil,tools.all_for({read=true},'master'))
check(not read_only:find('read_many',1,true) and not read_only:find('Scope shell discovery',1,true),'guidance names only available readers/shell')
local none=agent.subagent_system_prompt(bot,{})
check(not none:find(mark,1,true) and not none:find('Before requesting tools',1,true),'no unavailable tools on reasoning-only profile')
check(json.encode(list)==original_schemas,'treatment does not alter any schemas')
overrides.WASM_AGENT_BATCHING_GUIDANCE='false'
check(agent.system_prompt('master',nil,nil,list)==control,'only literal1 opts in; exact control bytes retained')
local root=dofile('lua/core/paths.lua').data()..'/batching/'
local first,second=root..'first.txt',root..'second.txt'
assert(host.write_file(first,'alpha\nbeta\n'));assert(host.write_file(second,'second\n'))
local requests={{path=first,offset=2,limit=1},{path=second},{path=root..'missing.txt'}}
local calls={
  {id='range-group',type='function',['function']={name='read_many',arguments=json.encode({requests=requests})}},
  {id='single-range',type='function',['function']={name='read',arguments=json.encode({path=first,offset=1,limit=1})}},
}
local function execute(mode)
  overrides.WASM_AGENT_BATCHING_GUIDANCE=mode
  local step,sent=0,{}
  host.http_stream=function(_,_,_,body)
    step=step+1;sent[step]=json.decode(body)
    if step==1 then return json.encode({status=200,content='',stream_complete=true,finish_reason='tool_calls',
      usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls=calls}) end
    return json.encode({status=200,content='verified fixture',stream_complete=true,finish_reason='stop',
      usage={prompt_tokens=100,completion_tokens=20,total_tokens=120},tool_calls={}})
  end
  local sid=memory.start_session('','batch-'..mode,{user_id='master',node_id='',title='batch-'..mode})
  check(agent.new(sid,function() end,'master','master',''):run('read the known ranges')=='verified fixture','mock loop finished normally')
  check(step==2,'two calls returned together need one follow-up model request')
  local results={}
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do if row.role=='tool' then results[#results+1]=row end end
  check(#results==2 and results[1].tool_call_id=='range-group' and results[2].tool_call_id=='single-range','group keeps original call ids and result order')
  local batch=json.decode(results[1].content)
  check(batch.failed==1 and #batch.results==3 and batch.results[1].content=='beta\n' and batch.results[2].content=='second\n'
    and batch.results[3].error=='not_found','all ranges and partial failures survive batching')
  check(json.decode(results[2].content).content=='alpha\n','sibling exact result retained')
  local starts,ends={},{}
  for _,e in ipairs(telemetry.events(sid,0,100).events) do
    if e.kind=='tool' and e.phase=='start' then starts[#starts+1]=e.payload end
    if e.kind=='tool' and e.phase=='end' then ends[#ends+1]=e.payload end
  end
  check(#starts==2 and #ends==2,'tool telemetry has matched boundaries')
  check(starts[1].tool_group_id==starts[2].tool_group_id and starts[1].tool_group_size==2
    and starts[1].tool_group_index==1 and starts[2].tool_group_index==2,'response group identity/count/order measured')
  check(starts[1].read_many_ranges==3 and starts[2].read_many_ranges==nil,'range count distinct from tool call count')
  check(starts[1].batching_guidance==(mode=='1' and 'candidate-1' or 'control')
    and ends[1].batching_guidance==starts[1].batching_guidance,'both telemetry boundaries name actual treatment')
  check(ends[1].ok==false,'partial read failure not disguised as group success')
  check(not results[1].content:find('batching_guidance',1,true),'instrumentation does not enter tool results')
  return sent[1].messages[1].content,results
end
local a,ar=execute('0');local b,br=execute('1')
check(not a:find(mark,1,true) and b:find(mark,1,true),'actual serialized request differs in intended instruction only')
check(ar[1].content==br[1].content and ar[2].content==br[2].content,'control/treatment read outputs byte-identical')
print('batching guidance ok ('..checks..' checks; zero paid model calls)')
