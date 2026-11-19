-- The tool-environment deny rule is a SHAPE, and the node's policy may re-grant a NAME (session
-- isolation, finding 5, round 2). One script, two invocations - that is the whole point: the same code
-- must withhold a secret by shape and hand the very same variable over when the policy lists it.
--
--   withheld (no policy):  WA_TEST_ENV_ALLOW=withheld  GH_TOKEN=... wa --db <scratch>/t.db
--   granted:               WA_TEST_ENV_ALLOW=granted WA_GRANT_POLICY=<scratch>/policy.json
--                          ({"version":1,"tool_env_allow":["GH_TOKEN"]})  GH_TOKEN=...
--
-- scripts/test-tool-env-allow.sh runs both. The canaries are exported by that runner and never real.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local mode = tostring(host.getenv("WA_TEST_ENV_ALLOW") or "withheld")
local ctx = { session_id = "env-allow-probe", user_id = "master" }

-- A child's environment, read the way a model would read it.
local probe = tools.dispatch(memory, "bash", { command = "env" }, "master", ctx) or {}
local environment = tostring(probe.stdout or "")
ok(environment ~= "", "the bash child ran and printed its environment: " .. tostring(probe.error))
-- The control: an ordinary name still arrives, so "absent" below is about the rule and not about a child
-- that printed nothing (the same control the other session-isolation sections use).
ok(environment:find("ISOLATION_TEST_PLAIN=", 1, true) ~= nil, "an ordinary variable still reaches the child")
-- Every one of these is withheld by SHAPE, whatever the policy says about GH_TOKEN.
for _, name in ipairs({ "ISOLATION_TEST_TOKEN", "ISOLATION_TEST_SECRET", "ISOLATION_TEST_PASSWORD",
    "ANTHROPIC_AUTH_TOKEN", "WASM_AGENT_LLM_API_KEY" }) do
  if host.getenv(name) == nil then print("note: " .. name .. " was not exported by the runner") end
  ok(not environment:find(name .. "=", 1, true), "a name the deny shapes match is withheld: " .. name)
end

-- The one variable the two invocations differ on.
local held = environment:find("GH_TOKEN=", 1, true) ~= nil
if mode == "granted" then
  ok(held, "the policy's tool_env_allow hands GH_TOKEN to the child")
else
  ok(not held, "without the policy, GH_TOKEN is withheld")
end

-- And the record SAYS so, with the key to add: an operator reading a failing gh must not have to guess.
local started = tools.dispatch(memory, "operation", { action = "start", command = "echo env-allow",
  timeout_seconds = 30 }, "master", ctx) or {}
if type(started.operation_id) == 'string' then
  local state = tools.dispatch(memory, "operation", { action = "status", id = started.operation_id }, "master", ctx) or {}
  local names, named = state.env_withheld or {}, false
  for _, entry in ipairs(type(names) == 'table' and names or {}) do
    if tostring(entry) == "GH_TOKEN" then named = true end
  end
  if mode == "granted" then
    ok(not named, "a granted name is not reported as withheld: " .. json.encode(names))
  else
    ok(named, "the record names GH_TOKEN as withheld: " .. json.encode(names))
    ok(tostring(state.env_withheld_note or ""):find("tool_env_allow", 1, true) ~= nil,
      "and says where to allow it: " .. tostring(state.env_withheld_note))
    ok(tostring(state.env_withheld_note or ""):find("GH_TOKEN", 1, true) ~= nil, "naming the variable itself")
  end
  tools.dispatch(memory, "operation", { action = "cancel", id = started.operation_id }, "master", ctx)
end

print(string.format("tool env allow (%s): %d checks, %d failed", mode, checks, failed))
if failed > 0 then os.exit(1) end

