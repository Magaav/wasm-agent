-- The efficiency report is deterministic and spends no model call. This proves
-- the parts a reader would trust: the byte domination is of the whole request,
-- the cache/cost arithmetic is the provider's own categories priced at the
-- configured rates, a prefix break is named rather than hidden, an unmeasured
-- call stays unmeasured, and the prefix artifact is written where it says it is.
--
-- Run: WA_SCRIPT=scripts/test-efficiency-report.lua wa --db /tmp/x.db
local json = dofile('lua/vendor/json.lua')
local native_getenv = host.getenv
local RATES = { input = 0.15, output = 0.6, cacheRead = 0.003, cacheWrite = 0 }
host.getenv = function(key)
  if key == 'WASM_AGENT_MODEL_RATES' then return json.encode({ ['test-model'] = RATES }) end
  return native_getenv(key)
end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local telemetry = dofile('lua/core/telemetry.lua'); telemetry.setup()
local efficiency = dofile('lua/core/efficiency.lua')

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then error(label) end
end
local function near(a, b, tolerance, label)
  check(type(a) == 'number' and math.abs(a - b) <= tolerance,
    label .. ' (got ' .. tostring(a) .. ', want ' .. tostring(b) .. ')')
end
local function session(title)
  return memory.start_session('', title, { user_id = 'master', node_id = '', title = title })
end

local SHAPE = {
  system_bytes = 1000, user_bytes = 100, assistant_bytes = 2000, tool_result_bytes = 3000,
  other_bytes = 0, schema_bytes = 4000, reasoning_source_bytes = 800,
  tool_arguments_source_bytes = 300, messages = 10, tool_results = 3, tool_calls = 3,
  images = 0, total_message_bytes = 6100,
}
local RAW = {
  prompt_tokens = 10000, completion_tokens = 500,
  prompt_tokens_details = { cached_tokens = 9000 },
}

-- A clean, append-only call: every field the report reads is present.
local clean = session('efficiency-clean')
local start = telemetry.start({ session_id = clean, run_id = 'run' }, 'model_call', {
  model = 'test-model', provider = 'test-provider', settings = { reasoning = 'high' },
  prompt_shape = SHAPE,
  prefix_audit = { schema_version = 1, relation = 'append_only', shared_messages = 8,
    messages = 10, tools_changed = false, model_changed = false, routing_changed = false,
    cache_relevant_changed = false },
  request_hash = 'deadbeef', request_bytes = 10100,
})
telemetry.finish(start, { ok = true, usage = RAW, normalized = telemetry.normalize(RAW, RATES) })

local report = efficiency.build({ session_id = clean, hours = 48 })
check(report.available, 'a session with a model call is measured')
check(report.domination.whole_bytes == 10100, 'the whole request is messages plus schema bytes')
near(report.domination.rows[1].percent, 100 * 4000 / 10100, 0.01, 'the schema share is of the whole request')
local total_percent = 0
for _, row in ipairs(report.domination.rows) do
  if not row.subset then total_percent = total_percent + row.percent end
end
near(total_percent, 100, 0.001, 'the non-subset shares add up to 100 percent')
check(report.domination.rows[5].subset and report.domination.rows[5].percent == nil,
  'reasoning is a marked subset, not a second share of the whole')
check(report.domination.rows[5].stable == true,
  'reasoning is marked stable: it is prefix-stable and must not be offered as a target')

