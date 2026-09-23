-- Scoped WhatsApp responder tools.
--
-- This module is what a `whatsapp-responder` subagent run may reach. It is deliberately *not* a general
-- shell: the run gets bounded conversation context, a durable decision, and a verified send - nothing
-- that can edit files, run commands or deploy. The restrictions are structural, not sentences in a
-- prompt.
--
-- A reply always says what it is. The send tool prefixes the body with `REPLY_PREFIX` (an icon, the
-- word `Copiloto` in WhatsApp's italic markup, and a newline) before
-- it is reserved, sent or verified, so a message written by a model and sent as the operator cannot be
-- mistaken for the operator's own words - and cannot be sent unmarked by forgetting an instruction, by a
-- second route, or by a caller that hands a bare body to the tool. The wording lives here, as one
-- constant: a profile knob would be a second way for the marker to be absent.
--
-- Trusted context. Everything the tools need beyond the profile arrives on `ctx`, never from the event
-- body and never from the model's arguments:
--
--   ctx.subagent  the runtime's resolved snapshot: {id, allowed_tools, resources, limits, ...}
--   ctx.profile   (tests/direct callers) a local approved profile
--   ctx.event     ONLY the identity the runtime resolved from the ledger: {conversation_id, message_id}
--   ctx.effects   the durable effect store (reserve/confirm/record, see effect_store below)
--   ctx.send      (tests/injection only) the route implementation; production leaves it nil
--
-- A raw event may carry other fields; they are ignored. In particular an event can never supply
-- `reply_script`, `store_send_script`, a browser endpoint or a capability - only identity. An event can
-- narrow what the run does; it can never widen it.
--
-- The profile is a *local, approved* config (`<config>/subagent-profiles/whatsapp-responder.json`). Its
-- scope may permit several direct conversations (`resources.conversation` or
-- `resources.allowed_conversations`), but a tool call may only act on the one the trusted event names,
-- and only after a ledger check proves the message belongs to it. `resources.actions` gates the two
-- capabilities separately: `read` does not imply `send`.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}
M.PROFILE_ID = "whatsapp-responder"
-- Every reply carries this at the very beginning, so a person on the other side knows a copilot wrote it.
-- It is applied in the send tool, before the body is reserved and verified, which is what makes it a
-- guarantee rather than a hope. Keep it short: it is part of the message.
M.REPLY_ICON = "🤖"
-- Three parts, in order: an icon, the word in WhatsApp's *italic* markup (`_..._`), and a newline - so
-- the marker reads as a header above the message rather than as the first words of the sentence. The
-- icon is its own constant only so that changing it is one line; the prefix stays one constant, because
-- a profile knob would be a second way for the marker to be absent.
M.REPLY_PREFIX = M.REPLY_ICON .. " _Copiloto_\n"
M.SCHEMA_VERSION = 1

local function fail(code, extra)
  local result = { error = code }
  if type(extra) == "table" then
    for key, value in pairs(extra) do result[key] = value end
  end
  return result
end

local function contains(list, value)
  if type(list) ~= "table" then return false end
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

function M.profile_path()
  local explicit = host.getenv and host.getenv("WA_WHATSAPP_PROFILE") or nil
  if explicit and explicit ~= "" then return explicit end
  return paths.config() .. "/subagent-profiles/" .. M.PROFILE_ID .. ".json"
end

-- Validate the parts the tools depend on. A profile that is missing them is refused whole, rather than
-- silently treated as "no restrictions". `schema_version` is accepted when absent because a runtime
-- normalizer may drop it; when present it must match.
function M.validate_profile(profile)
  if type(profile) ~= "table" then return nil, "profile_not_a_table" end
  if profile.schema_version ~= nil and tonumber(profile.schema_version) ~= M.SCHEMA_VERSION then
    return nil, "unsupported_profile_schema_version"
  end
  if type(profile.id) ~= "string" or profile.id == "" then return nil, "profile_id_required" end
  if type(profile.allowed_tools) ~= "table" then return nil, "profile_allowed_tools_required" end
  if type(profile.resources) ~= "table" then return nil, "profile_resources_required" end
  if profile.limits ~= nil and type(profile.limits) ~= "table" then return nil, "profile_limits_invalid" end
  return profile, nil
end

function M.load(path)
  path = path or M.profile_path()
  local raw = host.read_file and host.read_file(path)
  if not raw or raw == "" then return nil, "profile_unreadable" end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil, "profile_not_json" end
  return M.validate_profile(decoded)
