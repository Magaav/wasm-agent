-- The prompt a node on this path BUILDS: one guidance sentence, the run tool alone, no codemode
-- guidance - in both envelopes, for a master and for a child.
--
-- The per-mode goldens this file used to compare against are gone with the modes (review r1 item 6): a
--27490af recorded only the six explicit values of WASM_AGENT_RAW_CODE, every one of which this build
-- refuses by name, and it had no native case to record. What remains is asserted on the bytes
-- agent:build_context really produces, which is the same call a first request makes.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local golden = dofile('scripts/lib/prompt-golden.lua')
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

-- The per-mode goldens are GONE with the modes (Victor 21/11): a27490af recorded only the six explicit
-- values of WASM_AGENT_RAW_CODE, every one of which this build refuses by name, and it has NO native case
-- to compare against (its own mode() answered 'only' for that value). What this file still proves is the
-- half that matters for the cache: the bytes a thread on this path gets, asserted below. The three
-- model-facing strings this path is built from were compared byte-for-byte against 97251587 when the
-- switch was removed (docs/missions/reports/one-run-path.md). A native golden recorded FROM THIS RELEASE
-- is the follow-up that pins it from here on.


-- ---------------------------------------------------------------- a default node is arm B
-- No switch at all: the provider ROW decides (model_profile.builtin_transport), the same row a real node
-- reads. On a tool-calling provider the node is native, and a native node - in EITHER envelope, as a
-- master OR a child - declares the run tool alone, is sent the run-tool guidance, and is not sent the
-- codemode guidance.
--
-- These rows do not SKIP (rel review r3, item 2), and they are not made to pass by a stub: measured, a
-- stubbed provider.settings in THIS copy never reaches raw_code, which dofiles its own copy - the build
-- kept answering native under a stub that named a provider with no row. So the row is ASSERTED instead:
-- the node's own provider must answer tool_call, and if it ever does not, this test FAILS by name rather
-- than quietly printing "did not apply". That is honest because the decision is a literal table in the
-- tree, not machine state: model_profile.DEFAULT_TRANSPORTS has one entry, opencode-go -> tool_call, and
-- provider.active() resolves to the first provider when a remembered id matches none.
local provider = dofile('lua/core/provider.lua')
local profile = dofile('lua/core/model_profile.lua')
local settings_ok, settings = pcall(provider.settings)
ok(settings_ok and type(settings) == 'table', 'the node has a provider row to decide from')
eq(profile.builtin_transport(settings.provider), profile.TOOL_CALL,
  'the node provider (' .. tostring(settings.provider) .. ') has a tool_call row, so the arm-B rows apply')

do
  local TOOL_CALL = raw.guidance_for()
  local CODEMODE_LINE = 'one ' .. TICK .. 'codemode' .. TICK .. ' call runs JavaScript'
  for _, envelope in ipairs({ 'progressive', 'full' }) do
    local master = build({ WASM_AGENT_RAW_CODE = '', WASM_AGENT_ENVELOPE_MODE = envelope }, nil)
    eq(master.bot.codeact_transport, 'tool_call', 'arm B ' .. envelope .. ': the tool-call transport')
    eq(names_of(master.tools), 'run', 'arm B ' .. envelope .. ': a master declares the run tool alone')
    has(master.system, TOOL_CALL, 'arm B ' .. envelope .. ': the run-tool guidance')
    has(master.system, 'One run(code) can do a whole step', 'arm B ' .. envelope .. ': the batching sentence')
    has_not(master.system, CODEMODE_LINE, 'arm B ' .. envelope .. ': no codemode guidance')

    local child = build({ WASM_AGENT_RAW_CODE = '', WASM_AGENT_ENVELOPE_MODE = envelope },
      { id = 'orchestration-worker', allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } })
    eq(names_of(child.tools), 'run', 'arm B ' .. envelope .. ': a child declares the run tool alone')
    has(child.system, TOOL_CALL, 'arm B ' .. envelope .. ': the child gets the run-tool guidance')
    has_not(child.system, CODEMODE_LINE, 'arm B ' .. envelope .. ': the child gets no codemode guidance')
  end
end

-- ---------------------------------------------------------------- the two cited differences
-- A child whose profile allows code mode keeps exactly the tools its profile allows. a27490af emptied
-- this list, but not because of the mode: its A/B arm answered "fence" whenever WASM_AGENT_RAW_CODE was
-- unset, and that arm's allow-list (no tools) filtered the child; 1468bc53 made the arm read WA_AB_ARM.
-- The two rows that named a mode here described the removed codemode surface; the child that CAN run
-- code is asserted by the arm-B rows above (it declares the run tool alone). What survives is the child
-- that cannot code at all: the one door must never take its only way to act.

-- child's only way to act.
local read_only = build({ WASM_AGENT_RAW_CODE = '', WASM_AGENT_ENVELOPE_MODE = 'full' },
  { id = 'explore', allowed = { 'read', 'bash', 'ls' } })
eq(names_of(read_only.tools), 'bash,ls,read', 'a native child without code mode keeps the tools it was given')



print('prompt golden ok (' .. checks .. ' checks)')
