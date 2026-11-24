-- A picture that lives on ANOTHER node reaches the model here (mission run-block-images-reach-model,
-- item 3).
--
-- WHAT WAS WRONG. `tools.remote({node, capability:"read", path:"x.png"})` answered
-- `remote_image_transport_unsupported` (lua/core/tools.lua): the peer's read stored the picture in ITS
-- attachment store and answered a reference whose path is a file on the wrong machine, and nothing on the
-- wire could carry the bytes - so the model that had just screenshotted a page on `nextcloud` could never
-- look at it (session 6a89dcbc, seq 148-151).
--
-- What this row pins, with the peer as a FIXTURE (no rendezvous, no relay, no live node - a stub shaped
-- exactly as the wire shapes an answer, the same seam the real call crosses):
--   1. the caller asks for bytes on a read, and never mutates the model's own arguments;
--   2. the peer half sends the bytes INSTEAD of the reference, and a digest that matches them;
--   3. a picture over the transfer cap is refused BY NAME, with its size and the cap - and its bytes are
--      never read at all;
--   4. the caller half verifies (digest, mime, size), stores the picture HERE, and answers a reference
--      whose file exists on this node; a peer that lies about the digest gets nothing stored;
--   5. the model sees it: a run block reading a picture on a peer sends one image part, and the result
--      text carries no reference table;
--   6. an OLD peer (one that does not know the request field) keeps today's refusal - the change assumes
--      nothing about the peer's build.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_RAW_CODE' then return nil end
  if key == 'WASM_AGENT_CODEMODE' then return 'native' end
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'fixture_key_not_a_credential' end
  if key == 'WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if key == 'WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  return real_getenv(key)
end
host.http = function() error('network forbidden') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
-- ONE instance per module path: the agent reloads its modules through dofile, and a stub on a second
-- instance would never be read by the code under test.
local original_dofile = dofile
local nodes = original_dofile('lua/core/nodes.lua')
local peer = { name = 'scratch-peer', node_id = string.rep('a', 32), local_node = false, online = true }
local answer, sent_arguments = nil, nil
nodes.find = function(selector)
  if tostring(selector) == 'scratch-peer' or tostring(selector) == peer.node_id then return peer end
  return nil
