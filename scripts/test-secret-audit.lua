-- A redaction always leaves its `secret_redacted` record, even when the ledger refuses the write.
--
-- THE DEFECT THIS ROW PINS (change/secret-event-never-lost). main-health on 2104a4d8 went red at
-- scripts/test-redact-secrets.lua:130, under load: the turn ran, the transcript was clean - the redaction
-- worked - and there was no `secret_redacted` event. `telemetry.event` DROPS a record the ledger refuses
-- (the busy short-cut, the cooldown, and the bounded retry all end in `note_drop`) and nothing retries it
-- later, so that is a lost audit record and not a test race: measured 23/11 with a competing writer
-- holding the ledger's write lock for one turn (BEGIN IMMEDIATE from another process, this mission's
-- report) - "secret_redacted_rows=0 events=0 dropped=1 ... this record is lost, the run is not".
--
-- The row therefore writes the audit record through `telemetry.audit`, which pays the ledger's patience
-- and keeps the record owed when even that fails, and it asserts the three halves of that promise:
-- the record is in the ledger after two refusals; a ledger that refuses for the whole patience is
-- reported as NOT recorded (never as "recorded"), with the record kept; and the ledger's own report says
-- whether anything is still owed. A run that cannot read the ledger fails here instead of passing:
-- "no events" and "could not look" are different statements.
--
-- WHAT IS INJECTED, AND WHY NOT THE CONTRACT FAKE. scripts/lib/contract-host.lua scripts one answer per
-- SQL statement and has no SQLite behind it, so it cannot stand in for a row that needs the REAL ledger
-- (memory's schema, telemetry's writes, the agent loop). The one answer this row injects is the host's own
-- refusal under a held write lock - `database is locked` - and every other call goes to the real host
-- unchanged, so nothing else here can be a fake's invention.
local json = dofile("lua/vendor/json.lua")
local scratch = dofile("scripts/lib/scratch-home.lua")
local refusal_why = scratch.guard("test-secret-audit.lua")
if refusal_why then print("REFUSED " .. refusal_why); os.exit(2) end

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local SECRET = "sk-audit-0123456789abcdef"
local real_getenv = host.getenv
local sqlite_attempts = "5"
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return SECRET end
  -- The ACCOUNTING path must not retry its way out of the injected refusal: with one attempt it drops the
  -- record on the first refusal, which is the behaviour this row exists to catch (a row that lets the old
  -- path retry twice would pass on the old code and prove nothing).
  if key == "WASM_AGENT_TELEMETRY_WRITE_ATTEMPTS" then return "1" end
  -- The audit path's own patience, per phase: five attempts while the property is measured, one where the
  -- row needs the exhausted answer without waiting twenty seconds for it.
  if key == "WASM_AGENT_SQLITE_RETRY_ATTEMPTS" then return sqlite_attempts end
  return real_getenv(key)
end

-- The ledger refuses the next `left` harness_events rows whose KIND is the audited one, with the host's own
-- words for a write lock held by another connection; everything else is the real host. The test is on the
-- row's kind and not on which writer produced it: on the old code the same record was written by
-- `telemetry.event`, and this row must refuse THAT row too or it cannot tell the two paths apart.
local real_sql_exec = host.sql_exec
local refusals = { left = 0, fired = 0, kind = "secret_redacted" }
host.sql_exec = function(statement, params)
  local text = tostring(statement or "")
  local decoded = nil
  if refusals.left > 0 and text:find("INSERT INTO harness_events", 1, true) then
    local parsed = json.decode(tostring(params or "[]"))
    if type(parsed) == "table" then decoded = parsed[5] end
  end
  if refusals.left > 0 and decoded == refusals.kind then
    refusals.left = refusals.left - 1
    refusals.fired = refusals.fired + 1
    return json.encode({ error = "database is locked" })
  end
  return real_sql_exec(statement, params)
end

local memory = dofile("lua/core/memory.lua")
local telemetry = dofile("lua/core/telemetry.lua")
memory.setup()
telemetry.setup()
-- A node without the durable path cannot keep this promise at all, and saying so is the check.
ok(type(telemetry.audit) == "function", "telemetry must offer a durable audit write (telemetry.audit)")
ok(type(telemetry.owed) == "function" and type(telemetry.flush_audit) == "function",
  "a refused audit record must be countable and flushable (telemetry.owed/flush_audit)")

local function secret_rows(session_id)
  local result = telemetry.events(session_id, 0, 500)
  -- UNKNOWN IS NOT YES: a ledger that could not be read is not a ledger with no rows.
  ok(result.available ~= false, "the ledger must be readable to judge this row: " ..
    tostring(result.reason or "unknown") .. " " .. tostring(result.detail or ""))
  local n = 0
  for _, event in ipairs(result.events) do
    if event.kind == "secret_redacted" then n = n + 1 end
  end
  return n, result
end

