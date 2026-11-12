-- The WhatsApp message index, as the model sees it and as the node asks for it. Model-free, hermetic:
-- nothing here connects to WhatsApp, and the only writes go to this run's private WASM_AGENT_HOME.
--
-- What it pins (`docs/HOST.md`, `docs/SERVICE-COMPONENTS.md` "The message index"):
--
--   * the six tools exist as master tools with the shapes the docs promise, each with a discovery
--     cue, and every one of them but `whatsapp_download` and `whatsapp_backfill` is a read (both ask
--     the component to do something, so neither may pass the steering fence as read-only);
--   * a guest may not query the operator's message index;
--   * a refusal is a word, not a silent success - a search with no narrowing, a bare phone number, an
--     unknown kind - and a refusal never writes a job;
--   * when the binary carries the capability, one valid query is really queued on `whatsapp.query`
--     and the answer to a component that has not settled it is "still running, here is the id";
--   * the component's own contract: its world imports the queue `worker` and never the `producer`, and
--     its manifest grants exactly the two namespaces it consumes;
--   * the node policy rules the index prefix the component writes (`ix/*`), because a prefix the
--     shipped policy does not rule is a write refused with `no_policy` the moment one is installed.
--
-- The index itself (records, tokens, ranking, retention) is measured in Rust, where a fake client can
-- build the messages: `rust/components/wa-whatsapp` (`cargo test --lib`, `src/index/tests.rs`).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function skip(label) skipped = skipped + 1; print("skip " .. label) end
-- `codemode_nested` is the in-script path: these names are connectors, so a direct call is pointed
-- at code mode when the run has it (`lua/core/codemode_policy.lua`), and the call made from inside a
-- script is the one this file measures.
local ctx = { user_id = "master", role = "master", codemode_nested = true }
local function call(name, args, role) return tools.dispatch(memory, name, args, role or "master", ctx) end

-- ---- the component's contract ---------------------------------------------------------------------
-- The component composes the published contracts from `wit/deps/` and imports the queue's `worker`
-- interface only: a `producer` import would be a capability its manifest does not grant, and a copy
-- that drifts from `wit/queue` is a component built against a contract nobody publishes. The byte-for
-- -byte comparison of the three copies lives in `scripts/test-whatsapp-send.lua`; this file pins what
-- this change added to them.
local world = host.read_file("rust/components/wa-whatsapp/wit/wa.wit") or ""
ok(world:find("import wa:queue/worker@0.1.0;", 1, true) ~= nil, "the world imports the queue worker interface")
ok(world:find("wa:queue/producer", 1, true) == nil, "the component never produces on a queue")

local manifest = json.decode(host.read_file("rust/components/wa-whatsapp/manifest.json") or "{}")
local grant = type(manifest) == "table" and manifest.capabilities and manifest.capabilities.queue or {}
local consume = grant.consume or {}
ok(json.encode(consume):find("whatsapp.query", 1, true) ~= nil, "the component is granted the query queue")
ok(json.encode(consume):find("whatsapp.outbox", 1, true) ~= nil, "the outbox grant is untouched")
ok(grant.produce == nil and json.encode(grant):find("admin", 1, true) == nil,
  "the component neither produces nor administers a queue")
ok(json.encode(manifest.capabilities):find("ix/", 1, true) == nil, "the index prefix is a policy rule, not a grant")

-- The shipped policy rules the prefix the index writes, and still refuses somebody else's keys.
local policy = json.decode(host.read_file("policies/default.json") or "{}")
local component = type(policy) == "table" and policy.components and policy.components["wa-whatsapp"] or {}
local allow = component.capabilities and component.capabilities["kv.write"] and component.capabilities["kv.write"].allow or {}
local ruled = false
for _, prefix in ipairs(allow) do if prefix == "ix/*" then ruled = true end end
ok(ruled, "policies/default.json rules the index prefix (ix/*) for wa-whatsapp")
ok(component.capabilities["whatsapp.send"] ~= nil, "the send rule is untouched")