end
nodes.operator_status = function() return { operator_of_peer = true } end
nodes.remote_call = function(selector, capability, args)
  sent_arguments = args
  if capability == 'read' and answer ~= nil then return answer end
  -- The calls batch: the peer answers one result per entry, in order (lua/core/server.lua's own shape).
  -- An entry that read a picture answers the reference this node cannot use - the case the batch
  -- refusal below has to name.
  if capability == 'batch' and answer ~= nil then
    -- What a peer answers a batch entry with: the REFERENCE it holds (a path on ITS machine), never
    -- bytes - a batch does not carry the `image_bytes` request. The third entry answers bytes anyway,
    -- which no peer should send and the batch must still refuse rather than hand on.
    local reference = { name = 'red-64x48.png', mime = 'image/png', bytes = 125,
      sha256 = answer.image_data and answer.image_data.sha256 or string.rep('f', 64),
      path = '/on/the/other/machine/red-64x48.png' }
    local results = {}
    for index = 1, #((args or {}).calls or {}) do
      if index == 3 then results[index] = answer
      else results[index] = { type = 'image', mime = 'image/png', bytes = 125,
        sha256 = reference.sha256, path = reference.path, _images = { reference } } end
    end
    return { batch = 1, results = results }
  end
  return { error = 'fixture_peer_answered_nothing' }
end
local loaded = {}
dofile = function(path)
  if path == 'lua/core/nodes.lua' then return nodes end
  if loaded[path] then return loaded[path] end
  local module = original_dofile(path); loaded[path] = module; return module
end
local tools = dofile('lua/core/tools.lua')
local provider = dofile('lua/core/provider.lua')
local agent = dofile('lua/core/agent.lua')
-- The transfer module. A node without it is the BASE tree this row must fail on, so its absence is a
-- named fact here rather than a bootstrap error before a single check runs.
local module_ok, remote_image = pcall(dofile, 'lua/core/remote_image.lua')
if not module_ok or type(remote_image) ~= 'table' then remote_image = nil end

local ready = false
if type(host.quickjs) == 'function' then
  local ok, raw = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = json.decode(raw); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no run block ran and nothing here was measured')

local ROOT = real_getenv('WASM_AGENT_LUA_ROOT') or '.'
local PICTURE = ROOT .. '/fixtures/run-images/red-64x48.png'
local function picture_bytes(path)
  local ok, raw = pcall(host.read_image_base64, path, 4000000)
  local value = ok and json.decode(raw) or nil
  if type(value) ~= 'table' or type(value.base64) ~= 'string' then return nil end
  return memory.base64_decode(value.base64)
end
local PICTURE_BYTES = picture_bytes(PICTURE)
assert(PICTURE_BYTES and #PICTURE_BYTES == 125, 'fixture missing or changed: ' .. PICTURE)

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end
local function keys(table_value)
  local list = {}
  for key in pairs(table_value or {}) do list[#list + 1] = key end
  table.sort(list)
  return table.concat(list, ',')
end

-- THE WIRE, BY HAND. This is exactly what a peer answers for a read of this picture when the caller
-- asked for bytes (lua/core/remote_image.lua, offer): the picture, its digest, its type, and NOT a
-- reference. Crafted here so this half is judged on its own - the peer half is measured further down.
local PICTURE_B64 = nil
do
  local ok_read, raw = pcall(host.read_image_base64, PICTURE, 4000000)
  local value = ok_read and json.decode(raw) or nil
  PICTURE_B64 = type(value) == 'table' and value.base64 or nil
end
assert(type(PICTURE_B64) == 'string', 'fixture unreadable: ' .. PICTURE)
local function wire_answer(value_b64, mime)
  return { type = 'image', mime = mime or 'image/png', bytes = 125,
    sha256 = host.sha256(value_b64), path = '/on/the/other/machine/red-64x48.png',
    image_data = { name = 'red-64x48.png', mime = mime or 'image/png', bytes = 125,
      sha256 = host.sha256(value_b64), base64 = value_b64 } }
end

-- 1. THE CALLER HALF, FIRST: a peer that sent the bytes is not refused, and the answer is a reference
-- this node can open. On the base tree this is the check that fails, with the refusal the model read.
do
  answer = wire_answer(PICTURE_B64)
  local got = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'read', path = PICTURE },
    'master', { user_id = 'master' })
  eq(type(got._images) == 'table' and #got._images or 0, 1,
    'the picture the peer sent is stored HERE and answered as this node reference (error: ' .. tostring(got.error) .. ')')
  eq(got.error, nil, 'and the call is not refused: ' .. tostring(got.note))
  local reference = got._images[1]
  eq(reference.sha256, host.sha256(PICTURE_B64), 'keyed by the digest of the picture sent')
  eq(host.path_kind(reference.path), 'file', 'and the file it names exists on THIS node: ' .. tostring(reference.path))
  eq(memory.base64_decode((memory.load_image(reference)).b64), PICTURE_BYTES, 'the stored bytes are the picture')
  ok(got.image_data == nil, 'the wire field is consumed, never handed on')
  eq(sent_arguments and sent_arguments.image_bytes, true, 'the request that went to the peer asked for bytes')
end

-- 2. The request: a read asks for bytes, and the model's own arguments are untouched.
ok(remote_image ~= nil, 'lua/core/remote_image.lua is missing: this node cannot transfer a peer picture at all')
if remote_image then
  local mine = { path = 'x.png' }
  local sent = remote_image.request(mine)
  eq(sent.image_bytes, true, 'the caller asks the peer for the picture bytes')
  eq(sent.path, 'x.png', 'and for the same path')
  ok(mine.image_bytes == nil, 'the model arguments are not mutated')
end

-- 3. The peer half: bytes instead of a reference, under a digest that matches them.
do
  local offered = tools.dispatch(memory, 'read', { path = PICTURE, image_bytes = true }, 'master',
    { user_id = 'master' })
  local data = offered and offered.image_data
  ok(type(data) == 'table', 'the peer answers a read of a picture with its bytes: ' .. keys(offered))
  eq(data and data.mime, 'image/png', 'the transfer names the type')
  eq(data and data.bytes, 125, 'the transfer names the byte count')
  eq(data and host.sha256(data.base64), data and data.sha256,
    'the digest the peer names is the digest of the bytes it sends')
  ok(offered._images == nil, 'the reference is NOT sent as well: a path on that machine is useless here')
  local plain = tools.dispatch(memory, 'read', { path = PICTURE }, 'master', { user_id = 'master' })
  ok(type(plain) == 'table' and type(plain._images) == 'table',
    'a read that did not ask for bytes still answers the local reference it always did')
end

-- 4. The cap: a picture over it is refused BY NAME, and its bytes are never read.
if remote_image then
  local huge = { _images = { { name = 'huge.png', mime = 'image/png', sha256 = string.rep('c', 64),
    bytes = remote_image.MAX_BYTES + 1 } } }
  local refused = remote_image.offer(huge, function() error('the bytes of an over-cap picture must not be read') end)
  eq(refused.error, 'remote_image_too_large', 'a picture over the cap is refused by name')
  eq(refused.max_bytes, remote_image.MAX_BYTES, 'the refusal names the cap')
  eq(refused.bytes, remote_image.MAX_BYTES + 1, 'the refusal names the size it refused')
  ok(tostring(refused.note):find('huge.png', 1, true) ~= nil, 'the refusal names the picture')
  ok(tostring(refused.note):find('not sent', 1, true) ~= nil, 'and says it was not sent, in words a reader can act on')
end

-- 4. The caller half: verified, stored here, or nothing.
local WIRE = nil
do
  local offered = tools.dispatch(memory, 'read', { path = PICTURE, image_bytes = true }, 'master',
    { user_id = 'master' })
  WIRE = json.encode(offered)
end
local function fresh() return json.decode(WIRE) end
do
  answer = fresh()
  local got = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'read', path = PICTURE },
    'master', { user_id = 'master' })
  eq(got.error, nil, 'a transferred picture is not refused: ' .. tostring(got.note))
  eq(type(got._images) == 'table' and #got._images, 1, 'the answer carries one reference of THIS node')
  local reference = got._images[1]
  eq(reference.sha256, host.sha256(json.decode(WIRE).image_data.base64), 'keyed by the picture digest')
  eq(host.path_kind(reference.path), 'file', 'and the file it names exists on THIS node: ' .. tostring(reference.path))
  eq(memory.base64_decode((memory.load_image(reference)).b64), PICTURE_BYTES, 'the stored bytes are the picture')
  ok(got.image_data == nil, 'the wire field is consumed, never handed on')
  eq(sent_arguments and sent_arguments.image_bytes, true, 'the request that went to the peer asked for bytes')
end
do
  answer = fresh()
  answer.image_data.sha256 = string.rep('d', 64)
  local lied = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'read', path = PICTURE },
    'master', { user_id = 'master' })
  eq(lied.error, 'remote_image_digest_mismatch', 'a peer whose digest does not match its bytes is refused by name')
  ok(lied._images == nil, 'and nothing is stored or handed on')
