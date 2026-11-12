-- The explicit WhatsApp send, as the model sees it and as the node queues it. Model-free, hermetic:
-- nothing here connects to WhatsApp, and the only writes go to this run's private WASM_AGENT_HOME.
--
-- What it pins (`docs/HOST.md`, `docs/SERVICE-COMPONENTS.md`):
--
--   * ONE tool answers its own outcome (operator decision, 11/11): `mcp_whatsapp_send` takes
--     chat/text (with `reply_to`/`mentions` optional) and waits for the job's terminal state - `done`
--     with the message id, `failed` with the reason, or `pending` with the id and the resume - and the
--     same tool resumes with `{id}` (or `{ids:[...]}`, 1..20) without ever sending again;
--   * `mcp_whatsapp_send_status` is that resume with `wait_s:0`: callable, read-only, master-only, and
--     in NO catalogue the model is offered;
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
ok(schemas.mcp_whatsapp_send ~= nil, "mcp_whatsapp_send is a catalogued master tool")
ok(tools.snippet("mcp_whatsapp_send") ~= nil, "the send has a discovery cue")
-- The hidden compatibility alias: callable, and in no catalogue the model is offered.
ok(schemas.mcp_whatsapp_send_status == nil, "mcp_whatsapp_send_status is not in the model's catalogue")
ok(tools.snippet("mcp_whatsapp_send_status") == nil, "and it has no discovery cue")
local whatsapp_lib = dofile("lua/core/whatsapp.lua")
ok(whatsapp_lib.hidden("mcp_whatsapp_send_status") == true, "it is the surface's hidden alias")
ok(whatsapp_lib.tool("mcp_whatsapp_send_status") ~= nil, "and it is still callable, so an old script works")
local send = schemas.mcp_whatsapp_send
local params = send.parameters
ok(params.type == "object", "mcp_whatsapp_send takes an object")
ok(params.properties.chat ~= nil and params.properties.text ~= nil, "mcp_whatsapp_send takes chat and text")
ok(params.properties.reply_to ~= nil and params.properties.mentions ~= nil, "mcp_whatsapp_send takes reply_to and mentions")
ok(params.properties.mentions.type == "array" and params.properties.mentions.maxItems == 64, "mentions are a bounded array")
ok(params.properties.text.maxLength == 65536, "text has the same bound the queue enforces")
-- One tool, two calls: no shape is "required", and the description says which is which.
ok(params.required == nil, "neither shape is required: chat+text sends, id/ids resumes")
ok(params.properties.id ~= nil and params.properties.ids ~= nil, "the resume arguments are in the schema")
ok(params.properties.ids.minItems == 1 and params.properties.ids.maxItems == 20, "ids is bounded 1..20")
ok(params.properties["until"] ~= nil and params.properties["until"].enum[1] == "all", "until says all or any")
ok(params.properties.wait_s.minimum == 0 and params.properties.wait_s.maximum == 300, "wait_s is bounded 0..300")
ok(send.description:find("exact chat", 1, true) ~= nil, "the description says chat is exact")
ok(send.description:find('state:"done"', 1, true) ~= nil, "the description names the done answer")
ok(send.description:find('state:"pending"', 1, true) ~= nil, "and the pending answer with its resume")
ok(send.description:find("mcp_whatsapp_send_status", 1, true) == nil,
  "the description never sends the model to a second tool")

