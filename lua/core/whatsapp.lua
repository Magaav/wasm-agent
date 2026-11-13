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
-- `mcp_whatsapp_download`, `mcp_whatsapp_backfill`, `mcp_whatsapp_send` - eight offered to the model -
-- and `mcp_whatsapp_send_status`, a hidden alias kept only for a script written before a send answered
-- its own outcome (no catalogue offers it, no guidance names it, and `mcp_whatsapp_send({id})` is what
-- it became).
--
-- `send` is one call that ANSWERS (operator decision, 11/11): the message is still a job on the account
-- node's durable queue and still sent by the component, but the tool no longer stops at the job id and
-- leaves the outcome to a second call nobody is sure to make. It waits for that job's terminal state
-- and answers it - `done` with the message id WhatsApp gave it, `failed` with the reason, or `pending`
-- with the id and the call that resumes the wait. The wait is bounded by `wait_s`, by the calling
-- script's own remaining time and by stop/steer, and it takes no lock and no queue lease: it only reads
-- what the queue knows, so the worker on the account node keeps sending while it sleeps. Resuming is a
-- READ (below, `M.effect`), so it joins other calls instead of queueing behind an effect; several jobs
-- can be resumed in one call with `ids` (1..20), and `mcp_whatsapp_send({ids:[...]})` answers one entry
-- per id in the order asked.
--
-- Every one of the eight is answered by the node that holds the account, from any node (operator
-- decision, 11/11: a master uses every tool from wherever it runs). A call on a node that runs no
-- `wa-whatsapp` component is forwarded to the account node through the ordinary `remote_call` path,
-- so the effect happens where the worker is and under the owner's own guards: the `whatsapp.send`
-- policy (rate limit, daily cap, audit) still runs on the node that holds the account, a refusal it
-- makes travels back unchanged with `served_by`, and `send` is queued on the owner's durable queue
-- (never this node's, which has no worker to settle it). A wait after a routed send is a loop of short
-- state reads, never one long call: the owner queues and answers at once and this node asks for the
-- state itself. `download` answers the file path ON the owner node and says so with `served_by` - the
-- path is real there, not here.
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
    description = 'Send one WhatsApp message yourself, on this account, to one exact chat, and answer what WhatsApp did with it. It is queued on the account node\'s durable queue and sent by the wa-whatsapp component; this call waits for that answer and returns {state:"done", id, message_id, served_by} or {state:"failed", id, reason, served_by}. wait_s is how long it waits: default 60, 0 queues and answers at once, at most 300, and never longer than the script that asked has left. Not finished in time is not an error: it answers {state:\"pending\", id, waited_s} and, in a script, the same {state:\"pending\", op} handle every other call answers - wait(op) resumes it and never sends again (a repeated chat+text+reply_to is one job, so nothing is sent twice), and one wait(...) collects several sends in one call, one entry per op in the order asked. Outside a script the answer\'s resume field names the one call that collects the same job. Governance applies (the node policy whatsapp.send rule: rate limits, daily cap, audit); a refusal comes back as an error word and nothing is sent. chat is an exact JID: <digits>@s.whatsapp.net (phone number), <digits>@lid (the hidden LID identity) or <digits>@g.us (group) - a name is not accepted here, use mcp_whatsapp_contacts to turn a name into a chat first.',
    parameters = { type = 'object', properties = {
      chat = { type = 'string', maxLength = 160, description = 'Exact chat JID: <digits>@s.whatsapp.net, <digits>@lid or <digits>@g.us. A bare phone number is refused.' },
      text = { type = 'string', maxLength = 65536, description = 'The message body, exactly as it should appear.' },
      reply_to = { type = 'string', maxLength = 128, description = 'Optional message id to quote.' },
      mentions = { type = 'array', maxItems = 64, items = { type = 'string' }, description = 'Optional mention targets as exact user JIDs; meaningful in a group.' },
      id = { type = 'integer', minimum = 1, description = 'Resume waiting on a job an earlier send answered: no chat or text, and nothing is sent again.' },
      ids = { type = 'array', minItems = 1, maxItems = 20, items = { type = 'integer', minimum = 1 }, description = 'Resume several jobs in one call: one entry per id, in the order asked. Nothing is sent again.' },
      ['until'] = { type = 'string', enum = { 'all', 'any' }, description = 'With ids: wait until every one is done or failed (default all), or answer as soon as one is.' },
      wait_s = { type = 'integer', minimum = 0, maximum = 300, description = 'How long to wait for the answer (default 60; 0 queues and answers at once).' },
    }, additionalProperties = false },
    request = function(args) return { chat = args.chat, text = args.text, reply_to = args.reply_to, mentions = args.mentions } end,
  },
  {
    verb = 'send_status', capability = 'whatsapp_send_status', effect = 'read', hidden = true,
    description = 'Kept for a script written before one send answered its own outcome: the same answer as mcp_whatsapp_send({id, wait_s:0}). No catalogue and no guidance offers it - call mcp_whatsapp_send with the id instead.',
    parameters = { type = 'object', properties = { id = { type = 'integer', minimum = 1, description = 'The job id a send answered.' } }, required = { 'id' }, additionalProperties = false },
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
---
--- One tool is two calls (operator decision, 11/11): `mcp_whatsapp_send({chat, text})` queues a message,
--- and `mcp_whatsapp_send({id})`/`({ids})` waits on a job that is already queued. The second form sends
--- nothing and reads what the queue knows, so it is a READ - it must not be serialized behind effects,
--- must not count as "did the agent change something", and may sit beside other calls in a script. The
--- send form keeps `write`, so it stays serialized and under the `whatsapp.send` policy.
function M.effect(name, args)
  local tool = M.tool(name)
  if not tool then return nil end
  if tool.verb == 'send' and M.is_wait(args) then return 'read' end
  return tool.effect
end

--- Is this the resume form of a call: job ids and no message (`lua/core/whatsapp.lua`, `M.send`)?
function M.is_wait(args)
  if type(args) ~= 'table' then return false end
  if args.chat ~= nil or args.text ~= nil then return false end
  return args.id ~= nil or args.ids ~= nil
end

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
    send = 'send',
    -- A retired spelling of the status read recovers to the ONE tool that answers now, never to the
    -- hidden alias: `mcp_whatsapp_send({id})` is the resume, and no guidance names the alias any more.
    send_status = 'send',
  })[verb]
  if not mapped then return nil end
  return 'mcp_whatsapp_' .. mapped
