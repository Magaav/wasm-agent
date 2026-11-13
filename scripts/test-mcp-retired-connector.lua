-- A retired connector must SAY it is retired, not keep reporting the last error of a program that no
-- longer exists.
--
-- The WhatsApp Go connector (`connectors/whatsapp`) went on 11/11 (Phase 4) and nothing in this tree
-- serves its port any more; 28787/8787 belongs to unrelated services. A registry row can outlive its
-- program, and the row kept publishing `failing` with the error it last recorded - "connector stopped,
-- port 8787 held by space-serve" - which reads as a live incident. Measured 13/11, session b393f280 on
-- node `work`: the model read that stale status and spent ten rounds on a connector that cannot be
-- started again, before it gave up on the task.
--
-- Hermetic: the registry is seeded the way a probe leaves it (`mcp.extensions.v1`), and no server, port
-- or process is touched.
local json = dofile("lua/vendor/json.lua")
assert(json.decode(host.sql_exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)", "[]")).ok,
  "private registry table setup failed")
local mcp = dofile("lua/core/mcp.lua")
local command = dofile("lua/core/mcp_command.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function contains(haystack, needle) return tostring(haystack or ""):find(needle, 1, true) ~= nil end
local function meta_set(key, value)
  assert(json.decode(host.sql_exec("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", json.encode({ key, value }))).ok,
    "meta write failed for " .. key)
end

-- The state a probe of the Go connector left behind on a node, beside one ordinary connector that is
-- genuinely failing - so this file also proves a real failure is still reported as one.
local PORT_ERROR = "connector stopped, port 8787 held by space-serve"
local registry = { schema = 1, revision = 11, servers = {
  whatsapp = {
    enabled = false, revision = 3,
    definition = { id = "whatsapp", name = "WhatsApp connector", transport = "stdio",
      program = "wa-whatsapp", args = { "serve", "--listen", "127.0.0.1:28787" },
      tools = { read_newest = "read", inspect_chat = "read", send = "write" } },
    probe = { ok = false, error = PORT_ERROR, tools = {
      { name = "read_newest", description = "Read one WhatsApp chat newest-first", input_schema_json = '{"type":"object","properties":{}}' } } },
    observed_status = "last probe failed - down ~37h",
    last_call = { ok = false, error = PORT_ERROR },
  },
  mail = {
    enabled = false, revision = 2,
    definition = { id = "mail", name = "Mail", transport = "stdio", program = "mcp-mail.mjs",
      args = {}, tools = { search = "read" } },
    probe = { ok = false, error = "mcp_operation_failed: spawn failed" },
    observed_status = "last probe failed",
  },
} }
meta_set("mcp.extensions.v1", json.encode(registry))

local list = command.local_connectors({})
local by_id = {}
for _, row in ipairs(list or {}) do by_id[row.id] = row end
ok(by_id.whatsapp ~= nil and by_id.mail ~= nil, "both rows are listed: " .. json.encode(list))

-- ---- 1. The retired Go connector is `retired`, once, in words a reader can act on --------------
local retired = by_id.whatsapp
local retired_json = json.encode(retired)
ok(retired.state == "retired", "the Go connector row is retired, not failing: " .. retired_json)
ok(retired.error == nil, "the row carries no live error: " .. retired_json)
ok(contains(retired.note, "removed on 11/11"), "the row says when it went: " .. tostring(retired.note))
ok(contains(retired.note, "mcp_whatsapp_"), "the row names the surface that replaced it: " .. tostring(retired.note))
ok(retired.tool_count == 0, "no tool of a retired connector is offered: " .. retired_json)
-- The noise itself: nothing the model reads may still claim the port is a live problem.
for _, gone in ipairs({ "8787", PORT_ERROR, "down ~37h", "space-serve" }) do
  ok(not contains(retired_json, gone), "the row no longer carries " .. gone .. ": " .. retired_json)
end
for _, tool in ipairs(retired.tools or {}) do
  ok(tool.published == false, "a retired connector's tool is not published: " .. json.encode(tool))
end

-- ---- 2. A connector that is really failing is still reported as one ---------------------------
local mail = by_id.mail
ok(mail.state == "failing" and contains(mail.error, "spawn failed"),
  "an ordinary connector keeps its own failure and its own words: " .. json.encode({ state = mail.state, error = mail.error }))
ok(mail.error ~= nil, "a real failure is not reworded into a retirement: " .. json.encode({ state = mail.state, error = mail.error }))

-- ---- 3. Through the tool the model actually reads ---------------------------------------------
-- `mcp` (action list) is the surface: its answer must not carry the port either.
local answered = mcp.control({ action = "list" }, { role = "master" })
ok(answered.ok == true and type(answered.servers) == "table", "the registry still answers: " .. json.encode(answered))
local via_mcp = json.encode(answered.servers)
ok(not contains(via_mcp, "8787") and not contains(via_mcp, "space-serve"),
  "the registry's own answer carries no port noise: " .. via_mcp:sub(1, 400))

print("mcp retired connector ok (" .. checks .. " checks)")
