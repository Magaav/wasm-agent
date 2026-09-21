-- The scoped WhatsApp responder tools enforce their restrictions structurally.
--
-- These are the rules that keep a whatsapp-responder run inside one conversation with no shell, no edit
-- and no deploy. Each bypass review found has a mutation test here: a non-self send cannot be smuggled
-- into the UI script, a crash between send and confirm must not replay, a missing counter/store is not
-- "unlimited", a shell exit is not a send, and an event cannot supply a route or a capability.
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
    allowed_tools = { "whatsapp_read", "whatsapp_decide", "whatsapp_send" },
    resources = {
      allowed_conversation = "5511888888888@c.us",
      allowed_conversations = { "5511888888888@c.us" },
      actions = { "read", "send" },
      self_destination = "5511999999999@c.us",
      account = "5511999999999",
      browser_endpoint = "ws://[::1]:9222/devtools/page/FIXTURE",
      send_path = "ui",
      allow_mark_read = false,
      send_approved = false,
      reply_script = "C:/approved/whatsapp-reply.mjs",
      store_send_script = "",
    },
    limits = { context_messages = 5, body_bytes = 100, sends_per_run = 1 },
  }
end

-- A durable effect store implementing the reserve/confirm contract, including the crash window.
local function new_effects()
  local store = { rows = {}, budget_used = 0, fail_confirm = false, reconcile_status = "unknown" }
  local function send_row(message_id)
    for _, row in ipairs(store.rows) do
      if row.message_id == message_id and row.kind == "send" then return row end
    end
    return nil
  end
  function store.record(row)
    -- A decision must never overwrite a pending/sent send; reserve() must stay truthful.
    store.rows[#store.rows + 1] = { kind = "decision", message_id = row.message_id, conversation_id = row.conversation_id, decision = row.decision }
    return true
  end
  function store.reserve(request)
    local prior = send_row(request.message_id)
    if prior then
      if prior.state == "sent" then return { status = "already_sent", record = prior } end
      return { status = "ambiguous", record = prior }
    end
    if store.budget_used >= request.limit then return { status = "budget_exceeded" } end
    store.budget_used = store.budget_used + 1
    local row = { kind = "send", message_id = request.message_id, conversation_id = request.conversation_id, state = "pending" }
    store.rows[#store.rows + 1] = row
    return { status = "reserved", record = row }
  end
  function store.confirm(request)
    local prior = send_row(request.message_id)
    if not prior or prior.state ~= "pending" then return false end
    if store.fail_confirm then return false end
    prior.state = "sent"
    prior.message = request.message
    return true
  end
  function store.unknown(request)
    local prior = send_row(request.message_id)
    if prior then prior.state = "unknown" end
    return true
  end
  function store.release(request)
    for index, row in ipairs(store.rows) do
      if row.message_id == request.message_id and row.kind == "send" and row.state == "pending" then
        table.remove(store.rows, index)
        store.budget_used = store.budget_used - 1
        return true
      end
    end
    return false
  end
  function store.reconcile() return { status = store.reconcile_status } end
  function store.find(message_id) return send_row(message_id) end
  return store
end

local function verified_result(conversation_id, body, message_id)
  return { ok = true, sent = true, verified = true, chat = { id = conversation_id }, body = body,
    account = "5511999999999", browser_endpoint = "ws://[::1]:9222/devtools/page/FIXTURE",
    message = { id = message_id or "3EB0FIXTURE", ack = 3 } }
end

local function memory_for()
  return {
    conversation = function(id, limit)
      return { { role = "user", content = "are you coming?", conversation_id = id }, limit = limit }
    end,
  }
end

local function send_ctx(profile, effects, message_id, sender)
  return {
    profile = profile,
    event = { conversation_id = profile.resources.allowed_conversation, message_id = message_id },
    effects = effects,
    send = sender or function(request) return verified_result(request.conversation_id, request.body) end,
  }
end

-- Schemas are what the registry advertises.
local names = {}
for _, item in ipairs(whatsapp.schemas()) do names[item["function"].name] = true end
check(names["whatsapp_read"] and names["whatsapp_decide"] and names["whatsapp_send"], "schemas name the scoped tools")
check(not names["whatsapp_conversation"], "the pre-rename name is not advertised")
check(not names["bash"] and not names["edit"] and not names["operation"], "no shell/edit/deploy tool is exposed")

local profile = base_profile()
local memory = memory_for()
local event = { conversation_id = "5511888888888@c.us", message_id = "MSG1" }
local ctx = { profile = profile, event = event, effects = new_effects() }

-- Conversation scope: the trusted event's conversation works; another is refused; a ledger row outside it
-- is a scope mismatch.
local read = whatsapp.dispatch(memory, "whatsapp_read", {}, ctx)
check(read.conversation_id == "5511888888888@c.us" and read.count == 1, "reads the event's conversation")
check(whatsapp.dispatch(memory, "whatsapp_conversation", {}, ctx).count == 1, "the pre-rename alias still dispatches")
local stray = { conversation = function() return { { conversation_id = "999@c.us" } } end }
check(whatsapp.dispatch(stray, "whatsapp_read", {}, ctx).error == "ledger_scope_mismatch", "a ledger row outside the conversation is refused")
check(whatsapp.dispatch(memory, "whatsapp_read", {}, { profile = profile }).error == "event_context_required", "a tool call needs the trusted event identity")
local foreign = { profile = profile, event = { conversation_id = "999@c.us", message_id = "M" }, effects = new_effects() }
check(whatsapp.dispatch(memory, "whatsapp_read", {}, foreign).error == "conversation_not_in_profile", "another conversation is refused")
check(whatsapp.dispatch(memory, "whatsapp_read", { conversation_id = "999@c.us" }, ctx).error == "event_conversation_immutable", "a foreign conversation argument cannot steer a read")
check(whatsapp.dispatch(memory, "whatsapp_send", { conversation_id = "999@c.us", body = "x", confirm = true }, send_ctx(profile, new_effects(), "FGN")).error == "event_conversation_immutable", "a foreign conversation argument cannot steer a send")

-- A decision is durable, never sends, and never clobbers a pending send.
local decided = whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply", reason = "waiting on them" }, ctx)
check(decided.decision == "reply" and decided.send_approved == false, "a decision reports but does not grant send approval")
check(decided.recorded == true, "the decision is recorded durably")
check(decided.sent == nil, "a decision never sends")
check(whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" }, { profile = profile, event = event }).error == "effect_store_unbound", "a decision without a durable store is refused")

-- Sending is refused while the profile does not approve it; a tool outside allowed_tools is refused.
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, ctx).error == "send_not_approved", "send needs the profile's approval, not the decision")
local notAllowed = whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" },
  { profile = { schema_version = 1, id = "whatsapp-responder", allowed_tools = { "whatsapp_send" }, resources = {} }, event = event, effects = new_effects() })
