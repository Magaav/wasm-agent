-- Private subprocess fixture. All inference and queue effects are explicitly fake.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local config=json.decode(assert(host.read_file(host.getenv('WA_WAVE_PROBE_CONFIG'))))
assert(config.label=='PRIVATE FAKE QUEUE ONLY','private fixture required')
local runtime=json.decode(host.runtime_info());local wave=dofile('lua/core/wave_autoflush.lua')
local ctx={role='master',user_id='master',session_id=config.parent,run_id='native-probe'}
-- Deterministic native admission fixture; execution origin and physical image
-- remain the ACTUAL native process values, never stubbed.
host.subagent=function(action)assert(action=='list');return json.encode({subagents=assert(config.views)})end
if config.kind=='unchanged' then
 local r=wave.control(config.args,ctx);assert(r.held and not r.ok and r.error:find('wave_candidate_missing_corrupt_or_unchanged',1,true),json.encode(r));print(json.encode({ok=true,held=true,error=r.error}));return
end
assert(runtime.run_origin=='job','native job context required')
local old=dofile;local provider=dofile('lua/core/provider.lua');local getenv=host.getenv
host.getenv=function(k)
 if k=='WASM_AGENT_LLM_API_KEY' then return 'private-fixture' end
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 if k=='WASM_AGENT_CODEMODE' then return 'off' end
 return getenv(k)
end
host.http=function()error('network forbidden')end;host.http_stream=host.http
provider.complete_with=function()return {content='job fixture final',finish_reason='stop',usage={prompt_tokens=1,completion_tokens=1,total_tokens=2}} end
local calls=0;local baseline=config.baseline and assert(load(assert(host.read_file(config.baseline)),'@old-job-oracle'))()
dofile=function(p)
 if p=='lua/core/provider.lua' then return provider end
 if p=='lua/core/wave_autoflush.lua' and baseline then return baseline end
 if p=='lua/core/update.lua' then return {request_bound=function()calls=calls+1;return {queued=true,label='FAKE'}end} end
 return old(p)
end
if not baseline then
 assert(wave.control({action='enable',revision=0},ctx).not_applicable,'job cannot enable self deployment')
 assert(wave.admission_guard(ctx)==nil,'operational job is not fenced')
end
local agent=old('lua/core/agent.lua');local bot=agent.new(config.parent,function()end,'master','master','');local bot_reply=bot:run('operational job in wasm-agent environment')
assert(calls==(baseline and 1 or 0),'native job queue oracle: '..json.encode({calls=calls,reply=bot_reply}))
print(json.encode({ok=true,origin=runtime.run_origin,queue_calls=calls,label='FAKE queue, not installation'}))
