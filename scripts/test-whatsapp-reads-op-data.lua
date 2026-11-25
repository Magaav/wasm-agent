-- The tool answers of the WhatsApp reads are the same bytes however the host spells their op.
--
-- "WhatsApp leaves the host" (docs/missions/reports/whatsapp-leaves-the-host.md): the host used to carry
-- one compile-time op variant, one bind and one capability row per read question, so every WhatsApp change
-- was a hub change. Now `host.whatsapp_index({op, ...args})` carries them all, and the question travels in
-- the request. This row is the one that says a read cannot tell: for every read op, the generic door and
-- the named row answer byte for byte the same document, and a tool whose catalogue row points at the
-- generic door answers exactly what the named capability answers.
--
-- WHERE THE GOLDENS COME FROM (rule 14): the documents below were captured from the BASE binary
-- (wasm-agent v0.1.2 - va1857d15 - tree 70eb209d, this branch's base, before any of it) with this same
-- script, a scratch home and a queue of its own; they are asserted verbatim.
--
-- NOTHING HERE TOUCHES AN ACCOUNT: a scratch node runs no `wa-whatsapp` component, so every answer is a
-- refusal decided before a job exists, except the one "still running" answer taken from this node's OWN
-- queue. `15550000001@lid` is a synthetic 555 number: never an account, never a phone.

local json = dofile("lua/vendor/json.lua")
local whatsapp = dofile("lua/core/whatsapp.lua")

-- A row that queues one job refuses the operator's real store (quality rule 2).
local home = host.getenv("WASM_AGENT_HOME") or ""
local real = (host.getenv("HOME") or "") .. "/.wasm-agent"
assert(home ~= "", "this row needs its own WASM_AGENT_HOME")
assert(home ~= real, "this row refuses the operator store: " .. home)

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label .. " - whatsapp reads op data", 2) end
end

local function same(a, b, path)
  path = path or "answer"
  if type(a) ~= type(b) then return false, path .. " is " .. type(a) .. " here and " .. type(b) .. " there" end
  if type(a) ~= "table" then
    if a ~= b then return false, path .. " is " .. tostring(a) .. " here and " .. tostring(b) .. " there" end
    return true
  end
  for key, value in pairs(a) do
    local fine, why = same(value, b[key], path .. "." .. tostring(key))
    if not fine then return false, why end
  end
  for key in pairs(b) do
    if a[key] == nil then return false, path .. "." .. tostring(key) .. " is missing here" end
  end
  return true
end

ok(type(host.whatsapp_reactions) == "function", "the named capability is registered on this node")
ok(type(host.whatsapp_index) == "function", "the generic row is registered on this node")

-- The exact documents the base binary answered through the reactions tool (captured, not remembered).
local GOLDEN = {
  {
    name = "missing_chat",
    args = {},
    raw = '{"detail":"one message: pass chat and id","effect":"none","error":"whatsapp_reactions_chat_and_id_required","ok":false,"op":"reactions"}',
  },
  {
    name = "bad_chat",
    args = { chat = "not a chat", id = "3EB0C0FFEE11" },
    raw = '{"detail":"chat JID contains whitespace or a control character","effect":"none","error":"whatsapp_reactions_bad_chat","ok":false,"op":"reactions"}',
  },
}
for _, case in ipairs(GOLDEN) do
  local raw = tostring(host.whatsapp_reactions(json.encode(case.args)))
  ok(raw == case.raw, "the named row answers the base bytes for " .. case.name)
  local via_generic = tostring(host.whatsapp_index(json.encode({ op = "reactions", chat = case.args.chat, id = case.args.id })))
  ok(via_generic == case.raw, "the generic door answers the same bytes for " .. case.name)
end

-- Every read op this branch has moved, with arguments that need no queue: a refusal is decided before
-- anything is enqueued, so the comparison cannot depend on this node's state. The tool door is compared
-- too: it is the path the model takes (`M.invoke`), and after a repoint it goes through the generic row.
local OPS = {
  { op = "search", args = {} },
  { op = "read", args = {} },
  { op = "contacts", args = { q = "1555" } },
  -- `message` is the one read the model is not offered: the component points at it inside a long message
  -- (`rust/components/wa-whatsapp/src/view.rs`), no catalogue row names it, and the capability answers a
  -- script. It has no tool door to compare, so its entry says so.
  { op = "message", args = {}, tool = false },
}

for _, case in ipairs(OPS) do
  local payload = { op = case.op }
  for key, value in pairs(case.args) do payload[key] = value end
  local named = tostring(host["whatsapp_" .. case.op](json.encode(case.args)))
  local generic = tostring(host.whatsapp_index(json.encode(payload)))
  ok(named == generic, case.op .. ": the generic door answers the named row's bytes")
  if case.tool ~= false then
    local tool = whatsapp.tool("mcp_whatsapp_" .. case.op)
    ok(tool ~= nil, "the " .. case.op .. " tool is this surface")
    local via_tool = whatsapp.invoke(tool, case.args)
    local fine, why = same(json.decode(named), via_tool)
    ok(fine, case.op .. ": the tool door answers the named row's document (" .. tostring(why) .. ")")
    ok(tool.capability == "whatsapp_index", case.op .. ": the tool row points at the generic door")
  end
end

-- The generic door refuses to guess which question it is, and queues nothing.
local no_op = json.decode(tostring(host.whatsapp_index(json.encode({ q = "boleto" }))))
ok(no_op.error == "whatsapp_index_op_required" and no_op.ok == false, "no op is a named refusal")

-- Whatever it is asked, an op nothing knows is refused by name.
local unknown = json.decode(tostring(host.whatsapp_index(json.encode({ op = "nope" }))))
ok(unknown.error == "whatsapp_nope_bad_op", "an unknown op is refused by name")

-- The one "still running" answer, from this node's own queue: the same on both doors.
local args = { chat = "15550000001@lid", id = "3EB0C0FFEE11" }
local named = json.decode(tostring(host.whatsapp_reactions(json.encode(args))))
ok(named.error == "whatsapp_reactions_slow", "an unanswered query is slow, not an error")
ok(named.detail == "the wa-whatsapp component has not answered yet; the same call reads the same job",
  "the sentence a model reads while it waits")
local payload = { op = "reactions", chat = args.chat, id = args.id }
local generic = json.decode(tostring(host.whatsapp_index(json.encode(payload))))
ok(generic.id == named.id, "the generic door reads the same job")
ok(generic.error == named.error and generic.detail == named.detail, "and the same answer")
local again = json.decode(tostring(host.whatsapp_index(json.encode(payload))))
ok(again.id == named.id, "a repeated generic call reads the same job (the dedupe key of the request)")

print("whatsapp reads op data ok (" .. checks .. " checks)")