check(notAllowed.error == "tool_not_in_profile", "a tool outside allowed_tools is refused")

-- A `store` label cannot smuggle the UI script past the unread guard; the flag pass-through is binding-only.
profile.resources.send_approved = true
profile.resources.send_path = "store"
profile.resources.store_send_script = ""
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, new_effects(), "S0")).error == "store_route_unbound", "store route without a store script is refused")
check(#whatsapp.route_flags(profile, { name = "store", self_only = false }) == 0, "the store route takes no unread flag")
profile.resources.send_path = "ui"
check(#whatsapp.route_flags(profile, { name = "ui", self_only = false }) == 0, "an unapproved non-self UI send takes no flag")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, new_effects(), "S1")).error == "unread_would_be_broken", "an unapproved non-self UI send is refused")
profile.resources.allow_mark_read = true
check(whatsapp.route_flags(profile, { name = "ui", self_only = false })[1] == "--allow-mark-read", "an approved non-self UI send passes --allow-mark-read to the raw script")
check(#whatsapp.route_flags(profile, { name = "ui", self_only = true }) == 0, "a notes-to-self send needs no flag")

-- A debug/event argument cannot supply the approved flag: route_flags reads the profile only.
local forged = base_profile()
forged.resources.send_approved = true
forged.resources.send_path = "ui"
forged.resources.allow_mark_read = false
check(#whatsapp.route_flags(forged, { name = "ui", self_only = false }) == 0, "an event-supplied flag cannot approve a send")

-- The happy path: reserve, send, confirm.
profile.resources.send_path = "store"
profile.resources.store_send_script = "C:/approved/store-send.mjs"
local effects = new_effects()
local sent_request = nil
local sender = function(request) sent_request = request; return verified_result(request.conversation_id, request.body, "3EB0SENT") end
local okay = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes, 3pm", confirm = true }, send_ctx(profile, effects, "MSG2", sender))
check(okay.ok == true and okay.verified == true and sent_request.body == "yes, 3pm", "an approved send reaches the route with the exact body")
check(effects.find("MSG2").state == "sent", "a verified send is confirmed durably")

-- Idempotency: the same message id never sends twice, and no route is called.
local calls = 0
local counting = function(request) calls = calls + 1; return verified_result(request.conversation_id, request.body) end
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes, 3pm", confirm = true }, send_ctx(profile, effects, "MSG2", counting)).already_sent == true, "the same message id is not sent twice")
check(calls == 0, "an already-sent message never reaches the route")

-- The crash window: a reservation exists but was never confirmed. A later attempt must reconcile and
-- refuse, never send.
local crash = new_effects()
check(crash.reserve({ message_id = "CRASH", conversation_id = profile.resources.allowed_conversation, body = "x", limit = 1 }).status == "reserved", "a reservation is persisted before the send")
local crash_calls = 0
local crash_sender = function(request) crash_calls = crash_calls + 1; return verified_result(request.conversation_id, request.body) end
crash.reconcile_status = "unknown"
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(profile, crash, "CRASH", crash_sender)).error == "ambiguous_prior_send", "a pending reservation refuses a replay")
check(crash_calls == 0, "an ambiguous prior reservation never sends")
crash.reconcile_status = "sent"
local reconciled = whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(profile, crash, "CRASH", crash_sender))
check(reconciled.already_sent == true and reconciled.reconciled == true, "a reconciled prior send is reported, not resent")
check(crash_calls == 0, "reconciliation does not send")
crash.reconcile_status = "not_sent"
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(profile, crash, "CRASH", crash_sender)).error == "ambiguous_prior_send", "even a not-sent reconciliation refuses a replay")

