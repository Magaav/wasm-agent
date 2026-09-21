-- The scoped WhatsApp responder tools enforce their restrictions structurally.
--
-- These are the rules that keep a whatsapp-responder run inside one conversation with no shell, no edit
-- and no deploy. Each bypass the review found has a mutation test here: a store route cannot run the UI
-- script, a missing counter is not unlimited, a shell exit is not a send, and an event cannot supply a
-- route or a capability.
local whatsapp = dofile("lua/core/whatsapp.lua")

local checks = 0
local function check(value, label)
  checks = checks + 1
  assert(value, label or ("check " .. checks))
end

local function base_profile()
  return {
    schema_version = 1,
    id = "whatsapp-responder",
    instructions = "Answer as the operator, in one conversation.",
    allowed_tools = { "whatsapp_conversation", "whatsapp_decide", "whatsapp_send" },
    resources = {
      allowed_conversation = "5511888888888@c.us",
      allowed_conversations = { "5511888888888@c.us" },
      self_destination = "5511999999999@c.us",
      account = "operator",
      browser_endpoint = "ws://localhost:9222/devtools/page/FIXTURE",
      send_path = "ui",
      allow_mark_read = false,
      send_approved = false,
      reply_script = "C:/approved/whatsapp-reply.mjs",
      store_send_script = "",
    },
    limits = { context_messages = 5, body_bytes = 100, sends_per_run = 1 },
  }
end

local function new_effects()
  local store = { rows = {} }
  function store.find(message_id)
    for _, row in ipairs(store.rows) do
      if row.message_id == message_id then return row end
    end
    return nil
  end
  function store.record(row)
    store.rows[#store.rows + 1] = row
    return true
  end
  return store
end

local function verified_result(conversation_id, body, message_id)
  return { ok = true, sent = true, verified = true, chat = { id = conversation_id }, body = body,
    message = { id = message_id or "3EB0FIXTURE", ack = 3 } }
end

local function memory_for(conversation_id)
  return {
    conversation = function(id, limit)
      return { { role = "user", content = "are you coming?", conversation_id = id }, limit = limit }
    end,
  }
end

-- Schemas are what the registry advertises.
local names = {}
for _, item in ipairs(whatsapp.schemas()) do names[item["function"].name] = true end
check(names["whatsapp_conversation"] and names["whatsapp_decide"] and names["whatsapp_send"], "schemas name the scoped tools")
check(not names["bash"] and not names["edit"] and not names["operation"], "no shell/edit/deploy tool is exposed")

local profile = base_profile()
local memory = memory_for("5511888888888@c.us")
local effects = new_effects()
local sends = { count = 0 }
local event = { conversation_id = "5511888888888@c.us", message_id = "MSG1" }
local ctx = { profile = profile, event = event, effects = effects, sends = sends }

-- Conversation scope: the trusted event's conversation works; another is refused; a ledger row outside it
-- is a scope mismatch.
local read = whatsapp.dispatch(memory, "whatsapp_conversation", {}, ctx)
check(read.conversation_id == "5511888888888@c.us" and read.count == 1, "reads the event's conversation")
local stray = { conversation = function() return { { conversation_id = "999@c.us" } } end }
check(whatsapp.dispatch(stray, "whatsapp_conversation", {}, ctx).error == "ledger_scope_mismatch", "a ledger row outside the conversation is refused")
check(whatsapp.dispatch(memory, "whatsapp_conversation", {}, { profile = profile }).error == "event_context_required", "a tool call needs the trusted event identity")
local foreign = { profile = profile, event = { conversation_id = "999@c.us", message_id = "M" }, effects = effects, sends = sends }
check(whatsapp.dispatch(memory, "whatsapp_conversation", {}, foreign).error == "conversation_not_in_profile", "another conversation is refused")

-- A decision is durable, and it never sends or approves.
local decided = whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply", reason = "waiting on them" }, ctx)
check(decided.decision == "reply" and decided.send_approved == false, "a decision reports but does not grant send approval")
check(decided.recorded == true and effects.find("MSG1") and effects.find("MSG1").kind == "decision", "the decision is recorded durably")
check(decided.sent == nil, "a decision never sends")
check(whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" }, { profile = profile, event = event }).error == "effect_store_unbound", "a decision without a durable store is refused")

-- Sending is refused while the profile does not approve it; a tool outside allowed_tools is refused.
local refused = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes, 3pm", confirm = true }, ctx)
check(refused.error == "send_not_approved", "send needs the profile's approval, not the decision")
local notAllowed = whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" },
  { profile = { schema_version = 1, id = "whatsapp-responder", allowed_tools = { "whatsapp_send" }, resources = {} }, event = event, effects = effects })
check(notAllowed.error == "tool_not_in_profile", "a tool outside allowed_tools is refused")

-- The mutation the review found: `send_path="store"` used to bypass the unread guard while still running
-- the UI script. It must be a real route or a refusal.
profile.resources.send_approved = true
profile.resources.send_path = "store"
profile.resources.store_send_script = ""
local storeUnbound = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, ctx)
check(storeUnbound.error == "store_route_unbound", "store route without a store script is refused (UI script cannot be smuggled in)")

