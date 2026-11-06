-- The WhatsApp message index, as the model sees it and as the node asks for it. Model-free, hermetic:
-- nothing here connects to WhatsApp, and the only writes go to this run's private WASM_AGENT_HOME.
--
-- What it pins (`docs/HOST.md`, `docs/SERVICE-COMPONENTS.md` "The message index"):
--
--   * the five tools exist as master tools with the shapes the docs promise, each with a discovery
--     cue, and every one of them but `whatsapp_download` is a read;
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
local ctx = { user_id = "master", role = "master" }
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
local schemas = {}
for _, item in ipairs(tools.catalog("master")) do schemas[item["function"].name] = item["function"] end
for _, name in ipairs({ "whatsapp_search", "whatsapp_read", "whatsapp_reactions", "whatsapp_media", "whatsapp_download" }) do
  ok(schemas[name] ~= nil, name .. " is a catalogued master tool")
  ok(tools.snippet(name) ~= nil, name .. " has a discovery cue")
  ok(schemas[name].parameters.type == "object", name .. " takes an object")
  ok(tools.has_effect(name) == (name == "whatsapp_download"), name .. " is a read unless it is the download")
end

local search = schemas.whatsapp_search.parameters
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
local read = schemas.whatsapp_read.parameters
ok(read.properties.chat ~= nil and read.properties.before ~= nil, "read takes chat and before")
ok(read.properties.limit.maximum == 100, "read returns at most 100 messages")
ok(#read.required == 1 and read.required[1] == "chat", "chat is the one required argument of a read")
for _, name in ipairs({ "whatsapp_reactions", "whatsapp_media", "whatsapp_download" }) do
  local params = schemas[name].parameters
  ok(params.properties.chat ~= nil and params.properties.id ~= nil, name .. " takes chat and id")
  ok(#params.required == 2, name .. " requires both")
end
ok(schemas.whatsapp_download.parameters.properties.max_bytes.maximum == 524288,
  "a download is bounded by the same 512 KiB the queue's progress stream can carry")
ok(schemas.whatsapp_media.description:find("media key", 1, true) ~= nil,
  "the media tool says it never returns the key")
ok(schemas.whatsapp_download.description:find("bounded", 1, true) ~= nil, "the download tool says it is bounded")
ok(schemas.whatsapp_read.description:find("next_before", 1, true) ~= nil, "the read tool documents its cursor")

-- Master-only: the index is the operator's own conversations.
for _, name in ipairs({ "whatsapp_search", "whatsapp_read", "whatsapp_reactions", "whatsapp_media", "whatsapp_download" }) do
  local refused = call(name, { q = "x", chat = "5511999999999@lid", id = "3EB0" }, "guest")
  ok(refused.error == "forbidden_for_role:guest", "a guest may not call " .. name)
end

-- ---- the capability, when this binary has it ------------------------------------------------------
if type(host.whatsapp_search) ~= "function" then
  for _, name in ipairs({ "whatsapp_search", "whatsapp_read", "whatsapp_reactions", "whatsapp_media", "whatsapp_download" }) do
    ok(call(name, { q = "x", chat = "5511999999999@lid", id = "3EB0" }).error == name .. "_unavailable",
      "a binary without the capability answers unavailable, not a silent success: " .. name)
  end
  skip("the producer half of whatsapp.query: this binary has no host.whatsapp_search")
else
  -- A refusal is a word, and it happens before the queue: nothing is written for a request that never
  -- validated.
  local empty = call("whatsapp_search", {})
  ok(empty.ok ~= true and empty.error == "whatsapp_search_empty_query", "a search needs a narrowing: " .. json.encode(empty))
  ok(empty.effect == "none", "a refused search has no effect")
  local bare = call("whatsapp_read", { chat = "5511999999999" })
  ok(bare.error == "whatsapp_read_bad_chat", "a bare phone number is not an exact JID")
  local kind = call("whatsapp_search", { q = "x", kind = "gif" })
  ok(kind.error == "whatsapp_search_bad_kind", "an unknown kind is refused")
  local no_id = call("whatsapp_reactions", { chat = "5511999999999@lid" })
  ok(no_id.error == "whatsapp_reactions_chat_and_id_required", "one message needs chat and id")

  -- The real enqueue, into this run's private home. Nothing consumes it here (the component is not
  -- running), so the answer is the honest "still running, here is the id" - and the same call again
  -- reads the same job instead of queueing a second scan.
  local slow = call("whatsapp_search", { q = "boleto", chat = "5511999999999@lid" })
  if slow.ok == true then
    -- A node that does run the component answers the question instead: also fine, and prove it is an
    -- answer rather than a queue receipt.
    ok(slow.op == "search" and type(slow.hits) == "table", "the search answered with its hits")
  else
    ok(slow.error == "whatsapp_search_slow", "an unanswered query says so: " .. json.encode(slow))
    ok(slow.retry == true, "the slow answer tells the caller it can ask again")
    ok(type(slow.id) == "number" and slow.id > 0, "the slow answer carries the job id")
    ok(slow.state == "queued", "the state is the word the docs promise: 'queued'")
    local again = call("whatsapp_search", { q = "boleto", chat = "5511999999999@lid" })
    ok(again.id == slow.id, "the same question is the same job")
    ok(json.encode(slow):find("boleto", 1, true) == nil, "an answer never echoes the query text")
  end
end

print("whatsapp index ok (" .. checks .. " checks, " .. skipped .. " skipped)")
