local json = dofile('lua/vendor/json.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '', scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('refuses: ' .. reason) end
local env_get = host.getenv
host.getenv = function(k)
  if k == 'WASM_AGENT_CODEMODE' then return 'native' end
  if k == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  if k == 'WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k == 'WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  return env_get(k)
end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local agentlib = dofile('lua/core/agent.lua')
local sid = memory.start_session('', 'probe', { user_id = 'master' })
local ok, agent = pcall(agentlib.new, sid, function() end, 'master', 'master', '', { orchestration = false })
if not ok then print('agent.new failed: ' .. tostring(agent)); return end
local built, messages = pcall(function() return agent:build_context() end)
if not built then print('build_context failed: ' .. tostring(messages)); return end
local system = tostring((messages[1] or {}).content or '')
print('system_bytes ' .. #system)
print('system_sha ' .. host.sha256(system))
print('rules ' .. tostring(select(2, system:gsub('\n%- ', ''))))
print('has_preamble ' .. tostring(system:find('one short sentence', 1, true) ~= nil))
local tools = agent.tool_list or {}
print('tools ' .. #tools)
for _, schema in ipairs(tools) do
  local f = schema['function'] or {}
  print(string.format('tool %s desc_bytes %d', tostring(f.name), #tostring(f.description or '')))
end