-- The per-run budget is consumed by the durable reservation, before the effect.
local budget = new_effects()
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "one", confirm = true }, send_ctx(profile, budget, "B1")).ok == true, "the first send consumes the budget")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "two", confirm = true }, send_ctx(profile, budget, "B2")).error == "sends_per_run_exceeded", "the per-run limit is enforced by the reservation")

-- Persistence failure after a verified send is not success.
local failConfirm = new_effects()
failConfirm.fail_confirm = true
local notConfirmed = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, failConfirm, "F1"))
check(notConfirmed.error ~= nil and notConfirmed.error:find("send_not_confirmed") ~= nil, "a verified send whose record fails is not success")
check(failConfirm.find("F1").state == "pending", "the reservation remains pending after a failed confirmation")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, failConfirm, "F1")).error == "ambiguous_prior_send", "a failed confirmation is never replayed")

-- An unknown outcome after a possible effect is recorded and never retried.
local unknownStore = new_effects()
local dispatched = function(request)
  return { ok = false, sent = false, verified = false, error = "not_verified", dispatch = "ok",
    chat = { id = request.conversation_id }, body = request.body }
end
local unknownResult = whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, unknownStore, "U1", dispatched))
check(unknownResult.error ~= nil and unknownResult.error:find("outcome unknown") ~= nil, "a dispatch that cannot be verified is an unknown outcome")
check(unknownStore.find("U1").state == "unknown", "an unknown outcome is recorded durably")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, unknownStore, "U1")).error == "ambiguous_prior_send", "an unknown outcome is never replayed")

-- A refusal before dispatch proves no effect and releases the reservation.
local refusedStore = new_effects()
local refused = function(request)
  return { ok = false, error = "composer_preoccupied", chat = { id = request.conversation_id } }
end
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, refusedStore, "R1", refused)).error == "composer_preoccupied", "a route refusal is surfaced")
check(refusedStore.find("R1") == nil, "a proven no-effect refusal releases the reservation")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, send_ctx(profile, refusedStore, "R1")).ok == true, "a released reservation can send later")

-- Missing durable capabilities are refusals, not unlimited.
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes", confirm = true }, { profile = profile, event = event, effects = { record = function() return true end } }).error == "effect_store_unbound", "a store without reserve+confirm is refused")

-- The event cannot supply a route or a script: extra fields are dropped.
local injected = whatsapp.trusted_event({ conversation_id = "x", message_id = "y", reply_script = "/evil", send_path = "store", browser_endpoint = "ws://evil" })
check(injected.reply_script == nil and injected.send_path == nil and injected.browser_endpoint == nil, "an event cannot inject a route or capability")

-- Body and confirm bounds.
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "yes" }, send_ctx(profile, new_effects(), "C1")).error == "confirm_required", "confirm is required")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = string.rep("x", 101), confirm = true }, send_ctx(profile, new_effects(), "C2")).error == "body_too_long", "the body bound is enforced")

