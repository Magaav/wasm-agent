-- A node that does not hold the WhatsApp account must still ANSWER: every `mcp_whatsapp_*` read is
-- routed to the account node, inside one bounded wait, and a node that cannot answer never queues a
-- local job at all.
--
-- Measured (13/11, session b393f280 on node `work`): `mcp_whatsapp_contacts` was called three times and
-- `mcp_whatsapp_read` once, and every answer was `{"error":"whatsapp_contacts_slow","state":"queued",
-- "retry":true}` with the same job id - a durable job on a node where no `wa-whatsapp` component runs,
-- so nothing could ever settle it. Sends already routed (the 11/11 account routing); reads did not.
--
-- Model-free and hermetic: the host capabilities, the fleet and the relay are stubs, and the only state
-- this file touches is the private WASM_AGENT_HOME the fast path gives it.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local ctx = { user_id = "master", role = "master", codemode_nested = true }
-- The clock is the test's, not the machine's (the same door `scripts/test-whatsapp-send-waits.lua`
-- uses): one counter that every recorded sleep moves, so a 20 s budget costs microseconds and the
-- backoff the loop used is measurable.
local at = 1700000000
local sleeps = {}
host.now = function() return at end
local function clock_sleep(seconds) sleeps[#sleeps + 1] = seconds; at = at + seconds; return true end

-- ---- the node this test plays ----------------------------------------------------------------
-- `openclaw` holds the account. This node runs no component, and - the case that produced the loop -
-- its own capability does not even know that: `host.whatsapp_*` enqueues a job on this node's queue
-- and answers `..._slow` with the id, exactly as `rust/wa-capabilities/src/whatsapp_query.rs` did
-- (`ask` -> `settle` -> `seam` `..._slow`) when the component registry still said `running`.
local calls = { local_capability = 0, remote = {} }
local function slow_capability(op)
  return function()
    calls.local_capability = calls.local_capability + 1
    return json.encode({ error = "whatsapp_" .. op .. "_slow", id = 42, state = "queued", retry = true,
      detail = "the wa-whatsapp component has not answered yet; the same call reads the same job" })
  end
end
local function answered_capability(op, body)
  return function()
    calls.local_capability = calls.local_capability + 1
    local answer = { op = op, count = 0 }
    for key, value in pairs(body or {}) do answer[key] = value end
    return json.encode(answer)
  end
end
for _, name in ipairs({ "whatsapp_contacts", "whatsapp_search", "whatsapp_read", "whatsapp_reactions",
  "whatsapp_media", "whatsapp_download", "whatsapp_backfill", "whatsapp_send_status" }) do
  host[name] = slow_capability(name:gsub("^whatsapp_", ""))
end
-- This node's own registry: no `wa-whatsapp` running here.
host.service = function() return json.encode({ { name = "wa-whatsapp", state = "stopped" } }) end
local real_getenv = host.getenv
local env_set = {}
host.getenv = function(name)
  if env_set[name] ~= nil then return env_set[name] end
  return real_getenv(name)
end

-- The fleet: one peer that says it holds the account, in the shape `lua/core/federation.lua` caches.
local function catalog(holders)
  return function()
    local peers = {}
    for index, name in ipairs(holders) do
      peers["node-" .. index] = { name = name, node_id = "node-" .. index,
        connectors = { { id = "whatsapp", whatsapp_account = true } } }
    end
    return { at = 0, peers = peers }
  end
end
-- The relay, as the account node answers it: `served_by`-less, so the router's own fields are the
-- evidence the answer took a hop.
local function remote(door)
  return function(node, capability, args)
    calls.remote[#calls.remote + 1] = { node = node, capability = capability, args = args }
    return door(node, capability, args)
  end
end
local function routed_ctx(holders, door)
  local c = { user_id = "master", role = "master", codemode_nested = true, remote_call = remote(door),
    owner_catalog = catalog(holders or {}), whatsapp_wait = { sleep = clock_sleep } }
  return c
end

-- ---- 1. A read on a node without the account goes to the account node -------------------------
-- This is the failure the session measured: the capability here answers `..._slow` with a local job,
-- and on the shipped build that answer was handed to the model as the answer.
local rctx = routed_ctx({ "openclaw" }, function()
  return { ok = true, chat = "5551@s.whatsapp.net", candidates = {}, count = 0, matched = 0 }
end)
calls.local_capability = 0
local contacts = tools.dispatch(memory, "mcp_whatsapp_contacts", { q = "Laura" }, "master", rctx)
ok(calls.local_capability == 0, "a node without the account never asks its own capability: " .. json.encode(contacts))
ok(calls.remote[1] and calls.remote[1].node == "openclaw" and calls.remote[1].capability == "mcp_whatsapp_contacts",
  "the read is asked of the node that holds the account: " .. json.encode(calls.remote))
ok(contacts.ok ~= false and contacts.served_by == "openclaw" and contacts.asked_owner == "openclaw",
  "the answer is the account node's, and it says so: " .. json.encode(contacts))
ok(contacts.state == nil and contacts.retry == nil, "no queued local job reaches the model: " .. json.encode(contacts))

-- Every read verb routes, not only contacts: the same door, the same answer shape.
calls.remote = {}
local verbs = {
  { "mcp_whatsapp_search", { q = "relatorio" } },
  { "mcp_whatsapp_read", { chat = "5551@s.whatsapp.net" } },
  { "mcp_whatsapp_reactions", { chat = "5551@s.whatsapp.net", id = "ABC" } },
  { "mcp_whatsapp_media", { chat = "5551@s.whatsapp.net", id = "ABC" } },
  { "mcp_whatsapp_download", { chat = "5551@s.whatsapp.net", id = "ABC" } },
  { "mcp_whatsapp_backfill", { chat = "5551@s.whatsapp.net", count = 10 } },
}
for _, case in ipairs(verbs) do
  local answer = tools.dispatch(memory, case[1], case[2], "master", rctx)
  ok(answer.served_by == "openclaw" and answer.asked_owner == "openclaw",
    case[1] .. " is answered by the account node: " .. json.encode(answer))
  ok(calls.remote[#calls.remote].capability == case[1], case[1] .. " is asked by its own name")
end
ok(#calls.remote == #verbs, "one short remote call per read, no retry storm: " .. #calls.remote)

-- ---- 2. A declared owner is used before any fleet lookup ------------------------------------
env_set.WASM_AGENT_WHATSAPP_OWNER = "openclaw"
calls.remote, calls.local_capability = {}, 0
-- No catalog at all: the deploy's declaration is enough, and it is the strongest fact there is.
local declared_ctx = { user_id = "master", role = "master", codemode_nested = true,
  remote_call = remote(function() return { ok = true, count = 1, messages = {} } end),
  whatsapp_wait = { sleep = clock_sleep } }
local read = tools.dispatch(memory, "mcp_whatsapp_read", { chat = "5551@s.whatsapp.net" }, "master", declared_ctx)
ok(calls.local_capability == 0 and read.served_by == "openclaw",
  "a declared owner answers a read without asking this node: " .. json.encode(read))
env_set.WASM_AGENT_WHATSAPP_OWNER = nil

-- ---- 3. The account node answers its own reads, exactly as before ----------------------------
for _, name in ipairs({ "whatsapp_contacts", "whatsapp_read" }) do
  host[name] = answered_capability(name:gsub("^whatsapp_", ""), { served_here = true })
end
host.service = function() return json.encode({ { name = "wa-whatsapp", state = "running" } }) end
calls.remote = {}
local local_ctx = routed_ctx({ "openclaw" }, function() error("the account node must not route to a peer") end)
local here = tools.dispatch(memory, "mcp_whatsapp_contacts", { q = "Laura" }, "master", local_ctx)
ok(here.served_here == true and #calls.remote == 0,
  "the node that holds the account answers locally: " .. json.encode(here))

-- ---- 4. Nobody can answer: one fast refusal that names the account node ---------------------
host.service = function() return json.encode({ { name = "wa-whatsapp", state = "stopped" } }) end
for _, name in ipairs({ "whatsapp_contacts", "whatsapp_read" }) do host[name] = slow_capability(name:gsub("^whatsapp_", "")) end
local silent = routed_ctx({ "openclaw" }, function() return { error = "whatsapp_owner_unreachable", owner = "openclaw" } end)
calls.local_capability = 0
local refused = tools.dispatch(memory, "mcp_whatsapp_contacts", { q = "Laura" }, "master", silent)
ok(refused.ok == false and refused.error == "whatsapp_account_unreachable",
  "an unreachable account node is one refusal, not a queued job: " .. json.encode(refused))
ok(refused.account_lives_on == "openclaw" and tostring(refused.note):find("lives on openclaw", 1, true) ~= nil,
  "the refusal names the node that holds the account: " .. json.encode(refused))
ok(calls.local_capability == 0 and refused.retry == nil,
  "the refusal is immediate and offers no retry: " .. json.encode(refused))

-- ---- 5. Nobody can answer: one refusal, and never a local job offered as a handle -----------
-- The capability says this node runs no component (this is the honest, serving-node answer) and the
-- fleet names no other holder: that is one refusal that says so, with no job and no retry loop.
for _, name in ipairs({ "whatsapp_contacts", "whatsapp_read" }) do
  host[name] = function()
    calls.local_capability = calls.local_capability + 1
    return json.encode({ ok = false, error = "whatsapp_component_absent", component = "wa-whatsapp",
      state = "stopped", effect = "none",
      note = "this node runs no wa-whatsapp component; no node in this fleet says it runs wa-whatsapp "
        .. "(set WASM_AGENT_WHATSAPP_OWNER on this node, or enable the component where the account is)" })
  end
end
local nowhere = { user_id = "master", role = "master", codemode_nested = true,
  remote_call = remote(function() error("no peer may be asked") end), owner_catalog = catalog({}),
  whatsapp_wait = { sleep = clock_sleep } }
calls.local_capability, calls.remote = 0, {}
local alone = tools.dispatch(memory, "mcp_whatsapp_read", { chat = "5551@s.whatsapp.net" }, "master", nowhere)
ok(alone.ok == false and alone.error == "whatsapp_component_absent",
  "no component and no owner is one refusal, never a queue: " .. json.encode(alone))
ok(calls.local_capability == 1 and #calls.remote == 0,
  "the refusal costs one local check and no remote call: " .. json.encode(calls))
ok(alone.id == nil and tostring(alone.note):find("WASM_AGENT_WHATSAPP_OWNER", 1, true) ~= nil,
  "and it offers no job handle, only the next step: " .. json.encode(alone))

-- The last case: the capability queues anyway, and nobody in the fleet names a holder. There is
-- nowhere to route to, so the answer stands - and it says that nothing here can settle that job, which
-- is the trap the session fell into (three reads of the same queued id).
for _, name in ipairs({ "whatsapp_contacts", "whatsapp_read" }) do host[name] = slow_capability(name:gsub("^whatsapp_", "")) end
local stuck = tools.dispatch(memory, "mcp_whatsapp_contacts", { q = "Laura" }, "master", nowhere)
ok(stuck.error == "whatsapp_contacts_slow" and stuck.id == 42,
  "with no account node known, the local job is still named: " .. json.encode(stuck))
ok(tostring(stuck.note):find("nothing here settles that job", 1, true) ~= nil,
  "and the answer says it cannot be settled here: " .. json.encode(stuck))

-- ---- 6. The account node's own queue is busy: the answer is its job id and one resume ---------
-- A `..._slow` FROM THE ACCOUNT NODE is legitimate (its worker is behind); it is re-asked inside the
-- bounded wait, and what the model ends with is the owner's id - never a local one, never a bare retry.
local slow_owner = routed_ctx({ "openclaw" }, function()
  return { error = "whatsapp_read_slow", id = 7, state = "queued", retry = true, owner = "openclaw" }
end)
local pending = tools.dispatch(memory, "mcp_whatsapp_read", { chat = "5551@s.whatsapp.net" }, "master", slow_owner)
ok(pending.ok == true and pending.state == "pending" and pending.id == 7,
  "a busy account node answers pending with ITS job id: " .. json.encode(pending))
ok(pending.served_by == "openclaw" and type(pending.waited_s) == "number" and type(pending.reads) == "number",
  "the pending answer says who holds the job and how long it waited: " .. json.encode(pending))
ok(tostring(pending.resume):find("same arguments", 1, true) ~= nil,
  "the pending answer names the one call that collects it: " .. json.encode(pending))
ok(#sleeps >= 1 and sleeps[1] == 0.5, "a busy account node is re-asked with backoff, not in a spin: " .. json.encode(sleeps))
ok(pending.waited_s >= 1 and pending.reads >= 2,
  "the bounded wait went round before answering pending: " .. json.encode({ waited_s = pending.waited_s, reads = pending.reads }))

print("whatsapp route ok (" .. checks .. " checks)")
