-- The full built system prompt and declared tool list, pinned as goldens RECORDED FROM a27490af
-- (rel review r2, item 4). Two things this catches that a hash of a rebuilt block cannot:
--   * the goldens were recorded by scripts/generate-prompt-goldens.lua running ON a27490af, so they
--     describe what that commit really sent - not what this tree believes it sent;
--   * the bytes compared are agent:build_context's own, the same call a first request makes, so a
--     section, guideline or tool ordering that changed anywhere in the stack shows up here.
--
-- The one named exception: upstream put the "conform: no profile for ..." notice INSIDE the prompt;
-- commit 568ed30c moved it to the operator log (review MUST 4), so the helper drops exactly that line
-- and this test asserts the built prompt carries none of it.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local golden = dofile('scripts/lib/prompt-golden.lua')
local cases = dofile('scripts/lib/prompt-golden-cases.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local agent = dofile('lua/core/agent.lua')
local tools = dofile('lua/core/tools.lua')
local raw = dofile('lua/core/raw_code.lua')
local TICK = string.char(96)

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    local at = 1
    while at <= #got and at <= #want and got:sub(at, at) == want:sub(at, at) do at = at + 1 end
    error(string.format('%s\n  first difference at byte %d\n  got:  %q\n  want: %q', label, at,
      got:sub(math.max(1, at - 60), at + 60), want:sub(math.max(1, at - 60), at + 60)), 0)
  end
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then error(label .. ': missing ' .. needle, 0) end
end
local function has_not(text, needle, label)
  checks = checks + 1
  if tostring(text):find(needle, 1, true) then error(label .. ': must not carry ' .. needle, 0) end
end
local function names_of(list)
  local names = {}
  for _, item in ipairs(list or {}) do names[#names + 1] = item['function'].name end
  table.sort(names)
  return table.concat(names, ',')
end

-- Fixtures live under the TREE this script runs from (WASM_AGENT_LUA_ROOT), never under the process
-- cwd: the same rule scripts/test-mcp-vault-approval.lua follows.
local ROOT = (host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/fixtures/prompt-golden'
local real = host.getenv

-- One build, exactly as the first request makes it.
-- '' (an empty string) in env means UNSET for that key: the arm-B rows must not inherit a switch the
-- caller happened to export, or a gate run with WASM_AGENT_RAW_CODE=only would assert the wrong node
-- (measured: this test failed that way when the runner exported only).
local function build(env, subagent)
  host.getenv = function(k)
    if env[k] == '' then return nil end
    if env[k] ~= nil then return env[k] end
    return real(k)
  end
  local okc, value = pcall(function()
    local sid = memory.start_session('', 'golden check ' .. tostring(env.WASM_AGENT_RAW_CODE), { user_id = 'master', title = 'golden check' })
    local opts = {}
    if subagent then
      local allowed = {}
      for _, name in ipairs(subagent.allowed or {}) do allowed[name] = true end
      opts.subagent = { id = subagent.id, allowed = allowed, allowed_tools = subagent.allowed or {} }
    end
    local bot = agent.new(sid, function() end, 'master', 'master', '', opts)
    local messages = bot:build_context()
    return { system = messages[1].content, tools = bot.tool_list or {}, bot = bot }
  end)
  host.getenv = real
  if not okc then error(value, 0) end
  return value
end

-- ---------------------------------------------------------------- the goldens, every explicit mode
for _, case in ipairs(cases) do
  local path = ROOT .. '/' .. case.name .. '.json'
  local body = host.read_file(path)
  ok(type(body) == 'string' and body ~= '', 'the golden exists: ' .. path .. ' (regenerate with scripts/generate-prompt-goldens.lua on a27490af)')
  local want = json.decode(body)
  local built = build({ WASM_AGENT_RAW_CODE = case.mode, WASM_AGENT_ENVELOPE_MODE = case.envelope }, case.subagent)
  local got = golden.normalize(built)
  -- The notice upstream printed in the prompt is gone from the BUILT bytes, not only from the golden:
  -- if it ever returns, this fires instead of being silently normalised away.
  eq(got.notice_lines_removed, 0, case.name .. ': the built prompt carries no conform notice line')
  eq(got.system, want.system, case.name .. ': the full built system prompt matches a27490af')
  eq(json.encode(got.tools), json.encode(want.tools), case.name .. ': the declared tool list matches a27490af')
end

-- ---------------------------------------------------------------- a default node is arm B
-- No switch at all: the provider row decides (model_profile.builtin_transport), the same row a real
-- node reads. On a tool-calling provider the node is native, and a native node - in EITHER envelope, as
-- a master OR a child - declares the run tool alone, is sent the run-tool guidance, and is not sent the
-- codemode guidance.
local provider = dofile('lua/core/provider.lua')
local profile = dofile('lua/core/model_profile.lua')
local settings_ok, settings = pcall(provider.settings)
ok(settings_ok and type(settings) == 'table', 'the node has a provider row to decide from')
local tool_calling = profile.builtin_transport(settings.provider) == profile.TOOL_CALL
ok(type(tool_calling) == 'boolean', 'the provider row answers yes or no, never unknown')
if tool_calling then
  local TOOL_CALL = raw.guidance_for('tool_call')
  local CODEMODE_LINE = 'one ' .. TICK .. 'codemode' .. TICK .. ' call runs JavaScript'
  for _, envelope in ipairs({ 'progressive', 'full' }) do
    local master = build({ WASM_AGENT_RAW_CODE = '', WASM_AGENT_ENVELOPE_MODE = envelope }, nil)
    eq(names_of(master.tools), 'run', 'default ' .. envelope .. ': a master declares the run tool alone')
    eq(master.bot.codeact_transport, 'tool_call', 'default ' .. envelope .. ': the tool-call transport')
    has(master.system, TOOL_CALL, 'default ' .. envelope .. ': the run-tool guidance')
    has(master.system, 'One run(code) can do a whole step', 'default ' .. envelope .. ': the batching sentence')
    has_not(master.system, CODEMODE_LINE, 'default ' .. envelope .. ': no codemode guidance')

    local child = build({ WASM_AGENT_RAW_CODE = '', WASM_AGENT_ENVELOPE_MODE = envelope },
      { id = 'orchestration-worker', allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } })
    eq(names_of(child.tools), 'run', 'default ' .. envelope .. ': a child declares the run tool alone')
    has(child.system, TOOL_CALL, 'default ' .. envelope .. ': the child gets the run-tool guidance')
    has_not(child.system, CODEMODE_LINE, 'default ' .. envelope .. ': the child gets no codemode guidance')
  end
else
  -- Not a silent pass: this node's provider keeps the block default, which the goldens above already
  -- cover, and the arm-B rows are recorded as not applicable BY NAME.
  print('prompt golden: ' .. tostring(settings.provider) .. ' has no tool-call row, arm-B rows did not apply')
end

-- ---------------------------------------------------------------- the two cited differences
-- A child whose profile allows code mode keeps exactly the tools its profile allows. a27490af emptied
-- this list, but not because of the mode: its A/B arm answered "fence" whenever WASM_AGENT_RAW_CODE was
-- unset, and that arm's allow-list (no tools) filtered the child; 1468bc53 made the arm read WA_AB_ARM.
local code_child = build({ WASM_AGENT_RAW_CODE = 'codemode', WASM_AGENT_ENVELOPE_MODE = 'full' },
  { id = 'orchestration-worker', allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } })
eq(names_of(code_child.tools), 'bash,codemode,edit,ls,read,run,write',
  'codemode: a child keeps exactly the tools its profile allows')

-- A child that cannot use code mode keeps the tools it has, so the native narrowing can never take a
-- child's only way to act.
local read_only = build({ WASM_AGENT_RAW_CODE = 'native', WASM_AGENT_ENVELOPE_MODE = 'full' },
  { id = 'explore', allowed = { 'read', 'bash', 'ls' } })
eq(names_of(read_only.tools), 'bash,ls,read', 'a native child without code mode keeps the tools it was given')

-- A child that CAN run code declares the one door, in the full envelope too (rel review r2, item 3).
local native_child = build({ WASM_AGENT_RAW_CODE = 'native', WASM_AGENT_ENVELOPE_MODE = 'full' },
  { id = 'orchestration-worker', allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } })
eq(names_of(native_child.tools), 'run', 'a native child that can run code declares the run tool alone')

print('prompt golden ok (' .. checks .. ' checks)')
