-- The full built system prompt and declared tool list, pinned as goldens RECORDED FROM a27490af
-- (rel review r2, item 4). Two things this catches that a hash of a rebuilt block cannot:
--   * the goldens were recorded by scripts/generate-prompt-goldens.lua running ON a27490af, so they
--     describe what that commit really sent - not what this tree believes it sent;
--   * the bytes compared are agent:build_context's own, the same call a first request makes, so a
--     section, guideline or tool ordering that changed anywhere in the stack shows up here.
--
-- The one named difference (rel review r3, item 2): upstream put the "conform: no profile for ..."
-- notice INSIDE the prompt, once per process, so a27490af's first recorded case carries it; commit
-- 568ed30c moved it to the operator log, so this branch's prompts carry none. The golden KEEPS base's
-- line and this test compares it exactly, naming the case - nothing is stripped silently.
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
-- The prompt depends on the PROCESS cwd through the skills walk (lua/core/skills.lua scans the tree and
-- its parents up to the repo root), so a golden is only meaningful for ONE cwd: the tree root, which is
-- where scripts/fast.sh runs its rows. Anywhere else this refuses BY NAME rather than comparing a
-- different node shape (found the hard way: a recording made from the mission directory carried no
-- skills block at all, and the row then failed on a prompt that was right).
local TREE = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local CWD = dofile('lua/core/platform.lua').cwd()
ok(CWD == TREE, 'this test must run from the tree root (cwd=' .. tostring(CWD) .. ', tree=' .. tostring(TREE) .. ')')
local ROOT = TREE .. '/fixtures/prompt-golden'
local real = host.getenv

-- One build, exactly as the first request makes it.
-- '' (an empty string) in env means UNSET for that key: the arm-B rows must not inherit a switch the
-- caller happened to export, or a gate run with WASM_AGENT_RAW_CODE=only would assert the wrong node
-- (measured: this test failed that way when the runner exported only).
local INSTRUCTIONS = golden.instruction_env()
local function build(env, subagent)
  host.getenv = function(k)
    if env[k] == '' then return nil end
    if env[k] ~= nil then return env[k] end
    if INSTRUCTIONS[k] ~= nil then return INSTRUCTIONS[k] end
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

-- The ONE case whose a27490af bytes carry the conform notice (measured: the first case a recording
-- process builds, because raw_code.TRANSPORT_NOTICE_SHOWN shows it once per process).
local NOTICE_CASE = 'progressive-only'

-- ---------------------------------------------------------------- the goldens, every explicit mode
for _, case in ipairs(cases) do
  local path = ROOT .. '/' .. case.name .. '.json'
  local body = host.read_file(path)
  ok(type(body) == 'string' and body ~= '', 'the golden exists: ' .. path .. ' (regenerate with scripts/generate-prompt-goldens.lua on a27490af)')
  local want = json.decode(body)
  local built = build({ WASM_AGENT_RAW_CODE = case.mode, WASM_AGENT_ENVELOPE_MODE = case.envelope }, case.subagent)
  local got = golden.normalize(built)
  -- Nothing is normalised away (rel review r3, item 2): the bytes compare EXACTLY, and the one case
  -- where a27490af differs is named rather than hidden. Measured on the real tree, not assumed: a27490af
  -- appends the conform notice to the prompt for the FIRST case it builds in a process
  -- (raw_code.TRANSPORT_NOTICE_SHOWN shows it once), which in this case list is progressive-only.
  local base_notices = #golden.notice_lines(want.system)
  local built_notices = #golden.notice_lines(got.system)
  eq(built_notices, 0, case.name .. ': this branch puts no conform notice line in the prompt')
  if case.name == NOTICE_CASE then
    eq(base_notices, 1, NOTICE_CASE .. ': a27490af carried the conform notice in this prompt (the one case)')
    eq(golden.without_notices(got.system), golden.without_notices(want.system),
      NOTICE_CASE .. ': and every other byte of that prompt matches a27490af')
  else
    eq(base_notices, 0, case.name .. ': a27490af carried no conform notice in this prompt')
    eq(got.system, want.system, case.name .. ': the full built system prompt matches a27490af')
  end
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
