-- Records the prompt goldens the parity test checks against, FROM THE TREE IT RUNS IN.
--
--   WASM_AGENT_LUA_ROOT=<tree> WA_SCRIPT=scripts/generate-prompt-goldens.lua wa --db <scratch>/db.sqlite
--
-- Run it on a27490af (a worktree of that commit, never this tree) to record what a27490af really built;
-- the goldens under fixtures/prompt-golden/ are those bytes. Re-running it on this tree must produce the
-- same files for every EXPLICIT mode - that is what "byte-identical" means - and it refuses to write
-- when it did not build every case, so a partial run cannot replace a golden with an empty one.
if not host then error('this script runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this script refuses to run (' .. reason .. ')') end

local golden = dofile('scripts/lib/prompt-golden.lua')
local json = golden.json
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local agent = dofile('lua/core/agent.lua')
local cases = dofile('scripts/lib/prompt-golden-cases.lua')

-- Record from the tree root, and only from there: the prompt depends on the process cwd through the
-- skills walk, so a recording made anywhere else describes a different node (scripts/test-prompt-golden.lua
-- refuses the same way).
local TREE = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local CWD = dofile('lua/core/platform.lua').cwd()
if CWD ~= TREE then
  error('run this from the tree root (cwd=' .. tostring(CWD) .. ', tree=' .. tostring(TREE) .. ')', 0)
end
local OUT = os.getenv('WA_GOLDEN_OUT') or (TREE .. '/fixtures/prompt-golden')
local real = host.getenv
local written, refused = 0, {}

local function run_case(case)
  local instructions = golden.instruction_env()
  local function env(k)
    if k == 'WASM_AGENT_RAW_CODE' then return case.mode end
    if k == 'WASM_AGENT_ENVELOPE_MODE' then return case.envelope end
    if instructions[k] ~= nil then return instructions[k] end
    return real(k)
  end
  host.getenv = env
  local ok, value = pcall(function()
    local sid = memory.start_session('', 'golden ' .. case.name, { user_id = 'master', title = 'golden ' .. case.name })
    local opts = {}
    if case.subagent then
      local allowed = {}
      for _, name in ipairs(case.subagent.allowed or {}) do allowed[name] = true end
      opts.subagent = { id = case.subagent.id, allowed = allowed, allowed_tools = case.subagent.allowed or {} }
    end
    local bot = agent.new(sid, function() end, 'master', 'master', '', opts)
    local messages = bot:build_context()
    return { system = messages[1].content, tools = bot.tool_list or {} }
  end)
  host.getenv = real
  if not ok then return nil, tostring(value) end
  return golden.normalize(value)
end

for _, case in ipairs(cases) do
  local normalized, why = run_case(case)
  if not normalized then
    refused[#refused + 1] = case.name .. ': ' .. tostring(why)
  else
    local body = golden.encode(normalized)
    local wrote, err = pcall(function()
      host.write_file(OUT .. '/' .. case.name .. '.json', body .. '\n')
    end)
    if not wrote then refused[#refused + 1] = case.name .. ': write failed: ' .. tostring(err)
    else written = written + 1 end
  end
end
if #refused > 0 then
  error('golden generation incomplete: ' .. table.concat(refused, '; '), 0)
end
print('prompt goldens written (' .. written .. ' files in ' .. OUT .. ')')
