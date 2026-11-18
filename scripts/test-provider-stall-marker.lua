-- Only a stall carries the stall marker (18/11 round 2, finding 5).
--
-- Round 1 added "(provider_stalled: no response within Ns)" to EVERY send() error, so a refused
-- connection or a failed name resolution came back named as a provider stall - and the stall replay
-- (lua/core/provider.lua, is_response_timeout) reads exactly that marker. A transport failure must keep
-- its own name; only "the request went out and no response header came back before the deadline" is a
-- stall, because only that one is safe to replay.
--
-- The row makes a real request to a closed loopback port: nothing listens, so the failure is the
-- transport's own (connection refused), not a stall. Hermetic: loopback only, no network, no provider.
local json = dofile('lua/vendor/json.lua')
local provider = dofile('lua/core/provider.lua')
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

if not (host.http_stream) then
  print('SKIP provider-stall-marker: this binary has no host.http_stream')
  return
end

-- A port nothing listens on: bind nothing, ask for a free port and do not take it.
local port
for candidate = 45917, 45930 do
  local probe = host.tcp_probe and host.tcp_probe('127.0.0.1', candidate)
  if probe == nil or probe == false then port = candidate break end
end
port = port or 45917
local url = 'http://127.0.0.1:' .. port .. '/v1/chat/completions'
local raw = host.http_stream('POST', url, json.encode({ ['content-type'] = 'application/json' }),
  json.encode({ model = 'none', messages = {} }), json.encode({ first_response_seconds = 2 }))
local answer = type(raw) == 'string' and raw or json.encode(raw or {})
check(answer ~= '', 'the call answered something: ' .. tostring(answer):sub(1, 300))
-- The failure is the transport's, and it keeps its own name: no stall marker, and the failure layer
-- does not classify it as a stall either.
check(answer:find('provider_stalled', 1, true) == nil,
  'a refused connection is NOT a stall: ' .. tostring(answer):sub(1, 400))
check(provider.is_response_timeout('provider_error: ' .. answer) == false,
  'and the stall replay does not fire for it: ' .. tostring(answer):sub(1, 400))
local classified = dofile('lua/core/run_failure.lua').classify('provider_error: ' .. answer)
check(classified.code ~= 'provider_stalled',
  'the failure layer names it as the transport failure it is, not as a stall: ' .. tostring(classified.code))

-- The positive side of the same rule is a timeout, and it is what the marker exists for: a timeout
-- while waiting for the response headers carries it, a connect timeout does not.
local marker = ' (provider_stalled: no response within 2s)'
check(provider.is_response_timeout('provider_error: timeout: receive response' .. marker) == true,
  'a receive-response timeout is the stall the replay exists for')
check(provider.is_response_timeout('provider_error: timeout: connect' .. marker) == false,
  'a connect timeout is not: nothing was sent, so nothing may be replayed as a stall')

print(string.format("ok provider-stall-marker: %d checks", checks))
