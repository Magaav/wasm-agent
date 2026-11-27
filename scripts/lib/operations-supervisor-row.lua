-- Slice 1 of `ready-operations-own-program.md`: the same operation verbs, answered by the process that
-- owns the children when the node names a supervisor (`WASM_AGENT_OPERATIONS_SUPERVISOR`).
--
-- This row runs on the product's own interpreter (WA_SCRIPT, driven by scripts/test-operation-supervisor.cjs)
-- and prints one `ROW <json>` line per observation. It asserts what can be judged from inside one process;
-- the comparison between the in-process run and the wired run belongs to the harness, which is the only
-- place that can hold both answers.
--
-- Why the three properties are here and not in a unit test: env withholding is decided when a manager is
-- BUILT (wa-operation's `withheld_env`, a process-wide OnceLock), and cancellation is a flag on the entry
-- the owning process holds. Neither is observable except by starting a real child in a real process.
local json = dofile('lua/vendor/json.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua')

-- A row that starts a real process and writes records refuses to run on the node's own home.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
  local real_node = home:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local dir = tostring(host.getenv("WA_ROW_DIR") or "")
if dir == "" then
  print("refusing to run: WA_ROW_DIR must name the scratch directory this row writes its markers in")
  os.exit(2)
end

memory.setup()

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL operations-supervisor: " .. label)
  end
end
local function row(step, value) print("ROW " .. json.encode({ step = step, value = value })) end
local function read(path)
  local handle = io.open(path, 'r')
  if not handle then return '' end
  local text = handle:read('a') or ''
  handle:close()
  return text
end

local session = "operations-supervisor-row"
if not memory.session(session) then
  memory.start_session("", "supervisor", { id = session, user_id = session, node_id = "" })
end
local ctx = { session_id = session, user_id = session, run_id = host.uuid() }

-- WHAT ANSWERED: the identity of the process that owns the manager (`host.operation` is the wire).
row("identity", json.decode(host.operation("identity", "{}")))

local marker = dir .. "/marker.txt"
local envfile = dir .. "/env.txt"
-- The marker proves the cancellation reached the CHILD (a line written before the sleep and none after
-- it); the env file proves the child could not read the node's credential.
local command = string.format(
  "printf 'start\\n' >> '%s'; printf 'gh=[%%s]\\n' \"$GH_TOKEN\" > '%s'; sleep 8; printf 'end\\n' >> '%s'",
  marker, envfile, marker)

local started = tools.dispatch(memory, "operation",
  { action = "start", command = command, cwd = dir, timeout_seconds = 30 }, "master", ctx)
row("start", started)
local id = type(started) == "table" and started.operation_id or nil
if type(id) ~= "string" or id == "" then
  ok(false, "start answered no operation id: " .. json.encode(started))
  print("ROW done " .. json.encode({ checks = checks, failed = failed }))
  os.exit(1)
end

-- THE CHILD MUST HAVE RUN BEFORE IT IS CANCELLED. Cancelling in the same millisecond a start was
-- admitted kills the child before its first line runs, and then the marker proves nothing about
-- cancellation (measured: the first version of this row failed exactly that way). So the cancel waits
-- for the FACT - the line the child writes - and not for a sleep long enough to hope.
local function waitFor(path, needle, ticks)
  for _ = 1, ticks do
    local body = read(path)
    if body:find(needle, 1, true) then return body end
    os.execute("sleep 0.05")
  end
  return read(path)
end
local ran = waitFor(marker, "start", 100)
ok(ran:find("start", 1, true) ~= nil, "the child ran before the cancel (marker " .. json.encode(ran) .. ")")
-- A TRANSIENT STATE IS NOT AN ANSWER. A status read while the record was still being written said
-- "accepted" in one process and "running" in the other (measured: this row failed that way, twice in
-- five runs). The snapshot is taken at a point both processes must agree on: the child has run, so the
-- record says running.
local status
for _ = 1, 100 do
  status = tools.dispatch(memory, "operation", { action = "status", id = id }, "master", ctx)
  if type(status) == "table" and status.state == "running" then break end
  os.execute("sleep 0.05")
end
row("status", status)
row("cancel", tools.dispatch(memory, "operation", { action = "cancel", id = id }, "master", ctx))
-- `await` is the settlement boundary: it answers when the operation settled or when its own bound ran out,
-- so this is a wait on the fact, not a sleep long enough to hope.
row("await", tools.dispatch(memory, "operation",
  { action = "await", id = id, wait_for = "settled", wait_ms = 8000 }, "master", ctx))
local settled = tools.dispatch(memory, "operation", { action = "status", id = id }, "master", ctx)
row("settled", settled)

local marks = read(marker)
row("marker", marks)
row("env", read(envfile))

ok(type(settled) == "table" and settled.settled == true,
  "a cancelled operation settles: " .. json.encode(settled))
-- A cancelled group leaves the line it wrote BEFORE the cancel and never the one after it.
ok(marks:find("start", 1, true) ~= nil, "the child ran before the cancel: marker was " .. json.encode(marks))
ok(marks:find("end", 1, true) == nil, "the cancel reached the child (no end line): " .. json.encode(marks))
-- The env rule is the supervisor's own when the supervisor spawned the child.
ok(type(settled) == "table" and type(settled.env_withheld) == "table"
    and json.encode(settled.env_withheld):find("GH_TOKEN", 1, true) ~= nil,
  "the record names GH_TOKEN as withheld: " .. json.encode(type(settled) == "table" and settled.env_withheld or nil))
ok(read(envfile):find("gh=[]", 1, true) ~= nil,
  "the child could not read GH_TOKEN: " .. json.encode(read(envfile)))

print("ROW done " .. json.encode({ checks = checks, failed = failed }))
if failed > 0 then os.exit(1) end
