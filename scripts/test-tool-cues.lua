-- The prompt index must not duplicate the schema.
--
-- The index line for a tool is an authored discovery cue (`tools.snippet`), because
-- `description:match("^[^.]*")` put the schema's first sentence in the request twice and the
-- description's opening is written to explain, not to be found. This test pins the three
-- properties: every built-in has a cue, no cue is stale, the schema description never leaks
-- into the index, and the two prompt builders both read the cue (with the names-only switch
-- still able to drop it for the experiment).
local json = dofile("lua/vendor/json.lua")
local tools = dofile("lua/core/tools.lua")
local agent = dofile("lua/core/agent.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

-- Every built-in tool has a cue: shared, admin, and the `tool_result` added for a master.
local builtin = {}
for _, item in ipairs(tools.shared) do builtin[item["function"].name] = true end
for _, item in ipairs(tools.admin) do builtin[item["function"].name] = true end
builtin["tool_result"] = true
for name in pairs(builtin) do
  ok(tools.snippet(name) ~= nil, "every built-in tool needs a cue: " .. name)
end

-- No stale cue: every cue names a tool the registry knows. The catalog, not the prompt
-- projection: a cue may belong to a tool a child gets while the parent prompt hides it (the
-- WhatsApp responder), so `all` alone would call those cues stale.
local catalog = tools.catalog or tools.all
local available = {}
for _, item in ipairs(catalog("master")) do available[item["function"].name] = true end
for _, name in ipairs(tools.cue_names()) do
  ok(available[name] == true, "a cue must name a real tool: " .. name)
end

-- The index line is the cue, and the schema description does not leak into it.
local tool_list = tools.all("master")
local prompt = agent.system_prompt("master", nil, nil, tool_list)
ok(prompt:find("- read: " .. tools.snippet("read"), 1, true) ~= nil,
  "the index line must be the authored cue")
local read_description
for _, item in ipairs(tool_list) do
  if item["function"].name == "read" then read_description = item["function"].description end
end
ok(read_description ~= nil, "read must be in the master tool list")
ok(prompt:find(read_description:sub(1, 40), 1, true) == nil,
  "the schema description must not be duplicated in the index")

-- Shell search has a faster default without pretending that the native grep tool is
-- the shell program: native grep remains the portable, bounded literal-search contract.
local rg_guidance = "prefer ripgrep (`rg` and `rg --files`)"
ok(prompt:find(rg_guidance, 1, true) ~= nil,
  "a master with bash must prefer ripgrep for shell search and file discovery")
local no_shell = agent.system_prompt("master", nil, nil,
  tools.all_for({ read = true, grep = true }, "master"))
ok(no_shell:find(rg_guidance, 1, true) == nil,
  "ripgrep guidance must not be offered when bash is unavailable")

-- The child prompt reads the same cue; the names-only switch still drops it.
local bot = { subagent = { id = "test", instructions = "", limits = {} }, role = "master" }
local child = agent.subagent_system_prompt(bot, tool_list)
ok(child:find("- read: " .. tools.snippet("read"), 1, true) ~= nil,
  "the child index must be the authored cue")
ok(child:find(rg_guidance, 1, true) ~= nil,
  "a child with bash must also prefer ripgrep for shell search")
local no_shell_child = agent.subagent_system_prompt(bot,
  tools.all_for({ read = true, grep = true }, "master"))
ok(no_shell_child:find(rg_guidance, 1, true) == nil,
  "a child without bash must not receive ripgrep guidance")
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_TOOL_SNIPPETS" then return "names" end
  return real_getenv(key)
end
local names = agent.subagent_system_prompt(bot, tool_list)
host.getenv = real_getenv
ok(names:find("- read", 1, true) ~= nil and names:find("- read:", 1, true) == nil,
  "names-only must drop the cue and keep the name")

-- Structural guard: the description-slicing cue must not come back.
local source = tostring(host.read_file("lua/core/agent.lua") or "")
ok(source:find(':match("^[^.]*")', 1, true) == nil,
  "agent.lua must not derive a cue by slicing the description")

print("tool cues ok (" .. checks .. " checks)")
