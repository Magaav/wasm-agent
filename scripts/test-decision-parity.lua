-- Parity: the subscription path's reader-visible decisions, against the same expectation fixture the
-- ordinary OpenAI-compatible path is asserted against in `rust/wa-host/src/host.rs`.
--
-- Hermetic: no network, no credential, no model, no Node. The wire is driven event by event through
-- `subscription_wire.session`, and the fixture carries both dialects plus one expected sequence, so
-- a change on either side that breaks the shared meaning fails one of the two readers instead of
-- each passing against its own prose. The ordinary half is produced in Rust (the reader there emits
-- the events); this script cannot call it, so it is the Rust test's job to check that half - what
-- this script adds is that the *same* file's expectation is what the subscription side produces.
local json = dofile('lua/vendor/json.lua')
local wire = dofile('lua/core/subscription_wire.lua')

local FIXTURE = 'tests/fixtures/decision-events/parity.json'
local raw = host.read_file(FIXTURE)
assert(raw and raw ~= '', 'the decision parity fixture ' .. FIXTURE .. ' must be present')
local fixture = json.decode(raw)
assert(type(fixture) == 'table', 'the decision parity fixture must decode')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function eq(actual, expected, message)
  check(actual == expected, message .. ' (got ' .. tostring(actual) .. ', want ' .. tostring(expected) .. ')')
end

-- The bound and the marker are one contract: the cap is in code points on both paths, and the note
-- a capped preview carries is the same text. Pinning them here means the Rust constant and this one
-- cannot silently drift apart while both suites stay green.
eq(wire.DECISION_PREVIEW_CHARS, fixture.bounded_preview_chars, 'the shared preview cap')
check(type(fixture.truncation_marker) == 'string' and #fixture.truncation_marker > 0,
  'the fixture names the truncation marker')

local emitted = {}
local session = wire.session({
  stream_id = 'decision-parity',
  run_id = 'decision-parity',
  started_ms = 0,
  emit = function(event) if event.type == 'decision' then emitted[#emitted + 1] = event end end,
})
for _, event in ipairs(fixture.subscription_events or {}) do
  assert(type(event.type) == 'string', 'every subscription fixture event names its type')
  session.event(event.type, json.encode(event))
end

local expected = fixture.expected_reader_semantics or {}
eq(#emitted, #expected, 'the subscription path publishes the same number of decisions as the shared expectation')
for index = 1, math.min(#emitted, #expected) do
  local actual, wanted = emitted[index], expected[index]
  eq(actual.complete, wanted.complete, 'decision ' .. index .. ' completion state')
  eq(actual.name, wanted.name, 'decision ' .. index .. ' tool name')
  eq(actual.arguments_text, wanted.arguments_text, 'decision ' .. index .. ' arguments text')
  eq(actual.arguments_truncated or false, wanted.arguments_truncated or false,
    'decision ' .. index .. ' truncation flag')
  check(type(actual.call_id) == 'string' and actual.call_id ~= '',
    'decision ' .. index .. ' carries a non-empty call id')
  check(actual.previous_call_id == nil,
    'a single stable call id needs no re-identification in the parity fixture')
end

-- A text-only exchange must produce no decision at all on this path either. Driven through the
-- same session shape, so "no tool call" cannot be confused with "the reader was never started".
local text_events = {}
local text_session = wire.session({
  stream_id = 'decision-parity-text',
  run_id = 'decision-parity-text',
  started_ms = 0,
  emit = function(event) if event.type == 'decision' then text_events[#text_events + 1] = event end end,
})
for _, event in ipairs({
  {type = 'response.created', response = {id = 'resp-text'}},
  {type = 'response.output_item.added', output_index = 0, item = {type = 'message', id = 'msg-1', role = 'assistant'}},
  {type = 'response.output_text.delta', output_index = 0, item_id = 'msg-1', delta = 'just words'},
  {type = 'response.output_item.done', output_index = 0, item = {type = 'message', id = 'msg-1', role = 'assistant',
    phase = 'final_answer', content = {{type = 'output_text', text = 'just words'}}}},
  {type = 'response.completed', response = {id = 'resp-text', status = 'completed',
    usage = {input_tokens = 1, output_tokens = 1, total_tokens = 2}}},
}) do
  text_session.event(event.type, json.encode(event))
end
eq(#text_events, 0, 'a text-only answer emits no decision on the subscription path')

print('decision parity ok (' .. checks .. ' checks)')
