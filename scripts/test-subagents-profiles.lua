-- Model-free contract checks for the local-subagent policy layer.
--
-- Run ONLY through: node scripts/test-subagents-policy.cjs [wa-binary]
-- A scratch database alone is NOT isolation: this suite writes profiles under paths.config().
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local expected_home = host.getenv("WA_TEST_SUBAGENT_HOME") or ""
local fixture_token = host.getenv("WA_TEST_SUBAGENT_TOKEN") or ""
local function normalized(value) return tostring(value):gsub("\\", "/"):gsub("/+$", "") end
assert(expected_home ~= "" and fixture_token ~= "", "policy_fixture_requires_isolated_wrapper")
assert(normalized(paths.home()) == normalized(expected_home), "policy_fixture_home_mismatch")
assert(host.read_file(paths.home() .. "/.subagent-policy-fixture") == fixture_token,
  "policy_fixture_marker_mismatch")
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()

local subagents = dofile("lua/core/subagents.lua")
local checks = 0
local function check(value, label)
  if not value then error("FAIL: " .. label, 2) end
  checks = checks + 1
end
local function ctx(user, role, session)
  return { user_id = user or "alice", role = role or "master", session_id = session or "parent-thread",
           run_id = "parent-run", node_id = "" }
end

-- 1. Built-in profiles exist and are what the default read-only promise says.
local profiles = subagents.profiles()
check(profiles.explore and profiles.guest, "explore and guest built-ins must exist")
check(profiles.explore.builtin == true and profiles.guest.builtin == true, "built-ins are marked builtin")
local explore, refusal = subagents.resolve("explore", ctx("alice"))
check(explore, "explore resolves for a master: " .. tostring(refusal))
check(#explore.allowed_tools > 0 and not explore.allowed.bash and not explore.allowed.write,
  "explore must not carry bash or write")
check(explore.allowed.graph,
  "explore must be able to navigate the code graph, or a delegated exploration is blind to it")
local guest_profile, guest_refusal = subagents.resolve("guest", ctx("guest1", "guest"))
check(guest_profile, "guest resolves for a guest: " .. tostring(guest_refusal))
check(not guest_profile.allowed.bash and not guest_profile.allowed.read,
  "a guest child never gets a shell or file reads")

-- 2. A profile name cannot elevate: explore's `read` is not in a guest ceiling.
local clamped, clamp_refusal = subagents.resolve("explore", ctx("guest1", "guest"))
check(clamped == nil, "a guest must not resolve a master read-only profile")
check(tostring(clamp_refusal):find("profile_exceeds_caller", 1, true), "the refusal names the exceeded tool: " .. tostring(clamp_refusal))

-- 3. A broad profile requires explicit operator authorization.
local dir = paths.config() .. "/subagent-profiles"
local function write_profile(name, body)
  -- host.write_file creates the parent directory and writes atomically, so this
  -- works identically on Windows and Linux without a shell.
  assert(host.write_file(dir .. "/" .. name .. ".json", json.encode(body)), "write profile " .. name)
