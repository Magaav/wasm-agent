-- The one WhatsApp surface on every node: `mcp_whatsapp_<verb>` (2026-11-11, issue #118).
--
-- One family of names, the same on every node, and the account stays where it lives. A call on a node
-- that runs no `wa-whatsapp` component is answered by the node that holds the account - named by the
-- deploy in `WASM_AGENT_WHATSAPP_OWNER`, or found in the fleet by asking which node runs the component
-- - instead of queueing a job nothing on this node can ever settle (#99, `docs/WHATSAPP-CUTOVER.md`).
--
-- What this replaces, and why it is one file: the same questions used to exist under three spellings -
-- `whatsapp_*` (this node's tools), `peer_<node>__whatsapp_*` (the same tools, federated) and
-- `peer_<node>__mcp_whatsapp_native_*_<hash8>` / `mcp_whatsapp_*_<hash8>` (the same questions again,
-- through an MCP connector and its namespace hash). A model asked to "send a nice message to Laura"
-- spent six calls guessing those spellings and then guessed a phone number (session 570a0da0,
-- 11/11). One name, one door, one answer shape.
--
-- The names are exact and stable: no namespace hash, no peer prefix. `mcp_whatsapp_contacts`,
-- `mcp_whatsapp_search`, `mcp_whatsapp_read`, `mcp_whatsapp_reactions`, `mcp_whatsapp_media`,
-- `mcp_whatsapp_download`, `mcp_whatsapp_backfill`, `mcp_whatsapp_send`, `mcp_whatsapp_send_status`.
--
-- Every one of the nine is answered by the node that holds the account, from any node (operator
-- decision, 11/11: a master uses every tool from wherever it runs). A call on a node that runs no
-- `wa-whatsapp` component is forwarded to the account node through the ordinary `remote_call` path,
-- so the effect happens where the worker is and under the owner's own guards: the `whatsapp.send`
-- policy (rate limit, daily cap, audit) still runs on the node that holds the account, a refusal it
-- makes travels back unchanged with `served_by`, `send` is queued on the owner's durable queue (never
-- this node's, which has no worker to settle it) and `send_status` asks the same owner that allocated
-- the id. `download` answers the file path ON the owner node and says so with `served_by` - the path
-- is real there, not here.
--
-- What still refuses is what routing cannot answer, and it names the next step: no node known to hold
-- the account, or an ambiguous fleet (two holders are not resolved by picking the first).
local json = dofile('lua/vendor/json.lua')
local M = {}

-- The component whose queue and index answer these questions (`rust/components/wa-whatsapp`).
M.COMPONENT = 'wa-whatsapp'

-- The bounds the component enforces are the bounds the schema states: a model that reads "at most 50"
-- is told the truth, and a caller that passes more is clamped by the same number in Rust
-- (`wa_whatsapp_index::SEARCH_MAX`, `READ_MAX`, `CONTACTS_MAX`).
local function string_of() return { type = 'string' } end
local function integer_of() return { type = 'integer' } end
local function bounded(minimum, maximum) return { type = 'integer', minimum = minimum, maximum = maximum } end

-- The verbs, in the order a reader needs them: find the chat, read it, look inside one message, then
-- the three that leave this node. `capability` is the host capability the answer comes from;
-- `parameters` is the schema the model is offered; `request` turns the tool arguments into the one
-- wire shape the capability reads back.
M.TOOLS = {
  {
    verb = 'contacts', capability = 'whatsapp_contacts', effect = 'read',
    description = 'Which WhatsApp chat a name means. Answers from the names this node has actually seen on messages (push names, a group subject when one was fetched, and the chat\'s own digits), best match first, each candidate with its exact JID, whether it is a person or a group, how many messages, when it was last heard from and a confidence (exact, prefix, partial). One exact match also fills chat; several matches are listed as candidates and marked ambiguous, never resolved, because picking the wrong Laura is the mistake this exists to prevent. No query lists the chats the index knows, newest first.',
    parameters = { type = 'object', properties = {
      q = { type = 'string', maxLength = 80, description = 'The name to resolve: a name, part of one, or a phone number. Omit it to list the chats the index knows.' },
      limit = bounded(1, 20),
    }, additionalProperties = false },
    request = function(args) return { q = args.q, limit = args.limit } end,
  },
  {
    verb = 'search', capability = 'whatsapp_search', effect = 'read',
    description = 'Search every WhatsApp message this account has indexed: text, captions, document filenames and voice-note transcripts, accent-folded, so "acao" finds "Ação" and "relatorio" finds "Relatório.pdf". Messages of every kind are indexed (text, image, video, audio, voice note, document, sticker, location, contact card, poll) and so are edits and deletions. Narrow with at least one of q, chat, kind or from; the filters combine (since/until is a time window in epoch milliseconds, seconds accepted). Every hit carries the chat name, the sender name, the time three ways (at, at_local, at_iso) and the message shape, and a long body is a pointer to whatsapp_message. The best match comes first; a search that matched more than it could return says truncated=true and matched=N.',
    parameters = { type = 'object', properties = {
      q = { type = 'string', maxLength = 200, description = 'Literal text, accent-folded.' },
      chat = { type = 'string', maxLength = 160 }, ['from'] = { type = 'string', maxLength = 160 },
      -- The kinds the index distinguishes (`wa_whatsapp_index::KINDS`): `voice` is a push-to-talk note,
      -- `audio` a music file, and `edit`/`delete` are the events a source mutation produces.
      kind = { type = 'string', enum = { 'text', 'image', 'video', 'audio', 'voice', 'document', 'sticker',
        'location', 'contact', 'poll', 'reaction', 'edit', 'delete', 'other' },
        description = 'Only this message kind. voice is a push-to-talk note; audio is a music file.' },
      ['since'] = integer_of(), ['until'] = integer_of(), limit = bounded(1, 50),
    }, additionalProperties = false },
    request = function(args)
      return { q = args.q, chat = args.chat, kind = args.kind, ['from'] = args['from'], ['since'] = args['since'], ['until'] = args['until'], limit = args.limit }
    end,
  },
  {
    verb = 'read', capability = 'whatsapp_read', effect = 'read',
    description = 'Read one WhatsApp chat, newest message first. chat is an exact JID (<digits>@s.whatsapp.net, <digits>@lid, <digits>@g.us) OR a name: a name is resolved through the same ranking the contacts tool uses, and an ambiguous name answers with the candidates instead of reading the wrong chat. The answer starts with a header - the chat name, whether it is a person or a group, a group\'s participant names, and the unread count when the index has one - then the messages: id, time three ways, from (name and jid), text (a snippet, with full for the whole stored body), reply_to (the quoted message), reactions folded on, media metadata, and edited/deleted flags. Pass next_before back as before to read the older page.',
    parameters = { type = 'object', properties = {
      chat = { type = 'string', maxLength = 80, description = 'An exact chat JID, or a name to resolve (ambiguous names answer with candidates).' },
      before = { type = 'string', maxLength = 128, description = 'The next_before cursor from the previous page.' },
      limit = bounded(1, 100),
    }, required = { 'chat' }, additionalProperties = false },
    request = function(args) return { chat = args.chat, before = args.before, limit = args.limit } end,
  },
  {
    verb = 'reactions', capability = 'whatsapp_reactions', effect = 'read',
    description = 'Who reacted to one WhatsApp message, with which emoji. A reaction that was taken back is not listed; by_emoji counts what is left.',
    parameters = { type = 'object', properties = { chat = { type = 'string', maxLength = 160 }, id = { type = 'string', maxLength = 128 } }, required = { 'chat', 'id' }, additionalProperties = false },
    request = function(args) return { chat = args.chat, id = args.id } end,
  },
  {
    verb = 'media', capability = 'whatsapp_media', effect = 'read',
    description = 'The media metadata of one indexed WhatsApp message: kind, mime, filename, size, sha256, duration, page count - or the location, contact card or poll it carries. No bytes and no media key; use whatsapp_download for the file.',
    parameters = { type = 'object', properties = { chat = { type = 'string', maxLength = 160 }, id = { type = 'string', maxLength = 128 } }, required = { 'chat', 'id' }, additionalProperties = false },
    request = function(args) return { chat = args.chat, id = args.id } end,
  },
  {
    verb = 'download', capability = 'whatsapp_download', effect = 'write',
    description = 'Decrypt the media of one indexed WhatsApp message on the node that holds the account and answer with the file path there (mime, filename, bytes and sha256 included). The decrypted file lands in the bounded download folder of the node that holds the account, and the decrypt is bounded by max_bytes (524288 at most): a video larger than the bound answers download_too_large with its size instead of pretending; view-once and revoked media is never downloadable. Feed the path to OCR or transcription tools.',
    parameters = { type = 'object', properties = {
      chat = { type = 'string', maxLength = 160 }, id = { type = 'string', maxLength = 128 }, max_bytes = { type = 'integer', minimum = 1, maximum = 524288 },
    }, required = { 'chat', 'id' }, additionalProperties = false },
    request = function(args) return { chat = args.chat, id = args.id, max_bytes = args.max_bytes } end,
  },
  {
    verb = 'backfill', capability = 'whatsapp_backfill', effect = 'write',
    description = 'Ask the primary phone for older WhatsApp messages, so the index covers the account history and not only the live stream. Name one exact chat JID to reach back into that conversation, or name none to ask for the chats the index already knows (at most 20, newest first). The messages arrive through the normal protocol and are indexed as history, so a later whatsapp_search finds them. This is a request to the phone, not an answer: the result is the ids and counts that were asked for, plus a note when it stopped early.',
    parameters = { type = 'object', properties = {
      chat = { type = 'string', maxLength = 160 }, count = { type = 'integer', minimum = 1, maximum = 500 },
    }, additionalProperties = false },
    request = function(args) return { chat = args.chat, count = args.count } end,
  },
  {
    verb = 'send', capability = 'whatsapp_send', effect = 'write',
    description = 'Send one WhatsApp message yourself, on this account, to one exact chat. It is queued on the account node\'s durable queue and sent by the wa-whatsapp component, so the answer is a job id, not a delivery: read the outcome with mcp_whatsapp_send_status. Governance applies (the node policy whatsapp.send rule: rate limits, daily cap, audit); a refusal comes back as an error word and nothing is sent. chat is an exact JID: <digits>@s.whatsapp.net (phone number), <digits>@lid (the hidden LID identity) or <digits>@g.us (group) - a name is not accepted here, use mcp_whatsapp_contacts to turn a name into a chat first. The same chat+text+reply_to is one job, so a repeated call does not send twice.',
    parameters = { type = 'object', properties = {
      chat = { type = 'string', maxLength = 160, description = 'Exact chat JID: <digits>@s.whatsapp.net, <digits>@lid or <digits>@g.us. A bare phone number is refused.' },
      text = { type = 'string', maxLength = 65536, description = 'The message body, exactly as it should appear.' },
      reply_to = { type = 'string', maxLength = 128, description = 'Optional message id to quote.' },
      mentions = { type = 'array', maxItems = 64, items = { type = 'string' }, description = 'Optional mention targets as exact user JIDs; meaningful in a group.' },
    }, required = { 'chat', 'text' }, additionalProperties = false },
    request = function(args) return { chat = args.chat, text = args.text, reply_to = args.reply_to, mentions = args.mentions } end,
  },
  {
    verb = 'send_status', capability = 'whatsapp_send_status', effect = 'read',
    description = 'State of a message you asked mcp_whatsapp_send to send: queued, done with the message id WhatsApp gave it, or failed with a reason. The question is put to the node that holds the account, the node that allocated the id; an id that node never allocated is refused, not guessed.',
    parameters = { type = 'object', properties = { id = { type = 'integer', minimum = 1, description = 'The job id whatsapp_send returned.' } }, required = { 'id' }, additionalProperties = false },
    request = function(args) return { id = tonumber(args.id) or args.id } end,
  },
}

M.by_verb = {}
for _, tool in ipairs(M.TOOLS) do
  tool.name = 'mcp_whatsapp_' .. tool.verb
  M.by_verb[tool.verb] = tool
end

--- The exact name one verb is offered as (`mcp_whatsapp_read`).
function M.name(verb) local tool = M.by_verb[verb]; return tool and tool.name or nil end

--- The tool a callable name is, or nil. Exact match only: a hashed or peer-prefixed spelling from an
--- older build is not this surface, and `M.renamed` explains where it went.
function M.tool(name)
  if type(name) ~= 'string' or name:sub(1, 12) ~= 'mcp_whatsapp' then return nil end
  for _, tool in ipairs(M.TOOLS) do if tool.name == name then return tool end end
  return nil
end

--- Does `name` change something outside this node? Reads answer questions; the rest do not.
function M.effect(name) local tool = M.tool(name); return tool and tool.effect or nil end

--- The one sentence a caller of a removed spelling needs: the family, and the name to use instead.
--
-- It covers the three shapes the operator asked to retire (`peer_openclaw_*` for WhatsApp, an MCP
-- namespace hash such as `mcp_whatsapp_native_read_newest_47452e4e`, and the bare `whatsapp_read`),
-- and it names the replacement instead of only refusing.
function M.renamed(name)
  name = tostring(name or '')
  local bare = name:match('^peer_[^_]+__(.+)$') or name
  local verb = bare:match('^mcp_whatsapp_native_([%a_]+)_%x%x%x%x%x%x%x%x$')
    or bare:match('^mcp_whatsapp_([%a_]+)_%x%x%x%x%x%x%x%x$')
    or bare:match('^whatsapp_([%a_]+)$')
  local mapped = verb and ({
    read_snapshot = 'search', read_newest = 'read', inspect_chat = 'read', lookup_self = 'contacts',
    list_chats = 'contacts', search = 'search', read = 'read', contacts = 'contacts',
    reactions = 'reactions', media = 'media', download = 'download', backfill = 'backfill',
    send = 'send', send_status = 'send_status',
  })[verb]
  if not mapped then return nil end
  return 'mcp_whatsapp_' .. mapped
end

--- The schemas the model is offered, in catalogue shape (`tools.catalog`).
function M.schemas()
  local out = {}
  for _, tool in ipairs(M.TOOLS) do
    out[#out + 1] = { type = 'function', ['function'] = {
      name = tool.name, description = tool.description, parameters = tool.parameters,
    } }
  end
  return out
end

--- Does this node run the component that holds the account? The deploy's own registry answers this
--- (`host.service` status), so "who owns the account" is a fact about the fleet, not a name in a file.
function M.holds_account()
  if type(host.service) ~= 'function' then return false end
  local ok, raw = pcall(host.service, json.encode({ action = 'status' }))
  if not ok then return false end
  local decoded_ok, list = pcall(json.decode, tostring(raw or ''))
  if not decoded_ok or type(list) ~= 'table' then return false end
  for _, service in ipairs(list) do
    if type(service) == 'table' and service.name == M.COMPONENT and service.state == 'running' then return true end
  end
  return false
end

--- The node that holds the account, or nil.
--
-- Two sources, in this order, and a guess is not one of them: the owner the deploy declared
-- (`WASM_AGENT_WHATSAPP_OWNER`, the same value the host capability reports), then the fleet - the one
-- online peer whose catalog says it runs the component. Zero peers, or two, answers nil: an ambiguous
-- fleet is not resolved by picking the first, and the refusal then says so instead of queueing.
function M.owner(catalog_fn)
  local declared = host.getenv('WASM_AGENT_WHATSAPP_OWNER')
  if type(declared) == 'string' and declared:match('%S') then return (declared:gsub('%s', '')) end
  -- `catalog_fn` is the test's door to the fleet (the real one is the federation cache); a caller never
  -- passes it, and a wrong one can only make this answer nil, which is the safe direction.
  local ok, catalog = pcall(catalog_fn or function() return dofile('lua/core/federation.lua').catalog() end)
  if not ok or type(catalog) ~= 'table' then return nil end
  local found = {}
  for _, peer in pairs(catalog.peers or {}) do
    local holds = false
    for _, connector in ipairs(peer.connectors or {}) do
      if connector.whatsapp_account == true then holds = true end
    end
    if holds and type(peer.name) == 'string' and peer.name ~= '' then found[#found + 1] = peer.name end
  end
  if #found == 1 then return found[1] end
  return nil
end

--- Ask the account node the same question, under its own guards.
--
-- `call` is `nodes.remote_call` unless a test passes its own; the answer keeps the same shape, gains
-- `served_by` (which node answered) and is never rewritten: a refusal from the owner travels as it
-- was, because it is the owner's decision.
function M.forward(owner, name, args, call)
  call = call or dofile('lua/core/nodes.lua').remote_call
  local ok, served = pcall(call, owner, name, args)
  if not ok then
    return { error = 'whatsapp_owner_unreachable', owner = owner, detail = tostring(served):sub(1, 160), effect = 'none' }
  end
  if type(served) ~= 'table' then
    return { error = 'whatsapp_owner_unreachable', owner = owner, effect = 'none' }
  end
  if served.error == nil then served.served_by = owner end
  return served
end

--- The refusal a node without the account gives when routing cannot answer: never a queue, always with
-- the next step. Two cases reach it - nobody in the fleet holds the account (or this node was told
-- none does), and an ambiguous fleet where two nodes do - and both name the fix instead of guessing.
local function absent_answer(answer, owner)
  local where = owner and ('the WhatsApp account is served by ' .. owner)
    or 'no node in this fleet says it runs ' .. M.COMPONENT .. ' (set WASM_AGENT_WHATSAPP_OWNER on this node, or enable the component where the account is)'
  local refusal = {
    ok = false, error = 'whatsapp_component_absent', effect = 'none',
    component = M.COMPONENT, state = answer and answer.state, where = 'this node',
    note = 'this node runs no ' .. M.COMPONENT .. ' component; ' .. where,
  }
  if owner then refusal.owner = owner end
  return refusal
end

--- One call. `name` is the exact callable name, or the bare verb (dispatch passes the name).
function M.call(name, args, ctx)
  local tool = M.tool(name) or (type(name) == 'string' and M.by_verb[name]) or nil
  if not tool then
    local renamed = M.renamed(name)
    if renamed then
      return { ok = false, error = 'whatsapp_tool_renamed', use = renamed, effect = 'none',
        note = tostring(name) .. ' is not a WhatsApp tool any more: call ' .. renamed .. ' (one surface, every node)' }
    end
    return { ok = false, error = 'unknown_tool:' .. tostring(name), effect = 'none' }
  end
  args = args or {}
  local absent = absent_answer
  local capability = host[tool.capability]
  if type(capability) ~= 'function' then
    -- A binary built without the capability cannot answer, and says which one is missing rather than
    -- pretending the account is quiet.
    return { ok = false, error = tool.name .. '_unavailable', capability = tool.capability, effect = 'none' }
  end
  local ok, answer = pcall(capability, json.encode(tool.request(args)))
  if not ok then return { ok = false, error = tool.name .. '_failed', detail = tostring(answer):sub(1, 160), effect = 'none' } end
  local decode_ok, decoded = pcall(json.decode, tostring(answer or ''))
  if not decode_ok or type(decoded) ~= 'table' then
    return { ok = false, error = tool.name .. '_answer_unreadable', effect = 'none' }
  end
  if decoded.error == 'whatsapp_component_absent' then
    local owner = (type(decoded.owner) == 'string' and decoded.owner ~= '' and decoded.owner)
      or M.owner(ctx and ctx.owner_catalog or nil)
    if owner then
      -- Every verb, read or effect, is the account node's question to answer: the effect happens where
      -- the worker is, under the owner's own guards, and the answer that comes back keeps its shape
      -- plus `served_by` (a refusal from the owner travels unchanged).
      local routed = M.forward(owner, tool.name, args, ctx and ctx.remote_call or nil)
      -- Say who answered, and that this node asked them: an answer served by another node is still this
      -- tool's answer, and the caller should not have to guess why it took a hop.
      if type(routed) == 'table' then routed.asked_owner = owner end
      return routed
    end
    return absent(decoded, owner)
  end
  return decoded
end

return M
