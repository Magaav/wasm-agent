-- Hermetic regression tests, not a task benchmark. Run only with a scratch
-- WASM_AGENT_HOME and --db; HTTP is replaced before any agent can run.
local json=dofile('lua/vendor/json.lua')
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_MAX_TOOL_ROUNDS='3'}
host.getenv=function(key) if overrides[key]~=nil then return overrides[key] end return native_getenv(key) end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http
local memory=dofile('lua/core/memory.lua'); memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local output=dofile('lua/core/tool_output.lua')
local tools=dofile('lua/core/tools.lua')
local provider=dofile('lua/core/provider.lua')
local cases=0
local function check(ok,message) assert(ok,message); cases=cases+1 end
local function session(title) return memory.start_session('',title,{user_id='master',node_id='',title=title}) end

local raw={prompt_tokens=1000,completion_tokens=200,total_tokens=1200,
  prompt_tokens_details={cached_tokens=800},completion_tokens_details={reasoning_tokens=150}}
local normalized=telemetry.normalize(raw,{input=1,output=2,cacheRead=.1})
check(normalized.input==200 and normalized.cacheRead==800 and normalized.total==1200,'disjoint Pi token accounting')
check(normalized.reasoning==150 and math.abs(normalized.cost-.00068)<1e-10,'reasoning is subset, not additional output cost')
check(not telemetry.normalize(nil).known,'missing usage is unknown')
check(not telemetry.normalize({prompt_tokens=1,completion_tokens=1}).cache_known,'unreported cache is unknown')
check(not telemetry.normalize(raw).cost_known,'unpriced tokens are not free')
check(telemetry.estimate_messages({{role='user',content={{type='image_url',image_url={url=string.rep('b',1000000)}}}}})<1300,'image estimate is not base64 length')
check(telemetry.normalize({prompt_tokens=1,completion_tokens=1,prompt_cache_hit_tokens=3}).issue=='cache_exceeds_input','inconsistent provider accounting visible')
local sid=session('durability')
local span=telemetry.start({session_id=sid,turn_id='turn'},'llm',{model='fixture'})
telemetry.finish(span,{ok=true,usage=raw,normalized=normalized})
local summary=telemetry.start({session_id=sid,turn_id='turn'},'summary',{})
telemetry.finish(summary,{ok=false,error='summary_failed',normalized=telemetry.normalize(nil)})
telemetry.start({session_id=sid,turn_id='unfinished'},'llm',{})
telemetry.event(sid,'turn','','turn','end',{outcome='answered'})
local report=dofile('lua/core/telemetry.lua').snapshot(sid)
check(report.total.calls==2 and report.compaction.calls==1 and report.total.failed==1,'summary failures included in durable totals')
check(report.turns==1 and report.pending==1 and report.total.missing_usage==1,'unfinished starts and turn outcomes survive module restart')
local page=telemetry.events(sid,0,2)
check(#page.events==2 and page.has_more and telemetry.events(sid,page.next_cursor,2).events[1].seq>page.next_cursor,'export cursor does not skip or repeat')

local text=string.rep('line data\n',9000)..'FATAL AT END'
local projected=json.decode(output.project('bash',{code=7,stdout=text}))
check(projected.omitted and projected.stdout:find('FATAL AT END',1,true),'bash preserves tail in bounded view')
local chunks,cursor={},1
repeat
  local page=output.read(projected.full_result.sha256,cursor,12000)
  check(not page.error and page.next_offset>cursor,'artifact pagination advances')
  chunks[#chunks+1]=page.content; cursor=page.next_offset
until cursor>projected.full_result.bytes
check(json.decode(table.concat(chunks)).stdout==text,'artifact reconstructs complete output byte-for-byte')
local unicode='€漢字🚀'; local ref=output.store(unicode); local reconstructed=''; cursor=1
repeat local part=output.read(ref.sha256,cursor,1); check(part.next_offset>cursor and utf8.len(part.content)~=nil,'small unicode pages remain valid and advance'); reconstructed=reconstructed..part.content; cursor=part.next_offset until cursor>#unicode
check(reconstructed==unicode,'unicode artifact retrieval is lossless')
check(not output.outcome('bash',{code=7}) and not output.outcome('write',{ok=false}),'failed effects are failed tools')
check(output.outcome('grep',{code=1}),'no-match is a valid search')
check(tools.dispatch(memory,'tool_result',{sha256=projected.full_result.sha256},'guest').error~=nil,'artifact retrieval role gate')
local write=host.write_file
host.write_file=function() return false end
local read=host.read_file; host.read_file=function() return 'old text' end
check(tools.dispatch(memory,'edit',{path='test',old_text='old',new_text='new'},'master').error=='write_failed','failed edit cannot report success')
host.read_file=read; host.write_file=write
check(tools.dispatch(memory,'edit',{path='test',old_text='',new_text='new'},'master').error=='old_text_required','empty edit cannot mutate by accident')

-- Inject one shared provider into the real agent, without changing its source.
local original_dofile=dofile
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib=dofile('lua/core/agent.lua')
dofile=original_dofile
local history=session('coverage')
for i=1,620 do memory.append_turn(history,{role=i%2==1 and 'user' or 'assistant',content='ROW_'..i}) end
local bot=agentlib.new(history,function() end,'master','master','')
local context=bot:build_context()
check(#context==621 and context[2].content=='ROW_1','all unsummarized rows included beyond 500')
local call={id='retrieval',type='function',['function']={name='bash',arguments='{}'}}
memory.append_turn(history,{role='assistant',content='',tool_calls={call},reasoning='saved reasoning'})
memory.append_turn(history,{role='tool',tool_call_id=call.id,tool_name='bash',content=json.encode(projected)})
context=bot:build_context()
check(context[#context].content==json.encode(projected),'rebuild keeps exact persisted tool view')
check(context[#context-1].reasoning_content=='saved reasoning','provider-required reasoning replay')

local budget=provider.budget
provider.budget=function() return {context=32000,reserve=4000,keep=4000,output=16000,source='test'} end
bot.context_tokens=function() return 31000,'test' end
provider.complete_with=function() return {content='',tool_calls={},finish_reason='stop'} end
local old=memory.session(history).summarized_until
check(not bot:maybe_compact(context) and memory.session(history).summarized_until==old,'empty summary cannot advance watermark')
provider.complete_with=function(_,messages)
  check(messages[2].content:find('ROW_1',1,true)~=nil,'summary starts at first unsummarized row')
  return {content='A valid checkpoint',tool_calls={},finish_reason='stop',usage=raw}
end
check(bot:maybe_compact(context) and memory.session(history).summarized_until>old,'valid summary advances coverage')
local backlog=session('bounded-summary')
local instruction='BEGIN '..string.rep('important instruction ',200)..' END'
local arguments=json.encode({path='fixture.txt',content=string.rep('exact argument ',600)})
memory.append_turn(backlog,{role='user',content=instruction})
memory.append_turn(backlog,{role='assistant',content='',tool_calls={{id='write-fixture',type='function',['function']={name='write',arguments=arguments}}}})
memory.append_turn(backlog,{role='tool',tool_call_id='write-fixture',tool_name='write',content='{"ok":true}'})
for i=1,120 do memory.append_turn(backlog,{role=i%2==1 and 'user' or 'assistant',content=string.rep('past work ',200)}) end
provider.complete_with=function(_,messages)
  check(messages[2].content:find(instruction,1,true)~=nil,'compaction preserves full user instructions')
  check(messages[2].content:find(json.encode(arguments):sub(2,-2),1,true)~=nil,'compaction preserves full tool arguments')
  check(#json.encode(messages)/4<32000,'summary of oversized backlog fits its own model window')
  return {content='checkpoint',finish_reason='stop',tool_calls={}}
end
local backlog_bot=agentlib.new(backlog,function() end,'master','master','')
check(backlog_bot:maybe_compact(),'oversized backlog compacted in a bounded prefix')
check(#memory.session_turns(backlog,{all=true,after_seq=memory.session(backlog).summarized_until})>20,'uncovered backlog is not falsely marked summarized')
provider.budget=budget

-- Exercise the real request serializer/accounting and real agent tool loop.
provider=original_dofile('lua/core/provider.lua')
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
agentlib=original_dofile('lua/core/agent.lua'); dofile=original_dofile
local calls=0; local sent={}
host.http_stream=function(_,_,_,body)
  calls=calls+1; sent[calls]=json.decode(body)
  if calls==1 then return json.encode({status=200,content='',reasoning='think',stream_complete=true,finish_reason='tool_calls',usage=raw,
    tool_calls={{id='bad-write',type='function',['function']={name='write',arguments='{broken json'}}}}) end
  return json.encode({status=200,content=string.rep('ANSWER',2000),reasoning='final thought',stream_complete=true,finish_reason='stop',usage=raw,tool_calls={}})
end
local run=session('real-loop'); bot=agentlib.new(run,function() end,'master','master','')
local reply=bot:turn('test the accounting without network')
check(#reply==12000,'final reply is not silently truncated at 8000')
check(sent[1].thinking.type=='enabled' and sent[1].reasoning_effort=='high' and sent[1].max_tokens>0,'Pi-compatible reasoning and output budget actually sent')
check(sent[2].messages[#sent[2].messages].content:find('invalid_tool_arguments_json',1,true)~=nil,'malformed JSON rejected before effects')
local final=memory.session_turns(run,{limit=1})[1]
check(final.reasoning=='final thought','final reasoning persisted for continuation')
local events=telemetry.events(run,0,100).events
local first_request; for _,event in ipairs(events) do if event.kind=='llm' and event.phase=='start' then first_request=event; break end end
check(first_request.payload.request_hash==host.sha256(json.encode(sent[1])),'hash matches exact streaming request including stream options')
check(memory.session_turns(run,{all=true})[1].id==first_request.turn_id,'request trace links to its actual user turn')
report=original_dofile('lua/core/telemetry.lua').snapshot(run)
check(report.total.calls==2 and report.tool_failures==1 and report.turns==1,'real loop durable outcomes')
check(report.total.prompt==2000 and report.total.input==400,'actual loop uses disjoint cache categories')
host.http_stream=function() return json.encode({status=200,content='partial',stream_complete=false,tool_calls={},usage=raw}) end
local interrupted=agentlib.new(session('interrupted-stream'),function() end,'master','master','')
check(not pcall(interrupted.turn,interrupted,'test interruption'),'incomplete stream cannot become a completed turn')
print('observability ok: '..cases..' assertions; zero model calls')