end
do
  answer = fresh()
  answer.image_data.mime = 'application/x-not-an-image'
  local wrong = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'read', path = PICTURE },
    'master', { user_id = 'master' })
  eq(wrong.error, 'remote_image_type_unsupported', 'a type this node does not store is refused by name')
end

-- 5. The model boundary: a run block reading a picture on a peer sends one image part.
do
  answer = fresh()
  local sid = memory.start_session('', 'peer picture', { user_id = 'master' })
  local rounds, captured = 0, nil
  provider.complete_with = function(_, messages)
    rounds = rounds + 1
    if rounds == 1 then
      return { content = '', finish_reason = 'tool_calls', tool_calls = {
        { id = 'peer-picture', type = 'function', ['function'] = { name = 'run',
          arguments = json.encode({ code = 'const p = await tools.remote({node:"scratch-peer",capability:"read",path:'
            .. json.encode(PICTURE) .. '}); return {ok:true}' }) } } } }
    end
    captured = messages
    return { content = 'PEER-IMAGE-DONE', finish_reason = 'stop', tool_calls = {} }
  end
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot:run('look at the picture on the peer')
  local parts, tool_text = {}, ''
  for _, message in ipairs(captured or {}) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do if part.type == 'image_url' then parts[#parts + 1] = part end end
    end
    if message.role == 'tool' then tool_text = tostring(message.content) end
  end
  eq(#parts, 1, 'the provider request carries one image part for the picture read on the peer')
  local payload = parts[1] and tostring(parts[1].image_url and parts[1].image_url.url or ''):match('^data:[^;]+;base64,(.*)$')
  eq(payload and memory.base64_decode(payload), PICTURE_BYTES, 'and it is that picture')
  ok(tool_text:find('_images', 1, true) == nil, 'the result text carries no reference table')
end

-- 6. An OLD peer: it does not know the field, so it answers the reference it always did - and this node
-- keeps the refusal it always gave. Nothing here assumes the peer build.
do
  answer = { _images = { { name = 'old.png', mime = 'image/png', sha256 = string.rep('e', 64), bytes = 125,
    path = '/on/the/other/machine/old.png' } } }
  local old = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'read', path = PICTURE },
    'master', { user_id = 'master' })
  eq(old.error, 'remote_image_transport_unsupported', 'a peer that sent no bytes keeps the named refusal of today')
  ok(old._images == nil, 'and no path from the other machine is handed on')
  answer = nil
