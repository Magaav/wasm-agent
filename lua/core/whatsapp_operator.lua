-- Operator-directed WhatsApp text on the Rust/WASI path (Phase 2 of the 10/11 decision).
--
-- docs/WHATSAPP-OPERATOR-MANAGEMENT.md is the contract, and this is the same state machine the Go
-- connector implemented (connectors/whatsapp/operator.go): prepare -> approve -> send -> status, with
-- the exact text signed BEFORE the approval binds it, a durable intent per (account, chat, text) and
-- one dispatch that is never replayed. What changes is where the message goes: the send itself is the
-- node's explicit-send outbox (`host.whatsapp_send` -> `whatsapp.outbox` -> the wa-whatsapp
-- component), and the component applies the last gate (`outbox::dispatch_refusal`): a posting hold, a
-- revoke/edit fence, or a reply source it cannot prove refuses the dispatch.
--
-- The gates, in the order a call meets them:
--   * authority: a provisioned `operator-management-<profile>.json` names the exact account,
--     generation and chats; approve presents the approval capability FILE and the other actions the
--     dispatch FILE, as the Go path did (`private_file`);
--   * scope: the chat must be one the profile names, and already an exact JID;
--   * text: <= 4096 bytes, valid UTF-8, non-empty; the `🤖 _Copiloto_` line is composed here, once,
--     before the digest, so the approved text IS the sent text;
--   * reply: the exact message must be in the index, in that chat, plain text, not our own, not
--     deleted/unsupported, and no own message may follow it (`source_snapshot`);
--   * approval: a 64-hex digest over the intent (id, chat, signed body, reply, mentions, source,
--     prepared time). approve must echo the exact fields AND the digest;
--   * freshness: an intent older than 600 s is prepared again, never sent late;
--   * one dispatch: the row becomes `dispatched` before the enqueue, and a second send returns the
--     status instead of writing a second job; an unknown outcome is `unknown` and is only inspected.
--
-- Difference from the Go path, stated so it is not mistaken for parity: mentions are the exact JIDs
-- the operator names (validated, deduplicated, at most 8); the Go connector additionally proved each
-- one against the group's observed participant list. A mention of a JID that is not in the group is
-- ignored by WhatsApp, so this cannot reach a stranger, and it is the only part of the Go gate that
-- is weaker here.
local json = dofile('lua/vendor/json.lua')

local M = { SIGNATURE = '🤖 _Copiloto_' }
local FRESH = 600
local MAX_BODY = 4096
local MAX_MENTIONS = 8
local MAX_REPLY = 128
local MAX_CHATS = 256
local ACTIONS = { prepare = true, approve = true, send = true, status = true }
local FIELDS = 'id,profile,account,generation,chat,body,reply,mentions,source,digest,state,prepared,job,message_id,reason'

local function fail(code, extra)
  local answer = extra or {}
  answer.ok = false
  answer.error = code
  return answer
end

local function decode(raw)
  local ok, value = pcall(json.decode, tostring(raw or ''))
  if not ok or type(value) ~= 'table' then return nil end
  return value
end

local function query(sql, params)
  local value = decode(host.sql_query(sql, json.encode(params or {})))
  if not value or value.error then error(value and value.error or 'operator_journal_unreadable') end
  return value
end

local function exec(sql, params)
  local value = decode(host.sql_exec(sql, json.encode(params or {})))
  if not value or value.error or value.ok ~= true then error(value and value.error or 'operator_journal_write_unverified') end
  return value
end

local ready = false
local function setup()
  if ready then return end
  exec([[CREATE TABLE IF NOT EXISTS whatsapp_operator_intents(
    id TEXT PRIMARY KEY, profile TEXT NOT NULL, account TEXT NOT NULL, generation INTEGER NOT NULL,
    chat TEXT NOT NULL, body TEXT NOT NULL, reply TEXT NOT NULL DEFAULT '', mentions TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '', digest TEXT NOT NULL, state TEXT NOT NULL, prepared INTEGER NOT NULL,
    job INTEGER, message_id TEXT, reason TEXT NOT NULL DEFAULT '')]], {})
  ready = true
