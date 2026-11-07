-- Which capabilities one turn actually calls (docs/CORE-SPLIT.md, "Call frequency").
--
-- The map in that document decides what to extract by asking how often the work happens; this script
-- is where the "how often" comes from. It wraps every `host.*` function with a counter and runs one
-- scripted turn of the hot loop - prompt assembly, the provider call and tool dispatch - with no
-- provider configured, so the turn takes the existing local fallback instead of making a network
-- call. The counts are therefore the *state and tool* half of a turn, which is the half a component
-- can be given; the model call itself is the gateway's, not a capability.
--
-- No node, no network, no model: the runner's own `--db` and a scratch WASM_AGENT_HOME.
local json = dofile('lua/vendor/json.lua')

local counts, originals = {}, {}
local function install()
  for name, value in pairs(host) do
    if type(value) == 'function' then
      originals[name] = value
      host[name] = function(...) counts[name] = (counts[name] or 0) + 1; return value(...) end
    end
  end
end
local function uninstall()
  for name, value in pairs(originals) do host[name] = value end
end
local function collecting(on)
  if on then install() else uninstall() end
end

-- The provider is hidden before the agent module loads, so the turn takes the local fallback. (A node
-- with a provider would answer the same capabilities and one network call.)
local real_getenv = host.getenv
host.getenv = function(name)
  if name == 'WASM_AGENT_LLM_API_KEY' or name == 'WASM_AGENT_LLM_BASE_URL' or name == 'WASM_AGENT_LLM_MODEL' then
    return nil
  end
  return real_getenv(name)
end

local memory = dofile('lua/core/memory.lua')
memory.setup()
local agent = dofile('lua/core/agent.lua')
local provider = dofile('lua/core/provider.lua')
-- The check runs with the stub still installed: a route this stub cannot hide would be a route the
-- turn would call, and the counting run must make no model call at all.
if provider.configured() then
  host.getenv = real_getenv
  print('SKIP one-turn capability counts: a provider still reports configured, and the counting run must not make a model call')
  return
end

local session = memory.start_session('local', 'chat',
  { id = 'calls-turn', user_id = 'master', node_id = 'bench', title = 'one turn' })
memory.append_turn(session, { role = 'user', content = 'read the file /etc/hostname and tell me what it says' })

local turn = agent.new(session, function() end, 'master', 'master', '')
counts = {}
collecting(true)
local started = host.monotonic_ms()
local ok, err = pcall(turn.run, turn, 'read the file /etc/hostname and tell me what it says')
local elapsed = host.monotonic_ms() - started
collecting(false)
host.getenv = real_getenv

local names = {}
for name in pairs(counts) do names[#names + 1] = name end
table.sort(names, function(a, b) if counts[a] == counts[b] then return a < b end return counts[a] > counts[b] end)
local total = 0
for _, name in ipairs(names) do total = total + counts[name] end
print(string.format('one turn: %s in %d ms, %d host calls', ok and 'ok' or ('failed: ' .. tostring(err)), math.floor(elapsed), math.floor(total)))
for _, name in ipairs(names) do
  print(string.format('%-6d %5.1f%%  %s', math.floor(counts[name]), counts[name] * 100.0 / total, name))
end
