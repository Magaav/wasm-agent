-- P2.4 of whatsapp-index-heals-itself: a SEND to a name is refused, and the refusal carries the
-- candidates - the tool never picks a recipient.
--
-- Hermetic: the two host capabilities the path touches are stubs, nothing is queued, no account.
-- What it pins:
--   * a name (no `@`, not a bare number) never reaches the send path: the refusal is `..._chat_ambiguous`
--     WITH the candidates when contacts knows the name, `..._chat_not_found` when it does not;
--   * `host.whatsapp_send` is never called for either (the counter is the proof: nothing was queued);
--   * a bare number keeps the schema's rule and is refused without a lookup;
--   * an exact JID still sends (the stubbed capability is called once).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")

local home = host.getenv("WASM_AGENT_HOME") or ""
assert(home ~= "", "this row needs its own WASM_AGENT_HOME")

local checks, sends, lookups = 0, 0, 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label .. " - whatsapp send name", 2) end
end

host.whatsapp_contacts = function(request)
  lookups = lookups + 1
  local asked = (json.decode(request) or {}).q or ""
  if asked == "Ana" then
    return json.encode({ ok = true, q = asked, count = 2, ambiguous = true, candidates = {
      { chat = "15550000001@lid", name = "Ana", type = "person", confidence = "exact", at_local = "2026-11-20 10:00" },
      { chat = "15550000002@s.whatsapp.net", name = "Ana", type = "person", confidence = "exact", at_local = "2026-11-19 09:00" },
    } })
  end
  return json.encode({ ok = true, q = asked, count = 0, ambiguous = false, candidates = {} })
end
host.whatsapp_send = function()
  sends = sends + 1
  return json.encode({ ok = true, state = "done", id = 1, message_id = "M1" })
end

local ctx = { user_id = "master", role = "master", codemode_nested = true }

-- 1. a name contacts knows twice: refused, with both candidates, and nothing queued.
local answer = tools.dispatch(memory, "mcp_whatsapp_send", { chat = "Ana", text = "oi" }, "master", ctx)
ok(answer.error == "whatsapp_send_chat_ambiguous", "a send to a name is refused by name: " .. json.encode({ error = answer.error }))
ok(type(answer.candidates) == "table" and #answer.candidates == 2, "the refusal carries the candidates")
ok(answer.effect == "none", "and changed nothing")
ok(sends == 0, "NOTHING was queued: the send capability was never called")
ok(answer.asked == "Ana", "the refusal says what was asked")

-- 2. a name nobody carries: the other word, and still nothing queued.
local missing = tools.dispatch(memory, "mcp_whatsapp_send", { chat = "Ninguem", text = "oi" }, "master", ctx)
ok(missing.error == "whatsapp_send_chat_not_found", "an unknown name says so: " .. json.encode({ error = missing.error }))
ok(sends == 0, "and still nothing queued")
ok(lookups == 2, "both names were looked up once each (" .. lookups .. ")")

-- 3. a bare number is NOT a name: it is never looked up. Its own refusal ("a bare phone number is
-- refused") is the host's exact-JID rule, which this hermetic row stubs away - so the assertion here is
-- the one this layer owns: no lookup, no guessing.
local before = lookups
tools.dispatch(memory, "mcp_whatsapp_send", { chat = "15550000003", text = "oi" }, "master", ctx)
ok(lookups == before, "a bare number never became a name lookup")

-- 4. an exact JID still sends: the send path is reached, once, and no lookup was needed for it.
local sent_before = sends
local exact = tools.dispatch(memory, "mcp_whatsapp_send", { chat = "15550000001@lid", text = "oi" }, "master", ctx)
ok(sends == sent_before + 1, "an exact JID reaches the send path: " .. json.encode({ sends = sends }))
ok(lookups == before, "and it needed no lookup")
ok(exact ~= nil, "and it answered")

print("whatsapp send name ok (" .. checks .. " checks)")
