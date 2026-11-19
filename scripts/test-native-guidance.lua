-- Item 1 (rel review r2): a native node receives ONE source of native guidance.
--
-- The prompt a native node builds must carry the run-tool sentence - guidance_for("tool_call"), with
-- the batching instruction riding inside it - and must NOT carry the codemode guidance ("one `codemode`
-- call runs JavaScript...", "Calling a tool directly also works"): that node has no codemode tool and no
-- direct call, so the codemode sentences name two doors it does not have. Asserted on the REAL built
-- system prompt (agent:build_context), never on a rebuilt block, for both envelopes and a subagent.
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
local function with(value, envelope, fn)
  host.getenv = function(k)
    if k == 'WASM_AGENT_RAW_CODE' then return value end
    if k == 'WASM_AGENT_ENVELOPE_MODE' then return envelope end
    return real(k)
  end
  local okc, value_or_error = pcall(fn)
  host.getenv = real
  if not okc then error(value_or_error, 0) end
  return value_or_error
end

local TOOL_CALL = raw.guidance_for('tool_call')
local FORBIDDEN = {
  'one `codemode` call runs JavaScript',
  'Calling a tool directly also works',
  'instead of a codemode call',
  'run a script by ending your message',
}

local function build(value, envelope, subagent)
  return with(value, envelope, function()
    local sid = memory.start_session('', 'native guidance ' .. tostring(value) .. ' ' .. tostring(envelope),
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
  local master = build('native', envelope, false)
  -- Which tools a native node DECLARES is the envelope's decision (progressive: run alone; full:
  -- the surface item 3 pins), and this item is about what the prompt SAYS. Both envelopes must say
  -- the same one thing.
  if envelope == 'progressive' then
    eq(master.tools, 'run', 'progressive: a native master declares run alone')
  end
  eq(count(master.system, 'Work in code'), 1, envelope .. ': exactly one guidance sentence')
  has(master.system, TOOL_CALL, envelope .. ': the one guidance is the run-tool sentence')
  has(master.system, 'One run(code) can do a whole step', envelope .. ': it carries the batching sentence')
  for _, forbidden in ipairs(FORBIDDEN) do
    has_not(master.system, forbidden, envelope .. ': the codemode guidance is not sent to a native node')
  end

  -- The child case is `orchestration-worker`: it is the ONE subagent profile code mode enables
  -- (codemode_policy.eligible), so it is the one that acts through a run tool at all. A profile with
  -- no code mode gets no guidance of either kind, which the control below pins.
  local child = build('native', envelope, true)
  eq(child.tools, 'bash,codemode,edit,read,run,write', envelope .. ': the subagent keeps its profile tools')
  eq(count(child.system, 'Work in code'), 1, envelope .. ': the child gets one guidance sentence too')
  has(child.system, TOOL_CALL, envelope .. ': the child gets the run-tool sentence')
  for _, forbidden in ipairs(FORBIDDEN) do
    has_not(child.system, forbidden, envelope .. ': the child is not offered the codemode guidance')
  end
end

-- The control for the child: a profile whose boundary does not enable code mode gets no guidance of
-- either kind, so the child assertions above measure the native door rather than a prompt that would
-- have carried a sentence for every child.
local plain_child = build('native', 'progressive', 'explore')
eq(plain_child.tools, 'bash,read,run', 'a profile without code mode keeps exactly the tools it allows')
eq(count(plain_child.system, 'Work in code'), 0, 'and gets no code-mode guidance, native or otherwise')

-- The block-mode node is the control: it still gets the codemode guidance, so the assertions above
-- measure the native door and not a prompt that lost its guidance for every mode.
local block_node = build('codemode', 'progressive', false)
has(block_node.system, 'one `codemode` call runs JavaScript', 'the codemode node keeps its own guidance')
has(block_node.system, 'Calling a tool directly also works', 'and its direct-call shortcut')


-- ---------------------------------------------------------------- item 2: the mode decides the door
-- A measured profile whose rates favour the fenced block (acts_in_answer over uses_run_tool) is the
-- exact input that used to bring the fence guidance back to a native node. The node has no fence
-- channel, so in native mode the transport must come from the MODE and never from the measurement.
local profile = dofile('lua/core/model_profile.lua')
local stored, store_error = profile.write('rel-r2-block-profile',
  { model = 'rel-r2-block-profile', rates = { uses_run_tool = 0, acts_in_answer = 1 }, tasks = {} })
ok(stored == true, 'the block-favouring profile is stored: ' .. tostring(store_error))

local result = with('native', 'progressive', function()
  local sid = memory.start_session('', 'native profile probe', { user_id = 'master', title = 'native profile' })
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot.model = 'rel-r2-block-profile'
  local messages = bot:build_context()
  return { system = tostring(messages[1].content), transport = bot.codeact_transport }
end)
eq(result.transport, 'tool_call', 'a native node records the tool-call transport whatever the profile says')
eq(count(result.system, 'Work in code'), 1, 'and still has exactly one guidance sentence')
has(result.system, TOOL_CALL, 'the run-tool sentence is the one it gets')
has_not(result.system, 'end your message with one', 'the fence sentence never comes back in native mode')

-- The control: the SAME profile in a mode that honours the measurement gets the fence guidance, so
-- the assertion above measures the native mode and not a profile that stopped being read everywhere.
local honoured = with('on', 'progressive', function()
  local sid = memory.start_session('', 'on profile probe', { user_id = 'master', title = 'on profile' })
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot.model = 'rel-r2-block-profile'
  local messages = bot:build_context()
  return { system = tostring(messages[1].content), transport = bot.codeact_transport }
end)
eq(honoured.transport, 'block', 'on: the measured block transport is still what the profile decides')
has(honoured.system, 'end your message with one', 'on: and the fence guidance is what that node is sent')

print('native guidance ok (' .. checks .. ' checks)')
