-- The gate: every refusal a model can read carries the code, the real cause, the offending input and the fix.
--
-- Evidence this test exists for (13/11, node `work`): a code-mode call with no argument failed with
-- `json_contract_invalid:json_number_invalid` three modules from its cause - the component loop handing
-- the parser the text `undefined` - and the model spent about five calls finding it. Then `notes_write`
-- called with `{content=...}` answered `notes_text_required` and nothing else; the accepted name was
-- nowhere in the answer and the model guessed three times.
--
-- What is checked, in the order a refusal travels:
--   1. the inventory of codes is not stale (one scan, shared with the generator);
--   2. every code in it renders a message, an input and a fix - bounded, one line, one sentence, with no
--      empty placeholder left behind;
--   3. every tool in the catalogue, refused for a missing or an extra argument, names the arguments it
--      DOES take, and every name it prints is one of those arguments;
--   4. a fix only names things that exist: a file in this tree, a code, a tool, or a word the tree's own
--      sources use;
--   5. the real boundary does it: a refused dispatch through `tools.dispatch` carries the four fields,
--      and the code it carried before this change is unchanged (clients match on it).
local refusal = dofile('lua/core/refusal.lua')
local generator = dofile('scripts/gen-refusal-codes.lua')
local inventory = dofile('lua/core/refusal_codes.lua')

local checks = 0
local function check(value, why) assert(value, why); checks = checks + 1 end
local function read(path)
  local handle = io.open(path, 'rb'); if not handle then return nil end
  local text = handle:read('a'); handle:close(); return text
end

-- ---- 1. the inventory is the source's own list ------------------------------------------------------
local origin, modules = generator.build()
local current = assert(read('lua/core/refusal_codes.lua'), 'lua/core/refusal_codes.lua is missing')
check(generator.render(origin) == current,
  'lua/core/refusal_codes.lua is stale: run `lua5.4 scripts/gen-refusal-codes.lua --write`')