end

-- ---------------------------------------------------------------- profiles and exact values

local function now()
  return math.floor(tonumber(host.now and host.now() or os.time()) or 0)
end

local function digit_run(text)
  return type(text) == 'string' and text ~= '' and text:match('^%d+$') ~= nil
end

-- The outbox's exact-JID rule, restated here because a profile is provisioned before any send exists:
-- `<digits>@s.whatsapp.net`, `<digits>@lid`, `<digits>@g.us`, or the legacy `<digits>-<digits>@g.us`.
local function chat_jid(text)
  if type(text) ~= 'string' then return false end
  text = text:gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' or #text > 129 then return false end
  if text:find('[%s%c]') then return false end
  local user, server = text:match('^(.-)@([%w%.]+)$')
  if not user or not server then return false end
  if user:find(':') then return false end
  if server == 's.whatsapp.net' or server == 'c.us' or server == 'lid' then return digit_run(user) end
  if server ~= 'g.us' then return false end
  local creator, epoch = user:match('^(%d+)%-(%d+)$')
  return digit_run(user) or (creator ~= nil and epoch ~= nil)
end

local function user_jid(text)
  if type(text) ~= 'string' or #text > 129 then return false end
  local user, server = text:match('^(.-)@([%w%.]+)$')
  if not user or not server or user:find(':') or user:find('[%s%c]') then return false end
  return (server == 's.whatsapp.net' or server == 'c.us' or server == 'lid') and digit_run(user)
end

local function operator_dir(explicit)
  local override = explicit or host.getenv('WA_WHATSAPP_OPERATOR_DIR')
  if override and override ~= '' then return override end
  local ok, home = pcall(function() return dofile('lua/core/paths.lua').home() end)
  return ok and home and (home .. '/.config/wa-whatsapp') or nil
end

-- A capability FILE, never a value in argv or a request: it must exist and be 64 lowercase hex digits,
-- which is the shape the Go connector provisioned. The file is not read as a bearer here (there is no
-- HTTP hop any more); it is the provisioning proof the operator route has always required.
local function private_file(path)
  if type(path) ~= 'string' or path == '' then return false end
  if host.path_kind(path) ~= 'file' then return false end
  local raw = host.read_file(path)
  if type(raw) ~= 'string' then return false end
  local token = raw:match('^%s*([%x]+)%s*$')
  return token ~= nil and #token == 64 and token:match('^[0-9a-f]+$') ~= nil
end