-- ---- (1) the property, through the real agent loop ------------------------------------------------
local agentlib = dofile("lua/core/agent.lua")
-- The secret sits in a file the call reads (written into this row's own scratch home, not the temp root),
-- so the leak is real output on either route and the command line never carries the value.
local leak_path = (host.getenv("WASM_AGENT_HOME") or "") .. "/leak-env.txt"
ok(host.write_file(leak_path, "=== env ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET .. "\n"), "the leak file is written in the scratch home")
local real_exec = host.exec
host.exec = function()
  return json.encode({ code = 0, stdout = "=== env ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET, stderr = "" })
end
local step = 0
local real_stream = host.http_stream
host.http_stream = function()
  step = step + 1
  if step == 1 then
    return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
      tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "bash", arguments = json.encode({ command = "cat " .. leak_path }) } } } })
  end
  return json.encode({ status = 200, content = "done", finish_reason = "stop", tool_calls = {} })
end
local sid = memory.ensure_session("secret-audit", "local", "audit")
local agent = agentlib.new(sid, function() end, "master", "secret-audit", "local")
agent.stream = true
-- Two refusals before the ledger takes the record: the old path drops it on the first one.
refusals.left = 2
local ran = pcall(agent.run, agent, "run env")
host.exec = real_exec
host.http_stream = real_stream
ok(ran, "the end-to-end turn must run")
ok(refusals.fired == 2, "the ledger must actually have refused the audit write twice (fired=" ..
  tostring(refusals.fired) .. "): without the refusal this row proves nothing")
local leaked = false
for _, row in ipairs(memory.session_messages(sid, { all = true })) do
  if tostring(row.content or ""):find(SECRET, 1, true) then leaked = true end
end
ok(not leaked, "the stored transcript must not contain the secret")
local rows, report = secret_rows(sid)
ok(rows == 1, "a redaction always leaves its record, even when the ledger refused it twice (rows=" ..
  tostring(rows) .. ")")
ok(report.audit_owed == 0, "the ledger owes no audit record after the turn (audit_owed=" ..
  tostring(report.audit_owed) .. ")")
ok(telemetry.owed() == 0, "no audit record is still owed")
ok(telemetry.drops().count == 0, "the refusal cost no dropped record (drops=" ..
  tostring(telemetry.drops().count) .. ")")

-- ---- (1b) THE TURN keeps it too: a record the ledger refused is written before the run returns ------
-- The agent's own flush at the end of the turn (lua/core/agent.lua, "THE AUDIT RECORDS TOO") and not this
-- row's: the audit path's patience is one attempt here, so the write is refused, the record is kept owed
-- through the rest of the turn, and the run writes it before it returns.
sqlite_attempts = "1"
refusals.left = 1
step = 0
host.exec = function()
  return json.encode({ code = 0, stdout = "=== env ===\nWASM_AGENT_LLM_API_KEY=" .. SECRET, stderr = "" })
end
local stream_again = host.http_stream
host.http_stream = function()
  step = step + 1
  if step == 1 then
    return json.encode({ status = 200, content = "", finish_reason = "tool_calls",
      tool_calls = { { id = "c2", type = "function",
        ["function"] = { name = "bash", arguments = json.encode({ command = "cat " .. leak_path }) } } } })
  end
  return json.encode({ status = 200, content = "done", finish_reason = "stop", tool_calls = {} })
end
local ran_again = pcall(agent.run, agent, "run env again")
host.exec = real_exec
host.http_stream = stream_again
ok(ran_again, "the second turn must run")
ok(refusals.fired == 3, "the ledger refused this turn's audit write too (fired=" ..
  tostring(refusals.fired) .. ")")
rows, report = secret_rows(sid)
ok(rows == 2, "the run's own flush wrote the kept record before it returned (rows=" .. tostring(rows) .. ")")
ok(telemetry.owed() == 0 and report.audit_owed == 0, "nothing is left owed after the turn")
sqlite_attempts = "5"

-- ---- (2) a ledger that refuses for the whole patience is NOT reported as recorded -----------------
sqlite_attempts = "1"
refusals.left = 1
local recorded, reason = telemetry.audit(sid, "run-2", "span-2", "secret_redacted", "redacted",
  { tool = "bash", names = { WASM_AGENT_LLM_API_KEY = 1 } })
ok(recorded == false, "a refused audit write must not be reported as recorded")
ok(type(reason) == "string" and #reason > 0, "the refusal must come with the ledger's own words")
ok(telemetry.owed() == 1, "the refused record is kept for a later write, not lost (owed=" ..
  tostring(telemetry.owed()) .. ")")
rows = secret_rows(sid)
ok(rows == 2, "nothing claims a row that was not written (rows=" .. tostring(rows) .. ")")
refusals.left = 0
local written, left = telemetry.flush_audit()
ok(written == 1 and left == 0, "the kept record is written once the ledger takes writes again (written=" ..
  tostring(written) .. " left=" .. tostring(left) .. ")")
rows, report = secret_rows(sid)
ok(rows == 3, "the flushed record is in the ledger (rows=" .. tostring(rows) .. ")")
ok(report.audit_owed == 0 and telemetry.owed() == 0, "the ledger owes nothing after the flush")

host.getenv = real_getenv
host.sql_exec = real_sql_exec
host.write_file(leak_path, "")
print("secret audit ok (" .. checks .. " checks)")
