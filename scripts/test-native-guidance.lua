-- Item 1 (rel review r2) with ONE PATH (Victor 21/11): a node receives ONE source of guidance.
--
-- The prompt a node builds must carry the run-tool sentence - raw_code.guidance_for(), with the batching
-- instruction riding inside it - and must NOT carry the codemode guidance ("one `codemode` call runs
-- JavaScript...", "Calling a tool directly also works"): this node offers one door, and a model reads every
-- door it is shown. Asserted on the REAL built system prompt (agent:build_context), never on a rebuilt
-- block, for both envelopes and a subagent.
--
-- There is no mode switch to set here any more: a node that sets WASM_AGENT_RAW_CODE refuses at start
-- (lua/core/raw_code.lua, M.switch_refusal), which scripts/test-one-run-path.lua pins separately.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local agent = dofile('lua/core/agent.lua')
local raw = dofile('lua/core/raw_code.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then error(label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')', 0) end
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then error(label .. ': missing ' .. needle, 0) end
end
local function has_not(text, needle, label)
  checks = checks + 1
  if tostring(text):find(needle, 1, true) then error(label .. ': must not carry ' .. needle, 0) end
end
local function count(text, needle)
  local n, at = 0, 1
  while true do
    local found = tostring(text):find(needle, at, true)
    if not found then return n end
    n = n + 1
    at = found + #needle
  end
end

local real = host.getenv
local function with(envelope, fn)
  host.getenv = function(k)
    if k == 'WASM_AGENT_RAW_CODE' then return nil end
    if k == 'WASM_AGENT_ENVELOPE_MODE' then return envelope end
    return real(k)
  end
  local okc, value_or_error = pcall(fn)
  host.getenv = real
  if not okc then error(value_or_error, 0) end
  return value_or_error
end

local TOOL_CALL = raw.guidance_for()
local FORBIDDEN = {
  'one `codemode` call runs JavaScript',
  'Calling a tool directly also works',
  'instead of a codemode call',
  'run a script by ending your message',
}

local function build(envelope, subagent)
  return with(envelope, function()
    local sid = memory.start_session('', 'native guidance ' .. tostring(envelope),
      { user_id = 'master', title = 'native guidance' })
    local opts = {}
    if subagent == 'explore' then
      opts.subagent = { id = 'explore', allowed = { read = true, bash = true, run = true },
        allowed_tools = { 'read', 'bash', 'run' } }
    elseif subagent then
      opts.subagent = { id = 'orchestration-worker',
        allowed = { read = true, bash = true, run = true, codemode = true, write = true, edit = true },
        allowed_tools = { 'read', 'bash', 'run', 'codemode', 'write', 'edit' } }
    end
    local bot = agent.new(sid, function() end, 'master', 'master', '', opts)
    local messages = bot:build_context()
    local names = {}
    for _, item in ipairs(bot.tool_list or {}) do names[#names + 1] = tostring(item['function'].name) end
    table.sort(names)
    return { system = tostring(messages[1].content), tools = table.concat(names, ','),
      transport = bot.codeact_transport }
  end)
end

for _, envelope in ipairs({ 'progressive', 'full' }) do
  local master = build(envelope, false)
  -- Which tools a node DECLARES is the envelope's decision (progressive: run alone; full: the surface
  -- item 3 pins), and this item is about what the prompt SAYS. Both envelopes must say the same one thing.
  if envelope == 'progressive' then
    eq(master.tools, 'run', 'progressive: a master declares run alone')
  end
  eq(master.transport, 'tool_call', envelope .. ': the one transport is the tool call')
  eq(count(master.system, 'Work in code'), 1, envelope .. ': exactly one guidance sentence')
  has(master.system, TOOL_CALL, envelope .. ': the one guidance is the run-tool sentence')
  has(master.system, 'One run(code) can do a whole step', envelope .. ': it carries the batching sentence')
  for _, forbidden in ipairs(FORBIDDEN) do
    has_not(master.system, forbidden, envelope .. ': the codemode guidance is not sent beside it')
  end

  -- The child case is `orchestration-worker`: it is the ONE subagent profile code mode enables
  -- (codemode_policy.eligible), so it is the one that acts through a run tool at all. A profile with
  -- no code mode gets no guidance of either kind, which the control below pins.
  local child = build(envelope, true)
  eq(child.tools, 'run', envelope .. ': a child that can run code declares the run tool alone')
  eq(count(child.system, 'Work in code'), 1, envelope .. ': the child gets one guidance sentence too')
  has(child.system, TOOL_CALL, envelope .. ': the child gets the run-tool sentence')
  for _, forbidden in ipairs(FORBIDDEN) do
    has_not(child.system, forbidden, envelope .. ': the child is not offered the codemode guidance')
  end
end

-- The control for the child: a profile whose boundary does not enable code mode gets no guidance of
-- either kind, so the child assertions above measure the one door rather than a prompt that would have
-- carried a sentence for every child.
local plain_child = build('progressive', 'explore')
eq(plain_child.tools, 'bash,read,run', 'a profile without code mode keeps exactly the tools it allows')
eq(count(plain_child.system, 'Work in code'), 0, 'and gets no code-mode guidance')

-- ---------------------------------------------------------------- item 2: nothing measures a second door
-- A measured profile whose rates favour the fenced block (acts_in_answer over uses_run_tool) used to be
-- the exact input that brought the fence guidance back. There is no fence channel at all now, so the
-- measurement cannot open one: the transport is the tool call whatever the profile says.
local profile = dofile('lua/core/model_profile.lua')
local stored, store_error = profile.write('rel-r2-block-profile',
  { model = 'rel-r2-block-profile', rates = { uses_run_tool = 0, acts_in_answer = 1 }, tasks = {} })
ok(stored == true, 'the block-favouring profile is stored: ' .. tostring(store_error))

local result = with('progressive', function()
  local sid = memory.start_session('', 'native profile probe', { user_id = 'master', title = 'native profile' })
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot.model = 'rel-r2-block-profile'
  local messages = bot:build_context()
  return { system = tostring(messages[1].content), transport = bot.codeact_transport }
end)
eq(result.transport, 'tool_call', 'a block-favouring profile cannot bring the fence back')
eq(count(result.system, 'Work in code'), 1, 'and still exactly one guidance sentence')
has(result.system, TOOL_CALL, 'the run-tool sentence is the one it gets')
has_not(result.system, 'end your message with one', 'the fence sentence never comes back')

-- ---------------------------------------------------------------- item 3: the full envelope
-- The full envelope (a child, an older session, WASM_AGENT_ENVELOPE_MODE=full) declares the ONE door
-- plus the control-plane tools a script cannot run. Without this a node was offered every tool beside
-- the run tool, the offer the 17/11 measurement already answered.
local full_master = build('full', false)
eq(full_master.tools, 'run', 'full envelope: a master declares the run tool alone')

print('native guidance ok (' .. checks .. ' checks)')