function M.profiles(explicit)
  local dir = operator_dir(explicit)
  if not dir then return {} end
  local ok, listing = pcall(function() return json.decode(host.list_dir(dir) or '') end)
  local profiles = {}
  for _, entry in ipairs(ok and type(listing) == 'table' and listing.entries or {}) do
    local name = entry.kind == 'file' and tostring(entry.name):match('^operator%-management%-([%w_%-]+)%.json$')
    if name then
      local parsed, config = pcall(json.decode, host.read_file(dir .. '/' .. entry.name) or '')
      local generation = type(config) == 'table' and tonumber(config.generation) or nil
      if parsed and type(config) == 'table' and config.kind == 'whatsapp-operator-v1'
        and chat_jid(config.account) and generation and generation >= 1 and generation % 1 == 0
        and type(config.conversations) == 'table' and #config.conversations >= 1 and #config.conversations <= MAX_CHATS then
        local chats, exact = {}, true
        for _, id in ipairs(config.conversations) do
          if chat_jid(id) then chats[#chats + 1] = id else exact = false end
        end
        if exact then
          profiles[name] = {
            file = dir .. '/' .. entry.name, account = config.account, generation = math.floor(generation),
            conversations = chats, approval_token_file = config.approval_token_file,
            dispatch_token_file = config.dispatch_token_file,
          }
        end
      end
    end
  end
  return profiles
end

-- ---------------------------------------------------------------- the values the digest binds

local function canon(parts)
  local out = {}
  for index = 1, #parts do
    local value = tostring(parts[index])
    out[index] = #value .. ':' .. value
  end
  return table.concat(out, '|')
end

local function digest(parts)
  return host.sha256(canon(parts))
end

local function mentions_key(list)
  return table.concat(list or {}, ',')
end

local function signature(body)
  if body:sub(1, #M.SIGNATURE) ~= M.SIGNATURE then return M.SIGNATURE .. '\n' .. body end
  local rest = body:sub(#M.SIGNATURE + 1)
  if rest == '' or rest:sub(1, 1) == '\n' then return body end
  return M.SIGNATURE .. '\n' .. rest
end

function M.signature(body)
  return signature(body)
end

local function exact_text(body)
  if type(body) ~= 'string' or body:match('^%s*$') then return nil, 'operator_exact_text_required' end
  if #body > MAX_BODY then return nil, 'operator_text_invalid_or_too_large' end
  if utf8.len(body) == nil then return nil, 'operator_text_invalid_or_too_large' end
  return body
end

local function exact_reply(reply)
  if reply == nil or reply == '' then return '' end
  if type(reply) ~= 'string' or #reply > MAX_REPLY then return nil end
  if reply:find('[%s%c]') then return nil end
  return reply
end

local function exact_mentions(list)
  if list == nil then return {} end
  if type(list) ~= 'table' or #list > MAX_MENTIONS then return nil end
  local out, seen = {}, {}
  for _, id in ipairs(list) do
    if not user_jid(id) then return nil end
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function intent_id(profile, chat, body, reply, mentions)
  return digest({ 'whatsapp-operator-v1', profile.account, tostring(profile.generation), chat, body, reply, mentions_key(mentions) })
end

local function approval_digest(row)
  return digest({ 'approval-v1', row.id, row.chat, row.body, row.reply or '', row.mentions or '', row.source or '', tostring(row.prepared) })
end

-- ---------------------------------------------------------------- the exact reply source

local function message_of(chat, id)
  if type(host.whatsapp_message) ~= 'function' then return nil, 'operator_component_unavailable' end
  local ok, raw = pcall(host.whatsapp_message, json.encode({ chat = chat, id = id }))
  if not ok then return nil, 'operator_component_unavailable' end
  local answer = decode(raw)
  if not answer then return nil, 'operator_component_unavailable' end
  if answer.ok ~= true then
    local code = tostring(answer.error or '')
    if code:find('_slow$') or code:find('_unavailable$') then return nil, 'operator_component_busy' end
    if code:find('_not_found$') then return nil, 'operator_reply_source_unproven' end
    return nil, 'operator_reply_source_unproven'
  end
  if type(answer.message) ~= 'table' then return nil, 'operator_reply_source_unproven' end
  return answer.message
end

-- The digest of one exact reply source: its id, text, sender, timestamp, authorship and the absence of
-- a newer own message. The last part is checked on the newest page (50); a source older than that page
-- with no own message in it is accepted, which is the one bound this port states instead of hiding.
local function source_snapshot(chat, reply)
  local message, error_word = message_of(chat, reply)
  if not message then return nil, error_word end
  if message.chat ~= chat then return nil, 'operator_reply_source_unproven' end
  if message.own == true then return nil, 'operator_reply_source_own' end
  if message.deleted == true then return nil, 'operator_reply_source_deleted' end
  if type(message.unsupported) == 'string' and message.unsupported ~= '' then return nil, 'operator_reply_source_unsupported' end
  if message.kind ~= 'text' or type(message.text) ~= 'string' or message.text == ''
    or type(message.sender) ~= 'string' or message.sender == '' or (tonumber(message.ts) or 0) <= 0 then
    return nil, 'operator_reply_requires_exact_plain_text_source'
  end
  local ok, raw = pcall(host.whatsapp_read, json.encode({ chat = chat, limit = 50 }))
  if ok then
    local page = decode(raw)
    for _, row in ipairs(page and page.ok == true and page.messages or {}) do
      if row.own == true and (tonumber(row.ts) or 0) >= (tonumber(message.ts) or 0) then
        return nil, 'operator_reply_precedence_changed'
      end
      if row.id == reply then break end
    end
  end
  return digest({ 'source-v1', reply, message.text, message.sender, tostring(message.ts), message.own and '1' or '0', tostring(message.sender_name or '') })
end

-- ---------------------------------------------------------------- the journal

local function read_intent(id)
  local rows = query('SELECT ' .. FIELDS .. ' FROM whatsapp_operator_intents WHERE id=?', { id })
  local row = rows[1]
  -- `job` is stored as 0 when there is none: a nil inside the parameter array would make it sparse
  -- and the JSON binder refuses a sparse array (the reason the row is normalized here).
  if row and (tonumber(row.job) or 0) <= 0 then row.job = nil end
  return row
end

local function view(row)
  if not row then return nil end
  return {
    ok = true, intent_id = row.id, account = row.account, generation = row.generation,
    conversation_id = row.chat, body = row.body, reply_to = row.reply ~= '' and row.reply or nil,
    mentions = decode(row.mentions) or {}, approval_digest = row.digest, state = row.state,
    prepared_at = row.prepared, job = row.job, message_id = row.message_id,
    reason = row.reason ~= '' and row.reason or nil,
  }
end

local function fresh(row)
  local age = now() - tonumber(row.prepared or 0)
  return age >= 0 and age <= FRESH
end

local function busy_elsewhere(profile, chat, id)
  local rows = query(
    'SELECT id FROM whatsapp_operator_intents WHERE account=? AND generation=? AND chat=? AND id<>? AND state IN (?,?)',
    { profile.account, profile.generation, chat, id or '', 'dispatched', 'unknown' })
  return #rows > 0
end

local function save(row)
  exec([[INSERT INTO whatsapp_operator_intents(id,profile,account,generation,chat,body,reply,mentions,source,digest,state,prepared,job,message_id,reason)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET digest=excluded.digest,state=excluded.state,prepared=excluded.prepared,
      job=excluded.job,message_id=excluded.message_id,reason=excluded.reason]],
    { row.id, row.profile, row.account, row.generation, row.chat, row.body, row.reply, row.mentions,
      row.source, row.digest, row.state, row.prepared, row.job or 0, row.message_id, row.reason })
end

-- ---------------------------------------------------------------- the four actions

local function prepare(profile, request)
  local chat = request.conversation_id
  local allowed = false
  for _, id in ipairs(profile.conversations) do if id == chat then allowed = true end end
  if not allowed then return fail('operator_conversation_outside_profile') end
  local body, text_error = exact_text(request.body)
  if not body then return fail(text_error) end
  local reply = exact_reply(request.reply_to)
  if not reply then return fail('operator_reply_to_invalid') end
  local mentions = exact_mentions(request.mentions)
  if not mentions then return fail('operator_mention_list_invalid') end
  local signed = signature(body)
  if #signed > MAX_BODY then return fail('operator_text_invalid_or_too_large') end
  local source = ''
  if reply ~= '' then
    local value, source_error = source_snapshot(chat, reply)
    if not value then return fail(source_error) end
    source = value
  end
  local id = intent_id(profile, chat, signed, reply, mentions)
  local existing = read_intent(id)
  if existing and existing.chat ~= chat then return fail('operator_alias_intent_exists_use_original_chat') end
  if existing and (existing.state == 'dispatched' or existing.state == 'accepted' or existing.state == 'echo_confirmed' or existing.state == 'not_submitted') then
    return view(existing)
  end
  if existing and existing.state == 'unknown' then return fail('operator_unknown_recipient_intent_requires_reconciliation', { intent_id = id }) end
  if busy_elsewhere(profile, chat, id) then return fail('operator_unknown_recipient_intent_requires_reconciliation', { intent_id = id }) end
  local row = {
    id = id, profile = request.profile, account = profile.account, generation = profile.generation,
    chat = chat, body = signed, reply = reply, mentions = json.encode(mentions), source = source,
    digest = '', state = 'prepared', prepared = now(), job = nil, message_id = '', reason = '',
  }
  if existing and existing.state == 'approved' and existing.body == row.body and existing.reply == row.reply
    and existing.mentions == row.mentions and existing.source == row.source and fresh(existing) then
    return view(existing)
  end
  if existing and existing.state == 'prepared' and existing.body == row.body and existing.reply == row.reply
    and existing.mentions == row.mentions and existing.source == row.source and fresh(existing) then
    return view(existing)
  end
  row.digest = approval_digest(row)
  save(row)
  return view(row)
end

local function same_intent(row, request)
  -- The caller may echo either the text it gave prepare or the signed body prepare returned: the
  -- signature is composed deterministically, so both name the same exact bytes.
  local body = type(request.body) == 'string' and signature(request.body) or ''
  local reply = exact_reply(request.reply_to)
  local mentions = exact_mentions(request.mentions)
  if not reply or not mentions then return false end
  return row.chat == request.conversation_id and row.body == body
    and row.reply == reply and row.mentions == json.encode(mentions)
end

local function approve(profile, request)
  local id, approval = request.intent_id, request.approval_digest
  if type(id) ~= 'string' or not id:match('^[0-9a-f]+$') or #id ~= 64 then return fail('operator_intent_id_required') end
  if type(approval) ~= 'string' or not approval:match('^[0-9a-f]+$') or #approval ~= 64 then return fail('operator_exact_approval_digest_required') end
  local row = read_intent(id)
  if not row then return fail('operator_intent_not_found') end
  if row.account ~= profile.account or tonumber(row.generation) ~= profile.generation then return fail('operator_scope_mismatch') end
  if row.chat ~= request.conversation_id then return fail('operator_scope_mismatch') end
  if not same_intent(row, request) or row.digest ~= approval or approval_digest(row) ~= row.digest then
    return fail('operator_approval_binding_mismatch')
  end
  if row.state ~= 'prepared' and row.state ~= 'approved' then return fail('operator_intent_already_dispatched') end
  if not fresh(row) then return fail('operator_preparation_stale_reprepare_and_reapprove') end
  if row.reply ~= '' then
    local source, source_error = source_snapshot(row.chat, row.reply)
    if not source then return fail(source_error) end
    if source ~= row.source then return fail('operator_preparation_stale_reprepare_and_reapprove') end
  end
  if not private_file(profile.approval_token_file) then return fail('operator_private_capability_file_required') end
  row.state = 'approved'
  row.reason = ''
  save(row)
  return view(row)
end

local function send(profile, request)
  local id = request.intent_id
  if type(id) ~= 'string' or #id ~= 64 then return fail('operator_intent_id_required') end
  local row = read_intent(id)
  if not row then return fail('operator_intent_not_found') end
  if row.account ~= profile.account or tonumber(row.generation) ~= profile.generation or row.chat ~= request.conversation_id then
    return fail('operator_scope_mismatch')
  end
  if row.state ~= 'approved' then return view(row) end
  if not private_file(profile.dispatch_token_file) then return fail('operator_private_capability_file_required') end
  if not fresh(row) then
    row.state = 'failed'
    row.reason = 'operator_preparation_stale_reprepare_and_reapprove'
    save(row)
    return view(row)
  end
  if row.reply ~= '' then
    local source, source_error = source_snapshot(row.chat, row.reply)
    if not source or source ~= row.source then
      row.state = 'failed'
      row.reason = source_error or 'operator_source_mutation_or_chat_hold'
      save(row)
      return view(row)
    end
  end
  if busy_elsewhere(profile, row.chat, row.id) then return fail('operator_unknown_recipient_intent_requires_reconciliation', { intent_id = row.id }) end
  -- Durable dispatch intent BEFORE the effect: a process that dies here is `unknown`, never replayed.
  row.state = 'dispatched'
  row.reason = 'durable dispatch intent; no replay'
  save(row)
  if type(host.whatsapp_send) ~= 'function' then
    row.state = 'failed'
    row.reason = 'whatsapp_send_unavailable'
    save(row)
    return view(row)
  end
  local mentions = decode(row.mentions) or {}
  local ok, raw = pcall(host.whatsapp_send, json.encode({
    chat = row.chat, text = row.body, reply_to = row.reply ~= '' and row.reply or nil, mentions = mentions,
  }))
  if not ok then
    row.state = 'unknown'
    row.reason = 'dispatch outcome unknown; inspect with status'
    save(row)
    return view(row)
  end
  local answer = decode(raw)
  if not answer then
    row.state = 'unknown'
    row.reason = 'dispatch outcome unknown; inspect with status'
    save(row)
    return view(row)
  end
  if answer.ok == true then
    row.job = tonumber(answer.id) or nil
    row.state = 'dispatched'
    row.reason = 'queued: the wa-whatsapp component sends it'
    save(row)
    return view(row)
  end
  -- A refusal before dispatch: the capability answered `effect: none`, so nothing was queued.
  row.state = 'failed'
  row.reason = tostring(answer.error or 'operator_dispatch_refused')
  save(row)
  return view(row)
end

local function echo(chat, message_id, body)
  if type(message_id) ~= 'string' or message_id == '' then return false end
  local message = message_of(chat, message_id)
  if not message then return false end
  return message.own == true and message.deleted ~= true and message.text == body
end

local function status(profile, request)
  local id = request.intent_id
  if type(id) ~= 'string' or #id ~= 64 then return fail('operator_intent_id_required') end
  local row = read_intent(id)
  if not row then return fail('operator_intent_not_found') end
  if row.account ~= profile.account or tonumber(row.generation) ~= profile.generation or row.chat ~= request.conversation_id then
    return fail('operator_scope_mismatch')
  end
  if row.state == 'dispatched' and row.job and tonumber(row.job) > 0 and type(host.whatsapp_send_status) == 'function' then
    local ok, raw = pcall(host.whatsapp_send_status, json.encode({ id = row.job }))
    local answer = ok and decode(raw) or nil
    if answer and answer.ok == true then
      if answer.state == 'done' and type(answer.message_id) == 'string' then
        row.message_id = answer.message_id
        row.state = echo(row.chat, row.message_id, row.body) and 'echo_confirmed' or 'accepted'
        row.reason = row.state == 'accepted' and 'server acceptance; recipient delivery/read unknown' or 'exact own ID/chat/body echo; delivery/read unknown'
        save(row)
      elseif answer.state == 'failed' or answer.state == 'dead' or answer.state == 'expired' then
        row.state = 'failed'
        row.reason = tostring(answer.reason or answer.state)
        save(row)
      end
    end
  elseif (row.state == 'accepted' or row.state == 'unknown') and echo(row.chat, row.message_id, row.body) then
    row.state = 'echo_confirmed'
    row.reason = 'exact own ID/chat/body echo; delivery/read unknown'
    save(row)
  end
  return view(row)
end

-- ---------------------------------------------------------------- the one entry point

function M.call(args, explicit)
  args = args or {}
  local action = tostring(args.action or '')
  if not ACTIONS[action] then return fail('operator_action_unsupported') end
  local request = type(args.request) == 'table' and args.request or {}
  if type(request.conversation_id) ~= 'string' or not chat_jid(request.conversation_id) then
    return fail('operator_exact_scope_required')
  end
  local profiles = M.profiles(explicit)
  local profile = profiles[tostring(args.profile or '')]
  if not profile then return fail('operator_profile_unknown') end
  if action ~= 'approve' and not private_file(profile.dispatch_token_file) then
    return fail('operator_private_capability_file_required')
  end
  local ok, answer = pcall(function()
    setup()
    request.profile = args.profile
    if action == 'prepare' then return prepare(profile, request) end
    if action == 'approve' then return approve(profile, request) end
    if action == 'send' then return send(profile, request) end
    return status(profile, request)
  end)
  if not ok then return fail('operator_journal_unavailable', { detail = tostring(answer):sub(1, 160) }) end
  return answer
end

return M
