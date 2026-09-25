-- The experiment's verifier and its treatment, both under test.
--
-- Two claims have to hold before any tool-surface result means anything:
--   1. the verifier rejects a plausible-looking wrong answer. The `wide` task asks for each
--      file's *first function*; the old substring check passed a reply naming the twelve
--      paths and no functions. This test constructs exactly that reply and requires failure,
--      along with the case where the right function is mentioned in prose beside a wrong
--      answer, and the case where an introductory sentence names the path first.
--   2. a task whose outcome is not text cannot pass on an empty fact list. `long-lived` has
--      no facts; success is the live process, so an empty list with no process must fail.
--   3. the treatment reaches the prompt the experiment actually runs. The rig runs children;
--      if `WASM_AGENT_TOOL_SNIPPETS` only changed `system_prompt`, the arm would differ in
--      nothing the model sees. This test builds the child prompt both ways and requires them
--      to differ, with the names-only form smaller.
local json = dofile("lua/vendor/json.lua")
local verify = dofile("scripts/lib/experiment-verify.lua")
local agent = dofile("lua/core/agent.lua")
local tools = dofile("lua/core/tools.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

-- The `wide` facts: the first function each of the twelve files defines.
local EXPECT = {
  { path = "lua/core/agent.lua", name = "record_turn" },
  { path = "lua/core/memory.lua", name = "decode" },
  { path = "lua/core/provider.lua", name = "env" },
  { path = "lua/core/subagents.lua", name = "profile_dir" },
  { path = "lua/core/tools.lua", name = "is_master" },
  { path = "lua/core/tool_output.lua", name = "slice" },
  { path = "lua/core/graph.lua", name = "capability" },
  { path = "lua/core/skills.lua", name = "read" },
  { path = "lua/core/nodes.lua", name = "rendezvous_url" },
  { path = "lua/core/spells.lua", name = "path" },
  { path = "lua/core/platform.lua", name = "info" },
  { path = "lua/core/paths.lua", name = "all" },
}

-- If the source moves, the fixture is wrong and the experiment measures the wrong fact.
-- Recompute the first function from source and require the fixture to match.
local function first_function(path)
  local text = tostring(host.read_file(path) or "")
  for line in text:gmatch("[^\n]+") do
    local name = line:match("^%s*local%s+function%s+([%w_]+)")
      or line:match("^%s*function%s+M[%.:]([%w_]+)")
      or line:match("^%s*function%s+([%w_]+)")
    if name then return name end
  end
  return nil
end
for _, fact in ipairs(EXPECT) do
  ok(first_function(fact.path) == fact.name, "the fixture fact must match source: " .. fact.path)
end

local function lines(pairs)
  local out = {}
  for _, pair in ipairs(pairs) do out[#out + 1] = pair end
  return table.concat(out, "\n")
end
local correct = lines({
  "lua/core/agent.lua: record_turn", "lua/core/memory.lua: decode",
  "lua/core/provider.lua: env", "lua/core/subagents.lua: profile_dir",
  "lua/core/tools.lua: is_master", "lua/core/tool_output.lua: M.slice",
  "lua/core/graph.lua: capability", "lua/core/skills.lua: read",
  "lua/core/nodes.lua: M.rendezvous_url", "lua/core/spells.lua: path",
  "lua/core/platform.lua: M.info", "lua/core/paths.lua: M.all",
})
ok(verify.verify(EXPECT, correct).complete, "a correct answer must pass")

-- The exact shape the old check passed: the twelve paths, no functions.
local paths_only = lines({
  "lua/core/agent.lua", "lua/core/memory.lua", "lua/core/provider.lua",
  "lua/core/subagents.lua", "lua/core/tools.lua", "lua/core/tool_output.lua",
  "lua/core/graph.lua", "lua/core/skills.lua", "lua/core/nodes.lua",
  "lua/core/spells.lua", "lua/core/platform.lua", "lua/core/paths.lua",
})
local path_verdict = verify.verify(EXPECT, paths_only)
ok(not path_verdict.complete, "paths without the functions must fail")
ok(#path_verdict.missing == #EXPECT, "an unanswered path is missing")

-- A wrong answer that mentions the right name in prose is still wrong.
local prose_wrong = verify.verify(EXPECT,
  correct:gsub("lua/core/skills%.lua: read", "lua/core/skills.lua: write (calls read later)"))
ok(not prose_wrong.complete, "a wrong answer mentioning the right name must fail")
ok(#prose_wrong.wrong == 1 and #prose_wrong.missing == 0, "the wrong answer is flagged as wrong")

-- An introductory sentence that names a path must not break a correct answer on a later line.
local intro = "I inspected lua/core/skills.lua and found its first function.\nlua/core/skills.lua: read"
ok(verify.verify({ { path = "lua/core/skills.lua", name = "read" } }, intro).complete,
  "prose mentioning the path must not invalidate the answer line")

-- Two different answers for one file is a conflict, not a pass.
local conflict = verify.verify({ { path = "lua/core/skills.lua", name = "read" } },
  "lua/core/skills.lua: read\nlua/core/skills.lua: write")
ok(not conflict.complete and #conflict.conflicts == 1, "conflicting answers must be reported")

-- A wrong function name is wrong, not missing, and only the wrong fact is flagged.
local one_wrong = verify.verify(EXPECT, correct:gsub("record_turn", "record"))
ok(not one_wrong.complete, "a wrong function name must fail")
ok(#one_wrong.wrong == 1 and #one_wrong.missing == 0, "only the wrong fact is flagged")

-- A short name must not match a longer word: `read` is not `readText`.
ok(not verify.verify({ { path = "lua/core/skills.lua", name = "read" } },
  "lua/core/skills.lua: readText").complete, "a name is parsed, not substring-matched")

-- Plain facts still work (the navigation fixture).
ok(verify.verify({ "lua/core/tools.lua", "exec_deadline_seconds" },
  "It is read in lua/core/tools.lua, in exec_deadline_seconds.").complete, "plain facts must pass")
ok(not verify.verify({ "exec_deadline_seconds" }, "not found").complete,
  "a missing plain fact must fail")

-- A task whose outcome is not text must not pass on an empty fact list.
local live = { expect = {}, outcome = "live_process" }
ok(not verify.success(live, "MOCK: the task is done.", {}).complete,
  "an empty fact list with no process must fail")
ok(verify.success(live, "", { { still_running = true } }).complete,
  "a process still running must pass")
ok(verify.success(live, "", { { still_running = false, file_grew = true } }).complete,
  "a process still writing must pass")
ok(not verify.success(live, "", { { still_running = false, file_grew = false } }).complete,
  "a process that stopped without writing must fail")
-- A text task is unaffected by the outcome rule.
ok(verify.success({ expect = { "lua/core/tools.lua" } }, "see lua/core/tools.lua", {}).complete,
  "a text task still passes on its facts")
local external = verify.success({ expect = {}, outcome = "external_patch" }, "looks good", {})
ok(external.complete == nil and external.external_verification_required == true,
  "a code patch stays unadjudicated until the independent verifier runs")

-- The treatment must reach the child prompt. The rig runs children, so this is the
-- prompt the arm under test actually sends.
local tool_list = tools.all("master")
local bot = { subagent = { id = "test", instructions = "", limits = {} }, role = "master" }
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_TOOL_SNIPPETS" then return nil end
  return real_getenv(key)
end
local derived = agent.subagent_system_prompt(bot, tool_list)
host.getenv = function(key)
  if key == "WASM_AGENT_TOOL_SNIPPETS" then return "names" end
  return real_getenv(key)
end
local names = agent.subagent_system_prompt(bot, tool_list)
host.getenv = real_getenv
ok(names ~= derived, "the snippet setting must change the child prompt")
ok(#names < #derived, "the names-only child prompt must be smaller")
ok(names:find("- read", 1, true) ~= nil and names:find("- read:", 1, true) == nil,
  "names-only must list the name without the derived description line")
ok(derived:find("- read:", 1, true) ~= nil, "the default child prompt must keep the description line")

print("experiment verify ok (" .. checks .. " checks)")
