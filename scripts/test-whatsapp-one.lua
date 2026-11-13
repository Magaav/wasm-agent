-- One WhatsApp surface, routed to the account node (#118). Hermetic: the host capability, the fleet
-- catalog and the remote call are injected, so nothing here touches WhatsApp, a peer or the network.
--
-- What it pins:
--
--   * the family is `mcp_whatsapp_<verb>`, eight names the model is offered and one hidden compatibility
--     alias (`mcp_whatsapp_send_status`, the resume `mcp_whatsapp_send({id, wait_s:0})`), and it is the
--     ONLY WhatsApp surface in every catalogue this node publishes - the tools the model is offered
--     (`tools.catalog`), the tools it exports to a master (`federation.exported`) and the rows `/mcp`
--     shows. A `peer_*` spelling, a namespace hash (`..._47452e4e`) or a bare `whatsapp_*` name appearing
--     again fails here, and so does the hidden alias reappearing in a catalogue or a `/mcp` row;
--   * a read on a node that runs no `wa-whatsapp` component is asked of the node that holds the account,
--     named by the deploy when it said so and found in the fleet when it did not - never hard-coded;
--   * every verb - the five reads and the four that leave this node - is answered by the node that
--     holds the account (operator decision, 11/11: a master uses every tool from any node), and the
--     answer says which node served it (`served_by`); a refusal the owner makes travels back unchanged;
--   * a decrypted file is written ON the owner node and the result says so (`served_by`), never
--     pretending the path is local;
--   * nothing is queued on a node that cannot settle it (#99): the answer of an absent component carries
--     no job id, no queue and `effect: none`;
--   * a retired spelling is refused with the name to use instead, so a session that remembers
--     `whatsapp_read` or `peer_openclaw__whatsapp_read` recovers in one step.
local json = dofile("lua/vendor/json.lua")
local whatsapp = dofile("lua/core/whatsapp.lua")
local tools = dofile("lua/core/tools.lua")
local federation = dofile("lua/core/federation.lua")
local command = dofile("lua/core/mcp_command.lua")
local mcp = dofile("lua/core/mcp.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label .. " - whatsapp one surface", 2) end
end

-- ---- the family, and nothing else ----------------------------------------------------------------
-- Offered to the model (operator decision, 11/11: one send that answers its own outcome).
local VERBS = { "contacts", "search", "read", "reactions", "media", "download", "backfill", "send" }
-- Callable but never offered: the resume form of `send`, kept for a script written before it existed.
local HIDDEN = { "send_status" }
ok(#whatsapp.TOOLS == #VERBS + #HIDDEN, "eight questions offered and one hidden alias, one surface")
for _, verb in ipairs(VERBS) do
  ok(whatsapp.name(verb) == "mcp_whatsapp_" .. verb, "the exact name of " .. verb)
  ok(whatsapp.tool("mcp_whatsapp_" .. verb) ~= nil, "the exact name is the one the facade answers")
  ok(whatsapp.hidden("mcp_whatsapp_" .. verb) == false, verb .. " is offered, not hidden")
end
for _, verb in ipairs(HIDDEN) do
  ok(whatsapp.name(verb) == "mcp_whatsapp_" .. verb, "the exact name of " .. verb)
  ok(whatsapp.tool("mcp_whatsapp_" .. verb) ~= nil, verb .. " is still callable, so an old script keeps working")
  ok(whatsapp.hidden("mcp_whatsapp_" .. verb) == true, verb .. " is the hidden alias")
end
local offered_names = {}
for _, schema in ipairs(whatsapp.schemas()) do offered_names[schema["function"].name] = true end
for _, verb in ipairs(VERBS) do ok(offered_names["mcp_whatsapp_" .. verb] == true, verb .. " is offered") end
for _, verb in ipairs(HIDDEN) do
  ok(offered_names["mcp_whatsapp_" .. verb] == nil, verb .. " is in no catalogue the model reads")
end
ok(whatsapp.tool("mcp_whatsapp_read_snapshot_deadbeef") == nil, "a hashed name is not this surface")
ok(whatsapp.tool("peer_openclaw__whatsapp_read") == nil, "a peer-prefixed name is not this surface")

-- Every catalogue this node publishes, scanned for the retired spellings. The three views are the ones
-- a model or an operator can be handed, so a leftover in any of them is the regression this guards.
local function retired(name)
  name = tostring(name)
  if name:match("^peer_[%w%-]+__whatsapp") or name:match("^peer_[%w%-]+__mcp_whatsapp") then return true end
  if name:match("^mcp_whatsapp_%a+_%x%x%x%x%x%x%x%x$") then return true end
  if name:match("^mcp_whatsapp_%a+_%a+_%x%x%x%x%x%x%x%x$") then return true end
  if name:match("^whatsapp_") then return true end
  return false
end
for _, item in ipairs(tools.catalog("master")) do
  local name = item["function"].name
  ok(not retired(name), "the model catalogue holds no retired WhatsApp spelling: " .. name)
end
for _, tool in ipairs(federation.exported()) do
  ok(not retired(tool.name), "this node exports no WhatsApp tool under a second spelling: " .. tool.name)
end
for _, entry in ipairs(command.local_connectors({})) do
  for _, tool in ipairs(entry.tools or {}) do
    if entry.id ~= nil and mcp.whatsapp_family(entry.id) then
      ok(tool.published ~= true, "a WhatsApp connector's tool is not published as callable: " .. tostring(tool.name))
      ok(tool.note == "superseded_by_mcp_whatsapp" or entry.note == "superseded_by_mcp_whatsapp",
        "and says why: " .. tostring(tool.name))
    end
  end
end
-- The mechanism that would recreate a hashed name for a WhatsApp connector is not called anywhere.
ok(mcp.whatsapp_family("whatsapp_native") and mcp.whatsapp_family("whatsapp")
  and mcp.whatsapp_family("whatsapp_wasm") and not mcp.whatsapp_family("mail")
  and not mcp.whatsapp_family("whatsappx"), "the family rule names the WhatsApp connectors and nobody else")

-- ---- who answers: the deployment's word first, the fleet second ----------------------------------
local real_getenv = host.getenv
local function env_with(value)
  host.getenv = function(key)
    if key == "WASM_AGENT_WHATSAPP_OWNER" then return value end
    return real_getenv(key)
  end
end
local function catalog_with(peers) return function() return { peers = peers } end end
local function peer_holding(name) return { name = name, node_id = "id-" .. name, connectors = {
  { id = "whatsapp", whatsapp_account = true } } } end
local function peer_without(name) return { name = name, node_id = "id-" .. name, connectors = {
  { id = "whatsapp", whatsapp_account = false } } } end

env_with("openclaw")
ok(whatsapp.owner(catalog_with({ peer_holding("other") })) == "openclaw",
  "the owner the deploy named wins over anything the fleet says")
env_with("")
ok(whatsapp.owner(catalog_with({ peer_holding("openclaw"), peer_without("work") })) == "openclaw",
  "with nothing declared, the one node that runs the component is the owner")
ok(whatsapp.owner(catalog_with({ peer_without("work") })) == nil, "nobody holding the account is nobody")
ok(whatsapp.owner(catalog_with({ peer_holding("a"), peer_holding("b") })) == nil,
  "two holders are not resolved by picking the first")
ok(whatsapp.owner(catalog_with(nil)) == nil, "an unreadable fleet is not a guess")
env_with("")

-- ---- one call: answered here, asked there, or refused with the owner -----------------------------
local function stub(capability, answer)
  host[capability] = function(request)
    local decoded = json.decode(request) or {}
    return json.encode(type(answer) == "function" and answer(decoded) or answer)
  end
end
local absent = { ok = false, error = "whatsapp_component_absent", state = "disabled", owner = "openclaw", effect = "none" }

stub("whatsapp_read", absent)
local asked = nil
local routed = whatsapp.call("mcp_whatsapp_read", { chat = "Laura" }, {
  remote_call = function(node, name, args)
    asked = { node = node, name = name, args = args }
    return { ok = true, header = { name = "Laura" }, messages = {} }
  end,
})
ok(asked ~= nil and asked.node == "openclaw", "a read is asked of the node that holds the account")
ok(asked.name == "mcp_whatsapp_read", "and is asked under the same name, so one answer shape serves both")
ok(asked.args.chat == "Laura", "the same question travels, including the name to resolve")
ok(routed.ok == true and routed.header.name == "Laura", "the answer is passed through")
ok(routed.served_by == "openclaw" and routed.asked_owner == "openclaw",
  "and says which node answered it")

local unreachable = whatsapp.call("mcp_whatsapp_read", { chat = "Laura" }, {
  remote_call = function() error("no route to openclaw") end,
})
ok(unreachable.error == "whatsapp_account_unreachable" and unreachable.account_lives_on == "openclaw",
  "an unreachable owner is a named refusal")
ok(unreachable.effect == "none" and unreachable.id == nil, "and it queues nothing")

-- Every verb is the account node's question to answer, effects included (operator decision, 11/11):
-- the effect happens where the worker is, under the owner's own guards, and the answer keeps its shape
-- plus `served_by` - so a master anywhere uses every tool, and a send is still queued on the durable
-- queue of the node that can settle it (#99).
local EFFECTS = {
  { verb = "download", args = { chat = "5511999999999@lid", id = "3EB0" }, key = "id", value = "3EB0" },
  { verb = "backfill", args = { chat = "5511999999999@lid", count = 5 }, key = "count", value = 5 },
  { verb = "send", args = { chat = "5519994939204@s.whatsapp.net", text = "oi" }, key = "text", value = "oi" },
  { verb = "send_status", args = { id = 7 }, key = "id", value = 7 },
}
for _, case in ipairs(EFFECTS) do
  local verb = case.verb
  stub(whatsapp.by_verb[verb].capability, absent)
  local asked = {}
  local answered = whatsapp.call("mcp_whatsapp_" .. verb, case.args, {
    remote_call = function(node, name, args)
      asked[#asked + 1] = { node = node, name = name, args = args }
      return { ok = true, id = 7, state = "done", message_id = "MSG-7",
        path = "/var/lib/wa/whatsapp-media/x.bin" }
    end,
  })
  ok(#asked >= 1 and asked[1].node == "openclaw",
    verb .. " is asked of the node that holds the account")
  ok(asked[1].name == "mcp_whatsapp_" .. verb, verb .. " travels under the same name, one answer shape")
  ok(asked[1].args[case.key] == case.value, verb .. " travels with the arguments the caller gave")
  ok(answered.ok == true and answered.served_by == "openclaw" and answered.asked_owner == "openclaw",
    verb .. " is answered by the owner and says which node answered: " .. json.encode(answered))
  -- A send that answers its own outcome adds ONE wait, and that wait is state reads of the same job:
  -- every further hop asks the owner what it knows, never to send the message a second time.
  for index = 2, #asked do
    ok(asked[index].name == "mcp_whatsapp_send_status" and asked[index].args.id == 7,
      verb .. " waits on the account node by reading the job state, hop " .. tostring(index))
    ok(asked[index].args.wait_s == nil, "a state read carries no wait of its own")
  end
end
ok(#EFFECTS == 4, "the four effects of the surface are covered")

-- A decrypted file is written on the owner node: the path that comes back is that node's, and
-- `served_by` is how the caller learns where it is - nobody is told the file is local.
stub("whatsapp_download", absent)
local file = whatsapp.call("mcp_whatsapp_download", { chat = "5511999999999@lid", id = "3EB0" }, {
  remote_call = function() return { ok = true, path = "/home/wa/.wasm-agent/data/whatsapp-media/x.jpg", mime = "image/jpeg" } end,
})
ok(file.path == "/home/wa/.wasm-agent/data/whatsapp-media/x.jpg", "the owner's file path is passed through")
ok(file.served_by == "openclaw", "and the result says the file is on openclaw, not here")

-- The owner's own guards stay where the account is (`whatsapp.send`: rate limit, daily cap, audit): its
-- refusal is the answer, unchanged and not relabelled.
local refused_by_owner = whatsapp.call("mcp_whatsapp_send", { chat = "5519994939204@s.whatsapp.net", text = "oi" }, {
  remote_call = function() return { ok = false, error = "whatsapp_send_rate_limited", effect = "none", retry_after_s = 60 } end,
})
ok(refused_by_owner.error == "whatsapp_send_rate_limited" and refused_by_owner.retry_after_s == 60,
  "the owner's refusal arrives as it was: " .. json.encode(refused_by_owner))
ok(refused_by_owner.served_by == nil and refused_by_owner.effect == "none",
  "and a refusal is not relabelled as an answer from another node")

-- An owner that cannot be reached is a named refusal, and nothing is queued on this node (#99).
local send_unreachable = whatsapp.call("mcp_whatsapp_send", { chat = "5519994939204@s.whatsapp.net", text = "oi" }, {
  remote_call = function() error("no route to openclaw") end,
})
ok(send_unreachable.error == "whatsapp_owner_unreachable" and send_unreachable.owner == "openclaw",
  "a send whose owner is unreachable is a named refusal")
ok(send_unreachable.id == nil and send_unreachable.queue == nil,
  "and it queues nothing here (#99)")
-- The effect is `unknown`, not `none`: the owner may have queued the message before the answer was
-- lost, and saying "nothing happened" would be a claim this node cannot observe (11/11).
ok(send_unreachable.effect == "unknown" and tostring(send_unreachable.note):find("same job", 1, true) ~= nil,
  "a lost answer is an unknown effect with the retry that is safe: " .. json.encode(send_unreachable))

-- Nobody named, nobody found: the refusal says how to fix it instead of queueing.
env_with("")
stub("whatsapp_read", { ok = false, error = "whatsapp_component_absent", state = "disabled", effect = "none" })
local orphan = whatsapp.call("mcp_whatsapp_read", { chat = "Laura" }, { owner_catalog = catalog_with({}) })
ok(orphan.error == "whatsapp_component_absent", "no component and no owner is still one honest word")
ok(orphan.owner == nil and orphan.effect == "none", "with no owner invented")
ok(orphan.note:find("WASM_AGENT_WHATSAPP_OWNER", 1, true) ~= nil, "and the next step in the note")

-- Routing cannot answer without an owner, or with two (an ambiguous fleet is never resolved by picking
-- the first): the same honest refusal, for an effect exactly as for a read, and nothing is forwarded.
stub("whatsapp_send", { ok = false, error = "whatsapp_component_absent", state = "disabled", effect = "none" })
for _, named in ipairs({ "none", "two" }) do
  local catalog = named == "none" and catalog_with({})
    or catalog_with({ peer_holding("a"), peer_holding("b") })
  local hops = 0
  local unowned = whatsapp.call("mcp_whatsapp_send", { chat = "5519994939204@s.whatsapp.net", text = "oi" }, {
    owner_catalog = catalog,
    remote_call = function() hops = hops + 1; return { ok = true } end,
  })
  ok(unowned.error == "whatsapp_component_absent", "with no single owner a send refuses (" .. named .. "): " .. json.encode(unowned))
  ok(unowned.owner == nil and unowned.effect == "none" and unowned.id == nil,
    "and invents no owner and queues nothing (" .. named .. ")")
  ok(unowned.note:find("WASM_AGENT_WHATSAPP_OWNER", 1, true) ~= nil, "with the next step in the note (" .. named .. ")")
  ok(hops == 0, "nothing was forwarded (" .. named .. ")")
end

-- A question is never routed to the node asking it: when the account node named in the deploy is this
-- node and its component is stopped, one hop would ask the same unanswered question again for ever.
-- That is the third case routing cannot answer, and it names the fix.
local my_name = whatsapp.self_name()
ok(type(my_name) == "string" and my_name ~= "", "this node can name itself")
env_with(my_name)
local self_hops = 0
local on_itself = whatsapp.call("mcp_whatsapp_send", { chat = "5519994939204@s.whatsapp.net", text = "oi" }, {
  remote_call = function() self_hops = self_hops + 1; return { ok = true } end,
})
ok(on_itself.error == "whatsapp_component_absent",
  "an effect on the account node itself with no component is refused: " .. json.encode(on_itself))
ok(on_itself.owner == my_name and on_itself.effect == "none" and on_itself.id == nil,
  "the refusal names this node and queues nothing")
ok(on_itself.note:find("wa services start", 1, true) ~= nil, "and says how to start it here")
ok(self_hops == 0, "nothing was routed to itself")
env_with("")

-- ---- a retired spelling recovers in one step ------------------------------------------------------
local renamed = {
  ["whatsapp_read"] = "mcp_whatsapp_read",
  ["whatsapp_search"] = "mcp_whatsapp_search",
  ["whatsapp_send"] = "mcp_whatsapp_send",
  -- A retired spelling of the status read points at the one tool that answers now, not at the hidden
  -- alias: send_status is the resume form of send (operator decision, 11/11).
  ["whatsapp_send_status"] = "mcp_whatsapp_send",
  ["peer_openclaw__whatsapp_send_status"] = "mcp_whatsapp_send",
  ["peer_openclaw__whatsapp_read"] = "mcp_whatsapp_read",
  ["peer_openclaw__mcp_whatsapp_native_read_newest_47452e4e"] = "mcp_whatsapp_read",
  ["mcp_whatsapp_native_read_snapshot_47452e4e"] = "mcp_whatsapp_search",
  ["mcp_whatsapp_native_inspect_chat_47452e4e"] = "mcp_whatsapp_read",
  ["mcp_whatsapp_native_lookup_self_47452e4e"] = "mcp_whatsapp_contacts",
}
for old, expected in pairs(renamed) do
  ok(whatsapp.renamed(old) == expected, old .. " maps to " .. expected)
  local refusal = tools.dispatch(dofile("lua/core/memory.lua"), old, {}, "master", { user_id = "master", role = "master" })
  ok(refusal.error == "whatsapp_tool_renamed", old .. " is refused as renamed: " .. json.encode(refusal))
  ok(refusal.use == expected and refusal.effect == "none", old .. " names the tool to call instead")
end
ok(whatsapp.renamed("read") == nil and whatsapp.renamed("mcp_mail_read_deadbeef") == nil,
  "a name from another tool is not claimed by this one")

-- ---- the /mcp view says which node holds the account ----------------------------------------------
local function holds(value)
  local real = host.service
  host.service = function() return json.encode({ { name = "wa-whatsapp", state = value } }) end
  local result = whatsapp.holds_account()
  host.service = real
  return result
end
ok(holds("running") == true, "a running component means this node holds the account")
ok(holds("disabled") == false, "a stopped component does not")
local surface = nil
for _, entry in ipairs(federation.connectors()) do if entry.whatsapp_account ~= nil then surface = entry end end
ok(surface ~= nil, "the /mcp view reports the WhatsApp surface as a row")
ok(surface.tool_count == #VERBS, "with the eight tools it gives the model, and not the hidden alias")
ok(holds("running") == true and whatsapp.holds_account() ~= nil, "the check is read from the services registry")

host.getenv = real_getenv
print("whatsapp one surface: " .. checks .. " checks passed")
