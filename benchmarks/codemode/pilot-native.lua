-- Private contestant driver. No production entry/configuration is changed.
local json=dofile('lua/vendor/json.lua')
local config=json.decode(assert(host.read_file(host.getenv('WA_BENCHMARK_CONFIG'))))
assert(config.mode=='qualification' or config.mode=='live' and host.getenv('WA_BENCHMARK_APPROVED_MANIFEST')==config.manifest_sha256,'benchmark human limits approval missing')
assert(config.model=='gpt-6.1-sol' and config.reasoning=='low','fixed model/reasoning required')
assert(config.route:match('^http://127%.0%.0%.1:%d+/arms/%x+$'),'private controlled model route required')
local get=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return config.arm~='wasm-current' and 'native' or ''end;return get(k)end
if config.arm=='node-v1' then
 assert(load(assert(host.read_file(config.reference_client)),'benchmark-reference-client'))().install({url=config.reference_url,key=config.reference_key})
end
local adapter=assert(load(assert(host.read_file(config.sandbox_client)),'benchmark-sandbox-client'))().install(config.sandbox)
local memory=dofile('lua/core/memory.lua');memory.setup()
local sid=memory.start_session('','isolated benchmark '..config.arm,{user_id='master'})
-- This private session's actual filesystem is the recorded container, not a
-- managed Git lane. Existing native write/profile/role validation is retained.
local cwd=memory.session_worktree;local workspace=memory.session_workspace
memory.session_worktree=function(id)if id==sid then return '/tmp/work'end;return cwd(id)end
memory.session_workspace=function(id)if id==sid then return {required=true,state='allocated',worktree='/tmp/work',benchmark_container=config.container}end;return workspace(id)end
local provider=dofile('lua/core/provider.lua');assert(provider.set_provider('openai-sub'));assert(provider.set_model(config.model));assert(provider.set_reasoning(config.reasoning));assert(provider.settings().model==config.model)
local agent=dofile('lua/core/agent.lua')
if config.arm=='node-v1' then local all=adapter.tools.all;adapter.tools.all=function(role)local rows=all(role);for _,row in ipairs(rows)do if row['function'].name=='codemode' then row['function'].description=row['function'].description:gsub('Opt%-in Node%-free','Benchmark-only Node-hosted QuickJS-WASI')end end;return rows end end
local bot=agent.new(sid,function(e)
 if e.type=='tool' then adapter.begin_tool(e.name)end
 print(json.encode({event=e}))
 if e.type=='tool_result' then adapter.end_tool(e.name)end
end,'master','master','')
local result=bot:run(config.prompt)
print(json.encode({ok=true,session_id=sid,result=result,arm=config.arm,mode=config.mode}))