end
write_profile("worker-insecure", {
  schema_version = 1, id = "worker-insecure",
  allowed_tools = { "read", "write", "bash" }, limits = {},
})
local insecure, insecure_refusal = subagents.resolve("worker-insecure", ctx("alice"))
check(insecure == nil, "a broad profile without operator_authorized must be refused")
check(tostring(insecure_refusal):find("profile_not_authorized", 1, true), "the refusal names authorization: " .. tostring(insecure_refusal))
write_profile("worker-secure", {
  schema_version = 1, id = "worker-secure", operator_authorized = true,
  allowed_tools = { "read", "write", "edit" },
  resources = { conversation = "conv-1" },
  limits = { timeout_seconds = 120, sends_per_run = 3 },
  instructions = "do the narrow task",
})
local secure, secure_refusal = subagents.resolve("worker-secure", ctx("alice"))
check(secure, "an operator-authorized broad profile resolves: " .. tostring(secure_refusal))
check(secure.allowed.write and secure.allowed.read, "the authorized profile keeps its exact tools")
check(secure.limits.max_tokens==nil and secure.limits.max_cost_usd==nil,'omitted cumulative budgets are unlimited')
check(explore.limits.max_tokens==nil and guest_profile.limits.max_tokens==100000,'general exploration unlimited, guest explicit cap preserved')
local listed=subagents.control({action='profiles'},ctx('alice'))
local discovery
for _,item in ipairs(listed.profiles) do if item.id=='worker-secure' then discovery=item end end
check(discovery and discovery.token_budget=='unlimited' and #discovery.effective_models>0,'profile discovery exposes effective models and budget semantics')
check(discovery.reasoning_choices[discovery.effective_models[1]]~=nil,'profile discovery exposes reasoning choices')
-- A specialist profile's own resources and limit names must survive resolution, or
-- the child is handed a different authority than the operator approved.
check(secure.resources.conversation == "conv-1", "the resolved resources must survive")
check(secure.limits.sends_per_run == 3, "a specialist limit must survive resolution")

-- 4. A malformed or misnamed file is reported, never silently dropped.
write_profile("wrong-name", { schema_version = 1, id = "another-id", allowed_tools = { "read" } })
local _, errors = subagents.profiles()
local found_error = false
for _, entry in ipairs(errors or {}) do
  if tostring(entry.path):find("wrong-name", 1, true) then found_error = true end
end
check(found_error, "a misnamed profile file must be reported")

-- 5. Schema filtering and dispatch re-check are the same exact set.
local filtered = tools.all_for({ read = true, grep = true }, "master")
check(#filtered == 2, "all_for returns exactly the allowed tools, got " .. #filtered)
for _, item in ipairs(filtered) do
  check(item["function"].name == "read" or item["function"].name == "grep", "unexpected tool " .. item["function"].name)
end
-- 5b. The production snapshot shape - the list the profile declared *and* the set
--     the runtime derived from it - must reach the schemas a child is offered.
--     Passing the list where a set was expected offered every child nothing.
local from_both = agentlib.subagent_tool_list({ allowed = { read = true, grep = true },
  allowed_tools = { "read", "grep" } }, "master")
check(#from_both == 2, "a child must be offered its profile's schemas, got " .. #from_both)
local from_list_only = agentlib.subagent_tool_list({ allowed_tools = { "read" } }, "master")
check(#from_list_only == 1 and from_list_only[1]["function"].name == "read",
  "a list-only snapshot must still offer the schemas")
check(#agentlib.subagent_tool_list({ allowed = {}, allowed_tools = {} }, "master") == 0,
  "an empty profile must still offer no schemas")
check(#agentlib.subagent_tool_list(nil, "master") == 0, "a snapshot-less child offers no schemas")
local denied = tools.dispatch(memory, "bash", { command = "echo hi" }, "master",
  { user_id = "alice", subagent = { allowed = { read = true } } })
check(denied.error == "capability_not_in_profile:bash", "dispatch must refuse a tool outside the profile")

-- 6. The lean child prompt carries the boundary and the profile, and never the
--    operator instruction file.
local child = agentlib.new("child-session", function() end, "master", "alice", "", {
  subagent = { id = "explore", allowed = { read = true }, allowed_tools = { "read" },
    instructions = "PROFILE-INSTRUCTION-MARKER", limits = { max_tokens = 1000 } },
})
local prompt = agentlib.subagent_system_prompt(child, tools.all_for({ read = true }, "master"))
check(prompt:find("PROFILE-INSTRUCTION-MARKER", 1, true), "the profile instruction must be present")
check(prompt:find("You are a subagent", 1, true), "the mandatory boundary must be present")
check(not prompt:find("Project-specific instructions", 1, true), "a child must not get the operator project instructions")
check(not prompt:find("AGENTS.md", 1, true), "a child must not be pointed at AGENTS.md")
-- The admission estimate is the first call's system/schema/user estimate. A
-- refusal must happen before a child session or native task is created.
local initial=agentlib.subagent_initial_tokens({id="explore",allowed={read=true},
  allowed_tools={"read"},instructions="PROFILE-INSTRUCTION-MARKER",limits={max_tokens=1000}},
  "master","investigate a file")
check(initial>0,"initial context estimator includes system, schema and task")
write_profile("tiny-budget",{schema_version=1,id="tiny-budget",allowed_tools={"read"},
  limits={max_tokens=1}})
local before=memory.list_sessions("alice",100)
local refusal_budget=subagents.start({profile="tiny-budget",prompt="investigate a file"},ctx("alice"))
check(tostring(refusal_budget.error):find("subagent_token_budget",1,true)~=nil and
  refusal_budget.estimated_prompt_tokens>=refusal_budget.max_tokens,
  "a too-small budget refuses at admission with its estimate")
check(#memory.list_sessions("alice",100)==#before,"budget refusal creates no child session")

-- 7. The tool list is visible to both roles, so a guest may spawn within its own
--    reduced authority, and the facade is named `subagent`.
local function has_tool(role, name)
  for _, item in ipairs(tools.all(role)) do
    if item["function"].name == name then return true end
  end
  return false
end
check(has_tool("master", "subagent"), "a master must see the subagent tool")
check(has_tool("guest", "subagent"), "a guest must see the subagent tool so it can spawn within its own authority")

-- 8. A child caller cannot recurse: the facade refuses start from a child ctx.
local recurse = subagents.control({ action = "start", profile = "explore", prompt = "x" },
  { user_id = "alice", role = "master", session_id = "child-session", run_id = "r",
    node_id = "", subagent = { id = "explore", depth = 1, allowed = { read = true } } })
check(recurse.error == "subagent_recursion_forbidden", "a child must not start a grandchild")

-- 9. The public HTTP facade resolves ownership server-side and never trusts the
--    body. With no model configured, start fails visibly but must not be
--    reachable with a body-supplied owner.
local facade = json.decode(wa_subagents(json.encode({ action = "profiles" }), ""))
check(type(facade.profiles) == "table", "the facade answers a control action")

-- 10. Session routing: a normal session must stay reusable, and a subagent
--     session must never be picked up as the conversation for a normal turn.
local normal = memory.start_session("", "chat", { user_id = "routing-user", node_id = "routing-node" })
check(memory.ensure_session("routing-user", "routing-node", "chat") == normal,
  "ensure_session must reuse a normal open session")
local child_session = memory.start_session("routing-node", "subagent",
  { user_id = "routing-user", node_id = "routing-node", parent_session_id = normal })
check(memory.ensure_session("routing-user", "routing-node", "chat") == normal,
  "ensure_session must never pick a subagent session")
check(memory.session(child_session).parent_session_id == normal,
  "a subagent session must carry its parent link")

-- 11. An empty `allowed_tools` means reasoning-only: no tools at all, and the
--     schema list a child is offered is empty.
write_profile("reason-only", {
  schema_version = 1, id = "reason-only", allowed_tools = {}, limits = { timeout_seconds = 60 },
})
local reason_only, reason_refusal = subagents.resolve("reason-only", ctx("alice"))
check(reason_only, "an empty allowed_tools profile must resolve: " .. tostring(reason_refusal))
check(#reason_only.allowed_tools == 0, "an empty profile must allow no tools")
check(#tools.all_for(reason_only.allowed, "master") == 0, "an empty profile must offer no schemas")

-- 12. An explicitly empty parent ceiling means none, never the role default.
local no_tools, no_tools_why = subagents.resolve("explore", { role = "master", ceiling = {} })
check(no_tools == nil, "an empty ceiling must not be re-derived from the role")
check(tostring(no_tools_why):find("profile_exceeds_caller", 1, true), "the refusal names the tool: " .. tostring(no_tools_why))

-- 13. Malformed, negative or unpriceable budgets are refused, not coerced.
write_profile("bad-token-limit", { schema_version = 1, id = "bad-token-limit", allowed_tools = {}, limits = { max_tokens = -5 } })
local bad, bad_why = subagents.resolve("bad-token-limit", ctx("alice"))
check(bad == nil and tostring(bad_why) == "invalid_limit:max_tokens",
  "a negative limit must be refused: " .. tostring(bad_why))
write_profile("malformed-limit", { schema_version = 1, id = "malformed-limit", allowed_tools = {}, limits = { max_tokens = "many" } })
local malformed, malformed_why = subagents.resolve("malformed-limit", ctx("alice"))
check(malformed == nil and tostring(malformed_why) == "invalid_limit:max_tokens",
  "a non-numeric limit must be refused: " .. tostring(malformed_why))
write_profile("cost-cap", { schema_version = 1, id = "cost-cap", allowed_tools = {}, limits = { max_cost_usd = 0.5 } })
local cost_start = subagents.control({ action = "start", profile = "cost-cap", prompt = "x" }, ctx("alice"))
check(cost_start.error == "cost_budget_requires_rates",
  "a dollar cap without known rates must fail closed: " .. json.encode(cost_start))

dofile('scripts/test-subagent-selection.lua')
print(string.format("subagents profiles ok (%d checks)", checks))
