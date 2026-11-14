-- WhatsApp has ONE surface: `mcp_whatsapp_<verb>`, answered by the node that holds the account.
--
-- Two things this pins, both measured on 13/11 (session b393f280 on node `work`, main 3f538a90):
--
--   * a peer that still offers a WhatsApp spelling must never become a `peer_<node>__*` tool here. The
--     model found `peer_openclaw__mcp_whatsapp_native_inspect_chat_*`, spent its rounds on a second
--     route for the same question, and the one surface went unused (`lua/core/federation.lua`).
--   * a name that exists must be found by a plain substring query of it - including a name from an
--     older build, which is what `searchTools("whatsapp_native")` was: it answered `[]` while the
--     question it names had a tool (`lua/core/codemode.lua` searches name + description).
--
-- Hermetic: the peers are stubs, the catalogue is this node's real one, and the only state written is
-- the private WASM_AGENT_HOME the fast path gives this row.
local json = dofile("lua/vendor/json.lua")
local env = host.getenv
host.getenv = function(key) if key == "WASM_AGENT_CODEMODE" then return "native" end; return env(key) end
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local codemode = dofile("lua/core/codemode.lua")
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

-- ---- the fleet: `openclaw` answers as an OLDER build does ---------------------------------------
-- It still exports the MCP-native WhatsApp tools (the spelling the model used) beside one ordinary
-- connector tool, so this file also proves the federation route itself still works.
local nodes = dofile("lua/core/nodes.lua")
local peer_tools = {
  { name = "mcp_whatsapp_native_inspect_chat_47452e4e", description = "MCP whatsapp_native / inspect_chat",
    parameters = { type = "object", properties = {} }, effect = "read" },
  { name = "mcp_whatsapp_native_lookup_self_47452e4e", description = "MCP whatsapp_native / lookup_self",
    parameters = { type = "object", properties = {} }, effect = "read" },
  { name = "whatsapp_read", description = "the bare spelling before 11/11",
    parameters = { type = "object", properties = {} }, effect = "read" },
  -- The second send path retired 14/11. A peer on an older build still exports it; it must not become a
  -- tool here, must not be discoverable, and must answer its one sentence if a cached name calls it.
  { name = "whatsapp_operator", effect = "write",
    description = "Operator-directed WhatsApp text (docs/WHATSAPP-OPERATOR-MANAGEMENT.md): prepare -> approve",
    parameters = { type = "object", properties = {} } },
  { name = "chat_read", description = "Read a chat on the peer",
    parameters = { type = "object", properties = { chat = { type = "string" } } }, effect = "read" },
}
nodes.list = function() return {
  { node_id = "self", name = "here", local_node = true, online = true },
  { node_id = "peer-1", name = "openclaw", online = true } } end
