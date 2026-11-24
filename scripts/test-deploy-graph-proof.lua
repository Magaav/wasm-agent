-- THE DEPLOY'S GRAPH PROOF, HELD AGAINST THE TWO WAYS IT CAN LIE (docs/GRAPH.md, deploy step 3e).
--
-- scripts/deploy.sh proves the staged `graph` component on the candidate binary before anything is
-- installed, by running scripts/check-graph-component.lua. The graph is OFF by default on every node, so
-- that proof process turns the switch on for its own call (`WA_GRAPH_COMPONENT=1`): what it proves is the
-- COMPONENT, not the node's default. This row holds both halves of that:
--
--   1. with the graph dormant on the node and the switch set for the proof, the proof PASSES through the
--      staged component - the state every deploy is in now;
--   2. without the switch, the same proof FAILS BY NAME ("the switch, not the component"), so a deploy can
--      never "prove" a component it never called;
--   3. with a BROKEN component staged (bytes that are no longer the pinned ones), the proof still FAILS -
--      the guarantee the proof exists for is intact.
--
--   WA_SCRIPT=scripts/test-deploy-graph-proof.lua wa ...   prints "deploy graph proof ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- The rule a test that writes state must pass (scripts/lib/test-home-guard.lua).
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
  -- A skip is not a pass: without staged components there is no component to prove.
  print("SKIP deploy-graph-proof: WA_COMPONENTS_DIR is not set, so this run has no built graph component to stage")
  return
end
for _, name in ipairs({ "graph.wasm", "graph.wasm.sha256", "graph.json" }) do
  local ok = host.canonical_path and host.canonical_path(components .. "/" .. name)
  if not ok then
    print("SKIP deploy-graph-proof: " .. components .. "/" .. name .. " is not there (the fast path and the gate build it)")
    return
  end
end

local binary = host.getenv("WA_BIN") or "wa"
local tree = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local scratch = tostring(test_home) .. "/deploy-graph-proof"
local function run(command)
  local answer = host.exec(command, "", 240)
  local decoded = type(answer) == "string" and json.decode(answer) or answer
  check(type(decoded) == "table", "the command answered something that is not JSON: " .. tostring(answer):sub(1, 200))
  return {
    code = tonumber(decoded.process_exit_code or decoded.code),
    out = tostring(decoded.stdout or "") .. tostring(decoded.stderr or ""),
  }
end

-- One staged component directory, a corrupt one, and a home per run: the proof must never touch the node's.
local staged = scratch .. "/staged"
local broken = scratch .. "/broken"
for _, dir in ipairs({ staged, broken }) do
  run("mkdir -p " .. quote(dir) .. " && cp " .. quote(components .. "/graph.wasm") .. " " .. quote(components .. "/graph.wasm.sha256") .. " " .. quote(components .. "/graph.json") .. " " .. quote(dir) .. "/")
end
-- A component whose bytes are not the ones its pin names: the deploy's own definition of broken.
run("printf 'broken' | dd of=" .. quote(broken .. "/graph.wasm") .. " bs=1 seek=64 conv=notrunc status=none")

local function proof(directory, switch, label)
  local home = scratch .. "/home-" .. label
  run("mkdir -p " .. quote(home))
  -- `env -u` first, so the row's own environment cannot decide the answer, and the switch named only in the
  -- run that must have it (a placeholder here once ran `true` and "passed" a proof that never happened).
  local parts = { "env -u WA_GRAPH_COMPONENT" }
  if switch then parts[#parts + 1] = "WA_GRAPH_COMPONENT=1" end
  local command = table.concat({
    table.concat(parts, " "),
    "WASM_AGENT_HOME=" .. quote(home),
    "WASM_AGENT_MANAGED=0",
    "WA_GRAPH_WATCH=0",
    "WA_COMPONENTS_DIR=" .. quote(directory),
    "WA_SCRIPT=" .. quote(tree .. "/scripts/check-graph-component.lua"),
    quote(binary), "--db", quote(home .. "/proof.db"),
  }, " ")
  return run(command)
end

------------------------------------------------------------- 1. the deploy's own invocation PASSES
local proved = proof(staged, true, "proved")
check(proved.code == 0, "the proof must pass on a staged component (exit " .. tostring(proved.code) .. "): " .. proved.out:sub(-300))
check(proved.out:find("graph component ok", 1, true) ~= nil, "and print its verdict: " .. proved.out:sub(-300))

------------------------------------------------- 2. without the switch it fails BY NAME, not as damage
local dormant = proof(staged, false, "dormant")
check(dormant.code ~= 0, "without the switch the proof must fail, and it answered success: " .. dormant.out:sub(-300))
check(dormant.out:find("graph_dormant", 1, true) ~= nil or dormant.out:find("switched off", 1, true) ~= nil,
  "and name the switch as the reason: " .. dormant.out:sub(-300))
check(dormant.out:find("graph component ok", 1, true) == nil, "and must never print the verdict it did not earn")

-------------------------------------------------------- 3. a BROKEN component still fails the proof
local damaged = proof(broken, true, "broken")
check(damaged.code ~= 0, "a component whose bytes are not its pin must fail the proof: " .. damaged.out:sub(-300))
check(damaged.out:find("graph component ok", 1, true) == nil, "and must not print the verdict")

print(("deploy graph proof ok (%d checks)"):format(checks))