near(report.cache.hit_percent, 90, 0.001, 'cache read share is read over prompt')
check(report.cache.uncached == 1000, 'uncached input is prompt minus read and write')
check(report.cache.new_messages == 2, 'new messages are the current count minus the shared count')
check(#report.cache.reasons == 0, 'an append-only call has no cache-relevant change')
check(#report.signals == 0, 'a fully measured, priced, append-only call has no signal')

check(report.cache.cost.known, 'a priced model yields a known cost')
near(report.cache.cost.uncached_input, 1000 * 0.15 / 1000000, 1e-12, 'uncached input is priced at the input rate')
near(report.cache.cost.cache_read, 9000 * 0.003 / 1000000, 1e-12, 'cache read is priced at the cache rate')
near(report.cache.cost.output, 500 * 0.6 / 1000000, 1e-12, 'output is priced at the output rate')
near(report.cache.cost.total, (1000 * 0.15 + 9000 * 0.003 + 500 * 0.6) / 1000000, 1e-12, 'the call cost is the sum of its parts')
near(report.cache.cost.cache_percent_of_total, 100 * (9000 * 0.003) / (1000 * 0.15 + 9000 * 0.003 + 500 * 0.6),
  0.01, 'cache percent of call cost')

local text = efficiency.render(report)
check(text:find('efficiency report', 1, true) ~= nil, 'the rendered report names itself')
check(text:find('where the request bytes go', 1, true) ~= nil, 'the domination table is rendered')
check(text:find('footer', 1, true) ~= nil, 'the footer of report links is rendered')
check(text:find('docs/OBSERVABILITY.md', 1, true) ~= nil, 'the footer points at the observability doc')
check(text:find('reasoning is prefix-stable', 1, true) ~= nil,
  'the report says reasoning is stable, so an efficiency pass does not window it')

-- A prefix rewrite must be named, and the first changed message reported.
local broken = session('efficiency-rewritten')
local start2 = telemetry.start({ session_id = broken, run_id = 'run' }, 'model_call', {
  model = 'test-model', prompt_shape = SHAPE,
  prefix_audit = { schema_version = 1, relation = 'rewritten', shared_messages = 2,
    first_changed_message = 3, tools_changed = true, model_changed = false, routing_changed = false,
    cache_relevant_changed = true },
})
telemetry.finish(start2, { ok = true, usage = RAW, normalized = telemetry.normalize(RAW, RATES) })
local broken_report = efficiency.build({ session_id = broken })
check(broken_report.cache.relation == 'rewritten', 'the relation is carried through')
check(#broken_report.cache.reasons == 2, 'a rewritten prefix with a changed tool set names both reasons')
local joined = table.concat(broken_report.signals, ' | ')
check(joined:find('prefix rewritten', 1, true) ~= nil, 'a prefix break is a signal')
check(joined:find('tool set changed', 1, true) ~= nil, 'a changed tool set is a signal')

-- An unmeasured call must stay unmeasured, not become a free one.
local unknown = session('efficiency-unknown')
local start3 = telemetry.start({ session_id = unknown, run_id = 'run' }, 'model_call', {
  model = 'test-model', prompt_shape = SHAPE,
})
telemetry.finish(start3, { ok = false, error = 'provider_error', normalized = telemetry.normalize(nil) })
local unknown_report = efficiency.build({ session_id = unknown })
check(unknown_report.cache.known == false and unknown_report.cache.hit_percent == nil,
  'a call with no cache usage has an unknown hit rate')
local unknown_text = efficiency.render(unknown_report)
check(unknown_text:find('unknown, not zero', 1, true) ~= nil, 'the unknown cache rate says so')

-- The prefix artifact is written from a debug capture, and the markdown is readable.
local with_prefix = session('efficiency-prefix')
memory.append_turn(with_prefix, {
  role = 'assistant', content = 'reply', trace = { {
    kind = 'model_call',
    request = {
      model = 'test-model',
      messages = {
        { role = 'system', content = 'SYSTEM PROMPT SENTINEL' },
        { role = 'user', content = 'hello' },
        { role = 'assistant', content = 'hi' },
      },
      tools = { { ['function'] = { name = 'read', description = 'read a file', parameters = {} } } },
    },
  } },
})
local start4 = telemetry.start({ session_id = with_prefix, run_id = 'run' }, 'model_call', {
  model = 'test-model', prompt_shape = SHAPE,
  prefix_audit = { schema_version = 1, relation = 'append_only', shared_messages = 1, messages = 3 },
})
telemetry.finish(start4, { ok = true, usage = RAW, normalized = telemetry.normalize(RAW, RATES) })
local artifact = efficiency.dump_prefix(nil, with_prefix)
check(artifact.error == nil, 'a debug capture dumps without a live agent')
check(artifact.source:find('debug', 1, true) ~= nil, 'the artifact names its source')
check(artifact.markdown and host.read_file(artifact.markdown), 'the markdown artifact is written')
check(host.read_file(artifact.markdown):find('SYSTEM PROMPT SENTINEL', 1, true) ~= nil,
  'the markdown holds the system prompt, so a human can read the prefix')
check(artifact.json and host.read_file(artifact.json), 'the exact JSON artifact is written')

-- A session with no call is not a zero-cost session.
local empty = session('efficiency-empty')
local empty_report = efficiency.build({ session_id = empty })
check(empty_report.available == false, 'a session with no call is unmeasured')
check(efficiency.render(empty_report):find('no model call recorded', 1, true) ~= nil,
  'the empty report says there is nothing to measure')

print('efficiency report ok (' .. checks .. ' checks)')
