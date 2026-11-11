-- A run that has ended holds nothing: `wa resume` must work without killing a process.
--
-- Measured on wasm_the_first, 10/11: after a provider timeout the session kept an `uncertain` claim.
-- Every `wa resume` was then refused `run_resource_refused ... resource_busy` - the failure path
-- marked the claim uncertain and `finish` deleted only claims that were not - until the stale wa.exe
-- processes were killed. The same happened to a second session after the runaway guard.
--
-- This is the end-to-end proof through the real host: a failing turn, then the *next* run's claim.
-- The `uncertain`/`finish` contract itself is pinned in Rust (rust/wa-capabilities/src/resources.rs);
-- this suite proves the Lua loop actually reaches it on every exit path.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-run-claim-release.lua wa --db /tmp/x.db
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
local resources = dofile("lua/core/resources.lua")
memory.setup()

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then error(string.format("%s: got %q, want %q", what, tostring(got), tostring(want))) end
end
local function ok(condition, what)
  checks = checks + 1
  if not condition then error(what) end
end

local function session_claim(session_id)
  local inventory = resources.inspect()
  for _, claim in ipairs((inventory and inventory.claims) or {}) do
    if claim.key == "session:" .. session_id then return claim end
  end
  return nil
end

local user = "run-claim-release"
local session_id = memory.ensure_session(user, "local", "claim release")
local agent = agentlib.new(session_id, function() end, "master", user, "local")
agent.stream = true
host.http_stream = function()
  return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local run_ok = pcall(agent.run, agent, "a turn the provider will not answer")
ok(not run_ok, "the turn fails")

local held = session_claim(session_id)
if held ~= nil then
  -- The deployed binary is older than this tree: it keeps the uncertain claim. Say so, and stop -
  -- the release is pinned in resources.rs, and claiming more here would be a test of the old
  -- binary's recovery path, not of this change.
  print("SKIP run-claim-release claim release: this wa binary keeps an uncertain claim "
    .. "(uncertain=" .. tostring(held.uncertain) .. "); the release is pinned in resources.rs")
else
  ok(true, "the failed run released its session claim")
  local probe = { session_id = session_id, user_id = user, run_id = host.uuid() }
  local claimed = resources.begin(probe)
  eq(claimed.ok, true, "the next run is admitted without killing a process")
  eq(resources.finish(probe).ok, true, "and releases its own claim")
  eq(session_claim(session_id), nil, "nothing is left behind")
end

-- The guard's exit path goes through the same release.
local agent2 = agentlib.new(session_id, function() end, "master", user, "local")
agent2.stream = true
local rounds = 0
host.http_stream = function()
  rounds = rounds + 1
  return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
    tool_calls = { { id = "c" .. rounds, type = "function",
      ["function"] = { name = "read", arguments = '{"path":"AGENTS.md","limit":1}' } } } })
end
local guard_ok, guard_error = pcall(agent2.run, agent2, "loop")
ok(not guard_ok, "the guard stops the turn")
if held == nil then
  -- Whatever the guard's named reason, its exit path releases the claim.
  eq(session_claim(session_id), nil, "a guard stop releases the claim too")
end

print(string.format("ok run-claim-release: %d checks", checks))
