-- THE LEAK SAFETY NET, DRIVEN THROUGH THE REAL LOOP (review r1, item 1).
--
-- What this file used to do was read the scanner directly, which could not see the defect the audit
-- found: the scan ran on every reply, also one that carried a real tool call, so a worker that quoted a
-- call format in its prose lost the call. So each row below is a provider stub reply fed to
-- agent.run, and what is judged is what the loop DID with it:
--
--   A. a real run call whose prose mentions the format  -> the call runs, no notice;
--   B. an answer that QUOTES the format inside a fence or inside backticks -> the answer, no notice;
--   C. bare markup, no call -> ONE continue naming the run tool, then the named failure;
--   D. an answer that ends in a run-TAGGED block, no call -> ONE continue (its action is still lost);
--   E. an answer that ends in a js fence WITHOUT the word run -> the answer, no notice.
--
-- Hermetic: no network, no node, a scratch home (the guard refuses the real one).
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local TICK = string.rep(string.char(96), 3)
local ONE = string.char(96)
local real_getenv = host.getenv
local overrides = {
  WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'leak-net-fixture',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0',
}
host.getenv = function(key)
  if key == 'WASM_AGENT_RAW_CODE' then return nil end -- ONE path: setting it refuses the run
  if overrides[key] ~= nil then return overrides[key] end
  return real_getenv(key)
