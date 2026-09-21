-- Scoped WhatsApp responder tools.
--
-- This module is what a `whatsapp-responder` subagent run may reach. It is deliberately *not* a general
-- shell: the run gets bounded conversation context, a durable decision, and a verified send - nothing
-- that can edit files, run commands or deploy. The restrictions are structural, not sentences in a
-- prompt.
--
-- Trusted context. Everything the tools need beyond the profile arrives on `ctx`, never from the event
-- body and never from the model's arguments:
--
--   ctx.profile   the local, approved profile (or ctx.profile_path / the default file)
--   ctx.event     ONLY the identity the runtime resolved from the ledger: {conversation_id, message_id}
--   ctx.effects   a durable effect store: { find(message_id) -> record|nil, record(record) -> ok }
--   ctx.sends     the persistent per-child counter: { count = n }
--   ctx.send      (tests/injection only) the route implementation; production leaves it nil
--
-- A raw event may carry other fields; they are ignored. In particular an event can never supply
-- `reply_script`, `store_send_script`, a browser endpoint or a capability - only identity. An event can
-- narrow what the run does; it can never widen it.
--
-- The profile is a *local, approved* config (`<config>/subagent-profiles/whatsapp-responder.json`). Its
-- scope may permit several direct conversations, but a tool call may only act on the one the trusted
-- event names, and only after a ledger check proves the message belongs to it.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}
M.PROFILE_ID = "whatsapp-responder"
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
  return profile.resources.allowed_conversation == conversation_id
end