-- Shell success is not send success: the operation wrapper and its stdout are both checked.
check(whatsapp.decode_exec('{"code":0,"stdout":"{\\"ok\\":true}"}') ~= nil, "a zero exit with JSON stdout decodes")
check(whatsapp.decode_exec('{"code":1,"stdout":"{\\"ok\\":true}"}') == nil, "a non-zero exit is refused")
check(whatsapp.decode_exec('{"code":0,"stdout":"not json"}') == nil, "non-JSON stdout is refused")

-- The send is only real when the app's store confirms the exact recipient, body and message id.
check(whatsapp.verify_send_result(verified_result("a", "b"), "a", "b") == nil, "a fully verified result passes")
check(whatsapp.verify_send_result(verified_result("a", "b"), "other", "b") == "send_recipient_mismatch", "a different recipient is refused")
check(whatsapp.verify_send_result(verified_result("a", "b"), "a", "different") == "send_body_mismatch", "a different body is refused")
check(whatsapp.verify_send_result({ ok = true, sent = true, verified = true, chat = { id = "a" }, body = "b", message = {} }, "a", "b") == "send_message_id_missing", "a missing message id is refused")

-- A profile that lost schema_version in normalization is still accepted; a wrong one is not.
check(whatsapp.validate_profile({ id = "x", allowed_tools = {}, resources = {} }) ~= nil, "a normalized profile without schema_version is accepted")
check(whatsapp.validate_profile({ schema_version = 2, id = "x", allowed_tools = {}, resources = {} }) == nil, "a wrong schema_version is refused")
check(whatsapp.dispatch(memory, "whatsapp_decide", { decision = "reply" }, { profile = { id = "x", allowed_tools = {} }, event = event }).error == "profile_resources_required", "a profile missing resources is refused")

-- Capabilities are separate: `resources.actions` gates read and send independently.
local readOnly = base_profile()
readOnly.resources.actions = { "read" }
readOnly.resources.send_approved = true
readOnly.resources.send_path = "store"
readOnly.resources.store_send_script = "C:/approved/store-send.mjs"
check(whatsapp.dispatch(memory, "whatsapp_read", {}, { profile = readOnly, event = event, effects = new_effects() }).count == 1, "read is allowed when actions names read")
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(readOnly, new_effects(), "A1")).error == "action_not_in_profile", "read does not imply send")
local sendOnly = base_profile()
sendOnly.resources.actions = { "send" }
check(whatsapp.dispatch(memory, "whatsapp_read", {}, { profile = sendOnly, event = event, effects = new_effects() }).error == "action_not_in_profile", "send does not imply read")

-- The route must prove the locally bound account and browser endpoint; an unproven or mismatched
-- identity fails closed, so a raw script that ignores the binding cannot be trusted.
local identity = base_profile()
identity.resources.send_approved = true
identity.resources.send_path = "store"
identity.resources.store_send_script = "C:/approved/store-send.mjs"
local wrongAccount = function(request)
  local result = verified_result(request.conversation_id, request.body)
  result.account = "5511000000000"
  return result
end
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(identity, new_effects(), "ID1", wrongAccount)).error == "send_account_mismatch", "a different logged-in account is refused")
local noAccount = function(request)
  local result = verified_result(request.conversation_id, request.body)
  result.account = nil
  return result
end
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(identity, new_effects(), "ID2", noAccount)).error == "send_account_unproven", "an unproven account is refused")
local wrongEndpoint = function(request)
  local result = verified_result(request.conversation_id, request.body)
  result.browser_endpoint = "ws://127.0.0.1:9222/devtools/page/OTHER"
  return result
end
check(whatsapp.dispatch(memory, "whatsapp_send", { body = "x", confirm = true }, send_ctx(identity, new_effects(), "ID3", wrongEndpoint)).error == "send_endpoint_mismatch", "a different browser endpoint is refused")
local idFlags = whatsapp.route_identity_flags(identity)
check(#idFlags == 2 and idFlags[1][1] == "--expect-account" and idFlags[2][1] == "--expect-browser-endpoint", "identity flags come from the profile binding")
check(whatsapp.account_matches("5511999999999", "5511999999999@s.whatsapp.net"), "account match normalizes the jid suffix")
check(not whatsapp.account_matches("5511999999999", "5511999999998"), "a different number does not match")

print("whatsapp scoped checks " .. checks)
print("whatsapp scoped ok")
