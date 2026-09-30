-- The live check for wasm-agent's own subscription wire: real requests, streamed, recorded.
--
-- What it proves, in order:
--   1. the wire completes real requests end to end and *streams* - the emitted delta / reasoning /
--      decision / commentary events are counted and printed, so "it streamed" is an observation and
--      not a claim;
--   2. the ids, the headers and the body this repo owns are accepted by the endpoint;
--   3. two real streams are recorded under `tests/fixtures/subscription/`, which is what the offline
--      parser test and the Rust line reader are tested against: one that ends in a tool call, one
--      that carries text.
--
-- It needs the network and a live credential, so it is not in the gate: run it by hand.
-- `bash scripts/test.sh` never calls this file.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/check-subscription-wire-live.lua \
--     <repo>/rust/target/release/wa --db <scratch>.db
--
-- The credential: this lane owns the wire, not the credential, so the stand-in below reads pi's
-- auth file the way the credential lane's `lua/core/subscription_auth.lua` will *not* - nothing under
-- `lua/` reads that file, and this is a diagnostic that has to run before that file lands. When
-- `lua/core/subscription_auth.lua` exists, the stand-in stops being used and the real seam is called.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local wire = dofile('lua/core/subscription_wire.lua')

local MODEL = host.getenv('WA_WIRE_MODEL') or 'gpt-6-luna'
local LEVEL = host.getenv('WA_WIRE_LEVEL') or 'low'
local BOUND = 1024 * 1024

-- The stand-in for the credential lane's seam. Read-only, and never printed.
if not pcall(function() return dofile('lua/core/subscription_auth.lua').token() end) then
  wire.credential_provider = function()
    local directory = host.getenv('PI_CODING_AGENT_DIR') or (paths.home() .. '/.pi/agent')
    local auth = json.decode(host.read_file(directory .. '/auth.json') or '{}')
    local oauth = auth['openai-codex'] or {}
    return {access = oauth.access, account_id = oauth.accountId, expires = oauth.expires}
  end
  print('credential: lua/core/subscription_auth.lua is absent; using the pi-auth stand-in')
end

-- Every event the wire sends to the UI, captured instead of drawn: a run's evidence, without a
-- client attached.
local counts, samples = {}, {}
local native_stream = host.stream
host.stream = function(payload)
  local event = json.decode(payload)
  local kind = event.type or '?'
  counts[kind] = (counts[kind] or 0) + 1
  if #samples < 8 then samples[#samples + 1] = event end
end

-- Redacted where the endpoint echoes part of the request back. The Authorization header is not part
-- of a response body, so no credential can reach a fixture. Named rather than silently dropped,
-- because a fixture that differs from the wire is not a fixture.
local REDACT = {'prompt_cache_key', 'safety_identifier', 'user_id', 'account_id'}

local function call(prompt, tools)
  local recorded, bytes = {}, 0
  local function record(line)
    local text = line
    for _, field in ipairs(REDACT) do
      text = text:gsub('"' .. field .. '":"[^"]*"', '"' .. field .. '":"<redacted>"')
    end
    bytes = bytes + #text + 1
    if bytes > BOUND then
      -- Failing loudly is the point: a fixture cut by the bound would silently become a *truncated*
      -- stream, and the parser test would then be pinning a bound as if it were the protocol.
      error('fixture_bound_exceeded: the stream is larger than ' .. tostring(BOUND) .. ' bytes; ' ..
        'raise the bound deliberately or use a shorter prompt')
    end
    recorded[#recorded + 1] = text
  end
  local started = math.floor(host.monotonic_ms())
  local result = wire.complete(MODEL,
    {{role = 'system', content = 'You are a fixture. Answer in as few words as possible.'},
     {role = 'user', content = prompt}}, tools, true,
    {session_id = host.uuid(), timeout_seconds = 300, on_line = record}, {selected = LEVEL})
  return result, table.concat(recorded, '\n') .. '\n', bytes, math.floor(host.monotonic_ms() - started)
end

local function write_fixture(name, body, lines)
  assert(body:find('response.completed', 1, true) or body:find('response.incomplete', 1, true),
    'the recorded stream has no terminal event: the fixture would be a truncation, not a stream')
  assert(host.write_file(name, body), 'the fixture must be written to ' .. name)
  print(string.format('fixture: %s (%d lines)', name, lines))
end

-- Pass 1: a stream that ends in a tool call - the decision telemetry and the call's id shape.
local zone = {{['function'] = {name = 'get_time', description = 'Read the current time for a zone.',
  parameters = {type = 'object', properties = {zone = {type = 'string'}}, required = {'zone'}}}}}
local tool_result, tool_body, tool_bytes, tool_ms = call(
  'Call the tool get_time exactly once with zone UTC, then reply with the single word DONE.', zone)
write_fixture('tests/fixtures/subscription/codex-responses-sse.txt', tool_body,
  select(2, tool_body:gsub('\n', '\n')))
for _, event in ipairs(samples) do
  if event.type == 'decision' then
    print(string.format('tool decision: complete=%s call_id=%s arguments_text=%s',
      tostring(event.complete), tostring(event.call_id), tostring(event.arguments_text)))
  end
end
print(string.format('pass 1: finish_reason=%s ttft_ms=%s events=%s usage=%s (%dms)', 
  tostring(tool_result.finish_reason), tostring(tool_result.ttft_ms), tostring(tool_result.events),
  json.encode(tool_result.usage), tool_ms))
for _, call_ in ipairs(tool_result.tool_calls or {}) do
  print(string.format('pass 1 tool call: id=%s name=%s arguments=%s', tostring(call_.id),
    tostring(call_['function'] and call_['function'].name),
    tostring(call_['function'] and call_['function'].arguments)))
end

-- Pass 2: a stream with text in it, so the provisional-then-resolved phase path is exercised on real
-- bytes: pre-tool prose arrives as `pending_delta` and is resolved when the message item completes.
counts, samples = {}, {}
local text_result, text_body, text_bytes, text_ms = call(
  'Write one short sentence saying what you are about to do, then call the tool get_time exactly ' ..
  'once with zone UTC, then reply with the single word DONE.', zone)
write_fixture('tests/fixtures/subscription/codex-responses-sse-text.txt', text_body,
  select(2, text_body:gsub('\n', '\n')))
print(string.format('pass 2: finish_reason=%s ttft_ms=%s events=%s answer=%s commentary=%d usage=%s (%dms)',
  tostring(text_result.finish_reason), tostring(text_result.ttft_ms), tostring(text_result.events),
  json.encode(text_result.content), #(text_result.commentary or {}), json.encode(text_result.usage),
  text_ms))

local kinds = {}
for kind in pairs(counts) do kinds[#kinds + 1] = kind end
table.sort(kinds)
local streamed = {}
for _, kind in ipairs(kinds) do streamed[#streamed + 1] = kind .. '=' .. counts[kind] end
print('pass 2 streamed events: ' .. table.concat(streamed, ' '))
print('pass 2 samples: ' .. json.encode(samples))
assert(counts.delta or counts.pending_delta or counts.commentary or counts.reasoning,
  'a text stream that emitted no text, reasoning or commentary event did not stream: the live ' ..
  'check would otherwise pass while the wire silently dropped every text event')
print('subscription wire live check ok')