local function effect_store(ctx)
  local effects = ctx and ctx.effects
  if type(effects) ~= "table" or type(effects.find) ~= "function" or type(effects.record) ~= "function" then
    return nil
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
-- own store. A keystroke's reply is not evidence; neither is a shell exit code.
function M.verify_send_result(result, conversation_id, body)
  if type(result) ~= "table" then return "send_not_verified" end
  if result.ok ~= true or result.sent ~= true or result.verified ~= true then return "send_not_verified" end
  local chat = result.chat
  if type(chat) ~= "table" or chat.id ~= conversation_id then return "send_recipient_mismatch" end
  if result.body ~= body then return "send_body_mismatch" end
  if type(result.message) ~= "table" or type(result.message.id) ~= "string" or result.message.id == "" then
    return "send_message_id_missing"
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
    schema("whatsapp_conversation",
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
  if not in_scope(profile, event.conversation_id) then
    return fail("conversation_not_in_profile")
  end
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
  return { conversation_id = event.conversation_id, messages = messages, count = #(messages or {}) }
end

local function decide_tool(args, profile, ctx)
  local event = M.trusted_event(ctx)
  if event.message_id == "" then return fail("event_context_required") end
  if args.decision ~= "reply" and args.decision ~= "no_reply" then return fail("invalid_decision") end
  local effects = effect_store(ctx)
  if not effects then return fail("effect_store_unbound", { note = "the runtime must pass a durable effect store" }) end
  local record = {
    kind = "decision",
    message_id = event.message_id,
    conversation_id = event.conversation_id,
    decision = args.decision,
    reason = tostring(args.reason or ""),
    at = host.now and host.now() or nil,
  }
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
-- script: that string used to bypass the unread guard. `store` needs a store send script; `ui` needs an
-- accepted unread consequence, which notes-to-self do not have (opening your own notes clears nothing).
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

local function send_tool(args, profile, ctx)
  local event = M.trusted_event(ctx)
  if event.conversation_id == "" or event.message_id == "" then return fail("event_context_required") end
  if not in_scope(profile, event.conversation_id) then return fail("conversation_not_in_profile") end
  if args.confirm ~= true then return fail("confirm_required") end
  if profile.resources.send_approved ~= true then
    return fail("send_not_approved", {
      note = "sending is approved by the local profile binding, never by a decision or an event",
    })
  end

  -- The per-child counter is trusted persistent context. A missing counter is not "unlimited": it is a
  -- refusal.
  if type(ctx.sends) ~= "table" then
    return fail("send_counter_unbound", { note = "the runtime must pass the persistent child counter" })
  end

  -- Idempotency comes before the per-run limit: a repeated delivery of the same message is not a second
  -- send, and must not spend the allowance the first one already spent.
  local effects = effect_store(ctx)
  if not effects then return fail("effect_store_unbound", { note = "the runtime must pass a durable effect store" }) end
  local prior = effects.find(event.message_id)
  if prior and prior.kind == "send" and prior.verified == true then
    return { already_sent = true, message = prior.message, conversation_id = event.conversation_id }
  end

  local limit = tonumber(profile.limits and profile.limits.sends_per_run) or 1
  if (tonumber(ctx.sends.count) or 0) >= limit then return fail("sends_per_run_exceeded", { limit = limit }) end

  local body = tostring(args.body or "")
  if body == "" then return fail("body_required") end
  local maximum = tonumber(profile.limits and profile.limits.body_bytes) or 4096
  if #body > maximum then return fail("body_too_long", { maximum = maximum }) end

  local route, why = resolve_route(profile, event.conversation_id)
  if not route then
    local extra = { route = profile.resources.send_path }
    if why == "unread_would_be_broken" then
      extra.options = {
        "bind resources.store_send_script to an approved store send path (opens nothing, marks nothing read)",
        "set resources.allow_mark_read=true to accept the marker being cleared",
        "reply only to the bound self destination, where opening clears nothing",
      }
    end
    return fail(why, extra)
  end

  local result
  if type(ctx.send) == "function" then
    result = ctx.send({ conversation_id = event.conversation_id, body = body, message_id = event.message_id, route = route.name, profile = profile })
  else
    if type(route.script) ~= "string" or route.script == "" then
      return fail("send_route_unbound", { route = route.name })
    end
    local node = (host.getenv and host.getenv("WA_NODE")) or "node"
    -- The body goes through a file, never the shell command line: a message is untrusted text.
    local body_file = paths.temp() .. "/wa-whatsapp-body-" .. tostring(host.uuid()) .. ".txt"
    if not (host.write_file and host.write_file(body_file, body)) then return fail("body_not_written") end
    local command = table.concat({
      quote(node), quote(route.script),
      "--chat", quote(event.conversation_id),
      "--body-file", quote(body_file),
      "--send",
    }, " ")
    local ok, raw = pcall(host.exec, command, "")
    if host.exec then pcall(host.exec, "rm -f " .. quote(body_file), "") end
    if not ok then return fail("send_route_failed", { detail = tostring(raw):sub(1, 200) }) end
    local decoded, decode_error = M.decode_exec(raw)
    if not decoded then return fail(decode_error, { detail = tostring(raw):sub(1, 200) }) end
    result = decoded
  end

  local verify_error = M.verify_send_result(result, event.conversation_id, body)
  if verify_error then return fail(verify_error, { observed = result }) end

  effects.record({
    kind = "send",
    message_id = event.message_id,
    conversation_id = event.conversation_id,
    verified = true,
    message = result.message,
    at = host.now and host.now() or nil,
  })
  ctx.sends.count = (tonumber(ctx.sends.count) or 0) + 1
  return result
end

function M.dispatch(memory, name, args, ctx)
  args = args or {}
  ctx = ctx or {}
  local profile, why = M.resolve(ctx)
  if not profile then return fail(why or "profile_unresolved") end
  if not contains(profile.allowed_tools, name) then
    return fail("tool_not_in_profile", { tool = name })
  end
  if name == "whatsapp_conversation" then return conversation_tool(memory, args, profile, ctx) end
  if name == "whatsapp_decide" then return decide_tool(args, profile, ctx) end
  if name == "whatsapp_send" then return send_tool(args, profile, ctx) end
  return fail("unknown_whatsapp_tool", { tool = name })
end

return M
