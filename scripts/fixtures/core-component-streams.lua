-- A2.2 (docs/KERNEL.md): what the Lua core can do through the component bridge - a table argument,
-- a streaming capability whose answer arrives one item at a time (`host.http_sse`), and the console
-- capabilities that only draw. Runs **unchanged** in both modes: native (`WA_SCRIPT`) and inside the
-- agent-core component (`wa --core-component`). That is the point: the Lua-facing API is identical,
-- so this script is its own parity test.
--
-- scripts/test-core-component-streams.mjs starts the local SSE stub (127.0.0.1, no internet), runs
-- this file both ways and fails when the two outputs differ. Every check below therefore has to hold
-- on both sides - which is why the two cases that can only differ (a function argument, the console
-- reader) accept either the native answer or the documented refusal, and count one check either way.
local json = dofile('lua/vendor/json.lua')
local checks = 0
local function check(value, label) checks = checks + 1; if not value then error('STREAM CHECK FAILED: ' .. label) end end
local url = host.getenv('WA_SSE_STUB_URL')
if not url or url == '' then print('core streams: skipped (WA_SSE_STUB_URL is not set)'); return end

-- 1. Lines arrive in order and unmodified, and the answer is the shape the native call returns.
local lines = {}
local outcome = json.decode(host.http_sse('POST', url .. '/events', '{}', '{"ping":true}', function(line)
  lines[#lines + 1] = line
end, 30))
check(type(outcome) == 'table', 'http_sse answers JSON')
check(outcome.status == 200, 'status 200, got ' .. tostring(outcome.status))
check(outcome.termination == 'eof', 'eof termination, got ' .. tostring(outcome.termination))
check(outcome.lines == 6, 'six lines counted, got ' .. tostring(outcome.lines))
check(#lines == 6, 'six lines delivered, got ' .. #lines)
check(lines[1] == 'data: {"n":1}', 'first line exact, got ' .. tostring(lines[1]))
check(lines[2] == '', 'the blank line between events is a line too, got ' .. tostring(lines[2]))
check(lines[5] == 'data: done', 'last data line exact, got ' .. tostring(lines[5]))

-- 2. A callback that returns false stops the read where it said so, successfully.
local stopped = json.decode(host.http_sse('POST', url .. '/events', '{}', '{}', function(line)
  lines[#lines + 1] = line
  return not (line == 'data: {"n":2}')
end, 30))
check(stopped.termination == 'callback_stopped', 'callback_stopped, got ' .. tostring(stopped.termination))
check(stopped.lines == 3, 'stopped on the third line, got ' .. tostring(stopped.lines))

-- 3. A callback that raises ends the read at that line with the error text, as native.
local raised = json.decode(host.http_sse('POST', url .. '/events', '{}', '{}', function(line)
  if line == 'data: {"n":2}' then error('stream callback refused') end
end, 30))
check(raised.termination == 'line_callback_failed', 'line_callback_failed, got ' .. tostring(raised.termination))
check(type(raised.error) == 'string' and raised.error:find('stream callback refused', 1, true) ~= nil,
  'the callback error text is reported, got ' .. tostring(raised.error))
check(raised.lines == 3, 'three lines read, got ' .. tostring(raised.lines))

-- 4. A non-200 is reported with its status and body, not read as events.
local failed = json.decode(host.http_sse('POST', url .. '/error', '{}', '{}', function() end, 30))
check(failed.status == 500, 'http 500 reported, got ' .. tostring(failed.status))
check(failed.termination == 'http_error', 'http_error, got ' .. tostring(failed.termination))
check(failed.body == 'upstream exploded', 'the error body is kept, got ' .. tostring(failed.body))

-- 5. The refusals the native capability makes before it opens a socket are the same refusals here.
check(json.decode(host.http_sse('POST', url .. '/events', '{}', '{}', nil)).error == 'http_sse_requires_on_line',
  'a call without a callback is refused, in the native words')
check(json.decode(host.http_sse('GET', url .. '/events', '{}', '{}', function() end)).error == 'method_not_supported',
  'a non-POST is refused, in the native words')
check((json.decode(host.http_sse('POST', url .. '/events', '{}', '{}', function() end, 0)).error or ''):find('invalid_sse_timeout', 1, true) ~= nil,
  'a timeout outside 1..86400 is refused, in the native words')

-- 6. Lines reach the callback while the socket is open: the stub holds the stream 250 ms after the
--    first line, so a reader that buffered the body would not see line one until the end.
local first_at, ended_at = nil, nil
local started = host.monotonic_ms()
local streamed = json.decode(host.http_sse('POST', url .. '/stream', '{}', '{}', function(line)
  if not first_at then first_at = host.monotonic_ms() - started end
end, 30))
ended_at = host.monotonic_ms() - started
check(streamed.termination == 'eof', 'the held stream still ends at eof, got ' .. tostring(streamed.termination))
check(type(first_at) == 'number' and first_at < 200, 'the first line arrives before the stream ends, first=' .. tostring(first_at))
check(ended_at >= 200, 'the stub really held the stream, ended=' .. tostring(ended_at))

-- 7. A **table** argument crosses the bridge: the capability receives a table, not a refusal. `sleep`
--    ignores its argument, so what is asserted is that the call completed instead of being refused,
--    and that the shapes JSON can carry are all accepted.
for _, argument in ipairs({ {}, { 1, 2, 3 }, { seconds = 0, nested = { list = { 'a', 1.5 } } } }) do
  local ok, problem = pcall(host.sleep, argument)
  check(ok, 'a table argument reaches the capability: ' .. tostring(problem))
end

-- 8. A Lua function still cannot cross, except where the capability calls back (http_sse above): the
--    native interpreter ignores it. Both answers are correct, and this check says which one it saw.
local passed, refusal = pcall(host.sleep, print)
if not passed then
  check(type(refusal) == 'string' and refusal:find('unsupported_in_component_v1:sleep', 1, true) == 1,
    'a function argument is refused by name: ' .. tostring(refusal))
else
  check(true, 'the native interpreter accepted a function argument')
end

-- 9. Console capabilities that only draw answer as they do to a native run with no editor in front of
--    them. `WASM_AGENT_CLI_TICKER=off` in the harness: a drawing ticker writes animation frames to
--    stdout, which no byte-for-byte comparison can call equal.
check(host.editor_status(true) == false, 'editor_status answers false with no editor')
check(host.editor_footer('hint', 'model') == false, 'editor_footer answers false with no editor')
check(json.decode(host.panel(json.encode({ title = 'a panel', rows = { 'one' } }))).action == 'unsupported',
  'panel answers unsupported with no editor')
check(host.ticker(nil) == nil, 'ticker(nil) answers nil')

-- 10. The interactive reader is not available to a component, and says so where it is refused.
local taken = table.pack(pcall(host.input_take))
if taken[1] then
  check(true, 'the native interpreter has the console reader')
else
  check(type(taken[2]) == 'string' and taken[2]:find('unsupported_in_component_v1:input_take', 1, true) == 1
    and taken[2]:find('interactive console reader', 1, true) ~= nil,
    'the console reader is refused, with its reason: ' .. tostring(taken[2]))
end

print('core streams ok (' .. checks .. ' checks)')