local remote = {}
nodes.remote_call = function(id, capability, args)
  remote[#remote + 1] = { id = id, capability = capability, args = args }
  if args.action == "catalog" then
    return { ok = true, schema = 2, tools = peer_tools, connectors = {
      { id = "whatsapp", name = "WhatsApp", whatsapp_account = true, tools = {} } } }
  end
  if args.action == "call" then return { ok = true, ran_on = id, tool = args.name } end
end
local real_dofile = dofile
dofile = function(path) if path == "lua/core/nodes.lua" then return nodes end return real_dofile(path) end
local federation = dofile("lua/core/federation.lua")
federation.refresh()
dofile = real_dofile

-- ---- 1. No peer WhatsApp spelling reaches this node's catalogue --------------------------------
local listed = {}
for _, schema in ipairs(federation.schemas()) do listed[schema["function"].name] = schema["function"].description end
ok(listed.peer_openclaw__chat_read ~= nil, "an ordinary peer tool is still federated: " .. json.encode(listed))
for _, name in ipairs({ "peer_openclaw__mcp_whatsapp_native_inspect_chat_47452e4e",
  "peer_openclaw__mcp_whatsapp_native_lookup_self_47452e4e", "peer_openclaw__whatsapp_read",
  "peer_openclaw__whatsapp_operator" }) do
  ok(listed[name] == nil, name .. " is not a peer tool any more")
end

-- The same through the catalogue the model and `searchTools` read.
local sid = memory.start_session("", "one surface", { user_id = "master" })
local ctx = { session_id = sid, user_id = "master" }
local all, peer_whatsapp = tools.all("master", ctx, memory), {}
for _, schema in ipairs(all) do
  local name = schema["function"].name
  if name:sub(1, 5) == "peer_" and name:lower():find("whatsapp", 1, true) then peer_whatsapp[#peer_whatsapp + 1] = name end
end
ok(#peer_whatsapp == 0, "no peer WhatsApp tool is in the catalogue: " .. json.encode(peer_whatsapp))
local peer_other = 0
for _, schema in ipairs(all) do if schema["function"].name == "peer_openclaw__chat_read" then peer_other = peer_other + 1 end end
ok(peer_other == 1, "the ordinary peer route is untouched: " .. json.encode(peer_other))

-- ---- 2. A cached spelling stops working at the same moment it stops being listed --------------
local refused = federation.call("peer_openclaw__mcp_whatsapp_native_inspect_chat_47452e4e", { chat = "x" })
ok(refused.ok == false and refused.error == "whatsapp_tool_renamed",
  "a peer WhatsApp name is refused by name, not run: " .. json.encode(refused))
ok(refused.use == "mcp_whatsapp_read",
  "the refusal names the one tool that answers it: " .. json.encode(refused))
ok(federation.resolve("peer_openclaw__mcp_whatsapp_native_inspect_chat_47452e4e") == nil,
  "a cached WhatsApp spelling does not resolve to a peer tool")
-- The dispatch refuses it too, with the same word: an older name is answered, never "unknown tool".
local via_dispatch = tools.dispatch(memory, "peer_openclaw__whatsapp_read", { chat = "x" }, "master", ctx)
ok(tostring(json.encode(via_dispatch)):find("whatsapp_tool_renamed", 1, true) ~= nil,
  "the dispatch answers an older WhatsApp spelling with the rename: " .. json.encode(via_dispatch))

-- The gate: every spelling of the surface is recognised, and nothing else is.
local whatsapp = dofile("lua/core/whatsapp.lua")
for _, name in ipairs({ "mcp_whatsapp_read", "mcp_whatsapp_send", "whatsapp_read",
  "whatsapp_contacts", "whatsapp_operator", "peer_openclaw__whatsapp_operator",
  "mcp_whatsapp_native_inspect_chat_47452e4e", "mcp_whatsapp_native_read_newest_47452e4e",
  "peer_openclaw__whatsapp_search", "peer_openclaw__mcp_whatsapp_native_list_chats_47452e4e" }) do
  ok(whatsapp.surface(name) == true, name .. " is a spelling of the one surface")
  ok(federation.whatsapp_spelling(name) == true, name .. " is not exportable to a master")
end
for _, name in ipairs({ "chat_read", "peer_openclaw__chat_read", "mcp_mail_search_ab12cd34", "read" }) do
  ok(whatsapp.surface(name) == false, name .. " is not a WhatsApp spelling")
  ok(federation.whatsapp_spelling(name) == false, name .. " stays exportable")
end

-- ---- 2b. A RETIRED spelling never comes back in any export --------------------------------------
-- `whatsapp_operator` was a second WhatsApp send path, retired 14/11 (docs/WHATSAPP-OPERATOR-MANAGEMENT.md
-- is now the pointer). The gate has two halves: no export of this node may carry a WhatsApp spelling, and
-- a peer that still exports one gets neither a tool here nor a silent success - it gets the one sentence.
local SENTENCE = 'retired: use mcp_whatsapp_send; turn on /approve to review drafts first'
ok(whatsapp.retired_name('whatsapp_operator') == SENTENCE, 'the retired name carries the exact sentence')
ok(whatsapp.retired_name('peer_openclaw__whatsapp_operator') == SENTENCE, 'so does its peer spelling')
ok(whatsapp.retired_name('whatsapp_read') == nil, 'a RENAMED spelling is not a retired one')
for _, tool in ipairs(federation.exported()) do
  ok(federation.whatsapp_spelling(tool.name) == false,
    'this node exports no WhatsApp spelling, retired or renamed: ' .. tostring(tool.name))
end
local stale = 0
for _, peer in pairs(federation.cached().peers or {}) do
  for _, tool in ipairs(peer.tools or {}) do
    if whatsapp.surface(tool.name) then stale = stale + 1 end
  end
end
ok(stale >= 1, 'the fixture peer does export WhatsApp spellings, so the next checks mean something')
local ran_on_peer = #remote
local refused = federation.call('peer_openclaw__whatsapp_operator', { profile = 'laura-1', action = 'status' })
ok(refused.ok == false and refused.error == 'whatsapp_tool_retired',
  'a cached retired name is refused by name: ' .. json.encode(refused))
ok(refused.note == SENTENCE and refused.use == 'mcp_whatsapp_send' and refused.effect == 'none',
  'with the one sentence, the door and no effect: ' .. json.encode(refused))
ok(#remote == ran_on_peer, 'and the peer was never asked: nothing ran anywhere')
local via_tools = tools.dispatch(memory, 'peer_openclaw__whatsapp_operator', {}, 'master', ctx)
ok(tostring(json.encode(via_tools)):find('whatsapp_tool_retired', 1, true) ~= nil,
  'the dispatcher answers it the same way: ' .. json.encode(via_tools))
local bare = tools.dispatch(memory, 'whatsapp_operator', {}, 'master', ctx)
ok(tostring(json.encode(bare)):find(SENTENCE, 1, true) ~= nil,
  'the bare name answers the sentence too, never "unknown tool": ' .. json.encode(bare))

-- ---- 3. A name that exists is found by a plain substring query of it --------------------------
local execution = tools.discovery_execution(memory, ctx)
local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, "master", ctx) end
local function search(query)
  local code = "const v=await searchTools(" .. json.encode(query) .. "); return JSON.stringify(v);"
  local result = codemode.run(memory, { code = code }, "master", ctx, all, function() return all end, dispatch, execution)
  local value = result and result.value
  for _ = 1, 2 do if type(value) == "string" then value = json.decode(value) end end
  return type(value) == "table" and value or {}
end
local function names(value)
  local list = {}
  for _, entry in ipairs(value) do list[#list + 1] = tostring(entry.name) end
  return list
end
local function has(value, name)
  for _, found in ipairs(names(value)) do if found == name then return true end end
  return false
end
ok(has(search("whatsapp_send"), "mcp_whatsapp_send"),
  "a plain substring of an existing name finds the tool: " .. json.encode(search("whatsapp_send")))
-- The evidence case: the spelling an older build had. It answered `[]` and left the model without a
-- route to the one tool that answers the same question.
ok(has(search("whatsapp_native"), "mcp_whatsapp_read"),
  "a retired spelling finds the tool that answers it: " .. json.encode(search("whatsapp_native")))
ok(has(search("inspect_chat"), "mcp_whatsapp_read"),
  "the old MCP-native name of the same question finds it too: " .. json.encode(search("inspect_chat")))
-- ...and nothing peer-prefixed is discoverable, because it is not in the catalogue at all.
local gone = search("select:peer_openclaw__mcp_whatsapp_native_inspect_chat_47452e4e")
ok(#gone == 1 and gone[1].found == false and gone[1].missing == true,
  "a peer WhatsApp name cannot be described either: " .. json.encode(gone))

print("whatsapp one surface ok (" .. checks .. " checks)")
