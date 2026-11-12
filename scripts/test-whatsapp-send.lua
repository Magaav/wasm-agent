-- The explicit WhatsApp send, as the model sees it and as the node queues it. Model-free, hermetic:
-- nothing here connects to WhatsApp, and the only writes go to this run's private WASM_AGENT_HOME.
--
-- What it pins (`docs/HOST.md`, `docs/SERVICE-COMPONENTS.md`):
--
--   * the two tools exist as master tools, with the shape the docs promise: `chat`/`text` required,
--     `reply_to`/`mentions` optional, and `mcp_whatsapp_send_status` read-only (an id argument only);
--   * both have a discovery cue (`scripts/test-tool-cues.lua` also checks the registry-wide rule);
--   * a guest may not send: the tool is master-only;
--   * a refusal is a word, not a silent success - a bare phone number is `whatsapp_send_bad_chat`, a
--     `@broadcast` chat is `whatsapp_send_unsupported_chat`, and an id this node never allocated is
--     `whatsapp_send_unknown_id`;
--   * when the binary carries the capability, one valid request is really queued and the status read
--     answers with the job's state - the producer half of the round trip the component completes
--     (`rust/wa-whatsapp-outbox/tests/outbox_roundtrip.rs`).
--
-- A binary that predates the capability is not a failure of this test: it is reported as skipped, in
-- its own words, so nobody reads "ok" as "the send path was exercised here".
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function skip(label) skipped = skipped + 1; print("skip " .. label) end
-- `codemode_nested` is the in-script path: these are connector tools, so a direct call is pointed
-- at code mode when the run has it, and the call made from inside a script is the one measured here.
local ctx = { user_id = "master", role = "master", codemode_nested = true }
local function call(name, args, role) return tools.dispatch(memory, name, args, role or "master", ctx) end

-- ---- the contract copies the component composes --------------------------------------------------
-- `rust/components/wa-whatsapp/wit` is its own world because wit-bindgen resolves a world's
-- dependencies from `wit/deps/`; the two published contracts it composes are copied there. A copy that
-- silently drifts from `wit/kernel-v2` or `wit/queue` is a component built against a contract nobody
-- publishes, so the copies are compared byte for byte here.
for _, pair in ipairs({
  { "wit/kernel-v2/kernel.wit", "rust/components/wa-whatsapp/wit/deps/kernel.wit" },
  { "wit/kernel-v2/deps/clocks.wit", "rust/components/wa-whatsapp/wit/deps/clocks.wit" },
  { "wit/queue/queue.wit", "rust/components/wa-whatsapp/wit/deps/queue/queue.wit" },
}) do
  local published = host.read_file(pair[1])
  local copy = host.read_file(pair[2])
  ok(type(published) == "string" and type(copy) == "string", "both copies of " .. pair[1] .. " are readable")
  ok(published == copy, "the component's copy of " .. pair[1] .. " is the published contract, byte for byte")
end
-- The component's world composes those two contracts and nothing else: a third import would be a
-- capability the manifest does not grant.
local world = host.read_file("rust/components/wa-whatsapp/wit/wa.wit") or ""
ok(world:find("include wa:kernel/service-component@0.2.0;", 1, true) ~= nil, "the world includes the kernel service contract")
ok(world:find("import wa:queue/worker@0.1.0;", 1, true) ~= nil, "the world imports the outbox's worker interface")
ok(world:find("wa:queue/producer", 1, true) == nil, "the component never produces on its own outbox")
-- The image reader (`docs/WHATSAPP-OCR.md`): the cutover finding was that the component imported no
-- vision interface at all, so turning the native connector off silently dropped image OCR. The
-- import, the published interface and the manifest grant are one fact, so all three are pinned.
ok(world:find("import wa:kernel/vision@0.2.0;", 1, true) ~= nil, "the world imports the kernel's OCR reader")
local kernel_contract = host.read_file("wit/kernel-v2/kernel.wit") or ""
ok(kernel_contract:find("interface vision", 1, true) ~= nil, "the reader is a published interface")
ok(kernel_contract:find("read: async func(image: list<u8>, mime: string)", 1, true) ~= nil,
  "the reader takes the image bytes and its media type, like the seams text-reader")

-- The component's manifest grants that one namespace and nothing else: the host reads `consume` as the
-- worker interface (`queue_host::Grants::from_manifest`), and a component granted more than it needs is
-- a component that can settle or requeue work it did not do.
local manifest = json.decode(host.read_file("rust/components/wa-whatsapp/manifest.json") or "{}")
local grant = type(manifest) == "table" and manifest.capabilities and manifest.capabilities.queue or {}
ok(json.encode(grant):find("whatsapp.outbox", 1, true) ~= nil, "the component is granted the outbox queue")
ok(grant.consume ~= nil or grant.interfaces ~= nil, "the queue grant names the interface it uses")
ok(grant.produce == nil and json.encode(grant):find("admin", 1, true) == nil,
  "the component neither produces on its own outbox nor administers it")
ok((manifest.capabilities or {}).stt == true, "the transcription grant is untouched")
ok((manifest.capabilities or {}).ocr == true, "the OCR grant the vision call is checked against is declared")

