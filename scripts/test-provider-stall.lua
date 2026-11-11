-- A provider that stops answering must surface in minutes, with a name - not after three long
-- attempts and an empty assistant row.
--
-- Measured on wasm_the_first, 10/11 (session a073ee85): a provider accepted the connection and then
-- said nothing. The run spent twelve minutes in three `timeout: receive response` failures before it
-- ended, and the ending was invisible. Two halves fix that, and this suite pins both:
--
--   * the *deadline* is per call and short (`WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS`, 90s): the
--     host builds that call its own agent, so the process-wide HTTP timeouts stay what they are for
--     every other endpoint;
--   * the *name* is `provider_stalled`, carried in the error and published as `provider.stalled` the
--     moment the call gives up, so a hook or a wake can see it without waiting for the run to end.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-provider-stall.lua wa --db /tmp/x.db
local real_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  if key == 'WASM_AGENT_PROVIDER_RETRIES' then return '0' end
  if key == 'WASM_AGENT_PROVIDER_RESPONSE_TIMEOUT_RETRIES' then return '0' end
  return real_getenv(key)
end
host.sleep = function() end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
local provider = dofile("lua/core/provider.lua")
local selfloop = dofile("lua/core/selfloop.lua")
memory.setup()

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then error(string.format("%s: got %q, want %q", what, tostring(got), tostring(want))) end
end
local function has(haystack, needle, what)
  checks = checks + 1
  if not string.find(tostring(haystack), needle, 1, true) then
    error(string.format("%s: %q does not contain %q", what, tostring(haystack), needle))
  end
end
local function ok(condition, what)
  checks = checks + 1
  if not condition then error(what) end
end

-- --------------------------------------------------------------- the deadline's shape
eq(provider.first_response_seconds(), 90, "a provider call gets its own 90s first-response deadline")
local saved = real_getenv("WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS")
host.getenv = (function(previous)
  return function(key)
    if key == "WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS" then return "45" end
    return previous(key)
  end
end)(host.getenv)
eq(provider.first_response_seconds(), 45, "the deadline is configurable")
host.getenv = (function(previous)
  return function(key)
    if key == "WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS" then return "0" end
    return previous(key)
  end
end)(host.getenv)
eq(provider.first_response_seconds(), 0, "0 turns the per-call deadline off (the process-wide one stays)")
host.getenv = (function(previous)
  return function(key)
    if key == "WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS" then return "3" end
    return previous(key)
  end
end)(host.getenv)
eq(provider.first_response_seconds(), 10, "a deadline shorter than a request could ever take is raised to 10s")
host.getenv = (function(previous)
  return function(key)
    if key == "WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS" then return saved end
    return previous(key)
  end
end)(host.getenv)

-- --------------------------------------------------------------- the name survives the transport
local stalled = "timeout: receive response (provider_stalled: no response within 90s)"
eq(provider.is_stalled(stalled), true, "the host's marker is recognised")
eq(provider.is_stalled("timeout: connect"), false, "a connect timeout is named by the failure layer, not this one")
has("provider_error: " .. stalled, "provider_stalled", "the marker survives the provider_error prefix")
ok(provider.is_response_timeout("provider_error: " .. stalled),
  "the response-timeout retry predicate still matches, so the deadline did not change retry behaviour")

-- --------------------------------------------------------------- the request carries the deadline
local user = "provider-stall"
local session_id = memory.ensure_session(user, "local", "stall")
local events = {}
local agent = agentlib.new(session_id, function(event) events[#events + 1] = event end, "master", user, "local")
agent.stream = true
-- A durable subscriber: the named event, not only the run's ending.
local watched = selfloop.schedule({ session_id = session_id, owner = user, reason = "watch provider stalls",
  prompt = "report the stall", on = { "provider.stalled" } },
  { session_id = session_id, user_id = user })
ok(watched and watched.ok, "the stall watcher is scheduled: " .. json.encode(watched or {}))

local seen_options, calls = nil, 0
local real_stream = host.http_stream
host.http_stream = function(method, url, headers, body, options)
  calls = calls + 1
  seen_options = options
  return json.encode({ error = stalled })
end
local run_ok, run_error = pcall(agent.run, agent, "ask the provider that stopped answering")
ok(not run_ok, "the run fails")
has(run_error, "provider_stalled", "the failure carries the name")
ok(calls >= 1, "the provider was called")
ok(type(seen_options) == "string", "the call carried its own options")
local decoded = json.decode(seen_options or "{}")
eq(decoded.first_response_seconds, 90, "and the deadline travelled with it")
host.http_stream = real_stream

local wakes = selfloop.list({ session_id = session_id }, { session_id = session_id, user_id = user })
local fired = nil
for _, wake in ipairs((wakes and wakes.wakes) or {}) do
  if wake.reason == "watch provider stalls" then fired = wake end
end
ok(fired and fired.due_at, "the named provider.stalled event fired the subscriber's wake")

-- The run's own record names the stall too (run_failure owns the wording; this pins the join).
local rows = memory.session_messages(session_id) or {}
local last = rows[#rows]
eq(last and last.role, "assistant", "the run ended with an assistant row")
has(last and last.content, "provider_stalled", "and the row names the stall")

print(string.format("ok provider-stall: %d checks", checks))
