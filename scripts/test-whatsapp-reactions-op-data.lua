-- The tool answer of `mcp_whatsapp_reactions` is the same bytes however the host spells its op.
--
-- First slice of "WhatsApp leaves the host" (docs/missions/reports/whatsapp-leaves-the-host.md):
-- `host.whatsapp_reactions` no longer names a variant of the host's compile-time op enum - the bind hands
-- the word `reactions` to the generic path (`answer_text` in rust/wa-capabilities/src/whatsapp_query.rs),
-- which validates, queues and settles exactly as before. The move only pays if the model cannot tell, so
-- this row pins the bytes it reads.
--
-- WHERE THE GOLDEN COMES FROM (rule 14): the documents below were captured from the BASE binary
-- (wasm-agent v0.1.2 - va1857d15 - tree 70eb209d, this branch's base, before the change) with this same
-- script, a scratch home and a queue of its own. They are asserted verbatim after it.
--
-- NOTHING HERE TOUCHES AN ACCOUNT: a scratch node runs no `wa-whatsapp` component, so the first two
-- answers are refusals decided before a job exists, and the third is the "still running" answer of a job
-- on this node's OWN queue. `15550000001@lid` is a synthetic 555 number: never an account, never a phone.
--
-- WHAT CHANGED AND WHAT DID NOT: only the host's spelling of the op. The tool row, its description, its
-- arguments and its answer are untouched, which is why these bytes are the whole test.

local json = dofile("lua/vendor/json.lua")
local whatsapp = dofile("lua/core/whatsapp.lua")

-- A row that queues one job refuses the operator's real store (quality rule 2: a test that writes state
-- creates its own home; scripts/fast.sh gives every scripts/test-*.lua row one).
local home = host.getenv("WASM_AGENT_HOME") or ""
local real = (host.getenv("HOME") or "") .. "/.wasm-agent"
assert(home ~= "", "this row needs its own WASM_AGENT_HOME")
assert(home ~= real, "this row refuses the operator store: " .. home)

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label .. " - whatsapp reactions op data", 2) end
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

ok(type(host.whatsapp_reactions) == "function", "the capability is registered on this node")
local tool = whatsapp.tool("mcp_whatsapp_reactions")
ok(tool ~= nil, "the reactions tool is this surface")
ok(tool.capability == "whatsapp_reactions", "the tool asks the capability it always asked")

-- The exact documents the base binary answered: a question with no message in it, and a chat that is
-- not an address. Both are refused before anything is queued, so they cannot depend on the node's state.
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
  -- The host's own bytes, compared as bytes: the answer leaves the capability as this string.
  local raw = tostring(host.whatsapp_reactions(json.encode(case.args)))
  ok(raw == case.raw, "the host answers the base bytes for " .. case.name)
  -- The door the tool uses, and the document it decodes to: the same fields, no more, no fewer.
  local answer = whatsapp.invoke(tool, case.args)
  local fine, why = same(json.decode(case.raw), answer)
  ok(fine, "the tool answers the base document for " .. case.name .. " (" .. tostring(why) .. ")")
end

-- The third shape: a real job on this node's own queue, with no worker anywhere to settle it. The base
-- answer was `..._slow` with id 1 - the first job of a fresh home - and the sentence a waiting reader saw.
local args = { chat = "15550000001@lid", id = "3EB0C0FFEE11" }
local answer = json.decode(tostring(host.whatsapp_reactions(json.encode(args))))
ok(answer.error == "whatsapp_reactions_slow", "an unanswered query is slow, not an error")
ok(answer.ok == false and answer.op == "reactions" and answer.state == "queued", "the slow answer's fields")
ok(answer.retry == true and answer.effect == "none", "a slow answer changed nothing and is worth retrying")
ok(answer.detail == "the wa-whatsapp component has not answered yet; the same call reads the same job",
  "the sentence a model reads while it waits")
ok(type(answer.id) == "number" and answer.id >= 1, "the job id, so the same call reads the same job")

-- Nothing is queued twice: the same question reads the SAME job. The dedupe key is built from the
-- validated request, which is the one thing the op-as-data path could have changed silently.
local again = json.decode(tostring(host.whatsapp_reactions(json.encode(args))))
ok(again.id == answer.id, "the same question is the same job")
ok(again.error == answer.error and again.detail == answer.detail, "and the same answer")

-- The same question through the tool door: the model's answer, not the queue's record.
local via_tool = whatsapp.invoke(tool, args)
ok(via_tool.id == answer.id and via_tool.error == answer.error, "the tool door answers the same job and word")

print("whatsapp reactions op data ok (" .. checks .. " checks)")