-- ---- the tool shape -----------------------------------------------------------------------------
local schemas = {}
for _, item in ipairs(tools.catalog("master")) do schemas[item["function"].name] = item["function"] end
for _, name in ipairs({ "mcp_whatsapp_send", "mcp_whatsapp_send_status" }) do
  ok(schemas[name] ~= nil, name .. " is a catalogued master tool")
  ok(tools.snippet(name) ~= nil, name .. " has a discovery cue")
end
local send = schemas.mcp_whatsapp_send
local params = send.parameters
ok(params.type == "object", "mcp_whatsapp_send takes an object")
ok(params.properties.chat ~= nil and params.properties.text ~= nil, "mcp_whatsapp_send takes chat and text")
ok(params.properties.reply_to ~= nil and params.properties.mentions ~= nil, "mcp_whatsapp_send takes reply_to and mentions")
ok(params.properties.mentions.type == "array" and params.properties.mentions.maxItems == 64, "mentions are a bounded array")
ok(params.properties.text.maxLength == 65536, "text has the same bound the queue enforces")
ok(#params.required == 2 and params.required[1] == "chat" and params.required[2] == "text",
  "chat and text are the required arguments")
ok(send.description:find("exact chat", 1, true) ~= nil, "the description says chat is exact")
ok(send.description:find("mcp_whatsapp_send_status", 1, true) ~= nil, "the description points at the status read")
ok(schemas.mcp_whatsapp_send_status.parameters.properties.id ~= nil, "the status tool takes an id")
ok(#schemas.mcp_whatsapp_send_status.parameters.required == 1, "the id is required for a status read")

-- An effect that is not a read, and a read that is: this is what keeps a status poll out of the
-- "did the agent change something" question and keeps a send inside it.
ok(tools.has_effect("mcp_whatsapp_send") == true, "mcp_whatsapp_send is an effect")
ok(tools.has_effect("mcp_whatsapp_send_status") == false, "mcp_whatsapp_send_status is a read")

-- The tool is master-only, and a refusal never becomes a quiet nothing.
ok(call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "oi" }, "guest").error == "forbidden_for_role:guest",
  "a guest may not send from the operator's account")
ok(call("mcp_whatsapp_send_status", { id = 1 }, "guest").error == "forbidden_for_role:guest",
  "a guest may not read the outbox")

-- ---- the capability, when this binary has it ----------------------------------------------------
if type(host.whatsapp_send) ~= "function" then
  ok(call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "oi" }).error == "mcp_whatsapp_send_unavailable",
    "a binary without the capability answers unavailable, not a silent success")
  ok(call("mcp_whatsapp_send_status", { id = 1 }).error == "mcp_whatsapp_send_status_unavailable",
    "the status read says the same")
  skip("the producer/queue half: this binary has no host.whatsapp_send")
else
  ok(type(host.whatsapp_send_status) == "function", "the capability has its status read beside it")

  -- A refusal is a word. A bare number is not an exact JID, and a status address is not sendable.
  local bare = call("mcp_whatsapp_send", { chat = "5511999999999", text = "oi" })
  ok(bare.ok ~= true and bare.error == "whatsapp_send_bad_chat", "a bare phone number is refused: " .. json.encode(bare))
  ok(bare.effect == "none", "a refused send has no effect")
  local broadcast = call("mcp_whatsapp_send", { chat = "5511999999999@broadcast", text = "oi" })
  ok(broadcast.error == "whatsapp_send_unsupported_chat", "a status/broadcast chat is refused")
  local empty = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "" })
  ok(empty.error == "whatsapp_send_empty_text", "an empty body is refused")

  -- The real enqueue: one valid request, into this run's private home.
  local queued = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "outbox fixture" })
  if queued.ok ~= true then
    -- No node policy file here (manifest mode), so a refusal would be a store failure: report it
    -- rather than passing silently.
    error("the send was not queued: " .. json.encode(queued))
  end
  ok(type(queued.id) == "number" and queued.id > 0, "the send answers a job id")
  ok(queued.state == "queued", "the send answers the job state, not a delivery claim")
  ok(queued.queue == "whatsapp.outbox", "the queue name is the one the component consumes")
  ok(queued.fresh_for_ms == 300000, "freshness is the five-minute window the brief fixes")

  -- The same request is the same job: no double send from a repeated tool call.
  local again = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "outbox fixture" })
  ok(again.id == queued.id and again.deduped == true, "the same chat+text+reply_to is one job")

  -- The status read answers the job's state and never the text.
  local status = call("mcp_whatsapp_send_status", { id = queued.id })
  ok(status.ok == true and status.id == queued.id, "the status read answers the job")
  ok(status.state == "queued" or status.state == "leased" or status.state == "done",
    "the state is one of the words the docs promise: " .. json.encode(status))
  ok(json.encode(status):find("outbox fixture", 1, true) == nil, "the status read never returns the message text")

  local unknown = call("mcp_whatsapp_send_status", { id = 999999999 })
  ok(unknown.error == "whatsapp_send_unknown_id", "an id this node never allocated is refused")
end

print("whatsapp send ok (" .. checks .. " checks, " .. skipped .. " skipped)")