end

--- The schemas the model is offered, in catalogue shape (`tools.catalog`).
--
-- A hidden verb (today only `send_status`, the compatibility alias) is callable and is not offered: no
-- catalogue holds it, no guidance names it, and the model gets `mcp_whatsapp_send` instead - one call
-- that answers, and the same tool to resume a wait.
function M.schemas()
  local out = {}
  for _, tool in ipairs(M.TOOLS) do
    if not tool.hidden then
      out[#out + 1] = { type = 'function', ['function'] = {
        name = tool.name, description = tool.description, parameters = tool.parameters,
      } }
    end
  end
  return out
end

--- Is this name a hidden tool of the surface: callable, master-only, never offered?
function M.hidden(name)
  local tool = M.tool(name)
  return (tool ~= nil and tool.hidden == true) or false
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

--- This node's own name, or nil when it cannot be read. Used only to refuse routing a question to
-- itself; a guess here can only make this answer nil, which keeps the routing (the safe direction).
function M.self_name()
  local ok, name = pcall(function() return dofile('lua/core/nodes.lua').node_name() end)
  if ok and type(name) == 'string' and name ~= '' then return name end
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
  if served.error == nil then
    served.served_by = owner
    -- The node this answer came from: a caller that only sees the settled answer (`M.settle`) still
    -- learns that the question took a hop, not only who wrote the answer.
    served.asked_owner = owner
  end
  return served
end

--- The refusal a node without the account gives when routing cannot answer: never a queue, always with
-- the next step. Three cases reach it - nobody in the fleet holds the account (or this node was told
-- none does), an ambiguous fleet where two nodes do, and this node being the account node itself while
-- its component is stopped - and each names the fix instead of guessing.
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

--- One capability call of the account surface, decoded and never routed: routing is the caller's step.
function M.invoke(tool, args)
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
  return decoded
end

