-- Actual wasm agent loop and native tools with a recorded, model-free response script.
local json=dofile('lua/vendor/json.lua')
local real_getenv=host.getenv
local override={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='fixture-only',WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-fixture-model-store',WASM_AGENT_CONTEXT_BUDGET='0'}
host.getenv=function(k)if override[k]~=nil then return override[k] end;return real_getenv(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local mcp=dofile('lua/core/mcp.lua')
local tools=dofile('lua/core/tools.lua')
local agent=dofile('lua/core/agent.lua')
local paths=dofile('lua/core/paths.lua')
local out,source,arm=assert(host.getenv('WEB_SHADOW_OUT')),assert(host.getenv('WEB_SHADOW_SOURCE')),assert(host.getenv('WEB_SHADOW_ARM'))
local fixture=json.decode(assert(host.read_file(source..'/benchmarks/web-envelope/simple.json')))
local function now()return host.monotonic_ms() end
local setup_started=now()
local sid=memory.start_session('','web-shadow',{user_id='master',node_id='',title='web-shadow'})
local search_name,read_name,log_dir
if arm=='current' then
 local definition={id='fixture',transport='stdio',program=assert(host.getenv('WA_NODE')),args={source..'/scripts/fixtures/web-shadow-peer.mjs','--binding-json',json.encode({cache_dir=out..'/backend'})},timeout_seconds=10,tools={search='read',read='read'}}
 local ctx={role='master',session_id=sid,user_id='master'}
 assert(mcp.control({action='put',definition=definition,expected_revision=mcp.inventory().revision},ctx).ok)
 assert(mcp.control({action='probe',id='fixture',expected_revision=mcp.inventory().revision},ctx).ok)
 assert(mcp.control({action='enable',id='fixture',expected_revision=mcp.inventory().revision},ctx).ok)
 search_name=mcp.namespace('fixture','search');read_name=mcp.namespace('fixture','read');log_dir=out..'/backend'
else
 search_name='web_search';read_name='web_read';log_dir=paths.cache()..'/web/'..host.sha256('master\0'..sid)
end
local setup_ms=now()-setup_started
local captures,step={},0
local function data(row)
 local v=json.decode(row.content)
 if v.result_json then local r=json.decode(v.result_json);return r.structuredContent or json.decode(r.content[1].text) end
 if v.result then return v.result.structuredContent or json.decode(v.result.content[1].text) end
 return v
end
local function results()
 local out={};for _,r in ipairs(memory.session_messages(sid,{all=true}))do if r.role=='tool' then out[#out+1]={name=r.tool_name,data=data(r)} end end;return out
end
local function call(name,args,id)
 if arm~='current' then return {id=id,type='function',['function']={name='tool_call',arguments=json.encode({name=name,arguments=args})}} end
 return {id=id,type='function',['function']={name=name,arguments=json.encode(args)}}
end
host.http_stream=function(_,_,_,body)
 step=step+1;captures[#captures+1]=json.raw(body);local prior=results();local stage=step-(arm=='current' and 0 or 1);local calls,content={},nil
 if arm~='current' and step==1 then calls={{id='discover',type='function',['function']={name='tool_search',arguments=json.encode({query='web search read',limit=2})}}}
 elseif stage==1 then calls={call(search_name,{query=fixture.query,limit=2},'search')}
 elseif stage==2 then calls={call(read_name,{url=fixture.sources[1].url},'read-a'),call(read_name,{url=fixture.sources[2].url},'read-b')}
 elseif stage==3 then
  local a,b=prior[#prior-1].data,prior[#prior].data;assert(a.content:find('stdio',1,true));assert(b.content:find('tools/list',1,true));content='MCP uses stdio locally; tools/list discovers tools. Sources: '..a.url..' '..b.url
 elseif stage==4 then local b=prior[#prior].data;calls={call(read_name,{ref=b.ref},'followup')}
 elseif stage==5 then assert(prior[#prior].data.content:find('notifications/initialized',1,true));content='Initialization completes with notifications/initialized. Source: '..fixture.sources[2].url
 else error('unexpected_fixture_model_step') end
 -- No real provider usage exists. Zero mock counters are NOT a token/cost measurement.
 return json.encode({status=200,content=content or '',stream_complete=true,finish_reason=content and 'stop' or 'tool_calls',tool_calls=calls,usage={prompt_tokens=0,completion_tokens=0,total_tokens=0}})
end
local bot=agent.new(sid,function()end,'master','master','')
local started=now();local answer=bot:run(fixture.question);local first_ms=now()-started
local follow_started=now();local followup=bot:run(fixture.followup);local followup_ms=now()-follow_started
local final_rows=memory.session_messages(sid,{all=true});local native_results={};for _,row in ipairs(final_rows)do if row.role=='tool' then native_results[#native_results+1]={name=row.tool_name,content=row.content} end end
local cleanup={};if mcp.close_read_sessions then cleanup=mcp.close_read_sessions();for _,r in ipairs(cleanup)do assert(r.settled and r.settled.settled,'read session cleanup unverified')end end
local receipt={ok=true,arm=arm,setup_ms=setup_ms,first_ms=first_ms,followup_ms=followup_ms,answer=answer,followup=followup,requests=captures,tool_results=native_results,protocol_log=log_dir..'/protocol.jsonl',fetch_log=log_dir..'/fetch.jsonl',cleanup=cleanup,provider_calls=0,model_mode='recorded response script; no inference'}
assert(host.write_file(out..'/arm.json',json.encode(receipt)))
print('web shadow '..arm..' ok')