-- An effect that is not a read, and a read that is: what keeps a wait out of the "did the agent change
-- something" question, and keeps a send inside it. The args decide, because it is one tool.
ok(tools.has_effect("mcp_whatsapp_send") == true, "mcp_whatsapp_send with no arguments is the effect")
ok(tools.has_effect("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "oi" }) == true,
  "a send is an effect, so it stays serialized under whatsapp.send")
ok(tools.has_effect("mcp_whatsapp_send", { id = 1 }) == false, "a resume with an id is a read")
ok(tools.has_effect("mcp_whatsapp_send", { ids = { 1, 2 } }) == false, "a batched resume is a read")
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

  -- The real enqueue: one valid request, into this run's private home. `wait_s:0` is what answers at
  -- once here - this hermetic home runs no component, so nothing would ever settle the job and a real
  -- wait would only spend the row's own timeout to learn that.
  local queued = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "outbox fixture", wait_s = 0 })
  if queued.ok ~= true then
    -- No node policy file here (manifest mode), so a refusal would be a store failure: report it
    -- rather than passing silently.
    error("the send was not queued: " .. json.encode(queued))
  end
  ok(type(queued.id) == "number" and queued.id > 0, "the send answers the job the queue allocated")
  ok(queued.state == "pending", "with no component here it answers pending, not a delivery claim: " .. json.encode(queued))
  ok(queued.queue_state == "queued", "and it says the queue holds the job as queued")
  ok(type(queued.waited_s) == "number", "a pending answer says how long it waited")
  ok(tostring(queued.resume):find("mcp_whatsapp_send({id:" .. tostring(queued.id), 1, true) ~= nil,
    "and how to resume: " .. tostring(queued.resume))
  ok(queued.message_id == nil, "pending claims no message id")

  -- The producer's own answer, read straight from the capability: the queue name and the freshness
  -- window are facts about the queue, not about the wait.
  local producer = json.decode(host.whatsapp_send(json.encode({ chat = "5511999999999@lid", text = "producer fixture" })))
  ok(producer.queue == "whatsapp.outbox", "the queue name is the one the component consumes")
  ok(producer.fresh_for_ms == 300000, "freshness is the five-minute window the brief fixes")

  -- The same request is the same job: no double send from a repeated tool call.
  local again = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "outbox fixture", wait_s = 0 })
  ok(again.id == queued.id and again.state == "pending", "the same chat+text+reply_to is one job")

  -- The status read (the hidden alias, = resume with wait_s:0) answers the job's state and never the text.
  local status = call("mcp_whatsapp_send_status", { id = queued.id })
  ok(status.ok == true and status.id == queued.id and status.state == "pending",
    "the status read answers the job: " .. json.encode(status))
  ok(status.queue_state == "queued" or status.queue_state == "leased" or status.queue_state == "done",
    "the state is one of the words the docs promise: " .. json.encode(status))
  ok(json.encode(status):find("outbox fixture", 1, true) == nil, "the status read never returns the message text")

  -- The pattern the operator asked for, against the REAL queue: three sends stay serialized (effects),
  -- each answers at once with wait_s:0, and ONE batched resume collects the three outcomes in the order
  -- asked - and queues nothing again.
  local batch_ids = {}
  for index, text in ipairs({ "batch one", "batch two", "batch three" }) do
    local answer = call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = text, wait_s = 0 })
    ok(answer.state == "pending" and type(answer.id) == "number", text .. " is queued and answered at once")
    batch_ids[index] = answer.id
  end
  ok(batch_ids[1] ~= batch_ids[2] and batch_ids[2] ~= batch_ids[3], "three different messages are three jobs")
  local batched = call("mcp_whatsapp_send", { ids = batch_ids, wait_s = 0 })
  ok(type(batched.results) == "table" and #batched.results == 3,
    "one batched resume answers three outcomes: " .. json.encode(batched))
  for index, id in ipairs(batch_ids) do
    ok(batched.results[index].id == id, "entry " .. index .. " is the id asked for, in the order asked")
    ok(batched.results[index].state == "pending", "and it carries that job's state")
  end
  ok(tostring(batched.resume):find("ids", 1, true) ~= nil, "the rest can be resumed in one call again")

  local unknown = call("mcp_whatsapp_send_status", { id = 999999999 })
  ok(unknown.state == "failed" and unknown.error == "whatsapp_send_unknown_id",
    "an id this node never allocated is a failed answer, not a guess: " .. json.encode(unknown))
end

print("whatsapp send ok (" .. checks .. " checks, " .. skipped .. " skipped)")
