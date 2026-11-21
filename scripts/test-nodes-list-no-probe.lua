-- Item 2 of the harness-fixes-2 round: a test process must not start REAL probe children.
--
-- nodes.list() fans out a live capability probe - one `wa nodes probe <peer>` child per peer, against the
-- live fleet (lua/core/nodes.lua probe_peers). Rows that called it unstubbed started real children from a
-- test (measured 20/11: test-network-roster-offline, test-remote-refusals), which rule 13 forbids: never
-- call the live fleet from work or tests.
--
-- The fix is at ONE place, not per test: a script run refuses the fan-out unless the row asks
-- (`nodes.list{ probe = true }`), and the shared host fake (scripts/lib/contract-host.lua) refuses to start
-- an operation at all and COUNTS the attempt. This row asserts the count, so "no children" is measured.
--
--   WA_SCRIPT=scripts/test-nodes-list-no-probe.lua wa --db <scratch>/t.db
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-nodes-list-no-probe")
if why_home then print("REFUSED test-nodes-list-no-probe: " .. why_home); os.exit(2) end

local checks = 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then error("check failed: " .. message, 0) end
end

-- THE SHARED FAKE, not one written here: its answers are proved against the real host by
-- scripts/test-contract-host.lua, so a refusal this row reads is a refusal the node gives.
local contract = dofile("scripts/lib/contract-host.lua")
local fake, observed = contract.new({ root = host.paths().home })

-- A STUBBED NODE, with the fake host and a rendezvous that knows two peers. Nothing here is the real fleet:
-- no rendezvous URL is set, and the host.http answer is the test's own.
local nodes = dofile("lua/core/nodes.lua")
local PEERS = {
  { node_id = "peer-alpha", name = "alpha", public_key = "aa" },
  { node_id = "peer-beta", name = "beta", public_key = "bb" },
}
fake.http = function() return json.encode({ status = 200, body = json.encode({ nodes = PEERS }) }) end
fake.node_identity = function() return json.encode({ node_id = "self-node", public_key = "cc" }) end

-- host.runtime_info: NOT covered by the shared fake, and stubbed here for one reason only - the fan-out
-- refuses to start a probe child it cannot name a program for (nodes.lua probe_peers returns {} when
-- binary_path is empty), so without this the OLD code would start nothing either and the count below would
-- prove nothing. It answers the shape the real host answers (rust/wa-capabilities/src/host.rs runtime_info),
-- naming this process's own binary.
fake.runtime_info = function()
  return json.encode({ binary_path = tostring((json.decode(host.runtime_info()) or {}).binary_path or ""),
    version = "test", os = "linux", arch = "x86_64" })
end

-- 1. list() STARTS ZERO CHILDREN. The real host.operation is REPLACED by the fake's, so a start lands in
-- the counter and NO real process is ever spawned - this row is safe to run on the base, where the bug is
-- live. With the old code the fan-out called `start` once per peer; the refusal is what makes it zero.
local real_operation = host.operation
host.operation = fake.operation
local ok_list, rows = pcall(nodes.list, { peers = PEERS })
host.operation = real_operation
ok(ok_list, "nodes.list answered with the fake host (" .. tostring(rows):sub(1, 300) .. ")")
local starts = observed.operation_starts()
ok(starts == 0, "a test process started ZERO probe children (host.operation start calls: " .. tostring(starts) .. ")")
ok(starts == 0, "and the count is the measurement: a fan-out would have started one child per peer (" .. #PEERS .. ")")

-- 2. THE PREMISE, asked of the product: this process IS a script run, which is what makes the refusal apply.
-- Asserted after the count, so the count is the measurement and this only says WHY it is zero.
ok(host.script_run ~= nil and host.script_run() == true,
  "this row runs as a script run (host.script_run), which is what makes the refusal apply")

-- 3. AND IT SAYS SO, BY NAME. A peer whose capabilities were not asked must not read like a peer that was
-- asked and answered nothing: the reason is on the row, so a caller can tell the difference.
local peers = 0
for _, node in ipairs(rows) do
  if not node.local_node then
    peers = peers + 1
    ok(node.capabilities == nil, "peer " .. tostring(node.name) .. " carries no capabilities it never read")
    ok(tostring(node.capabilities_reason) == "probe_disabled_script_run",
      "and names the refusal (got " .. tostring(node.capabilities_reason) .. ")")
  end
end
ok(peers == #PEERS, "both peers are in the list (" .. tostring(peers) .. ")")

-- 4. THE ROSTER ITSELF IS UNTOUCHED. The refusal is about PROBING; names, ids and kinds still come back, so
-- a row that lists nodes for its roster keeps working.
local names = {}
for _, node in ipairs(rows) do names[tostring(node.name)] = true end
ok(names["alpha"] == true and names["beta"] == true, "the roster names both peers")
ok(starts == 0, "and nothing was started on the way (host.operation start calls: " .. tostring(starts) .. ")")

print("nodes-list-no-probe ok (" .. checks .. " checks)")