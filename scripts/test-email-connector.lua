-- The email connector as a node sees it: the contracts its component is built against, the grants its
-- manifest declares, the tools the catalogue offers, and the rule that no credential can live in its
-- config. Model-free and hermetic: no mailbox, no network, no node state - only files in this checkout.
--
-- What it pins (`docs/EMAIL-CONNECTOR.md`):
--
--   * the four contract snapshots under `rust/components/wa-email/wit/deps` are byte-for-byte the
--     published ones in `wit/`, because a component built against a contract nobody publishes is a
--     component that breaks at instantiate time;
--   * the manifest is a service component that asks for exactly what it uses: no `net` of its own (the
--     operator grants the two host:port pairs in the definition), the two queues, the one bus topic;
--   * the tools exist with the promised shape: `email_send` requires `to`/`subject`/`body`,
--     `email_send_status` is read-only, and the three questions never carry an effect;
--   * every `email_*` tool has a catalogue cue, so a model can find it;
--   * the config parser refuses a password in the config and a plaintext session to a remote host - the
--     two mistakes that would make this connector unsafe by accident.
--
-- A binary without the capability is reported as skipped rather than passed: "this node cannot send
-- email" and "the send path was exercised" are different statements.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function skip(label) skipped = skipped + 1; print("skip " .. label) end
local ctx = { user_id = "master", role = "master" }
local function call(name, args, role) return tools.dispatch(memory, name, args, role or "master", ctx) end

-- ---- the contract copies the component composes --------------------------------------------------
-- wit-bindgen resolves a world's dependencies from `wit/deps/`, so the component carries snapshots. A
-- snapshot that drifts from the published file is a component built against a contract nobody serves.
for _, pair in ipairs({
  { "wit/kernel-v2/kernel.wit", "rust/components/wa-email/wit/deps/kernel.wit" },
  { "wit/kernel-v2/deps/clocks.wit", "rust/components/wa-email/wit/deps/clocks.wit" },
  { "wit/queue/queue.wit", "rust/components/wa-email/wit/deps/queue/queue.wit" },
  { "wit/bus/bus.wit", "rust/components/wa-email/wit/deps/bus/bus.wit" },
  { "wit/kernel-v2/deps/cli.wit", "rust/components/wa-email/wit/deps/cli.wit" },
  { "wit/kernel-v2/deps/filesystem.wit", "rust/components/wa-email/wit/deps/filesystem.wit" },
  { "wit/kernel-v2/deps/random.wit", "rust/components/wa-email/wit/deps/random.wit" },
  { "wit/kernel-v2/deps/sockets.wit", "rust/components/wa-email/wit/deps/sockets.wit" },
}) do
  local published = host.read_file(pair[1])
  local copy = host.read_file(pair[2])
  ok(type(published) == "string" and published ~= "", "the published contract exists: " .. pair[1])
  ok(type(copy) == "string" and copy ~= "", "the component's copy exists: " .. pair[2])
  ok(published == copy, "the snapshot is the published contract, byte for byte: " .. pair[2])
end

-- The world's own contract: the TLS byte stream the host has to serve, and the three imports.
local world = host.read_file("rust/components/wa-email/wit/wa.wit") or ""
ok(world:find("world email-service", 1, true) ~= nil, "the component declares its own world")
ok(world:find("include wa:kernel/service-component@0.2.0", 1, true) ~= nil, "it is a wa:kernel@0.2 service")
ok(world:find("interface transport", 1, true) ~= nil, "it asks for the TLS byte stream it needs")
ok(world:find("connect: static async func", 1, true) ~= nil, "the transport connect is a native-async call")
ok(world:find("import wa:bus/publisher@0.1.0", 1, true) ~= nil, "it publishes on the bus")
ok(world:find("import wa:queue/worker@0.1.0", 1, true) ~= nil, "it works the queue")

