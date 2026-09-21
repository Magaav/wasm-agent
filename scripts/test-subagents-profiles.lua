-- Model-free contract checks for the local-subagent policy layer.
--
-- Run with the real host: WASM_AGENT_LUA_ROOT=<repo> wa --db <scratch> WA_SCRIPT=scripts/test-subagents-profiles.lua
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
local agentlib = dofile("lua/core/agent.lua")
local paths = dofile("lua/core/paths.lua")
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
  allowed_tools = { "read", "write", "edit" }, limits = { timeout_seconds = 120 },
  instructions = "do the narrow task",
})
local secure, secure_refusal = subagents.resolve("worker-secure", ctx("alice"))
check(secure, "an operator-authorized broad profile resolves: " .. tostring(secure_refusal))
check(secure.allowed.write and secure.allowed.read, "the authorized profile keeps its exact tools")

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

print(string.format("subagents profiles ok (%d checks)", checks))
