-- `/nodes` as a panel: the list the reader moves through, a node's page, and the way back.
-- Run under the host (WA_SCRIPT) with no rendezvous: the list is this node alone.
local nodes_cli = dofile("lua/core/nodes_cli.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function has(list, text)
  for _, line in ipairs(list) do if tostring(line):find(text, 1, true) then return true end end
  return false
end

-- The reader opens the only node, goes Back, then leaves with Esc.
local specs, answers = {}, { { action = "select", index = 1 }, { action = "select", index = 1 }, { action = "cancel" } }
nodes_cli.run({ print = print, panel = function(spec) specs[#specs + 1] = spec; return table.remove(answers, 1) end })
ok(#specs == 3, "list, node page, list again")
ok(specs[1].title == "Nodes" and #specs[1].options == 1, "the list is a panel of nodes")
ok(specs[1].options[1].label:find("(this node)", 1, true) ~= nil, "the local node is marked as this one")
ok(has(specs[1].lines, "Cluster: none"), "an unbound node says it has no cluster and how to join one")
ok(specs[2].options[1].label == "Back" and has(specs[2].lines, "Node id: "), "a node opens its own page with a way back")
ok(specs[3].selected == 1, "back on the list, the node just opened stays selected")

-- A peer's page: offline, when it was last seen, reached through the relay.
local lines = nodes_cli.details({
  node_id = "abcdef0123456789", name = "phone", role = "guest", online = false, last_seen = host.now() - 120,
  endpoints = {}, resources = { memory = { available_bytes = 1073741824, total_bytes = 4294967296 } },
})
ok(has(lines, "offline, seen 2m ago"), "an offline peer says when it was last seen")
ok(has(lines, "relay"), "a peer with no endpoint is reached through the relay")
ok(has(lines, "Memory: 1.0 GiB free of 4.0 GiB"), "resources are readable")

-- No raw editor: one printed line per node.
local printed = {}
nodes_cli.run({ print = function(text) printed[#printed + 1] = text end })
ok(#printed == 2 and has(printed, "(this node)"), "without a panel, /nodes prints the cluster and one line per node")

-- `/bind` names no fabric of its own: with nothing saved and no WASM_AGENT_RENDEZVOUS there is no
-- suggestion, and an empty service is refused rather than replaced by a built-in one.
local binding = dofile("lua/core/binding.lua")
ok(binding.default_service() == "", "an unbound node suggests no fabric")
ok(binding.inspect("").error == "binding_service_required", "/bind with no URL names none of its own")

if failed > 0 then print("nodes cli: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("nodes cli ok (" .. checks .. " checks)")
