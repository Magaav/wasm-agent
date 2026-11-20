-- r2 item 3 (review): CROSS-PROCESS. A fails a turn; B resumes AT ONCE and is admitted.
--
-- Measured on avell (which runs the BASE binary): the guard stopped the turn at 22:53:0xZ, the
-- `--resume` at 22:53:18Z was refused `run_resource_refused resource_busy`, and a launch at 22:54:33Z
-- passed. The release was unconditional already, but it sat AFTER run_failure.handle - which records
-- the failure, publishes it and schedules a wake, real work that took over a minute there. For that
-- whole window the session was still claimed by a run that had already ended.
--
-- The proof is a REAL SECOND PROCESS (`wa`, this tree's Lua, its own ledger connection) asking the claim
-- store two questions at the instant the run releases:
--   1. may the session be claimed now?          -> yes, the lease is free
--   2. are the failure's durable rows written?  -> NO, the failure has not been announced yet
-- Question 2 is what discriminates: a tree that announces first has the row on disk at that instant.
-- scripts/test-run-lease-order.sh reverts the order and requires this row to fail.
--
-- Scratch node only. Refuses the real ~/.wasm-agent.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")

do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL lease-order: " .. label)
  end
end

memory.setup()
local user = "lease-order"
local session = "lease-order-session"
if not memory.session(session) then
  memory.start_session("", "lease order", { id = session, user_id = user, node_id = "" })
end

local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return "test-only" end
  if key == "WASM_AGENT_PROVIDER_RETRIES" then return "0" end
  if key == "WASM_AGENT_PROVIDER_RESPONSE_TIMEOUT_RETRIES" then return "0" end
  return real_getenv(key)
end
local real_sleep = host.sleep
host.sleep = function() end

-- THE PROBE: a real second process, at the instant this run releases its lease.
local probe, probe_ran = nil, false
local real_resource = host.resource
host.resource = function(action, args_json)
  -- The probe runs AFTER the real call: at action=="finish" the claim is still held, so asking then
  -- would answer resource_busy on any tree and prove nothing. The instant that matters is the one just
  -- after the release completes and before the failure is recorded and announced.
  local result = real_resource(action, args_json)
  if action == "finish" and not probe_ran then
    probe_ran = true
    local temp = host.paths().temp
    local out = temp .. "/lease-probe.json"
    local bin = tostring(real_getenv("LEASE_PROBE_BIN") or "wa")
    local root = tostring(real_getenv("WASM_AGENT_LUA_ROOT") or "")
    -- The probe inherits WASM_AGENT_DB from this process (rust/wa-host sets it), so it reads THIS
    -- node's ledger. Passing its own --db was the bug: a second ledger has no failure rows ever, so the
    -- control's reverted order looked identical and the row could not discriminate.
    -- WASM_AGENT_DB must be passed EXPLICITLY. The parent's copy lives in Lua's environment override
    -- map (host::set_env_overrides), not in the OS environment, so a child that merely inherits sees
    -- no WASM_AGENT_DB and resolves the node's own default - it would read the REAL ledger and report
    -- zero rows for this scratch session in every order, which is exactly what made the control unable
    -- to discriminate until this was measured.
    -- The parent's ledger, passed as --db. An environment variable is not enough: the child's Rust
    -- host resolves its OWN ledger from HOME and overrides the map, so a child that only inherited
    -- the variable read a different database and reported zero rows in every order - which is what
    -- made the control unable to discriminate until this was measured.
    local db = tostring(host.getenv("WASM_AGENT_DB") or "")
    local command = string.format(
      "LEASE_PROBE_SESSION=%q LEASE_PROBE_USER=%q LEASE_PROBE_OUT=%q WASM_AGENT_LUA_ROOT=%q WA_SCRIPT=scripts/lease-probe.lua %s --db %q",
      session, user, out, root, bin, db)
    pcall(host.exec, command, "", 180)
    local raw_ok, raw = pcall(host.read_file, out)
    if raw_ok and type(raw) == "string" then
      local decoded_ok, decoded = pcall(json.decode, raw)
      if decoded_ok and type(decoded) == "table" then probe = decoded end
    end
  end
  return result
end

local agent = agentlib.new(session, function() end, "master", user, "local")
agent.stream = true
host.http_stream = function()
  return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" })
end
local ran = pcall(agent.run, agent, "a turn the provider will not answer")
host.resource = real_resource
host.sleep = real_sleep
host.getenv = real_getenv

ok(not ran, "the turn fails on the stalled provider")
ok(probe_ran, "a real second process asked at the instant this run released its lease")
ok(probe ~= nil, "and it answered")

if probe then
  ok(probe.ok == true,
    "the second process is ADMITTED: a failure that has not been announced yet still leaves the session free"
      .. " (got " .. tostring(probe.error) .. ")")
  ok(probe.failure_rows == 0,
    "and the failure was NOT yet announced at that instant (durable failure rows: "
      .. tostring(probe.failure_rows) .. ") - release happens before the record and the announce")
end
-- The failure IS recorded afterwards, so "zero rows" cannot pass by never recording anything.
local after = 0
local listed = memory.session_messages(session, { limit = 200 })
if type(listed) == "table" then
  for _, row in ipairs(listed) do
    if type(row) == "table" then
      local text = tostring(row.content or "")
      local failed_row = row.ok == false or row.ok == 0 or row.ok == "false"
      if failed_row and text:find("run_failed:", 1, true) ~= nil then after = after + 1 end
    end
  end
end
ok(after >= 1, "the failed run still wrote its named failure row afterwards (" .. after .. ")")

print(string.format("ok lease-order: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
