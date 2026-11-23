-- A picture the model READS inside a run block is a picture the model SEES (mission
-- run-block-images-reach-model, Victor 23/11).
--
-- What was measured on base 42f49385, with a real run block and a real 800x600 PNG: the next provider
-- request carried ZERO image parts, and the tool text carried the reference table itself -
--   {"_images":[{"bytes":12226,"mime":"image/png","name":"shot.png","path":"/…/attachments/….png",
--    "sha256":"3ca48…"}],...}
-- So the model was told where a picture it could not see happened to be stored. The model DOES take image
-- input: a pasted picture reached it as an image part in session 6a89dcbc. The gap was the route, not the
-- model.
--
-- What this row pins, every check through a REAL turn (a stub provider answers round one with the tool
-- call; round two inspects the ACTUAL provider messages the loop built) and the REAL sandbox:
--   1. a run block that reads a PNG sends exactly one image part, and its bytes are that picture;
--   2. two pictures read in one run arrive as two parts, in the order they were read;
--   3. five pictures: four ride out, and the one that does not is NAMED in the result text with the
--      bound it hit - never silence;
--   4. a plugin's `_images` is not promoted (and a call that is not the built-in read promotes nothing);
--   5. a model declared text-only gets one honest sentence per picture - path, pixel size, bytes - and no
--      image part, no base64 and no reference table;
--   6. a DIRECT read of a picture still reaches the model (the one-line-script route must carry it).
--
-- Run: scripts/test-run-images.lua under the node (this row needs host.quickjs and a scratch home).
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
local flags = { images = nil }
host.getenv = function(key)
  if key == 'WASM_AGENT_RAW_CODE' then return nil end
  if key == 'WASM_AGENT_CODEMODE' then return 'native' end
  -- A fixed route, so no vault, no pin and no route table decides what this row measures.
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'fixture_key_not_a_credential' end
  if key == 'WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if key == 'WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if key == 'WASM_AGENT_MODEL_IMAGES' then return flags.images end
  return real_getenv(key)
end
-- No network, ever: the provider is stubbed below and a test that reached the wire would be measuring
-- something else.
host.http = function() error('network forbidden') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local tools = original_dofile('lua/core/tools.lua')
local provider = original_dofile('lua/core/provider.lua')
local codemode = original_dofile('lua/core/codemode.lua')
dofile = function(path)
  -- The agent reloads its modules; handing it the SAME tables is what makes the provider stub below
  -- reach the loop (`scripts/test-codemode-model-boundary.lua` does the same).
  if path == 'lua/core/tools.lua' then return tools end
  if path == 'lua/core/provider.lua' then return provider end
  if path == 'lua/core/codemode.lua' then return codemode end
  return original_dofile(path)
end
local agent = original_dofile('lua/core/agent.lua')
local tool_output = original_dofile('lua/core/tool_output.lua')

local ready = false
if type(host.quickjs) == 'function' then
  local ok, raw = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = json.decode(raw); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no run block ran and nothing here was measured')

local ROOT = real_getenv('WASM_AGENT_LUA_ROOT') or '.'
local RED = ROOT .. '/fixtures/run-images/red-64x48.png'
local BLUE = ROOT .. '/fixtures/run-images/blue-64x48.png'
-- The fixture's own bytes, read through the host's image reader: host.read_file answers nil for a file
-- that is not UTF-8 text, which a PNG never is.
local function picture(path)
  local ok, raw = pcall(host.read_image_base64, path, 4000000)
  local value = ok and json.decode(raw) or nil
  if type(value) ~= 'table' or type(value.base64) ~= 'string' then return nil end
  return memory.base64_decode(value.base64), value.bytes, value.mime
