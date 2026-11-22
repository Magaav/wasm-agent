-- A search that finds nothing says why, and names the command-line program the query means (22/11).
--
-- MEASURED: a turn asked to "check github"; `searchTools("github")` answered `[]`, `capabilities()`
-- listed no GitHub tool, and the turn spent two discovery calls before it found that `gh` was installed
-- and `tools.bash` runs it. These checks drive the two paths real use takes - the guest's own
-- `searchTools` inside code mode (`tools.dispatch`), and the outer `tool_search` facade - through a
-- real run of each, never a direct call into the branch that answers them.
--
-- The PATH answer is STUBBED, so the verdict is the same on a machine with `gh` and on one without it:
-- the missing-program case cannot be produced on a machine that has the program, and a test that
-- depended on this host's PATH would pass here and fail on the next machine.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test stubs a host capability and writes a ledger: it refuses to run (" .. guard_reason .. ")")
end
local json = dofile("lua/vendor/json.lua")
-- A HAND-WRITTEN STUB, and why it is not `scripts/lib/contract-host.lua`: the shared fake implements the
-- STORE capabilities of the host (paths, files, sql, getenv) and is judged against the real host by
-- `scripts/test-contract-host.lua`. `executable_on_path` is not a store capability - it answers a fact
-- about the machine's own PATH, which no scratch root can stand in for - so this test stubs exactly
-- that one capability and nothing else. It records every name it is asked for, which is how "one PATH
-- lookup per miss" is measured, and it answers the two values the real host answers: an absolute path,
-- and nil for a program that is not there.
local real_on_path = host.executable_on_path
local asked = {}
local installed = { gh = "/scratch/bin/gh", glab = "/scratch/bin/glab", docker = "/scratch/bin/docker" }
host.executable_on_path = function(name)
  asked[#asked + 1] = name
  return installed[name]
end
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local policy = dofile("lua/core/codemode_policy.lua")
local sid = memory.start_session("", "search miss cli", { user_id = "master" })
local ctx = { session_id = sid, user_id = "master" }
policy.pin(memory, "master", ctx)
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
-- The vendor decoder reads an empty array as no value; the answer is an array either way.
local function array(value) return type(value) == "table" and value or {} end
-- The guest's own answer, read back from the script: `text()` is the output channel, so the value is
-- exactly what the script encoded. The scratch home has no installed codemode component, so this is
-- the native loop - the one a node without the component runs.
local function ask(body)
  local result = tools.dispatch(memory, "codemode",
    { code = "text(JSON.stringify(await (async()=>{" .. body .. "})())); return 1;" }, "master", ctx)
  if not result.ok then error("script failed: " .. json.encode(result):sub(1, 500)) end
  local item = result.items and result.items[1]
  if not item or type(item.text) ~= "string" then error("the script printed no output: " .. json.encode(result):sub(1, 500)) end
  return json.decode(item.text)
end
local function facade(query) return tools.dispatch(memory, "tool_search", { query = query }, "master", ctx) end

-- 1. The measured case: "github" finds no tool, says so, and names the program it means.
asked = {}
local miss = array(ask('return await searchTools("github");'))
check(#miss == 1 and miss[1].found == false and miss[1].name == "github",
  "a search that matches nothing answers one member that says so: " .. json.encode(miss):sub(1, 300))
check(type(miss[1].reason) == "string" and miss[1].reason:find("no tool in this script's catalogue matches 'github'", 1, true) ~= nil,
  "the miss says what did not match: " .. tostring(miss[1]))
check(miss[1].reason:find("gh is installed (/scratch/bin/gh): run it with tools.bash.", 1, true) ~= nil,
  "the miss names the installed program, where it lives, and how to run it: " .. tostring(miss[1].reason))
check(type(miss[1].cli) == "table" and miss[1].cli.name == "gh" and miss[1].cli.path == "/scratch/bin/gh",
  "the program is a field a script can read without parsing the sentence: " .. json.encode(miss[1].cli))
check(table.concat(asked, ",") == "gh", "one PATH lookup, for the program the query means: " .. table.concat(asked, ","))

-- 2. A caller that iterates the answer as a list still works: it is an Array, so .map runs on it.
local iterating = ask('const a = await searchTools("github"); return {len:a.length, map:a.map(t=>t.found), list:Array.isArray(a)};')
check(iterating.list == true and iterating.len == 1 and type(iterating.map) == "table" and iterating.map[1] == false,
  "the miss answer is still a plain Array a script maps over: " .. json.encode(iterating):sub(1, 300))

-- 3. The same query on a machine that does NOT have the program: the reason still says how a
--    command-line tool runs, and nothing is named that this machine cannot answer for.
installed.gh = nil; asked = {}
local absent = array(ask('return await searchTools("github");'))
check(#absent == 1 and absent[1].found == false, "a miss on a machine without the program still explains itself")
check(absent[1].reason:find("Any command-line tool on this machine runs through tools.bash.", 1, true) ~= nil,
  "without an installed program the miss names the way any command-line tool runs: " .. tostring(absent[1].reason))
check(absent[1].reason:find("gh is installed", 1, true) == nil and absent[1].cli == nil,
  "a program the lookup did not find is never named: " .. tostring(absent[1].reason))
check(table.concat(asked, ",") == "gh", "the answer is the host's, and it is still one lookup: " .. table.concat(asked, ","))
installed.gh = "/scratch/bin/gh"

-- 4. An alias and a program's own name are the same request.
asked = {}
local aliased = array(ask('return await searchTools("gitlab");'))
check(aliased[1].cli ~= nil and aliased[1].cli.name == "glab" and aliased[1].cli.path == "/scratch/bin/glab",
  "an alias names the program it means: " .. json.encode(aliased[1]):sub(1, 300))
local own_name = array(ask('return await searchTools("docker");'))
check(own_name[1].cli ~= nil and own_name[1].cli.path == "/scratch/bin/docker",
  "a program's own name is the same request: " .. json.encode(own_name[1]):sub(1, 300))

-- 5. A word the table does not name costs NO lookup: this is an allow-list, not an inventory of the
--    machine, and a miss of an ordinary word must not walk the PATH.
asked = {}
local other = array(ask('return await searchTools("codewhisper");'))
check(#other == 1 and other[1].found == false and #asked == 0,
  "a query naming no known program answers the reason and opens no PATH lookup: " .. table.concat(asked, ","))
check(other[1].reason:find("Any command-line tool on this machine runs through tools.bash.", 1, true) ~= nil and other[1].cli == nil,
  "and it still says how a command-line tool runs: " .. tostring(other[1].reason))

-- 6. A search that DOES match is untouched, and costs no lookup either.
asked = {}
local hit = array(ask('return await searchTools("read");'))
local named_false = 0
for _, entry in ipairs(hit) do if entry.found == false then named_false = named_false + 1 end end
check(#hit > 0 and hit[1].name ~= nil and named_false == 0,
  "a search that matches answers tool entries with no miss member among them: " .. json.encode(hit):sub(1, 300))
check(#asked == 0, "a hit opens no PATH lookup: " .. table.concat(asked, ","))

-- 7. The name branch is not the keyword branch: a name that is not here keeps its own answer.
local by_name = array(ask('return await searchTools({names:["nope_tool"]});'))
check(#by_name == 1 and by_name[1].found == false and by_name[1].error == "unknown_tool",
  "an unknown NAME is still the name branch, unchanged: " .. json.encode(by_name[1]):sub(1, 300))

-- 8. The outer facade answers the same fact for a query that matches nothing.
asked = {}
local outer = facade("github")
check(outer.matches == 0 and #array(outer.tools) == 0, "the facade still says it matched nothing")
check(type(outer.reason) == "string" and outer.reason:find("gh is installed (/scratch/bin/gh): run it with tools.bash.", 1, true) ~= nil,
  "the facade's miss says why and names the program: " .. tostring(outer.reason))
check(type(outer.cli) == "table" and outer.cli.name == "gh" and outer.cli.path == "/scratch/bin/gh",
  "and carries the program as a field: " .. json.encode(outer.cli))
check(table.concat(asked, ",") == "gh", "one lookup at the facade too: " .. table.concat(asked, ","))
installed.gh = nil
local outer_absent = facade("github")
check(outer_absent.reason ~= nil
  and outer_absent.reason:find("Any command-line tool on this machine runs through tools.bash.", 1, true) ~= nil
  and outer_absent.cli == nil, "without the program the facade says how a command-line tool runs: " .. tostring(outer_absent.reason))
installed.gh = "/scratch/bin/gh"
local outer_hit = facade("read")
check(outer_hit.matches > 0 and outer_hit.reason == nil and outer_hit.cli == nil,
  "a facade hit carries no miss sentence: " .. json.encode({ matches = outer_hit.matches, reason = outer_hit.reason }):sub(1, 200))

-- 9. The echoed query is bounded: a long search text cannot make the reason a page.
local long = string.rep("github", 30)
local bounded = array(ask("return await searchTools(" .. json.encode(long) .. ");"))
check(#bounded == 1 and #bounded[1].reason < 400,
  "a long query is echoed bounded in the reason: " .. tostring(#bounded[1].reason))

host.executable_on_path = real_on_path
print("search miss cli ok (" .. checks .. " checks)")