end

-- 7. A PICTURE INSIDE A calls BATCH IS REFUSED BY NAME, AND THE REFUSAL NAMES THE CALL THAT WORKS
-- (mission run-images-two-node, item 2). The batch is 1-8 reads in one signed round trip and its answer
-- is ordered text entries; a picture rides out with ONE call's own result. The refusal says so, with the
-- node and the path in it, instead of leaving a path on the other machine or a bare code.
do
  answer = fresh()
  local batch = tools.dispatch(memory, 'remote', { node = 'scratch-peer', capability = 'batch',
    calls = { { capability = 'read', path = PICTURE }, { capability = 'ls', path = '/tmp' },
      { capability = 'read', path = PICTURE } } }, 'master', { user_id = 'master' })
  local entry = (type(batch) == 'table' and batch.results or {})[1] or {}
  eq(entry.error, 'remote_image_batch_unsupported', 'a picture read inside calls is refused by name: '
    .. json.encode(entry))
  ok(tostring(entry.note or ''):find('as its own call', 1, true) ~= nil,
    'and the refusal names the single call: ' .. tostring(entry.note))
  ok(tostring(entry.note or ''):find('scratch-peer', 1, true) ~= nil, 'with the node in it')
  ok(tostring(entry.note or ''):find(PICTURE, 1, true) ~= nil, 'and the path in it')
  eq(entry.capability, 'read', 'the entry says which capability was refused')
  ok(entry._images == nil, 'and no path from the other machine is handed on')
  ok(type(batch.failed) == 'number' and batch.failed >= 1, 'the batch counts it as a failed entry')
  local second = (type(batch) == 'table' and batch.results or {})[2] or {}
  ok(second.error == nil or second.error == 'remote_image_batch_unsupported',
    'an entry that read no picture answers what it always did: ' .. json.encode(second))
  local third = (type(batch) == 'table' and batch.results or {})[3] or {}
  eq(third.error, 'remote_image_batch_unsupported',
    'and a peer that sent raw bytes in a batch entry is refused the same way, never handed on: '
      .. json.encode({ error = third.error, keys = (function() local k = {} for key in pairs(third) do k[#k+1] = key end table.sort(k) return k end)() }))
  ok(third.image_data == nil, 'the bytes are dropped from the entry')
  answer = nil
end

print('remote picture ok (' .. checks .. ' checks; peer stubbed at the wire seam)')