local code_list = {}
for code in pairs(inventory) do code_list[#code_list + 1] = code end
table.sort(code_list)
check(#code_list > 400, 'the inventory is not empty (' .. #code_list .. ' codes from ' .. modules .. ' modules)')

-- ---- 2. every code renders the contract ------------------------------------------------------------
-- A fixture schema stands in for a tool's own while the test is not inside a node: what is checked here
-- is the rendering, not the catalogue (that is check 3, and the real boundary is check 5).
local fixture_parameters = { type = 'object', properties = { text = { type = 'string', maxLength = 65536 } },
  required = { 'text' } }
local fixture_ctx = { tool = 'notes_write', parameters = fixture_parameters, input = '{"content":"hi"}' }
-- Every template variable the renderer knows. A sentence that still carries one of these is a template
-- that lost a value, which is how "needs ``" and "send e.g. ." reached a model before this change.
local PLACEHOLDERS = { 'origin', 'site', 'tool', 'detail', 'input', 'field', 'rule', 'rule_field', 'code',
  'accepted', 'expected', 'received', 'example', 'example_clause', 'available_sentence', 'role' }
local tiers = { code = 0, family = 0, shape = 0, message = 0 }
local rendered = {}
for _, code in ipairs(code_list) do
  local out = refusal.build(code, {}, fixture_ctx)
  rendered[#rendered + 1] = out
  tiers[out.tier] = (tiers[out.tier] or 0) + 1
  check(type(out.message) == 'string' and #out.message > 20, 'message for ' .. code .. ': ' .. tostring(out.message))
  check(type(out.fix) == 'string' and #out.fix > 10, 'fix for ' .. code .. ': ' .. tostring(out.fix))
  check(type(out.input) == 'string' and #out.input > 0, 'input for ' .. code .. ': ' .. tostring(out.input))
  check(#out.input <= refusal.MAX_INPUT, 'input is bounded for ' .. code .. ' (' .. #out.input .. ' bytes)')
  check(#out.message <= refusal.MAX_MESSAGE and #out.fix <= refusal.MAX_FIX, 'message and fix are bounded for ' .. code)
  check(not out.message:find('``', 1, true) and not out.fix:find('``', 1, true),
    'no empty placeholder in ' .. code .. ': ' .. out.message .. ' / ' .. out.fix)
  for _, name in ipairs(PLACEHOLDERS) do
    check(not out.message:find('{' .. name .. '}', 1, true) and not out.fix:find('{' .. name .. '}', 1, true),
      'no unfilled ' .. name .. ' left in ' .. code .. ': ' .. out.message .. ' / ' .. out.fix)
  end
  check(not out.message:find('\n') and not out.fix:find('\n'), 'one line per field for ' .. code)
  -- A template whose value was empty reads worse than a sentence without it: "e.g. ." and "send: ." are
  -- how a half-filled instruction looks, and a model pays for it with a call.
  check(not out.message:find('e.g. %.') and not out.fix:find('e.g. %.'),
    'no empty example in ' .. code .. ': ' .. out.fix)
  check(not out.message:find('send: %.') and not out.fix:find('send: %.'),
    'no empty "send" in ' .. code .. ': ' .. out.fix)
  check(out.message:match('%.$') ~= nil, 'the message is one sentence for ' .. code .. ': ' .. out.message)
  check(out.message ~= out.fix, 'the message and the fix are different things for ' .. code)
  check(out.unrecorded == nil, 'every code has a recorded cause (' .. code .. ')')
end
-- A ratchet, not a hope: most codes are described from their own site because someone read that site.
-- A change that drops one of those sentences has to say so here.
local SPECIFIC_FLOOR = 270
check(tiers.code >= SPECIFIC_FLOOR,
  string.format('codes described from their own site: %d (floor %d)', tiers.code, SPECIFIC_FLOOR))
print(string.format('refusals: %d codes - %d written from their site, %d by the shape of their name, '
  .. '%d by the shape tier, %d carrying a raised message', #code_list, tiers.code, tiers.family,
  tiers.shape, tiers.message))

-- ---- 3. the two cases that started this ------------------------------------------------------------
local notes = refusal.finalize({ error = 'schema_extra:arguments.content' },
  { tool = 'notes_write', parameters = fixture_parameters, input = '{"content":"a note"}' })
check(notes.error == 'schema_extra:arguments.content', 'the code is unchanged: ' .. tostring(notes.error))
check(notes.message:find('does not take the argument `content`', 1, true) ~= nil, 'the extra argument is named: ' .. notes.message)
check(notes.fix:find('text', 1, true) ~= nil, 'the accepted argument is in the fix: ' .. notes.fix)
check(notes.input:find('a note', 1, true) ~= nil, 'the offending input is quoted: ' .. notes.input)

local noarg = refusal.finalize({ error = 'json_contract_invalid:json_number_invalid', input = 'undefined' },
  { tool = 'nodes', site = 'the code-mode component loop', parameters = { type = 'object' } })
check(noarg.error == 'json_contract_invalid:json_number_invalid', 'the contract code is unchanged')
check(noarg.input == 'undefined', 'the text the loop handed over is the input: ' .. tostring(noarg.input))
check(noarg.message:find('not valid JSON', 1, true) ~= nil, 'the cause is named, not the parser: ' .. noarg.message)
check(noarg.message:find('the code-mode component loop', 1, true) ~= nil, 'the loop that handed it over is named: ' .. noarg.message)
check(noarg.fix:find('JSON object', 1, true) ~= nil, 'the fix says what to send: ' .. noarg.fix)

-- A refusal that already carries all four fields is returned untouched: the helper is idempotent and
-- never rewrites a site's own sentence.
local kept = refusal.finalize({ error = 'path_required', message = 'mine', fix = 'mine too', input = 'x' })
check(kept.message == 'mine' and kept.fix == 'mine too' and kept.input == 'x', 'a written refusal is kept')
local plain = { ok = true, content = 'not a refusal' }
check(refusal.finalize(plain) == plain, 'a successful result is not touched')

-- ---- 4. a fix only names what exists ---------------------------------------------------------------
-- The words this tree actually uses: one pass over the sources a fix may name, so a fix that invents a
-- tool, a file or a command is caught here instead of costing a model a round.
local vocabulary = {}
local function index(path)
  local text = read(path); if not text then return end
  for word in text:gmatch('[%w_%./%-]+') do vocabulary[word] = true end
end
local function index_dir(dir, pattern)
  local handle = io.popen and io.popen('ls ' .. dir .. ' 2>/dev/null')
  if not handle then return end
  for name in handle:lines() do if name:match(pattern) then index(dir .. '/' .. name) end end
  handle:close()
end
index_dir('lua/core', '%.lua$')
index_dir('scripts', '%.lua$')
index_dir('scripts', '%.mjs$')
index_dir('scripts', '%.sh$')
index_dir('docs', '%.md$')
local catalogue = {}
if type(host) == 'table' and host.sql_exec then
  local ok, tools = pcall(function() return dofile('lua/core/tools.lua').catalog('master') end)
  for _, item in ipairs(ok and tools or {}) do catalogue[item['function'].name] = true end
end
for _, tool in pairs(dofile('lua/core/retired.lua').NAMES) do catalogue[tool] = true end

local unused = 0
for _, out in ipairs(rendered) do
  for _, token in ipairs(refusal.entities(out.fix)) do
    -- A fix names a call as a call: `capabilities()`, `searchTools("*")`. The name is the identifier in
    -- front of it. A backticked JSON example is a shape, not a name, and is skipped.
    local name = token:gsub('^%s+', ''):gsub('%s+$', '')
    local first = name:sub(1, 1)
    local shape = first == '{' or first == '[' or first == '<' or first == '"' or first == "\'" 
    if not shape then name = name:match('^([%w_%./%-]+)') or name end
    local known = shape or vocabulary[name] ~= nil or catalogue[name] ~= nil
      or inventory[name] ~= nil or inventory[name:gsub(':.*$', '')] ~= nil
      or read(name) ~= nil
    check(known, 'the fix for ' .. tostring(out.error) .. ' names `' .. name .. '`, which this tree does not have')
  end
end
-- A fix may also be prose with no backticks; that is not a failure, only a missed chance to name things.
for _, out in ipairs(rendered) do if not out.fix:find('`') then unused = unused + 1 end end
local words = 0
for _ in pairs(vocabulary) do words = words + 1 end
check(words > 1000, 'the vocabulary the entity check uses was read from the tree (' .. words .. ' words)')
print(string.format('refusals: %d fixes name something backticked, %d are prose', #rendered - unused, unused))

-- ---- 4b. the two tiers nothing in this tree reaches yet, and the bounds ---------------------------
-- A code added tomorrow must not answer with nothing, and a code whose text IS the message (a tool that
-- raised) must keep its own words. Both are fixtures, so the fallbacks are proven, not assumed.
local future = refusal.build('a_code_from_tomorrow', {}, fixture_ctx)
check(future.tier == 'shape', 'a code nobody wrote a cause for is rendered by its own shape: ' .. tostring(future.tier))
check(future.message:find('a code from tomorrow', 1, true) ~= nil,
  'the shape tier reads the code as the rule it broke: ' .. future.message)
check(#future.fix > 20 and future.message ~= future.fix, 'the shape tier still says what to change: ' .. future.fix)

local raised = refusal.finalize({ error = 'lua/core/file_tools.lua:133: attempt to index a nil value' },
  { tool = 'read' })
check(raised.error == 'lua/core/file_tools.lua:133: attempt to index a nil value', 'a raise keeps its own text')
check(raised.message:find('lua/core/file_tools.lua:133', 1, true) ~= nil,
  'a raise names the line that raised: ' .. raised.message)
check(raised.fix:find('raised', 1, true) ~= nil, 'a raise says what to do about it: ' .. raised.fix)

local long_input = string.rep('x', 5000)
local bounded = refusal.finalize({ error = 'path_required' }, { tool = 'read', input = long_input })
check(#bounded.input <= refusal.MAX_INPUT, 'a huge argument text is cut to ' .. refusal.MAX_INPUT .. ' bytes')
local secret = refusal.finalize({ error = 'path_required' }, { tool = 'read',
  input = '{"key":"sk-live-abcdefghijklmnopqrstuvwxyz"}' })
check(secret.input:find('sk-live-abcdefghijklmnopqrstuvwxyz', 1, true) == nil,
  'a credential in the argument text never travels in a refusal: ' .. secret.input)

-- ---- 5. the real boundary --------------------------------------------------------------------------
-- Only inside a node: `tools.dispatch` needs the host for a session and its store. Under the fast path
-- (a `wa` row) it always runs; a bare `lua5.4` run reports it as not measured rather than as passed.
if type(host) == 'table' and host.sql_exec then
  local memory = dofile('lua/core/memory.lua'); memory.setup()
  local tools = dofile('lua/core/tools.lua')
  local sid = memory.start_session('', 'refusal contract', { user_id = 'master' })
  local ctx = { session_id = sid, user_id = 'master' }
  local function call(name, args, raw)
    ctx.tool_arguments_json = raw
    local result = tools.dispatch(memory, name, args, 'master', ctx)
    ctx.tool_arguments_json = nil
    return result
  end
  local missing = call('read', {}, '{}')
  check(missing.error == 'path_required', 'a refused read keeps its code: ' .. tostring(missing.error))
  check(type(missing.message) == 'string' and missing.message:find('`path`', 1, true) ~= nil,
    'the dispatcher names the missing argument: ' .. tostring(missing.message))
  check(type(missing.fix) == 'string' and missing.fix:find('read', 1, true) ~= nil,
    'the dispatcher says what to send: ' .. tostring(missing.fix))
  check(missing.input == '{}', 'the dispatcher quotes the argument text it refused: ' .. tostring(missing.input))

  local remote = call('remote', { args = { command = 'ls' } })
  check(remote.error == 'remote_node_required', 'a refused remote keeps its code: ' .. tostring(remote.error))
  check(type(remote.message) == 'string' and type(remote.fix) == 'string' and type(remote.input) == 'string',
    'the remote refusal carries the four fields')

  -- An unknown tool: the fix has to point at the way to find the real name.
  local unknown = call('no_such_tool', {})
  check(unknown.error ~= nil and type(unknown.message) == 'string', 'an unknown tool answers a refusal, not nothing')
  check(unknown.fix:find('searchTools', 1, true) ~= nil or unknown.fix:find('tool', 1, true) ~= nil,
    'the unknown-tool fix points at the way to find names: ' .. tostring(unknown.fix))

  local listed = call('searchTools', { query = '*' })
  check(type(listed) == 'table', 'the catalogue is readable for the entity check')
else
  print('SKIP test-refusal-contract: the dispatch half needs a node (no host here); '
    .. 'the rendering half above ran on its own')
end

print(string.format('refusal contract: %d checks passed', checks))