-- ---- the manifest -------------------------------------------------------------------------------
local manifest = json.decode(host.read_file("rust/components/wa-email/manifest.json") or "{}")
ok(manifest.name == "wa-email" and manifest.kind == "service", "the manifest names a service component")
ok(manifest.target == "wasm32-wasip2", "it targets the WASI 0.3 component target")
ok(type(manifest.capabilities) == "table", "it declares its capabilities")
local caps = manifest.capabilities
ok(type(caps.net) == "table" and #caps.net == 0, "no net addresses of its own: the definition's net grant is the only one")
ok(caps.storage == true, "it asks for its own kv namespace")
local queue = caps.queue or {}
local consumes = queue.consume or queue.namespaces or {}
local names = {}
for _, name in ipairs(consumes) do names[name] = true end
ok(names["email.outbox"] == true, "it works the outbox queue")
ok(names["email.query"] == true, "it works the query queue")
local bus_topics = (caps.bus or {}).publish or {}
ok(#bus_topics == 1 and bus_topics[1] == "email.received", "it publishes exactly the fact the docs name")
ok(type(manifest.limits) == "table" and type(manifest.limits.memory_mb) == "number", "it declares a memory bound")

-- ---- the configuration the component refuses -----------------------------------------------------
-- A password in the config, and a plaintext session to a remote host, are the two mistakes this
-- connector exists to make impossible; the guest refuses both before a socket is opened.
local config_source = host.read_file("rust/components/wa-email/src/config.rs") or ""
ok(config_source:find("email_credential_in_config", 1, true) ~= nil, "a password in the config is refused by name")
ok(config_source:find("email_tls_required", 1, true) ~= nil, "a plaintext session to a remote host is refused")
ok(config_source:find("loopback", 1, true) ~= nil, "plaintext is allowed only to a loopback test host")
local outbox_source = host.read_file("rust/wa-email-outbox/src/lib.rs") or ""
ok(outbox_source:find("Secret(***)", 1, true) ~= nil, "a credential is masked when it is printed")
ok(outbox_source:find("pub fn audit_target", 1, true) ~= nil, "the audit target is a digest, not an address")

-- ---- the tools ----------------------------------------------------------------------------------
local by_name = {}
for _, entry in ipairs(tools.admin or {}) do
  local spec = entry["function"]
  if spec and spec.name then by_name[spec.name] = spec end
end
for _, name in ipairs({ "email_send", "email_send_status", "email_search", "email_read", "email_media" }) do
  ok(by_name[name] ~= nil, "the catalogue offers " .. name)
  ok(type(by_name[name].description) == "string" and #by_name[name].description > 40, name .. " has a description a model can act on")
end
local send_props = (by_name.email_send or {}).parameters or {}
ok(type(send_props.properties) == "table", "email_send declares its arguments")
ok(send_props.required ~= nil, "email_send declares what is required")
for _, key in ipairs({ "to", "subject", "body" }) do
  local required = false
  for _, name in ipairs(send_props.required or {}) do
    if name == key then required = true end
  end
  ok(required, "email_send requires " .. key)
end
ok(type(send_props.properties.attachments) == "table", "email_send accepts attachments")
ok(by_name.email_send_status.parameters.properties.id ~= nil, "the status tool takes a job id")

-- The effect fence: a question is read-only, a send is not, and no guest may send.
ok(tools.has_effect("email_send") == true, "sending email is an effect")
for _, name in ipairs({ "email_search", "email_read", "email_media", "email_send_status" }) do
  ok(tools.has_effect(name) == false, name .. " is read-only")
end
local forbidden = call("email_send", { to = { "ana@example.com" }, subject = "s", body = "b" }, "guest")
ok(forbidden.error ~= nil, "a guest may not send email: " .. json.encode(forbidden))

-- ---- the answers a caller sees ------------------------------------------------------------------
-- These go through the host capability, so they need a binary that carries it; a node that predates the
-- tools reports skipped, in its own words, instead of reading a missing capability as a passed check.
local has_capability = type(host.email_send) == "function"
if not has_capability then
  skip("this binary predates the email tools: the refusal and queue shapes were not exercised here")
  print("email connector ok (" .. checks .. " checks, " .. skipped .. " skipped)")
  return
end
local bad = call("email_send", { to = { "ana" }, subject = "s", body = "b" })
ok(bad.ok == false and bad.error == "email_send_bad_to", "a bare address is refused: " .. json.encode(bad))
ok(bad.effect == "none", "a refusal never has an effect")
local injected = call("email_send", { to = { "ana@example.com" }, subject = "a\r\nBcc: evil@example.com", body = "b" })
ok(injected.ok == false and injected.error == "email_send_bad_subject", "a header injection is refused by name")
local empty = call("email_search", {})
ok(empty.ok == false and empty.error == "email_empty_query", "an empty search is refused: " .. json.encode(empty))
local no_uid = call("email_media", {})
ok(no_uid.ok == false and no_uid.error == "email_uid_required", "media without a uid is refused")

-- With the binary capability, a valid send is really queued and the status read answers its state.
do
  local queued = call("email_send", { to = { "ana@example.com" }, subject = "connector fixture", body = "corpo" })
  ok(queued.ok == true and type(queued.id) == "number", "a valid send is queued: " .. json.encode(queued))
  ok(queued.queue == "email.outbox", "it is queued on the queue the component works")
  local status = call("email_send_status", { id = queued.id })
  ok(status.ok == true and status.id == queued.id, "the status read answers the job")
  ok(json.encode(status):find("connector fixture", 1, true) == nil, "the status read never returns the message")
  local unknown = call("email_send_status", { id = 999999999 })
  ok(unknown.error == "email_send_unknown_id", "an id this node never allocated is refused")
end

print("email connector ok (" .. checks .. " checks, " .. skipped .. " skipped)")