--- The owner a routed call must ask, or the refusal that says why nobody can answer.
---
--- The deploy's word first (`decoded.owner`, which the absent answer carries), the fleet second, and
--- this node's own name is never a route: asking yourself again asks the same unanswered question for
--- ever, so that case says what to start instead of taking a hop.
local function route_owner(decoded, ctx)
  local declared = type(decoded) == 'table' and type(decoded.owner) == 'string' and decoded.owner ~= ''
    and decoded.owner or nil
  local owner = declared or M.owner(ctx and ctx.owner_catalog or nil)
  if not owner then return nil, absent_answer(decoded, nil) end
  if owner == M.self_name() then
    local mine = absent_answer(decoded, owner)
    mine.note = 'this node is the WhatsApp account node (' .. owner .. ') but runs no ' .. M.COMPONENT
      .. ' component: start it here (wa services start ' .. M.COMPONENT .. ')'
    return nil, mine
  end
  return owner
end

-- ---------------------------------------------------------------- the wait: one send that answers
-- Operator decision (11/11): one `mcp_whatsapp_send` is enough. The message is still a job on the
-- account node's durable queue and still sent by the wa-whatsapp component - what changed is that the
-- tool no longer stops at the job id and leaves the outcome to a second call nobody is sure to make.
--
-- Every bound is a different reason and none of them is optional:
--   * `wait_s` (default 60, 0..300) is what the caller asked for; 0 queues and answers at once;
--   * the calling script's own remaining time, minus a margin, is what a wait may spend
--     (`ctx.codemode_deadline`, stamped by `lua/core/codemode.lua` from the same `timeout_ms` the
--     sandbox was given). The sandbox refuses an admission after its deadline, so a wait that spent it
--     would turn a queued message into a dead script - the one outcome worse than `pending`;
--   * stop, steer and turn cancel end the wait at once, and the answer is `pending` with the id: the
--     job is durable, nothing was lost, and nothing is sent twice.
--
-- What the loop does NOT do matters as much. It takes no lock and no queue lease and writes nothing: a
-- state read only asks the queue what it knows, so the worker on the account node keeps taking and
-- settling jobs while this sleeps (a job in `leased` is still the worker's, never ours). Across nodes
-- it is a series of short `mcp_whatsapp_send_status` calls, each far under the relay's ~45 s call
-- limit, with backoff from 0.5 s to 5 s - never one long call that a relay deadline could cut.
M.WAIT = { default_s = 60, max_s = 300, margin_s = 2, first_s = 0.5, cap_s = 5 }
local FAILED_STATES = { failed = true, dead = true, expired = true }

local function clock_s() return tonumber(host.now()) or 0 end

--- How long this call has been waiting, to a tenth of a second.
local function waited_since(started)
  local seconds = clock_s() - started
  if seconds < 0 then seconds = 0 end
  return math.floor(seconds * 10 + 0.5) / 10
end

--- The seconds this call may wait: `wait_s`, capped at 300 and by the calling script's remaining time.
function M.wait_budget(requested, ctx)
  local wait_s = tonumber(requested)
  if wait_s == nil then wait_s = M.WAIT.default_s end
  if wait_s < 0 then wait_s = 0 end
  if wait_s > M.WAIT.max_s then wait_s = M.WAIT.max_s end
  local deadline = type(ctx) == 'table' and tonumber(ctx.codemode_deadline) or nil
  if deadline then
    local left = deadline - clock_s() - M.WAIT.margin_s
    if left < 0 then left = 0 end
    if left < wait_s then wait_s = left end
  end
  return wait_s
end

--- Did the run ask us to stop? Stop, steer and cancellation are one answer: stop waiting now.
local function stop_reason(ctx, options)
  if options and options.cancelled then
    local ok, value = pcall(options.cancelled)
    if ok and value then return type(value) == 'string' and value or 'run_cancelled' end
  end
  if type(host.run_cancelled) == 'function' then
    local ok, raw = pcall(host.run_cancelled)
    if ok then
      local decoded_ok, decoded = pcall(json.decode, tostring(raw or ''))
      if decoded_ok and type(decoded) == 'table' and decoded.cancelled then return 'run_cancelled' end
    end
  end
  -- A steering message ends this turn, so the wait ends with it: `pending`, the id, and the steered
  -- turn resumes where this one stopped (the same fence `tools.dispatch` checks before a call).
  if type(ctx) == 'table' and type(ctx.steering_admit) == 'function' then
    local ok, admitted = pcall(ctx.steering_admit)
    if ok and admitted == false then return 'steering_waiting' end
  end
  return nil
end

--- The node that answers a job's state, as one function `read(id)`.
---
--- `owner` names that node when the caller already knows it (a routed send knows who queued the job).
--- Without one, this node asks itself first and resolves the account node on the first
--- `whatsapp_component_absent` - once, not once per read - and every answer carries `served_by`, so a
--- caller never has to guess who was asked.
function M.status_reader(owner, ctx)
  local tool = M.by_verb.send_status
  local call = ctx and ctx.remote_call or nil
  local resolved = owner
  return function(id)
    if resolved then return M.forward(resolved, tool.name, { id = id }, call) end
    local answer = M.invoke(tool, { id = id })
    if type(answer) ~= 'table' or answer.error ~= 'whatsapp_component_absent' then
      if type(answer) == 'table' and answer.served_by == nil then answer.served_by = M.self_name() end
      return answer
    end
    local discovered = (type(answer.owner) == 'string' and answer.owner ~= '' and answer.owner)
      or M.owner(ctx and ctx.owner_catalog or nil)
    if discovered == nil or discovered == M.self_name() then return answer end
    resolved = discovered
    return M.forward(resolved, tool.name, { id = id }, call)
  end
end

--- Wait for one queued job's terminal state and answer it.
---
--- `ok` is true whenever the call answered: `done` and `pending` and `failed` are all outcomes of a
--- message that was queued, and the model reads `state`/`reason`. `ok = false` is kept for the CALL
--- failing - a bad argument, an id this node never allocated, an owner that cannot be reached - because
--- a sandbox turns `ok:false` into a thrown Error and an outcome that arrived would then be lost in a
--- message string instead of being read as a value.
---
--- `read(id)` asks the node that allocated the job for its state and is the only thing this loop does.
--- `wait_s` is already bounded (`M.wait_budget`). `options` carries what a test needs to drive the loop
--- without a clock or a peer - `sleep`, `cancelled` - plus `ctx` and `served_by`, which a real caller
--- passes and a test may too.
function M.settle(id, wait_s, read, options)
  options = options or {}
  local sleep = options.sleep or function(seconds)
    if type(host.sleep) ~= 'function' then return false end
    return (pcall(host.sleep, math.max(0, math.floor(seconds * 1000))))
  end
  local started, reads, pause = clock_s(), 0, M.WAIT.first_s
  local last, reason = nil, nil
  local function who()
    if type(last) == 'table' and type(last.served_by) == 'string' and last.served_by ~= '' then return last.served_by end
    return options.served_by
  end
  local function pending()
    local answer = { ok = true, state = 'pending', id = id, waited_s = waited_since(started), reads = reads,
      resume = 'mcp_whatsapp_send({id:' .. tostring(id) .. ', wait_s:' .. tostring(M.WAIT.default_s) .. '})',
      note = 'queued: the message is not lost - resume with the same tool and the id, which never sends again' }
    if type(last) == 'table' then
      if type(last.state) == 'string' then answer.queue_state = last.state end
      if last.attempts ~= nil then answer.attempts = last.attempts end
    end
    if reason then answer.reason = reason end
    if who() then answer.served_by = who() end
    if type(last) == 'table' and type(last.asked_owner) == 'string' then answer.asked_owner = last.asked_owner end
    return answer
  end
  while true do
    local stop = stop_reason(options.ctx, options)
    if stop then reason = stop; break end
    reads = reads + 1
    local answer = read(id)
    if type(answer) ~= 'table' then answer = { error = 'whatsapp_send_status_unreadable' } end
    last = answer
    local state = type(answer.state) == 'string' and answer.state or nil
    if answer.error == nil and state == 'done' then
      local done = { ok = true, state = 'done', id = id, message_id = answer.message_id,
        waited_s = waited_since(started), reads = reads }
      if answer.attempts ~= nil then done.attempts = answer.attempts end
      if who() then done.served_by = who() end
      if type(answer.asked_owner) == 'string' then done.asked_owner = answer.asked_owner end
      return done
    end
    if answer.error == nil and state and FAILED_STATES[state] then
      local failed = { ok = true, state = 'failed', id = id, reason = answer.reason or state,
        waited_s = waited_since(started), reads = reads }
      if answer.attempts ~= nil then failed.attempts = answer.attempts end
      if who() then failed.served_by = who() end
      if type(answer.asked_owner) == 'string' then failed.asked_owner = answer.asked_owner end
      return failed
    end
    if answer.error then
      reason = tostring(answer.error)
      -- An id the account node never allocated will not settle by being asked again: that is a refusal,
      -- and it says so instead of pretending this wait is still running.
      if reason == 'whatsapp_send_unknown_id' then
        local failed = { ok = false, state = 'failed', id = id, error = reason, reason = reason,
          waited_s = waited_since(started), reads = reads,
          note = 'the node that holds the account never allocated this id: nothing is queued under it' }
        if who() then failed.served_by = who() end
        return failed
      end
      break
    end
    if not state then
      -- An answer with no state word is not a state: report it instead of sleeping on a guess.
      reason = 'whatsapp_send_status_unreadable'
      break
    end
    local left = wait_s - (clock_s() - started)
    if left <= 0 then break end
    sleep(math.min(pause, left))
    pause = math.min(pause * 2, M.WAIT.cap_s)
  end
  return pending()
end

--- The options one wait runs with: `ctx` (stop, steer and the script's own deadline are read from it)
--- plus the two doors a test needs to drive the loop without a clock - `ctx.whatsapp_wait.sleep` and
--- `ctx.whatsapp_wait.cancelled`, the same kind of door `ctx.remote_call` and `ctx.owner_catalog` are.
local function wait_options(ctx, served_by, mode)
  local doors = type(ctx) == 'table' and type(ctx.whatsapp_wait) == 'table' and ctx.whatsapp_wait or {}
  return { ctx = ctx, served_by = served_by, sleep = doors.sleep, cancelled = doors.cancelled, ['until'] = mode }
end

--- Wait for several queued jobs in ONE call, and answer one entry per id in the order asked.
---
--- This is `M.settle` over a list: same budget (`wait_s` bounds the whole call, not each id), same
--- backoff, same stop, and the same one-state-read thing to do per round - never a lock, never a lease.
--- `until = 'any'` answers as soon as one job is done or failed and leaves the rest `pending` with their
--- ids; the default (`'all'`) returns when every one is terminal or the wait ends. An id this node never
--- allocated is answered as `failed` for that entry alone: one bad id in a batch must not hide the
--- outcome of the other nine.
function M.settle_many(ids, wait_s, read, options)
  options = options or {}
  local sleep = options.sleep or function(seconds)
    if type(host.sleep) ~= 'function' then return false end
    return (pcall(host.sleep, math.max(0, math.floor(seconds * 1000))))
  end
  local started, reads, pause = clock_s(), 0, M.WAIT.first_s
  local entries, terminal = {}, {}
  for index, id in ipairs(ids) do
    entries[index] = { ok = true, state = 'pending', id = id, waited_s = 0,
      resume = 'mcp_whatsapp_send({id:' .. tostring(id) .. ', wait_s:' .. tostring(M.WAIT.default_s) .. '})' }
  end
  local function count()
    local total = 0
    for index = 1, #ids do if terminal[index] then total = total + 1 end end
    return total
  end
  local function finish(reason)
    local remaining = {}
    for index, id in ipairs(ids) do
      local entry = entries[index]
      entry.waited_s = waited_since(started)
      if not terminal[index] then
        remaining[#remaining + 1] = id
        if reason then entry.reason = reason end
      end
    end
    local all = #remaining == 0
    local answer = { ok = true, state = all and 'settled' or 'pending',
      ['until'] = options['until'] or 'all', ids = ids, results = entries, waited_s = waited_since(started), reads = reads }
    if not all then
      answer.pending_ids = remaining
      answer.resume = 'mcp_whatsapp_send({ids:{' .. table.concat(remaining, ',') .. '}, wait_s:'
        .. tostring(M.WAIT.default_s) .. '})'
      if reason then answer.reason = reason end
    end
    if options.served_by then answer.served_by = options.served_by end
    return answer
  end
  while true do
    local stop = stop_reason(options.ctx, options)
    if stop then return finish(stop) end
    for index, id in ipairs(ids) do
      if not terminal[index] then
        reads = reads + 1
        local answer = read(id)
        if type(answer) ~= 'table' then answer = { error = 'whatsapp_send_status_unreadable' } end
        local entry = entries[index]
        if type(answer.served_by) == 'string' and answer.served_by ~= '' then entry.served_by = answer.served_by end
        if type(answer.asked_owner) == 'string' then entry.asked_owner = answer.asked_owner end
        if answer.attempts ~= nil then entry.attempts = answer.attempts end
        local state = type(answer.state) == 'string' and answer.state or nil
        if answer.error == nil and state == 'done' then
          entry.state, entry.message_id, terminal[index] = 'done', answer.message_id, true
        elseif answer.error == nil and state and FAILED_STATES[state] then
          entry.state, entry.reason, terminal[index] = 'failed', answer.reason or state, true
        elseif answer.error then
          if tostring(answer.error) == 'whatsapp_send_unknown_id' then
            entry.state, entry.ok, entry.error, entry.reason, terminal[index] = 'failed', false,
              'whatsapp_send_unknown_id', 'whatsapp_send_unknown_id', true
            entry.note = 'the node that holds the account never allocated this id: nothing is queued under it'
          else
            -- One id's unreadable answer does not end the others' wait: it stays pending with its reason.
            entry.reason = tostring(answer.error)
            entry.queue_state = nil
          end
        elseif not state then
          entry.reason = 'whatsapp_send_status_unreadable'
        elseif type(answer.state) == 'string' then
          entry.queue_state = answer.state
        end
      end
    end
    local total = count()
    if total == #ids then return finish(nil) end
    if options['until'] == 'any' and total > 0 then return finish(nil) end
    local left = wait_s - (clock_s() - started)
    if left <= 0 then return finish(nil) end
    sleep(math.min(pause, left))
    pause = math.min(pause * 2, M.WAIT.cap_s)
  end
end

--- `mcp_whatsapp_send`: two shapes, one tool.
---
---   {chat, text, reply_to?, mentions?, wait_s?}  queue the message, then wait for its outcome;
---   {id, wait_s?} or {ids:[...], until?, wait_s?}  wait for jobs an earlier call answered - never sends.
---
--- The id is the handle, and that is what makes this safe to repeat: a resume touches no queue at all,
--- and a repeated chat+text+reply_to is deduped into the job it already queued (`wa-queue` `dedupe`), so
--- a timeout, a retry of it and a dropped connection all end on the same one message.
function M.send(args, ctx)
  args = args or {}
  local wait_s = M.wait_budget(args.wait_s, ctx)
  local mode = args['until']
  if mode ~= nil and mode ~= 'all' and mode ~= 'any' then
    return { ok = false, error = 'whatsapp_send_bad_until', effect = 'none',
      note = 'until is "all" (the default: wait for every id) or "any" (answer as soon as one is done or failed)' }
  end
  if args.ids ~= nil then
    local ids = {}
    if type(args.ids) ~= 'table' then
      return { ok = false, error = 'whatsapp_send_bad_ids', effect = 'none',
        note = 'ids is a list of 1..20 job ids a previous mcp_whatsapp_send answered; a resume sends nothing' }
    end
    for _, item in ipairs(args.ids) do
      local id = tonumber(item)
      if not id or id < 1 then
        return { ok = false, error = 'whatsapp_send_bad_ids', effect = 'none',
          note = 'ids holds job ids (whole numbers >= 1) and nothing else; a resume sends nothing' }
      end
      ids[#ids + 1] = id
    end
    if #ids == 0 or #ids > 20 then
      return { ok = false, error = 'whatsapp_send_bad_ids', effect = 'none',
        note = 'ids holds 1..20 job ids; ask again with the ids a previous send answered' }
    end
    if args.chat ~= nil or args.text ~= nil then
      return { ok = false, error = 'whatsapp_send_id_or_message', effect = 'none',
        note = 'with ids this call only waits: pass chat+text to send a message, or ids alone to resume a wait' }
    end
    return M.settle_many(ids, wait_s, M.status_reader(nil, ctx), wait_options(ctx, M.self_name(), mode))
  end
  if args.id ~= nil then
    local id = tonumber(args.id)
    if not id then
      return { ok = false, error = 'whatsapp_send_bad_id', effect = 'none',
        note = 'id is the job id a previous mcp_whatsapp_send answered; a resume sends nothing' }
    end
    if args.chat ~= nil or args.text ~= nil then
      return { ok = false, error = 'whatsapp_send_id_or_message', effect = 'none',
        note = 'with an id this call only waits: pass chat+text to send a message, or id alone to resume a wait' }
    end
    return M.settle(id, wait_s, M.status_reader(nil, ctx), wait_options(ctx, M.self_name()))
  end
  if args.chat == nil and args.text == nil then
    return { ok = false, error = 'whatsapp_send_chat_text_required', effect = 'none',
      note = 'send a message with chat+text, or resume a wait with the id a previous send answered' }
  end
  local tool = M.by_verb.send
  local queued = M.invoke(tool, args)
  local owner = nil
  if queued.error == 'whatsapp_component_absent' then
    local refusal
    owner, refusal = route_owner(queued, ctx)
    if not owner then return refusal end
    -- One short remote call, not one long one: the account node queues and answers at once
    -- (`wait_s = 0`), and the wait itself is this node asking for the state, one short read at a time.
    local request = tool.request(args)
    request.wait_s = 0
    queued = M.forward(owner, tool.name, request, ctx and ctx.remote_call or nil)
    if queued.error == 'whatsapp_owner_unreachable' then
      -- The owner may have queued it: a lost answer is not a lost message. The dedupe key is what makes
      -- the retry safe - the same chat+text+reply_to is the same job, so it cannot become a second send.
      queued.effect = 'unknown'
      queued.note = 'the account node did not answer: the message may be queued on ' .. owner
        .. ' - repeating the same chat+text+reply_to is safe, it is the same job'
      return queued
    end
    queued.asked_owner = owner
  end
  if queued.error then return queued end
  local id = tonumber(queued.id) or queued.id
  if id == nil then
    return { ok = false, error = 'whatsapp_send_no_id', effect = 'unknown',
      detail = tostring(queued.note or 'the account node answered no job id') }
  end
  return M.settle(id, wait_s, M.status_reader(owner, ctx), wait_options(ctx, owner or M.self_name()))
end

--- The hidden compatibility alias: `mcp_whatsapp_send({id})` and no wait - one state read, answered with
--- the same `pending`/`done`/`failed` shape the send itself gives. No catalogue or guidance offers it;
--- a script written before a send answered its own outcome keeps working through it.
function M.status(args, ctx)
  args = args or {}
  local id = tonumber(args.id)
  if not id then return { ok = false, error = 'whatsapp_send_id_required', effect = 'none' } end
  return M.settle(id, 0, M.status_reader(nil, ctx), wait_options(ctx, M.self_name()))
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
  -- Two verbs are more than one capability call: a send queues and then waits for its outcome in the
  -- same step, and the hidden alias is that resume with no wait (operator decision, 11/11).
  if tool.verb == 'send' then return M.send(args, ctx) end
  if tool.verb == 'send_status' then return M.status(args, ctx) end
  local decoded = M.invoke(tool, args)
  if decoded.error ~= 'whatsapp_component_absent' then return decoded end
  -- Every verb, read or effect, is the account node's question to answer: the effect happens where the
  -- worker is, under the owner's own guards, and the answer that comes back keeps its shape plus
  -- `served_by` (a refusal from the owner travels unchanged).
  local owner, refusal = route_owner(decoded, ctx)
  if not owner then return refusal end
  local routed = M.forward(owner, tool.name, args, ctx and ctx.remote_call or nil)
  -- Say who answered, and that this node asked them: an answer served by another node is still this
  -- tool's answer, and the caller should not have to guess why it took a hop.
  if type(routed) == 'table' then routed.asked_owner = owner end
  return routed
end

return M