end

function M.resolve(ctx)
  ctx = ctx or {}
  if type(ctx.profile) == "table" then return M.validate_profile(ctx.profile) end
  -- The runtime passes the resolved snapshot on `ctx.subagent`; its `resources` and every declared limit
  -- survive resolution. Accept it as the profile view so the tool never re-reads a file a child could
  -- have changed.
  if type(ctx.subagent) == "table" then
    local snapshot = ctx.subagent
    local allowed = {}
    if type(snapshot.allowed_tools) == "table" then
      for _, name in ipairs(snapshot.allowed_tools) do allowed[#allowed + 1] = name end
    elseif type(snapshot.allowed) == "table" then
      for name in pairs(snapshot.allowed) do allowed[#allowed + 1] = name end
    end
    return M.validate_profile({
      schema_version = M.SCHEMA_VERSION,
      id = tostring(snapshot.id or M.PROFILE_ID),
      allowed_tools = allowed,
      resources = snapshot.resources or {},
      limits = snapshot.limits or {},
    })
  end
  return M.load(ctx.profile_path)
end

-- The only fields an event may contribute. Everything else is ignored, so an event cannot smuggle a
-- route, a script or a capability into the tools.
function M.trusted_event(ctx)
  local event = (ctx and type(ctx.event) == "table") and ctx.event or {}
  return {
    conversation_id = type(event.conversation_id) == "string" and event.conversation_id or "",
    message_id = type(event.message_id) == "string" and event.message_id or "",
  }
end

local function in_scope(profile, conversation_id)
  local list = profile.resources.allowed_conversations
  if type(list) == "table" then
    for _, value in ipairs(list) do
      if value == conversation_id then return true end
    end
  end
  if type(profile.resources.conversation) == "string" and profile.resources.conversation == conversation_id then
    return true
  end
  return profile.resources.allowed_conversation == conversation_id
end

-- A profile may separate its capabilities: `resources.actions` gates read and send independently, so a
-- child that may read a conversation is not thereby allowed to send. Absent, the capability is allowed
-- (the send gates and approval still apply).
local function action_allowed(profile, action)
  local actions = profile.resources.actions
  if type(actions) ~= "table" then return true end
  for _, value in ipairs(actions) do
    if value == action then return true end
  end
  return false
end

-- The durable effect store. Sends need `reserve` + `confirm`; decisions need `record`. A missing
-- capability is a refusal, never an implicit "unlimited". The contract the runtime adapter must satisfy:
--
--   effects.reserve({message_id, conversation_id, body, limit}) -> {status, record?}
--     status one of: "reserved" (a new reservation was created atomically and the caller may send),
--     "already_sent" (a prior *confirmed* send exists; do not send), "ambiguous" (a prior reservation
--     exists without a confirmed send; reconcile or refuse), "budget_exceeded".
--     The reservation must be durable BEFORE the send and atomically consume the per-run budget.
--   effects.confirm({message_id, conversation_id, message}) -> boolean
--     Persist a confirmed, store-verified send. False means the effect was not recorded.
--   effects.record(decision_record) -> boolean
--     Persist a decision. MUST NOT overwrite a pending/sent send record for the same message id, so
--     `reserve` stays truthful.
--   effects.reconcile({message_id, conversation_id, body}) -> {status="sent"|"not_sent"|"unknown", record?}
--     Optional, read-only: reconcile a prior ambiguous reservation against the app's store. Never sends.
--   effects.release({message_id}) -> boolean
--     Optional: clear a reservation ONLY when the route proved no effect happened.
--   effects.unknown({message_id, detail}) -> boolean
--     Optional: record an ambiguous outcome (the reservation may have had an effect) so it is not replayed.
local function effect_store(ctx, need)
  local effects = ctx and ctx.effects
  if type(effects) ~= "table" then return nil end
  for _, name in ipairs(need) do
    if type(effects[name]) ~= "function" then return nil end
  end
  return effects
end

-- A host.exec result is an *operation wrapper*: `{code, stdout, ...}`. Shell success is not send
-- success - the wrapper's exit code must be zero AND its stdout must decode to a JSON object. Exposed so
-- the refusal can be tested without a subprocess.
function M.decode_exec(raw)
  local ok, wrapper = pcall(json.decode, raw or "")
  if not ok or type(wrapper) ~= "table" then return nil, "send_route_failed" end
  if (tonumber(wrapper.code) or 1) ~= 0 then return nil, "send_route_failed" end
  local decoded_ok, result = pcall(json.decode, wrapper.stdout or "")
  if not decoded_ok or type(result) ~= "table" then return nil, "send_route_failed" end
  return result, nil
end

-- The send is only real when the tool verified the exact recipient, body and message id in the app's
-- own store. A keystroke's reply is not evidence; neither is a shell exit code. When the profile binds an
-- account or a browser endpoint, the *route* must report the identity it actually used and it must match
-- the local binding; an unproven or mismatched identity fails closed.
-- A phone/PN identity is a bare/formatted phone, or a jid ending `@c.us` / `@s.whatsapp.net`. Anything
-- else (notably a `@lid`, or a label with letters) is opaque and compares exactly. Stripping *all*
-- non-digits made `operator1` equal `other1`, and a PN equal a LID with the same digits.
local function phone_digits(value)
  local text = tostring(value or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local at = text:find("@", 1, true)
  if at then
    local domain = text:sub(at + 1):lower()
    if domain ~= "c.us" and domain ~= "s.whatsapp.net" then return nil end
    local digits = text:sub(1, at - 1):gsub("[^0-9]", "")
    if digits == "" then return nil end
    return digits
  end
  if text:match("[A-Za-z]") then return nil end
  local digits = text:gsub("[^0-9]", "")
  if #digits < 7 then return nil end
  return digits
end

function M.account_matches(expected, actual)
  local want, got = phone_digits(expected), phone_digits(actual)
  if want and got then return want == got end
  return tostring(expected) == tostring(actual)
end

function M.verify_send_result(result, conversation_id, body, expected)
  if type(result) ~= "table" then return "send_not_verified" end
  if result.ok ~= true or result.sent ~= true or result.verified ~= true then return "send_not_verified" end
  local chat = result.chat
  if type(chat) ~= "table" or chat.id ~= conversation_id then return "send_recipient_mismatch" end
  if result.body ~= body then return "send_body_mismatch" end
  if type(result.message) ~= "table" or type(result.message.id) ~= "string" or result.message.id == "" then
    return "send_message_id_missing"
  end
  expected = expected or {}
  if type(expected.account) == "string" and expected.account ~= "" then
    local actual = result.account or result.own_id
    if type(actual) ~= "string" or actual == "" then return "send_account_unproven" end
    if not M.account_matches(expected.account, actual) then return "send_account_mismatch" end
  end
  if type(expected.browser_endpoint) == "string" and expected.browser_endpoint ~= "" then
    local actual = result.browser_endpoint or result.endpoint
    if type(actual) ~= "string" or actual == "" then return "send_endpoint_unproven" end
    if actual ~= expected.browser_endpoint then return "send_endpoint_mismatch" end
  end
  return nil
end

-- ---- tool schemas -----------------------------------------------------------
local function schema(name, description, properties, required)
  local parameters = { type = "object" }
  if properties and next(properties) ~= nil then parameters.properties = properties end
  if required and #required > 0 then parameters.required = required end
  return { type = "function", ["function"] = { name = name, description = description, parameters = parameters } }
end

function M.schemas()
  return {
    schema("whatsapp_read",
      "Read the recent messages of the incoming conversation for this run, from the ledger. Bounded, read-only; never opens the app and never marks anything read. The conversation is fixed by the run's trusted event, not by an argument.",
      { limit = { type = "integer", minimum = 1, maximum = 200 } }),
    schema("whatsapp_decide",
      "Record the decision for this message durably: reply or no_reply, with a reason. No external effect and no send approval.",
      { decision = { type = "string", enum = { "reply", "no_reply" } }, reason = { type = "string" } },
      { "decision" }),
    schema("whatsapp_send",
      "Send one verified reply in the run's conversation. Refused unless the local profile approves sending, the conversation is in the approved scope, the route is real, and the send is verified by the app's store. Idempotent per message id; never retries an ambiguous send.",
      { body = { type = "string" }, confirm = { type = "boolean" } },
      { "body", "confirm" }),
  }
end

-- ---- dispatch ---------------------------------------------------------------

local function conversation_tool(memory, args, profile, ctx)
  local event = M.trusted_event(ctx)
  if event.conversation_id == "" then return fail("event_context_required") end
  -- The conversation is the trusted event's, never an argument: a model cannot steer a read to another
  -- chat, and a foreign argument is refused rather than ignored so the attempt is visible.
  if type(args.conversation_id) == "string" and args.conversation_id ~= "" and args.conversation_id ~= event.conversation_id then
    return fail("event_conversation_immutable", { bound = event.conversation_id })
  end
  if not in_scope(profile, event.conversation_id) then
    return fail("conversation_not_in_profile")
  end
  if not action_allowed(profile, "read") then return fail("action_not_in_profile", { action = "read" }) end
  local limit = tonumber(args.limit) or tonumber(profile.limits and profile.limits.context_messages) or 20
  limit = math.max(1, math.min(200, limit))
  local messages = memory.conversation(event.conversation_id, limit)
  -- The ledger read must not stray outside the bound conversation. A row that says otherwise is a
  -- scope mismatch, not context.
  for _, message in ipairs(messages or {}) do
    if message.conversation_id and message.conversation_id ~= event.conversation_id then
      return fail("ledger_scope_mismatch")
    end
  end
  -- The child must be able to name the conversation it is answering. It is given the ledger's own
  -- title and kind for exactly that: a label inferred from message bodies is how a group was
  -- reported as "futebol/bet" when its title was "A Casa Lar | 🏠". A missing record (or a memory
  -- implementation without the accessor) yields empty strings rather than a guess.
  local record = nil
  if type(memory.conversation_record) == "function" then
    record = memory.conversation_record(event.conversation_id)
  end
  return {
    conversation_id = event.conversation_id,
    title = tostring(record and record.title or ""),
    kind = tostring(record and record.kind or ""),
    messages = messages,
    count = #(messages or {}),
  }
end

-- The durable reason is a decision summary the operator reads, not the model's reasoning. A reason that
-- runs long is truncated here, visibly, so a chain of thought - or a restatement of the conversation -
-- cannot quietly become the record: a leaked justification is a second copy of the chat in the ledger.
-- The bound is a profile limit, so an operator can raise it; the marker is what keeps it honest.
local function bounded_reason(raw, profile)
  local text = tostring(raw or "")
  local maximum = tonumber(profile.limits and profile.limits.reason_bytes) or 320
  if maximum > 0 and #text > maximum then
    return text:sub(1, maximum) .. " [truncated at the reason bound]"
  end
  return text
end

local function decide_tool(args, profile, ctx)
  local event = M.trusted_event(ctx)
  if event.message_id == "" then return fail("event_context_required") end
  if args.decision ~= "reply" and args.decision ~= "no_reply" then return fail("invalid_decision") end
  local effects = effect_store(ctx, { "record" })
  if not effects then return fail("effect_store_unbound", { note = "the runtime must pass a durable effect store" }) end
  local record = {
    kind = "decision",
    message_id = event.message_id,
    conversation_id = event.conversation_id,
    decision = args.decision,
    reason = bounded_reason(args.reason, profile),
    at = host.now and host.now() or nil,
  }
  -- A decision is durable, and the adapter must store it without clobbering a send reservation.
  if not effects.record(record) then return fail("decision_not_recorded") end
  return {
    decision = args.decision,
    reason = record.reason,
    recorded = true,
    -- Reported so the run can see whether sending is even possible; it is not a grant.
    send_approved = profile.resources.send_approved == true,
  }
end

-- Resolve the real route before anything is sent. A profile cannot declare `store` and then run the UI
-- script: that string used to bypass the unread guard. `store` needs a store send script; `ui` always
-- opens the chat, so a *non-self* send needs the explicit unread approval, while a self send is allowed
-- here and the raw script independently refuses it when its unread is nonzero or unproven (a
-- manually-marked-unread notes-to-self has unread too).
local function resolve_route(profile, conversation_id)
  local route = profile.resources.send_path
  if route == nil or route == "" then route = "ui" end
  if route == "store" then
    local script = profile.resources.store_send_script
    if type(script) ~= "string" or script == "" then return nil, "store_route_unbound" end
    return { name = "store", script = script }, nil
  end
  if route ~= "ui" then return nil, "unsupported_send_route" end
  local self_destination = profile.resources.self_destination
  local self_only = type(self_destination) == "string" and self_destination ~= "" and self_destination == conversation_id
  if not self_only and profile.resources.allow_mark_read ~= true then
    return nil, "unread_would_be_broken"
  end
  local script = profile.resources.reply_script
  return { name = "ui", script = script, self_only = self_only }, nil
end

-- The raw-script flags are derived from the profile binding only, never from an event or an argument. A
-- non-self UI send needs the explicit `--allow-mark-read` approval; notes-to-self and the store route do
-- not take it. Exposed so the pass-through is testable without a subprocess.
function M.route_flags(profile, route)
  local flags = {}
  -- The approved flag is passed whenever the operator approved it, self or not; the raw script then
  -- enforces the unread guard for the exact target.
  if route.name == "ui" and profile.resources.allow_mark_read == true then
    flags[#flags + 1] = "--allow-mark-read"
  end
  return flags
end

-- Identity flags, from the local profile binding only. The route must prove it is acting as the bound
-- account, against the bound browser endpoint; refusing on a mismatch is the point.
function M.route_identity_flags(profile)
  local flags = {}
  local account = profile.resources.account
  if type(account) == "string" and account ~= "" then
    flags[#flags + 1] = { "--expect-account", account }
  end
  local endpoint = profile.resources.browser_endpoint
  if type(endpoint) == "string" and endpoint ~= "" then
    flags[#flags + 1] = { "--expect-browser-endpoint", endpoint }
  end
  return flags
end

local function send_tool(args, profile, ctx)
  local event = M.trusted_event(ctx)
  if event.conversation_id == "" or event.message_id == "" then return fail("event_context_required") end
  if type(args.conversation_id) == "string" and args.conversation_id ~= "" and args.conversation_id ~= event.conversation_id then
    return fail("event_conversation_immutable", { bound = event.conversation_id })
  end
  if not in_scope(profile, event.conversation_id) then return fail("conversation_not_in_profile") end
  if not action_allowed(profile, "send") then return fail("action_not_in_profile", { action = "send" }) end
  if args.confirm ~= true then return fail("confirm_required") end
  if profile.resources.send_approved ~= true then
    return fail("send_not_approved", {
      note = "sending is approved by the local profile binding, never by a decision or an event",
    })
  end
  local body = tostring(args.body or "")
  if body == "" then return fail("body_required") end
  -- Announce the copilot, here and not in a prompt: this is the one place every send passes through. A body
  -- that already carries the prefix is left alone, so a run that prefixes its own text (or a retry of the
  -- same body) is not doubled - two markers, one above the other, would be the only thing sillier than a
  -- reply that does not say what it is.
  local prefix = tostring(M.REPLY_PREFIX or "")
  if prefix ~= "" and body:sub(1, #prefix) ~= prefix then body = prefix .. body end
  local maximum = tonumber(profile.limits and profile.limits.body_bytes) or 4096
  if #body > maximum then return fail("body_too_long", { maximum = maximum }) end

  local route, why = resolve_route(profile, event.conversation_id)
  if not route then
    local extra = { route = profile.resources.send_path }
    if why == "unread_would_be_broken" then
      extra.options = {
        "bind resources.store_send_script to an operator-approved store send path (opens nothing, marks nothing read)",
        "set resources.allow_mark_read=true so the approved flag is passed to the raw UI script",
      }
    end
    return fail(why, extra)
  end

  local effects = effect_store(ctx, { "reserve", "confirm" })
  if not effects then
    return fail("effect_store_unbound", { note = "the runtime must pass a durable effect store with reserve+confirm" })
  end

  -- Atomically reserve BEFORE any send, and consume the per-run budget in the reservation. A crash
  -- between send and confirm then leaves a durable pending record rather than a replayable message.
  local limit = tonumber(profile.limits and profile.limits.sends_per_run) or 1
  local reservation = effects.reserve({
    message_id = event.message_id,
    conversation_id = event.conversation_id,
    body = body,
    limit = limit,
  })
  if type(reservation) ~= "table" then return fail("reservation_failed") end
  local status = reservation.status
  if status == "already_sent" then
    return { already_sent = true, message = reservation.record and reservation.record.message or nil,
      conversation_id = event.conversation_id }
  end
  if status == "ambiguous" then
    -- A prior reservation may have had an effect. Reconcile read-only if the adapter can; NEVER send.
    local reconciled = nil
    if type(effects.reconcile) == "function" then
      reconciled = effects.reconcile({ message_id = event.message_id, conversation_id = event.conversation_id, body = body })
    end
    if type(reconciled) == "table" and reconciled.status == "sent" then
      return { already_sent = true, reconciled = true,
        message = reconciled.record and reconciled.record.message or nil, conversation_id = event.conversation_id }
    end
    return fail("ambiguous_prior_send", {
      reconciliation = type(reconciled) == "table" and reconciled.status or "unavailable",
      note = "a prior reservation for this message may have sent; reconcile before any retry",
    })
  end
  if status == "budget_exceeded" then return fail("sends_per_run_exceeded", { limit = limit }) end
  if status ~= "reserved" then return fail("reservation_refused", { status = tostring(status) }) end

  local result
  if type(ctx.send) == "function" then
    result = ctx.send({ conversation_id = event.conversation_id, body = body, message_id = event.message_id, route = route.name, profile = profile })
  else
    if type(route.script) ~= "string" or route.script == "" then
      if type(effects.release) == "function" then pcall(effects.release, { message_id = event.message_id }) end
      return fail("send_route_unbound", { route = route.name })
    end
    local node = (host.getenv and host.getenv("WA_NODE")) or "node"
    -- The body goes through a file, never the shell command line: a message is untrusted text.
    local body_file = paths.temp() .. "/wa-whatsapp-body-" .. tostring(host.uuid()) .. ".txt"
    if not (host.write_file and host.write_file(body_file, body)) then
      if type(effects.release) == "function" then pcall(effects.release, { message_id = event.message_id }) end
      return fail("body_not_written")
    end
    local script_args = {
      quote(node), quote(route.script),
      "--chat", quote(event.conversation_id),
      "--body-file", quote(body_file),
      "--send",
    }
    -- The approved flag comes from the profile binding only, never from an event or an argument: the raw
    -- script refuses a non-self send without it.
    for _, flag in ipairs(M.route_flags(profile, route)) do
      script_args[#script_args + 1] = flag
    end
    for _, pair in ipairs(M.route_identity_flags(profile)) do
      script_args[#script_args + 1] = pair[1]
      script_args[#script_args + 1] = quote(pair[2])
    end
    local command = table.concat(script_args, " ")
    local ok, raw = pcall(host.exec, command, "")
    if host.exec then pcall(host.exec, "rm -f " .. quote(body_file), "") end
    if not ok then return fail("send_route_failed", { detail = tostring(raw):sub(1, 200) }) end
    local decoded, decode_error = M.decode_exec(raw)
    if not decoded then return fail(decode_error, { detail = tostring(raw):sub(1, 200) }) end
    result = decoded
  end

  local verify_error = M.verify_send_result(result, event.conversation_id, body,
    { account = profile.resources.account, browser_endpoint = profile.resources.browser_endpoint })
  if verify_error then
    -- No effect is proven only when the route refused before dispatching. Otherwise the send may have
    -- happened, so the outcome is unknown and the reservation stays (never replayed).
    local refused = type(result) == "table" and result.error ~= nil and result.dispatch == nil
    if refused then
      if type(effects.release) == "function" then pcall(effects.release, { message_id = event.message_id }) end
      return fail(tostring(result.error), { observed = result })
    end
    if type(effects.unknown) == "function" then
      pcall(effects.unknown, { message_id = event.message_id, conversation_id = event.conversation_id, detail = verify_error })
    end
    -- An identity violation is a definite refusal the child should see by name; a missing verification
    -- is an ambiguous outcome and is reported as unknown.
    local identity_error = verify_error == "send_account_mismatch" or verify_error == "send_account_unproven"
      or verify_error == "send_endpoint_mismatch" or verify_error == "send_endpoint_unproven"
    if identity_error then return fail(verify_error, { observed = result }) end
    return fail("send outcome unknown: " .. verify_error, { observed = result })
  end

  -- A verified send whose durable confirmation fails is NOT success: the effect happened but the record
  -- did not, and the reservation remains so a replay is refused.
  if not effects.confirm({ message_id = event.message_id, conversation_id = event.conversation_id, message = result.message }) then
    return fail("send_not_confirmed: verified in the app but the durable effect was not recorded", { observed = result })
  end
  return result
end

function M.dispatch(memory, name, args, ctx)
  args = args or {}
  ctx = ctx or {}
  local profile, why = M.resolve(ctx)
  if not profile then return fail(why or "profile_unresolved") end
  -- `whatsapp_conversation` is the pre-rename name; the advertised schema is `whatsapp_read`.
  if name == "whatsapp_conversation" then name = "whatsapp_read" end
  if not contains(profile.allowed_tools, name) then
    return fail("tool_not_in_profile", { tool = name })
  end
  if name == "whatsapp_read" then return conversation_tool(memory, args, profile, ctx) end
  if name == "whatsapp_decide" then return decide_tool(args, profile, ctx) end
  if name == "whatsapp_send" then return send_tool(args, profile, ctx) end
  return fail("unknown_whatsapp_tool", { tool = name })
end

return M
