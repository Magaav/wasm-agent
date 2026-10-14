-- Private benchmark runtime entry. The production engine remains Node-free.
-- This entry currently admits only deterministic, loopback, model-free fixtures.
local M={}
function M.run(prompt,on_event)
 assert(host.getenv('WA_BENCHMARK_MODEL_FREE')=='1','paid benchmark runtime entry not admitted')
 local arm=host.getenv('WA_BENCHMARK_ARM')
 assert(arm=='wasm-current' or arm=='node-v1' or arm=='rust-v2','native benchmark arm required')
 local url=host.getenv('WASM_AGENT_VAULT_URL') or ''
 assert(url:match('^http://127%.0%.0%.1:%d+/arms/%x+$'),'fixed loopback model-free route required')
 local get=host.getenv
 host.getenv=function(k)
  if k=='WASM_AGENT_CODEMODE' then return arm~='wasm-current' and 'native' or '' end
  return get(k)
 end
 if arm=='node-v1' then
  local code=assert(host.read_file(get('WA_CODEMODE_CONTROLLER_CLIENT')))
  assert(load(code,'reference-client'))().install({url=get('WA_CODEMODE_CONTROLLER_URL'),key=get('WA_CODEMODE_CONTROLLER_KEY')})
  local dofile_original=dofile
  dofile=function(name)
   local value=dofile_original(name)
   if name=='lua/core/tools.lua' then
    local original=value.catalog
    value.catalog=function(role)
     local list=original(role)
     for _,schema in ipairs(list)do
      if schema['function'].name=='codemode' then schema['function'].description=schema['function'].description:gsub('Opt%-in Node%-free','Benchmark-only Node-hosted QuickJS-WASI') end
     end
     return list
    end
   end
   return value
  end
 end
 local memory=dofile('lua/core/memory.lua');memory.setup()
 local provider=dofile('lua/core/provider.lua')
 assert(provider.set_provider('openai-sub'))
 assert(provider.set_model(assert(get('WASM_AGENT_LLM_MODEL'))))
 assert(provider.set_reasoning(assert(get('WASM_AGENT_REASONING'))))
 assert(provider.settings().model==get('WASM_AGENT_LLM_MODEL'),'private provider model pin failed')
 local agent=dofile('lua/core/agent.lua')
 local sid=memory.start_session('','model-free benchmark route',{user_id='master'})
 local bot=agent.new(sid,on_event,'master','master','')
 return bot:run(prompt),sid
end
return M
