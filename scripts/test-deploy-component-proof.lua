-- THE DEPLOY'S COMPONENT PROOF, HELD AGAINST EVERY WAY IT CAN LIE (Fable, 24/11).
--
-- scripts/deploy.sh proves two properties on the candidate binary and the staged component set before either
-- replaces what is running (step 3e, scripts/check-component-proof.lua):
--
--   * the candidate binary ANSWERS A CALL THROUGH A STAGED COMPONENT - through `memory`, which is ON by
--     default on every node and pinned by components.lock for every install kind, so the proof never sets a
--     feature switch; and
--   * a DORMANT FEATURE REFUSES BY NAME - the graph is off by default, and `graph_dormant` must come back
--     from this binary, which is the state every node ships in.
--
-- This row holds all four directions, each in its own scratch home:
--   1. the deploy's own invocation PASSES with the graph dormant (the shipped state);
--   2. it PASSES with the graph ENABLED as well (a policy file in the proof's own home) - the proof does not
--      depend on an optional feature either way, which is the whole point of the steer;
--   3. it FAILS when the staged component is broken (its bytes are no longer the ones its pin names);
--   4. the dormant refusal is BY NAME, asserted on the output, not inferred from an exit code.
--
-- Kept beside it, and only here: scripts/check-graph-component.lua, which proves the GRAPH component's own
-- answers (index -> query -> explain -> status). It cannot be switch-free, so it is no longer part of the
-- deploy: what it adds to THIS row is coverage of graph.wasm's answer path, which a broken graph component
-- would otherwise only fail in the gate's graph rows. The deploy proves the seam with a default-on component
-- instead, as the steer asks.
--
--   WA_SCRIPT=scripts/test-deploy-component-proof.lua wa ...   prints "deploy component proof ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function quote(path) return "'" .. tostring(path):gsub("'", "'\\''") .. "'" end

local components = host.getenv("WA_COMPONENTS_DIR")
if type(components) ~= "string" or components == "" then
  print("SKIP deploy-component-proof: WA_COMPONENTS_DIR is not set, so this run has no built component to stage")
  return
end
for _, name in ipairs({ "memory.wasm", "memory.wasm.sha256", "memory.json", "graph.wasm", "graph.wasm.sha256", "graph.json" }) do
  local there = host.canonical_path and host.canonical_path(components .. "/" .. name)
  if not there then
    print("SKIP deploy-component-proof: " .. components .. "/" .. name .. " is not there (the fast path and the gate build the set)")
    return
  end
end

local binary = host.getenv("WA_BIN") or "wa"
local tree = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local scratch = tostring(test_home) .. "/deploy-component-proof"
local function run(command)
  local answer = host.exec(command, "", 300)
  local decoded = type(answer) == "string" and json.decode(answer) or answer
  check(type(decoded) == "table", "the command answered something that is not JSON: " .. tostring(answer):sub(1, 200))
  return {
    code = tonumber(decoded.process_exit_code or decoded.code),
    out = tostring(decoded.stdout or "") .. tostring(decoded.stderr or ""),
  }
end

local function stage(dir)
  run("mkdir -p " .. quote(dir) .. " && cp " .. quote(components) .. "/*.wasm " .. quote(components) .. "/*.wasm.sha256 " .. quote(components) .. "/*.json " .. quote(dir) .. "/")
end
local staged, broken = scratch .. "/staged", scratch .. "/broken"
stage(staged)
stage(broken)
-- A component whose bytes are not the ones its pin names: the deploy's own definition of broken.
run("printf 'broken' | dd of=" .. quote(broken .. "/memory.wasm") .. " bs=1 seek=64 conv=notrunc status=none")

-- The deploy's own line, in the deploy's own conditions: no feature switch, its own home, the staged set.
local function prove(directory, label, graph)
  local home = scratch .. "/home-" .. label
  run("mkdir -p " .. quote(home))
  if graph == "on" then
    -- A policy file in the PROOF's own home: the switch a node would use, without an env var.
    run("mkdir -p " .. quote(home .. "/.wasm-agent") .. " && printf '%s' " .. quote('{"version":1,"features":{"graph":true}}')
      .. " > " .. quote(home .. "/.wasm-agent/policy.json"))
  end
  local command = table.concat({
    "env -u WA_GRAPH_COMPONENT",
    "WASM_AGENT_HOME=" .. quote(home),
    "WASM_AGENT_LUA_ROOT=" .. quote(tree),
    "WASM_AGENT_MANAGED=0",
    "WA_COMPONENTS_DIR=" .. quote(directory),
    "WA_SCRIPT=" .. quote(tree .. "/scripts/check-component-proof.lua"),
    quote(binary), "--db", quote(home .. "/proof.db"),
  }, " ")
  return run(command)
end

------------------------------------------------- 1. the shipped state: passes, graph dormant
local shipped = prove(staged, "shipped", "off")
check(shipped.code == 0, "the deploy's proof must pass with the graph dormant (exit " .. tostring(shipped.code) .. "): " .. shipped.out:sub(-400))
check(shipped.out:find("component proof ok", 1, true) ~= nil, "and print its verdict: " .. shipped.out:sub(-400))

-------------------------------------- 4. (asserted here, on the shipped run) the refusal is BY NAME
check(shipped.out:find("graph_dormant", 1, true) ~= nil,
  "the dormant graph must refuse BY NAME through the staged binary: " .. shipped.out:sub(-400))

------------------------------------------------- 2. and it passes with the graph ENABLED too
local enabled = prove(staged, "enabled", "on")
check(enabled.code == 0, "the proof must not depend on the graph being dormant (exit " .. tostring(enabled.code) .. "): " .. enabled.out:sub(-400))
check(enabled.out:find("component proof ok", 1, true) ~= nil, "and print its verdict either way: " .. enabled.out:sub(-400))

------------------------------------------------- 3. a BROKEN staged component still fails it
local damaged = prove(broken, "broken", "off")
check(damaged.code ~= 0, "a component whose bytes are not its pin must fail the proof: " .. damaged.out:sub(-400))
check(damaged.out:find("component proof ok", 1, true) == nil, "and must not print the verdict it did not earn")

------------------------------------------------- and graph.wasm's own answers, switch on, in its own home
local function graph_answers(directory, label)
  local home = scratch .. "/graph-" .. label
  run("mkdir -p " .. quote(home .. "/.wasm-agent"))
  local command = table.concat({
    "env -u WA_GRAPH_COMPONENT",
    "WA_GRAPH_COMPONENT=1",
    "WA_GRAPH_WATCH=0",
    "WASM_AGENT_HOME=" .. quote(home),
    "WASM_AGENT_LUA_ROOT=" .. quote(tree),
    "WASM_AGENT_MANAGED=0",
    "WA_COMPONENTS_DIR=" .. quote(directory),
    "WA_SCRIPT=" .. quote(tree .. "/scripts/check-graph-component.lua"),
    quote(binary), "--db", quote(home .. "/graph.db"),
  }, " ")
  return run(command)
end
local answered = graph_answers(staged, "ok")
check(answered.code == 0, "the graph component must still answer index/query/explain when a node uses it: " .. answered.out:sub(-400))
check(answered.out:find("graph component ok", 1, true) ~= nil, "and print its verdict: " .. answered.out:sub(-400))

print(("deploy component proof ok (%d checks)"):format(checks))

