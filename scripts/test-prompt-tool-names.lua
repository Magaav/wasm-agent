-- Every tool the prompt names must be callable in the envelope it is sent with.
--
-- A prompt that says "call `time`" to a model whose declarations lack `time` gets a skipped clock or
-- a wasted discovery round: providers only let a model call declared tools. This renders the prompt
-- for every role and envelope and checks each tool name it mentions - `backticked`, call syntax
-- name(...), tool_call(name="...") and bare snake_case tokens - against what that envelope can call.
--   generic + stack layers (authored in code): declared, or listed in the on-demand index, or
--     written as tool_call(name="..."), and in every case permitted for the role;
--   workflow + project layers (instruction files): a tool of that role's catalogue, so a renamed
--     tool or a guest file naming an operator tool fails.
-- The on-demand index itself must list every permitted, undeclared built-in tool (item: no tool is
-- unreachable because nobody told the model its name).
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local agent = dofile("lua/core/agent.lua")
local envelope = dofile("lua/core/envelope.lua")
local subagents = dofile("lua/core/subagents.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; if not value then error(label, 2) end end

local all_tools = {}
for _, role in ipairs({ "master", "guest" }) do
  for _, item in ipairs(tools.catalog(role)) do all_tools[item["function"].name] = true end
end

local function names_of(list)
  local out = {}
  for _, item in ipairs(list or {}) do out[item["function"].name] = true end
  return out
end

local function mentioned(text)
  local found = {}
  local function take(name) if all_tools[name] then found[name] = true end end
  for name in text:gmatch("`([%w_]+)`") do take(name) end
  for name in text:gmatch("`([%w_]+)%(") do take(name) end
  for name in text:gmatch("([%a][%w_]*)%(") do take(name) end
  for name in text:gmatch('tool_call%(name="([%w_]+)"') do take(name) end
  for name in text:gmatch("[%w_]+") do if name:find("_", 1, true) then take(name) end end
  return found
end

local function check_case(label, role, sections, declared, catalog, mode)
  local permitted = names_of(catalog)
  for name in pairs(declared) do permitted[name] = true end
  local role_catalog = names_of(tools.catalog(role))
  local indexed = {}
  local stack = sections.stack or ""
  for name in stack:gmatch("\n%- ([%w_]+)[:\n]") do indexed[name] = true end
  -- Full mode lists every visible skill's metadata; a description names the tools its procedure
  -- uses (often operator tools a guest may still read about). It is file content, not a call
  -- instruction, so it is excluded here; loading a skill is gated by the skill tool itself.
  local strict = (sections.generic or "") .. "\n" .. stack:gsub("<available_skills>.-</available_skills>", "")
  for name in pairs(mentioned(strict)) do
    local via_call = strict:find('tool_call(name="' .. name .. '"', 1, true) ~= nil
    local reachable = declared[name] or (mode == "progressive" and (indexed[name] or via_call))
    ok(reachable and permitted[name], label .. ": generic/stack names `" .. name .. "`, which this envelope cannot call")
  end
  local files = (sections.workflow or "") .. "\n" .. (sections.project or "")
  for name in pairs(mentioned(files)) do
    ok(role_catalog[name], label .. ": instructions name `" .. name .. "`, which is not a " .. role .. " tool")
  end
  if mode == "progressive" then
    local policy = dofile("lua/core/codemode_policy.lua")
    for name in pairs(permitted) do
      if not declared[name] and name ~= "tool_call" and name ~= "tool_search" and tools.snippet(name) then
        -- A connector tool (`mcp_*`, `peer_*`, and the one WhatsApp surface `mcp_whatsapp_*`) is named
        -- in the code-mode connector index, which a run carries when code mode is pinned - and it is
        -- deliberately left out of this built-in index (`agent.deferred_index`), because a connector is
        -- found through `tool_search` and called from a script. The item here is that no *built-in* is
        -- unreachable; the connector index completeness is `scripts/test-codemode-boundary.lua` and
        -- `scripts/test-whatsapp-one.lua`.
        ok(indexed[name] or policy.connector(name),
          label .. ": permitted tool `" .. name .. "` is missing from the on-demand index")
      end
    end
  end
end

local function project(role) return agent.project_instructions(role, dofile("lua/core/platform.lua").cwd()) end

for _, role in ipairs({ "master", "guest" }) do
  local catalog = tools.all(role)
  local boot = envelope.bootstrap(catalog, {})
  local files = project(role)
  check_case(role .. " progressive", role,
    agent.system_sections(role, files, nil, boot, "progressive", { catalog = catalog }),
    names_of(boot), catalog, "progressive")
  check_case(role .. " full", role,
    agent.system_sections(role, files, nil, catalog, "full", { catalog = catalog }),
    names_of(catalog), catalog, "full")
end

-- Orchestration on: the coordinator's declared surface gains route_task and subagent.
do
  local catalog = tools.all("master")
  local boot = envelope.bootstrap(catalog, {})
  local orch = {}
  for _, item in ipairs(boot) do orch[#orch + 1] = item end
  for _, item in ipairs(tools.catalog("master")) do
    local name = item["function"].name
    if name == "subagent" or name == "route_task" then orch[#orch + 1] = item end
  end
  local sections = agent.system_sections("master", project("master"), nil, orch, "progressive",
    { catalog = catalog, orchestration_enabled = true })
  ok(sections.workflow:find("## Orchestration on", 1, true) and not sections.workflow:find("## Orchestration off", 1, true),
    "orchestration on injects only its own section")
  check_case("master orchestration", "master", sections, names_of(orch), catalog, "progressive")
  local off = agent.system_sections("master", project("master"), nil, boot, "progressive", { catalog = catalog })
  ok(off.workflow:find("## Orchestration off", 1, true) and not off.workflow:find("orchestration_route_required", 1, true),
    "orchestration off carries no mode-on rules")
end

-- A subagent's prompt names only its own tools.
do
  local profile = subagents.resolve("orchestration-worker", { role = "master" })
  local list = agent.subagent_tool_list(profile, "master")
  local own = names_of(list)
  local prompt = agent.subagent_system_prompt({ subagent = profile, role = "master" }, list)
  for name in pairs(mentioned(prompt)) do
    ok(own[name], "subagent prompt names `" .. name .. "`, which its profile does not grant")
  end
end

-- `time` is part of every bootstrap, so the clock rule never points at an undeclared tool.
for _, mode in ipairs({ "lean", "classic" }) do
  local found = false
  for _, name in ipairs(envelope.core_names(mode)) do found = found or name == "time" end
  ok(found, mode .. " bootstrap declares time")
end

print("prompt tool names ok (" .. checks .. " checks, 0 skipped)")