end
host.http = function() error('network forbidden in the leak-net fixture') end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local agentlib = dofile('lua/core/agent.lua')
local raw = dofile('lua/core/raw_code.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

-- The marker shapes, named by the code that writes them so this file never depends on spelling.
local CLOSE_PARAM = '</' .. 'parameter>'
local TOOL_CALL = '<' .. 'tool_call>'
local TOOL_CALL_END = '</' .. 'tool_call>'
local BASH = '<' .. 'bash>'
local BASH_END = '</' .. 'bash>'
local DSML = '<\239\189\156DSML\239\189\156invoke name="x">'

local serial = 0
local function fresh(title)
  serial = serial + 1
  local who = 'leaknet-' .. tostring(serial)
  local sid = memory.start_session('', 'leak-net-round',
    { user_id = who, node_id = '', title = title })
  local bot = agentlib.new(sid, function() end, 'master', who, '')
  bot.stream = true
  return bot, sid
end

local function rows_of(sid)
  return memory.session_messages(sid) or {}
end
local function notices(sid)
  local seen = {}
  for _, row in ipairs(rows_of(sid)) do
    local content = tostring(row.content or '')
    if row.role == 'user' and content:find('[Harness notice]', 1, true) then seen[#seen + 1] = content end
  end
  return seen
end
local function tool_rows(sid)
  local n = 0
  for _, row in ipairs(rows_of(sid)) do if row.role == 'tool' then n = n + 1 end end
  return n
end

local function run_call(code)
  return { id = 'call_run_' .. tostring(serial), type = 'function',
    ['function'] = { name = 'run', arguments = json.encode({ code = code }) } }
end
local function scripted(replies)
  local index = 0
  host.http_stream = function()
    index = index + 1
    local reply = replies[index] or { content = 'The tree is clean.' }
    return json.encode({ status = 200, content = reply.content or '', reasoning = '',
      finish_reason = reply.finish_reason or 'stop', tool_calls = reply.tool_calls or {} })
  end
end

-- ------------------------------------------------------------------ A. a real call is never dropped
-- The prose carries three markers and the reply ALSO carries a real run call: the call runs, and the
-- model is told nothing about its own words.
scripted({ { content = 'Renaming the ' .. CLOSE_PARAM .. ' token and the ' .. TOOL_CALL .. ' shape, '
    .. 'and a ' .. BASH .. ' sample, as the report does.',
    finish_reason = 'tool_calls', tool_calls = { run_call('return 7;') } },
  { content = 'Done: the rename is one script.' } })
local bot, sid = fresh('call plus quoted markup')
local ok_a, reply_a = pcall(bot.run, bot, 'rename the token')
ok(ok_a, 'A: a reply with a real call and quoted markup must run: ' .. tostring(reply_a))
ok(tool_rows(sid) >= 1, 'A: the run call DISPATCHED')
ok(#notices(sid) == 0, 'A: and no notice was earned by its own prose (' .. #notices(sid) .. ')')

-- ------------------------------------------------------------------ B. a quote is an answer
-- Markup inside a fence, and inside inline backticks, with no call at all: an answer.
local quoted = 'The detector names these: ' .. ONE .. TOOL_CALL .. ONE .. ' and ' .. ONE .. CLOSE_PARAM .. ONE
  .. ' in prose, and here is the sample a report carries:\n'
  .. TICK .. 'text\n' .. BASH .. '{"command":"ls"}' .. BASH_END .. '\n' .. TICK
local quotes = 'And the bar looks like ' .. ONE .. DSML .. ONE .. ' in the raw stream.'
scripted({ { content = quoted } })
local bot_b, sid_b = fresh('markup inside a fence')
local ok_b, reply_b = pcall(bot_b.run, bot_b, 'show me the shape')
ok(ok_b, 'B: an answer that quotes the shape must end the turn: ' .. tostring(reply_b))
ok(#notices(sid_b) == 0, 'B: a fenced sample earns no notice (' .. #notices(sid_b) .. ')')
ok(tostring(reply_b):find('The detector names these', 1, true) ~= nil, 'B: and the answer is the answer')

scripted({ { content = quotes } })
local bot_b2, sid_b2 = fresh('markup inside backticks')
local ok_b2, reply_b2 = pcall(bot_b2.run, bot_b2, 'show me the bar')
ok(ok_b2, 'B: an inline quote must end the turn: ' .. tostring(reply_b2))
ok(#notices(sid_b2) == 0, 'B: an inline quote earns no notice (' .. #notices(sid_b2) .. ')')

-- ------------------------------------------------------------------ C. bare markup: one, then named
local bare = 'Let me look.\n' .. BASH .. '{"command":"ls /tmp"}' .. BASH_END
scripted({ { content = bare }, { content = 'The tree is clean.' } })
local bot_c, sid_c = fresh('bare markup once')
local ok_c, reply_c = pcall(bot_c.run, bot_c, 'check the tree')
ok(ok_c, 'C: bare markup must continue the turn, not fail it: ' .. tostring(reply_c))
local seen_c = notices(sid_c)
ok(#seen_c == 1, 'C: exactly one notice, not zero and not two (' .. #seen_c .. ')')
ok(seen_c[1]:find('tool-call markup as text, so nothing ran', 1, true) ~= nil, 'C: the notice names what happened')
ok(seen_c[1]:find('run tool', 1, true) ~= nil, 'C: and names the one door this node has')
ok(tool_rows(sid_c) == 0, 'C: nothing ran')

scripted({ { content = bare }, { content = bare } })
local bot_c2, sid_c2 = fresh('bare markup twice')
local ok_c2, err_c2 = pcall(bot_c2.run, bot_c2, 'check the tree')
ok(not ok_c2, 'C: a second consecutive one fails the run')
ok(tostring(err_c2):find('tool_call_markup_as_text', 1, true) ~= nil,
  'C: and it fails by name: ' .. tostring(err_c2):sub(1, 120))

-- ------------------------------------------------------------------ D. a run-tagged block is an ACTION
-- Nothing runs it any more, so an answer that ends in one would end the turn with the action lost.
local block = 'Let me look.\n' .. TICK .. 'js run\nreturn await tools.ls({path: "lua"});\n' .. TICK
scripted({ { content = block }, { content = 'Done.' } })
local bot_d, sid_d = fresh('run tagged block')
local ok_d, reply_d = pcall(bot_d.run, bot_d, 'look at lua')
ok(ok_d, 'D: a run-tagged block must continue the turn: ' .. tostring(reply_d))
local seen_d = notices(sid_d)
ok(#seen_d == 1, 'D: exactly one notice (' .. #seen_d .. ')')
ok(seen_d[1]:find('run tool', 1, true) ~= nil, 'D: naming the tool to call instead')

-- ------------------------------------------------------------------ E. a plain sample fence answers
-- The false positive the audit measured: an answer that ENDS in an untagged js fence is an answer.
local sample = 'This is how you would write it:\n' .. TICK .. 'js\nconst a = 1;\n' .. TICK
scripted({ { content = sample } })
local bot_e, sid_e = fresh('plain sample fence')
local ok_e, reply_e = pcall(bot_e.run, bot_e, 'show me an example')
ok(ok_e, 'E: an answer ending in a sample fence must end the turn: ' .. tostring(reply_e))
ok(#notices(sid_e) == 0, 'E: and earn no notice (' .. #notices(sid_e) .. ')')
ok(tostring(reply_e):find('This is how you would write it', 1, true) ~= nil, 'E: the answer is the answer')

-- ------------------------------------------------------------------ the reader, on its own
ok(raw.prose_only(quoted):find(TOOL_CALL, 1, true) == nil, 'the prose reader removes a fenced sample')
ok(raw.prose_only(quoted):find(BASH, 1, true) == nil, 'and an inline quote')
ok(raw.prose_only('a ' .. BASH .. 'x' .. BASH_END .. ' bare') ~= nil, 'and keeps bare markup')
ok(raw.prose_only('a ' .. BASH .. 'x' .. BASH_END .. ' bare'):find(BASH, 1, true) ~= nil, 'which is still scanned')
ok(raw.text_action(sample) == nil, 'a sample fence is not an action')
ok(raw.text_action(block) ~= nil, 'a run-tagged block that ends the answer is')

print('leak net ok (' .. checks .. ' checks)')