-- The UI route on a third-party chat refuses to clear unread without explicit acceptance...
profile.resources.send_path = "ui"
local unread = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, ctx)
check(unread.error == "unread_would_be_broken" and #unread.options == 3, "the UI route refuses to clear unread without approval")
-- ...but notes-to-self are the exemption, decided by the trusted self destination, not the event.
local self_profile = base_profile()
self_profile.resources.send_approved = true
self_profile.resources.send_path = "ui"
self_profile.resources.allow_mark_read = false
self_profile.resources.allowed_conversation = "5511999999999@c.us"
self_profile.resources.allowed_conversations = { "5511999999999@c.us" }
local self_ctx = {
  profile = self_profile,
  event = { conversation_id = "5511999999999@c.us", message_id = "SELF1" },
  effects = effects,
  sends = { count = 0 },
  send = function(request) return verified_result(request.conversation_id, request.body) end,
}
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "note", confirm = true }, self_ctx).verified == true, "a self-only UI send is allowed without marking anything read")

-- The event cannot supply a route or a script: extra fields are dropped.
local injected = whatsapp.trusted_event({ conversation_id = "x", message_id = "y", reply_script = "/evil", send_path = "store", browser_endpoint = "ws://evil" })
check(injected.reply_script == nil and injected.send_path == nil and injected.browser_endpoint == nil, "an event cannot inject a route or capability")

-- Confirm, body bound, trusted counter, and the store route.
profile.resources.send_path = "store"
profile.resources.store_send_script = "C:/approved/store-send.mjs"
local missingConfirm = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes" }, ctx)
check(missingConfirm.error == "confirm_required", "confirm is required")
local tooLong = whatsapp.dispatch(memory, "whatsapp_send", { body = string.rep("x", 101), confirm = true }, ctx)
check(tooLong.error == "body_too_long", "the body bound is enforced")
local noCounter = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, { profile = profile, event = event, effects = effects })
check(noCounter.error == "send_counter_unbound", "a missing per-run counter is refused, not unlimited")
local noEffects = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, { profile = profile, event = event, sends = { count = 0 } })
check(noEffects.error == "effect_store_unbound", "a missing durable effect store is refused")

local sent_request = nil
local send_ctx = {
  profile = profile,
  event = { conversation_id = "5511888888888@c.us", message_id = "MSG2" },
  effects = effects,
  sends = { count = 0 },
  send = function(request) sent_request = request; return verified_result(request.conversation_id, request.body, "3EB0SENT") end,
}
local okay = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes, 3pm", confirm = true }, send_ctx)
check(okay.ok == true and okay.verified == true and sent_request.body == "yes, 3pm", "an approved send reaches the route with the exact body")
check(send_ctx.sends.count == 1, "a verified send consumes the per-run allowance")
-- Idempotency: the same message id never sends twice.
local again = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes, 3pm", confirm = true }, send_ctx)
check(again.already_sent == true, "the same message id is not sent twice")
-- A second, different message exceeds the per-run limit.
send_ctx.event = { conversation_id = "5511888888888@c.us", message_id = "MSG3" }
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "one more", confirm = true }, send_ctx).error == "sends_per_run_exceeded", "the per-run send limit holds")

-- The effect decides: an unverified route result is never a success.
local unverified_ctx = {
  profile = profile, event = { conversation_id = "5511888888888@c.us", message_id = "MSG4" },
  effects = effects, sends = { count = 0 },
  send = function(request) return { ok = true, sent = true, verified = false, chat = { id = request.conversation_id }, body = request.body, message = { id = "x" } } end,
}
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, unverified_ctx).error == "send_not_verified", "an unverified result is refused")
check(whatsapp.verify_send_result(verified_result("a", "b"), "a", "b") == nil, "a fully verified result passes")
check(whatsapp.verify_send_result(verified_result("a", "b"), "other", "b") == "send_recipient_mismatch", "a different recipient is refused")
check(whatsapp.verify_send_result(verified_result("a", "b"), "a", "different") == "send_body_mismatch", "a different body is refused")
check(whatsapp.verify_send_result({ ok = true, sent = true, verified = true, chat = { id = "a" }, body = "b", message = {} }, "a", "b") == "send_message_id_missing", "a missing message id is refused")

-- Shell success is not send success: the operation wrapper and its stdout are both checked.
check(whatsapp.decode_exec('{"code":0,"stdout":"{\\"ok\\":true}"}') ~= nil, "a zero exit with JSON stdout decodes")
check(whatsapp.decode_exec('{"code":1,"stdout":"{\\"ok\\":true}"}') == nil, "a non-zero exit is refused")
check(whatsapp.decode_exec('{"code":0,"stdout":"not json"}') == nil, "non-JSON stdout is refused")

-- A profile that lost schema_version in normalization is still accepted; a wrong one is not.
check(whatsapp.validate_profile({ id = "x", allowed_tools = {}, resources = {} }) ~= nil, "a normalized profile without schema_version is accepted")
check(whatsapp.validate_profile({ schema_version = 2, id = "x", allowed_tools = {}, resources = {} }) == nil, "a wrong schema_version is refused")
check(whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" }, { profile = { id = "x", allowed_tools = {} }, event = event }).error == "profile_resources_required", "a profile missing resources is refused")

print("whatsapp scoped checks " .. checks)
print("whatsapp scoped ok")