end
local RED_BYTES = picture(RED)
local BLUE_BYTES = picture(BLUE)
assert(RED_BYTES and #RED_BYTES == 125, 'fixture missing or changed: ' .. RED)
assert(BLUE_BYTES and #BLUE_BYTES == 125, 'fixture missing or changed: ' .. BLUE)

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

-- Every picture the request carries, in the order the parts appear, with the bytes behind each one.
local function image_parts(messages)
  local found = {}
  for index, message in ipairs(messages) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do
        if part.type == 'image_url' then
          local url = tostring(part.image_url and part.image_url.url or '')
          local mime, payload = url:match('^data:([^;]+);base64,(.*)$')
          found[#found + 1] = { index = index, mime = mime, payload = payload or '',
            bytes = payload and memory.base64_decode(payload) or '' }
        end
      end
    end
  end
  return found
end

local function text_parts(messages)
  local found = {}
  for _, message in ipairs(messages) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do
        if part.type == 'text' then found[#found + 1] = tostring(part.text or '') end
      end
    end
  end
  return found
end

-- One real turn. Round one answers with the tool call under test; round two is where the assertions read
-- the messages the loop actually built for the provider.
local function drive(tool, args)
  local sid = memory.start_session('', 'run images ' .. tool, { user_id = 'master' })
  local rounds, captured = 0, nil
  provider.complete_with = function(_, messages)
    rounds = rounds + 1
    if rounds == 1 then
      return { content = '', finish_reason = 'tool_calls', tool_calls = {
        { id = 'rui-' .. tostring(rounds), type = 'function', ['function'] = { name = tool,
          arguments = json.encode(args) } } } }
    end
    captured = messages
    return { content = 'RUN-IMAGES-DONE', finish_reason = 'stop', tool_calls = {} }
  end
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  local answer = bot:run('read the picture')
  local tool_text, row_images = nil, nil
  for _, message in ipairs(captured or {}) do
    if message.role == 'tool' then tool_text = message.content end
  end
  for _, row in ipairs(memory.session_messages(sid, {})) do
    if row.role == 'tool' then row_images = row.images end
  end
  return { messages = captured or {}, tool_text = tostring(tool_text or ''), finished = answer,
    rounds = rounds, parts = image_parts(captured or {}), texts = text_parts(captured or {}),
    row_images = row_images }
end

local function quoted(path) return json.encode(path) end

-- The bound this row pins: four pictures ride out of one run result (lua/core/codemode.lua,
-- MAX_IMAGES). Written here as a literal on purpose - a row that read the constant it is judging could
-- not notice the constant moving.
local MAX_IMAGES = 4

-- 1. A picture read inside a run block reaches the model as an image.
do
  local turn = drive('run', { code = 'const shot = await tools.read({path:' .. quoted(RED) .. '}); return {mime: shot.mime, bytes: shot.bytes}' })
  eq(turn.rounds, 2, 'a run block reading a picture completes its turn')
  eq(#turn.parts, 1, 'the provider request carries exactly one image part for the picture the script read')
  local part = turn.parts[1] or {}
  eq(part.mime, 'image/png', 'the image part names the picture type')
  eq(part.bytes, RED_BYTES, 'the image part carries that picture\'s exact bytes')
  ok(turn.tool_text:find('_images', 1, true) == nil,
    'the run result text no longer carries the private reference table')
  ok(turn.tool_text:find(part.payload:sub(1, 64), 1, true) == nil, 'no base64 of the picture is in the result text')
  ok(type(turn.row_images) == 'table' and #turn.row_images == 1,
    'the picture is recorded on the tool row, so a later turn replays it')
  eq(turn.row_images and turn.row_images[1].sha256, host.sha256(part.payload),
    'the recorded reference is keyed by the sha256 of the picture the request carries')
end

-- 2. Two pictures, in the order they were read, in ONE provider message after the result block.
do
  local code = 'const a = await tools.read({path:' .. quoted(RED) .. '}); '
    .. 'const b = await tools.read({path:' .. quoted(BLUE) .. '}); return {ok: true}'
  local turn = drive('run', { code = code })
  eq(#turn.parts, 2, 'two pictures read in one run arrive as two image parts')
  eq(turn.parts[1] and turn.parts[1].bytes, RED_BYTES, 'the first part is the first picture read')
  eq(turn.parts[2] and turn.parts[2].bytes, BLUE_BYTES, 'the second part is the second picture read')
  eq(turn.parts[1] and turn.parts[1].index, turn.parts[2] and turn.parts[2].index,
    'both pictures ride in ONE message after the complete tool-result block')
end

-- 3. Over the bound: four ride out, and the fifth is NAMED with the bound it hit.
do
  local reads = {}
  for index = 1, 5 do
    reads[#reads + 1] = 'await tools.read({path:' .. quoted(RED) .. '})'
  end
  local turn = drive('run', { code = table.concat(reads, '; ') .. '; return {read: 5}' })
  eq(#turn.parts, MAX_IMAGES, 'at most ' .. MAX_IMAGES .. ' pictures ride out of one run result')
  ok(turn.tool_text:find('red-64x48.png', 1, true) ~= nil,
    'the picture that did not fit is named by its file in the result text')
  ok(turn.tool_text:find('at most ' .. MAX_IMAGES .. ' pictures', 1, true) ~= nil,
    'the result text says which bound dropped it')
  ok(turn.tool_text:find('images_note', 1, true) ~= nil, 'the drop is a field of the result, not a silent loss')
end

-- 4. Only the BUILT-IN read promotes. A script's own answer carrying the same key is ordinary JSON.
do
  local catalog = tools.all('master', { user_id = 'master' })
  catalog[#catalog + 1] = { ['function'] = { name = 'fixture_plugin',
    description = 'a plugin-shaped tool for this row', parameters = { type = 'object', properties = {} } } }
  local sid = memory.start_session('', 'run images plugin', { user_id = 'master' })
  local ctx = { session_id = sid, user_id = 'master' }
  local fake = { name = 'fake.png', mime = 'image/png', sha256 = string.rep('f', 64), bytes = 12,
    path = '/elsewhere/fake.png' }
  -- A script's dispatch is called as dispatch(tool, params, raw_arguments): the tool's NAME is the first
  -- argument (lua/core/codemode_pending.lua, invoke).
  local function dispatch(name)
    if name == 'fixture_plugin' then return { ok = true, _images = { fake } } end
    return { error = 'unexpected_call:' .. tostring(name) }
  end
  local result = codemode.run(memory, { code = 'return await tools.fixture_plugin({})' }, 'master', ctx,
    catalog, function() return catalog end, dispatch, function() return { status = 'available' } end)
  ok(result ~= nil, 'the script ran')
  ok(result._images == nil, 'a plugin answer carrying _images promotes nothing onto the run result')
  local value = type(result.value) == 'string' and json.decode(result.value) or result.value
  ok(type(value) == 'table' and type(value._images) == 'table',
    'the plugin _images stays ordinary JSON in the value the script received')
  local projected = tool_output.project('run', result)
  ok(projected:find('elsewhere/fake.png', 1, true) ~= nil,
    'and the model reads it as text, never as an image part')
end

-- 4b. At the model boundary: a call that is not read/run/codemode promotes nothing either.
do
  local saved = tools.dispatch
  local fake = { name = 'fake.png', mime = 'image/png', sha256 = string.rep('e', 64), bytes = 12,
    path = '/elsewhere/fake.png' }
  tools.dispatch = function(m, name, args, role, ctx, cwd, same)
    if name == 'grep' then return { _images = { fake }, count = 0, matches = {} } end
    return saved(m, name, args, role, ctx, cwd, same)
  end
  local sid = memory.start_session('', 'run images grep', { user_id = 'master' })
  local rounds, captured = 0, nil
  provider.complete_with = function(_, messages)
    rounds = rounds + 1
    if rounds == 1 then
      return { content = '', finish_reason = 'tool_calls', tool_calls = {
        { id = 'rui-grep', type = 'function', ['function'] = { name = 'grep',
          arguments = json.encode({ pattern = 'x' }) } } } }
    end
    captured = messages
    return { content = 'DONE', finish_reason = 'stop', tool_calls = {} }
  end
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot:run('grep for it')
  tools.dispatch = saved
  eq(#image_parts(captured or {}), 0, 'a grep result carrying _images is not promoted into an image')
  local text = ''
  for _, message in ipairs(captured or {}) do
    if message.role == 'tool' then text = tostring(message.content) end
  end
  ok(text:find('/elsewhere/fake.png', 1, true) ~= nil, 'and it stays visible as the JSON it is')
end

-- 5. A model that declares it takes no image input: one honest sentence per picture, nothing to decode.
do
  flags.images = 'off'
  local turn = drive('run', { code = 'await tools.read({path:' .. quoted(BLUE) .. '}); return {ok: true}' })
  eq(#turn.parts, 0, 'a model declared text-only is sent no image part')
  local sentence = nil
  for _, text in ipairs(turn.texts) do
    if text:find('this model takes no image input', 1, true) then sentence = text end
  end
  ok(sentence ~= nil, 'the picture is replaced by one honest sentence')
  ok(sentence and sentence:find('/attachments/', 1, true) ~= nil,
    'the sentence says where the file is: ' .. tostring(sentence))
  ok(sentence and sentence:find('64x48', 1, true) ~= nil, 'the sentence says the pixel size')
  ok(sentence and sentence:find('125 bytes', 1, true) ~= nil, 'the sentence says the byte size')
  for _, text in ipairs(turn.texts) do
    ok(text:find('base64', 1, true) == nil and text:find('iVBOR', 1, true) == nil,
      'no base64 blob reaches the model in the sentence')
  end
  flags.images = nil
end

-- 6. A DIRECT read of a picture still reaches the model: it runs as a one-line script, and the wrap must
-- carry the picture out (this is the regression the fix above exists for).
do
  local turn = drive('read', { path = RED })
  eq(#turn.parts, 1, 'a direct read of a picture still reaches the model as one image part')
  eq(turn.parts[1] and turn.parts[1].bytes, RED_BYTES, 'and it is that picture')
end

print('run block images ok (' .. checks .. ' checks; real sandbox, real provider messages)')