-- ---- the tool shape -------------------------------------------------------------------------------
--
-- One surface (#118): nine exact names on every node, `mcp_whatsapp_<verb>`, with no namespace hash and
-- no peer prefix. The names are computed here rather than copied, so a rename in the facade fails this
-- row instead of drifting away from it.
local whatsapp = dofile("lua/core/whatsapp.lua")
-- Eight verbs are offered to the model and one is hidden: `mcp_whatsapp_send_status` is the resume form
-- of `mcp_whatsapp_send` ({id, wait_s:0}), callable so an old script keeps working and in no catalogue.
local VERBS = { "contacts", "search", "read", "reactions", "media", "download", "backfill", "send" }
local HIDDEN = { "send_status" }
local schemas = {}
for _, item in ipairs(tools.catalog("master")) do schemas[item["function"].name] = item["function"] end
ok(#whatsapp.TOOLS == #VERBS + #HIDDEN, "the surface offers one tool per verb, plus its hidden alias")
for _, verb in ipairs(VERBS) do
  local name = "mcp_whatsapp_" .. verb
  ok(whatsapp.name(verb) == name, "the " .. verb .. " tool is named exactly " .. name)
  ok(schemas[name] ~= nil, name .. " is a catalogued master tool")
  ok(tools.snippet(name) ~= nil, name .. " has a discovery cue")
  ok(schemas[name].parameters.type == "object", name .. " takes an object")
end
for _, verb in ipairs(HIDDEN) do
  local name = "mcp_whatsapp_" .. verb
  ok(whatsapp.name(verb) == name, "the " .. verb .. " tool is named exactly " .. name)
  ok(whatsapp.tool(name) ~= nil, name .. " is still callable, so an old script keeps working")
  ok(whatsapp.hidden(name) == true, name .. " is the surface's hidden alias")
  ok(schemas[name] == nil, name .. " is in no catalogue the model is offered")
  ok(tools.snippet(name) == nil, name .. " has no discovery cue")
end
for _, verb in ipairs(VERBS) do
  local name = "mcp_whatsapp_" .. verb
  local read = (verb == "contacts" or verb == "search" or verb == "read" or verb == "reactions" or verb == "media")
  ok(tools.has_effect(name) == not read, name .. (read and " is a read" or " is an effect"))
end
ok(tools.has_effect("mcp_whatsapp_send_status") == false, "mcp_whatsapp_send_status is a read")
-- The spellings this change retired are not in the catalogue at all: no `peer_*` WhatsApp family, no
-- namespace hash, and no bare `whatsapp_*` tool.
for name in pairs(schemas) do
  local lower = name:lower()
  ok(not (lower:find("__whatsapp", 1, true) or lower:find("__mcp_whatsapp", 1, true)),
    "no peer-prefixed WhatsApp tool is catalogued: " .. name)
  ok(not (lower:sub(1, 13) == "mcp_whatsapp_" and lower:match("_%x%x%x%x%x%x%x%x$") ~= nil),
    "no hashed WhatsApp tool name is catalogued: " .. name)
  ok(not (lower:sub(1, 9) == "whatsapp_"), "no bare whatsapp_* tool is catalogued: " .. name)
end

local contacts = schemas.mcp_whatsapp_contacts.parameters
ok(contacts.properties.q ~= nil and contacts.properties.q.maxLength == 80,
  "contacts takes a bounded name to resolve")
ok(contacts.required == nil or #contacts.required == 0, "contacts needs no argument: no query lists the chats")
ok((schemas.mcp_whatsapp_contacts.description or ""):find("ambiguous", 1, true) ~= nil,
  "contacts says several matches are listed, not resolved")

local search = schemas.mcp_whatsapp_search.parameters
ok(search.properties.q ~= nil and search.properties.chat ~= nil and search.properties.kind ~= nil,
  "search takes q, chat and kind")
ok(search.properties["from"] ~= nil and search.properties["since"] ~= nil and search.properties["until"] ~= nil,
  "search takes from, since and until")
ok(search.properties.q.maxLength == 200, "q is bounded at 200 characters")
ok(search.properties.limit.maximum == 50, "search returns at most 50 hits")
local kinds = {}
for _, kind in ipairs(search.properties.kind.enum) do kinds[kind] = true end
for _, kind in ipairs({ "text", "image", "video", "audio", "voice", "document", "sticker", "location", "contact", "poll", "reaction", "edit", "delete" }) do
  ok(kinds[kind] == true, "search can narrow to the " .. kind .. " kind")
end
local read = schemas.mcp_whatsapp_read.parameters
ok(read.properties.chat ~= nil and read.properties.before ~= nil, "read takes chat and before")
ok(read.properties.limit.maximum == 100, "read returns at most 100 messages")
ok(#read.required == 1 and read.required[1] == "chat", "chat is the one required argument of a read")
ok((schemas.mcp_whatsapp_read.description or ""):find("name", 1, true) ~= nil,
  "read says a name is resolved, not only a JID")
ok((schemas.mcp_whatsapp_read.description or ""):find("next_before", 1, true) ~= nil,
  "the read tool documents its cursor")
for _, name in ipairs({ "mcp_whatsapp_reactions", "mcp_whatsapp_media", "mcp_whatsapp_download" }) do
  local params = schemas[name].parameters
  ok(params.properties.chat ~= nil and params.properties.id ~= nil, name .. " takes chat and id")
  ok(#params.required == 2, name .. " requires both")
end
ok(schemas.mcp_whatsapp_download.parameters.properties.max_bytes.maximum == 524288,
  "a download is bounded by the same 512 KiB the queue's progress stream can carry")
ok(schemas.mcp_whatsapp_media.description:find("media key", 1, true) ~= nil,
  "the media tool says it never returns the key")
ok(schemas.mcp_whatsapp_download.description:find("bounded", 1, true) ~= nil, "the download tool says it is bounded")
ok(schemas.mcp_whatsapp_send.description:find("exact", 1, true) ~= nil,
  "a send takes an exact JID, never a name: a recipient is not resolved by guessing")

-- backfill: the one query that asks the phone. `chat` and `count` are both optional (the index knows
-- which chats to ask for), the count is bounded at the component's own maximum, and nothing about the
-- shape lets a caller skip the request bound.
local backfill = schemas.mcp_whatsapp_backfill.parameters
ok(backfill.properties.chat ~= nil and backfill.properties.count ~= nil, "backfill takes chat and count")
ok(backfill.required == nil or #backfill.required == 0, "backfill needs no argument: no chat means the known chats")
ok(backfill.properties.count.minimum == 1 and backfill.properties.count.maximum == 500,
  "backfill asks for 1 to 500 messages per chat")
ok(schemas.mcp_whatsapp_backfill.description:find("history", 1, true) ~= nil,
  "the backfill tool says the messages land in the index")

-- Master-only: the index is the operator's own conversations.
for _, verb in ipairs(VERBS) do
  local name = "mcp_whatsapp_" .. verb
  local refused = call(name, { q = "x", chat = "5511999999999@lid", id = "3EB0", text = "x", count = 1 }, "guest")
  ok(refused.error == "forbidden_for_role:guest", "a guest may not call " .. name)
end

-- A name from an older build is refused with the name to use instead, never answered twice.
for old, replacement in pairs({
  ["whatsapp_read"] = "mcp_whatsapp_read", whatsapp_search = "mcp_whatsapp_search",
  ["peer_openclaw__whatsapp_read"] = "mcp_whatsapp_read",
  ["peer_openclaw__whatsapp_search"] = "mcp_whatsapp_search",
  ["mcp_whatsapp_native_read_newest_47452e4e"] = "mcp_whatsapp_read",
  ["mcp_whatsapp_native_read_snapshot_47452e4e"] = "mcp_whatsapp_search",
}) do
  local refusal = call(old, { chat = "5511999999999@lid" })
  ok(refusal.error == "whatsapp_tool_renamed", old .. " is refused as renamed: " .. json.encode(refusal))
  ok(refusal.use == replacement, old .. " names its replacement: " .. json.encode(refusal))
  ok(refusal.effect == "none", "a renamed tool changes nothing")
end

-- ---- the capability, when this binary has it ------------------------------------------------------
if type(host.whatsapp_search) ~= "function" then
  for _, verb in ipairs(VERBS) do
    local name = "mcp_whatsapp_" .. verb
    ok(call(name, { q = "x", chat = "5511999999999@lid", id = "3EB0", text = "x", count = 1, id = 1 }).error
      == name .. "_unavailable",
      "a binary without the capability answers unavailable, not a silent success: " .. name)
  end
  skip("the producer half of whatsapp.query: this binary has no host.whatsapp_search")
else
  -- A refusal is a word, and it happens before the queue: nothing is written for a request that never
  -- validated.
  local empty = call("mcp_whatsapp_search", {})
  ok(empty.ok ~= true and empty.error == "whatsapp_search_empty_query", "a search needs a narrowing: " .. json.encode(empty))
  ok(empty.effect == "none", "a refused search has no effect")
  -- An address-shaped chat still belongs to the exact-JID rule, in every op.
  local bad = call("mcp_whatsapp_read", { chat = "1-2-3@g.us" })
  ok(bad.error == "whatsapp_read_bad_chat", "an address-shaped chat keeps the exact-JID refusal")
  local kind = call("mcp_whatsapp_search", { q = "x", kind = "gif" })
  ok(kind.error == "whatsapp_search_bad_kind", "an unknown kind is refused")
  local no_id = call("mcp_whatsapp_reactions", { chat = "5511999999999@lid" })
  ok(no_id.error == "whatsapp_reactions_chat_and_id_required", "one message needs chat and id")
  local bare_backfill = call("mcp_whatsapp_backfill", { chat = "5511999999999", count = 10 })
  ok(bare_backfill.error == "whatsapp_backfill_bad_chat", "a backfill's chat is an exact JID too")
  local bare_send = call("mcp_whatsapp_send", { chat = "5511999999999", text = "oi" })
  ok(bare_send.error == "whatsapp_send_bad_chat", "a send's chat is an exact JID: a name is resolved first")

  -- A name is a *question*, not a bad argument: it is queued for the index to resolve (#117). This
  -- process runs no component, so the honest answer is "still running, here is the id".
  local named = call("mcp_whatsapp_read", { chat = "Laura" })
  if named.ok == true then
    ok(named.header ~= nil and type(named.messages) == "table", "a name was resolved and read")
  elseif named.error == "whatsapp_read_bad_chat" then
    -- A binary whose host.whatsapp_read predates name resolution: the Rust contract is measured in
    -- `cargo test` (`rust/components/wa-whatsapp/src/index/tests.rs`), and this row says so instead of
    -- pretending it saw the behaviour.
    skip("read by name: this binary's host.whatsapp_read predates name resolution")
  else
    ok(named.error == "whatsapp_read_slow", "a name is queued, not refused: " .. json.encode(named))
    ok(named.retry == true and type(named.id) == "number", "the slow answer carries the job and says it can be read again")
  end

  -- A backfill with no chat is a valid request: it asks for the chats the index already knows. Nothing
  -- consumes the job here, so the answer is the honest "still running" and not an invented count.
  local fill = call("mcp_whatsapp_backfill", { count = 25 })
  if fill.ok == true then
    ok(type(fill.chats) == "table" and type(fill.count) == "number", "the backfill answered with its request list")
    ok(fill.messages == nil, "a backfill answer never carries a message")
  else
    ok(fill.error == "whatsapp_backfill_slow", "an unanswered backfill says so: " .. json.encode(fill))
    ok(type(fill.id) == "number" and fill.id > 0, "the slow backfill carries the job id")
    local again = call("mcp_whatsapp_backfill", { count = 25 })
    ok(again.id == fill.id, "the same backfill question is the same job")
    local other = call("mcp_whatsapp_backfill", { count = 26 })
    ok(other.id ~= fill.id, "a different count is a different request, so it is a different job")
  end

  -- The real enqueue, into this run's private home. Nothing consumes it here (the component is not
  -- running), so the answer is the honest "still running, here is the id" - and the same call again
  -- reads the same job instead of queueing a second scan.
  local slow = call("mcp_whatsapp_search", { q = "boleto", chat = "5511999999999@lid" })
  if slow.ok == true then
    ok(slow.op == "search" and type(slow.hits) == "table", "the search answered with its hits")
  else
    ok(slow.error == "whatsapp_search_slow", "an unanswered query says so: " .. json.encode(slow))
    ok(slow.retry == true, "the slow answer tells the caller it can ask again")
    ok(type(slow.id) == "number" and slow.id > 0, "the slow answer carries the job id")
    ok(slow.state == "queued", "the state is the word the docs promise: 'queued'")
    local again = call("mcp_whatsapp_search", { q = "boleto", chat = "5511999999999@lid" })
    ok(again.id == slow.id, "the same question is the same job")
    ok(json.encode(slow):find("boleto", 1, true) == nil, "an answer never echoes the query text")
  end
end

print("whatsapp index ok (" .. checks .. " checks, " .. skipped .. " skipped)")
