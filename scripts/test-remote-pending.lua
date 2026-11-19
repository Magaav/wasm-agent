-- A remote call is never killed for waiting (mission change/remote-pending, item 1).
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-remote-pending.lua \
--     wa --db <scratch>/t.db
--
-- TWO SCRATCH NODES IN ONE PROCESS, and never the real fleet: the PEER half is the real
-- wa_peer_dispatch/operation path this node runs for a verified peer (the same seam
-- scripts/test-session-isolation.lua reaches), and the CALLER half is the real pending-call executor
-- over a relay stand-in that carries the two halves' answers between them. What this pins:
--
--   * a peer call that NAMED a budget and outlived it answers {state:"pending", op, node}: the
--     command keeps running on the peer as a managed operation;
--   * the caller's wait(op) resumes it, through SHORT relayed operation calls, and answers the
--     command's real result;
--   * cancel(op) stops it;
--   * a non-idempotent command (it appends a line) ran EXACTLY once - the failure the relay bound
--     used to cause, and the duplicate bills it produced;
--   * a command that fits its budget answers its own result, with no handle at all.
--
-- What this does NOT prove, and the report says so: the real relay's stamped deadline
-- (rust/wa-rendezvous) and the peer's own cancel flag (rust/wa-capabilities) are not driven here -
-- the stand-in carries answers, it does not hold connections.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got "
      .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local pending = dofile("lua/core/codemode_pending.lua")
local paths = dofile("lua/core/paths.lua")
dofile("lua/core/server.lua")

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function decode(text)
  local ok, value = pcall(json.decode, text)
  return ok and type(value) == "table" and value or nil
end

local peer_caller = { node_id = "rp-scratch-peer", role = "master" }
local peer_ctx = { session_id = "peer:rp-scratch-peer", user_id = "master" }
local sid = memory.start_session("", "remote pending", { user_id = "master" })
local caller_ctx = { session_id = sid, user_id = "master" }
local scope = host.sha256(json.encode({ session = sid, user = "master", role = "master",
  workspace = memory.session_workspace and memory.session_workspace(sid) or nil,
  profile = nil }))

local data = paths.data() .. "/remote-pending-test"
local marker = data .. "/marker.txt"
assert(host.write_file(marker, ""))

local function lines_of(path)
  local text = host.read_file(path)
  if type(text) ~= "string" then return 0 end
  local n = 0
  for _ in text:gmatch("\n") do n = n + 1 end
  return n
end

local function peer_bash(command, budget_ms)
  return wa_peer_dispatch("bash", { command = command, budget_ms = budget_ms },
    peer_caller, "master")
end

local function peer_await(id, steps)
  local last = nil
  for _ = 1, steps or 30 do
    last = tools.dispatch(memory, "operation", { action = "await", id = id, wait_ms = 1000,
      tool = "operation", output = true, max_bytes = 24576 }, "master", peer_ctx) or {}
    if last.settled == true or last.error ~= nil then break end
  end
  return last or {}
end

-- 1. A command that outlives the budget is ADOPTED: a handle, not a kill.
local slow = "printf 'run\\n' >> '" .. marker .. "'; sleep 6; echo rp-slow-done"
local adopted = peer_bash(slow, 3000)
check(type(adopted) == "table", "the peer answered something")
check(adopted.state == "pending", "a command past its budget answers a handle, not a kill: "
  .. json.encode(adopted):sub(1, 200))
check(type(adopted.op) == "string" and adopted.op ~= "", "the handle is the peer operation id")
check(adopted.node ~= nil and adopted.node ~= "", "the handle names the node the work is on")
local settled = peer_await(adopted.op)
check(settled.settled == true, "the adopted command settles on the peer: " .. json.encode(settled):sub(1, 200))
check(tonumber(settled.code) == 0 or settled.ok == true, "and it succeeded")
local ran = peer_await(adopted.op, 1)
check(type(ran) == "table", "a second look at the same handle answers again, and re-runs nothing")

-- 2. A command that fits its budget answers its own result: no handle at all.
local quick = peer_bash("echo rp-quick-done", 9000)
check(quick.state ~= "pending", "a command inside its budget is not a handle")
check(tostring(quick.stdout or ""):find("rp-quick-done", 1, true) ~= nil,
  "and it answers the command's own output: " .. json.encode(quick):sub(1, 200))

-- 3. cancel(op) stops it.
local long = peer_bash("sleep 300", 1000)
check(long.state == "pending", "a long command is adopted")
local stopped = tools.dispatch(memory, "operation", { action = "cancel", id = long.op },
  "master", peer_ctx) or {}
check(stopped.cancelled ~= false, "cancel stops the adopted operation: " .. json.encode(stopped):sub(1, 160))
local after = peer_await(long.op, 5)
check(after.settled == true, "and it is settled afterwards")

-- 4. The CALLER half: the pending executor over a relay stand-in carrying the two halves' answers.
local function relay(name, params, raw)
  if name ~= "remote" then return tools.dispatch(memory, name, params, "master", caller_ctx) end
  if params.capability == "bash" then
    return wa_peer_dispatch("bash", { command = params.command, budget_ms = 1000 },
      peer_caller, "master")
  end
  if params.capability == "operation" then
    return tools.dispatch(memory, "operation", params, "master", peer_ctx)
  end
  return { error = "relay_stand_in_unsupported", capability = tostring(params.capability) }
end

local raw = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "printf 'run\\n' >> '" .. marker .. "'; sleep 5; echo rp-resumed", wait_s = 0 })
local first = pending.invoke(relay, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash",
    command = "printf 'run\\n' >> '" .. marker .. "'; sleep 5; echo rp-resumed" }, raw, 0)
check(type(first) == "table" and first.state == "pending",
  "a remote call past its wait answers a pending handle: " .. json.encode(first or {}):sub(1, 220))
check(type(first.op) == "string" and first.op ~= "", "with the peer's operation id")
-- The handle names the machine the work is on. In this process the peer half runs on THIS node, so the
-- name is this node's own - what matters is that it is named and that it is the peer's answer, not a
-- label the caller invented.
local this_node = dofile("lua/core/nodes.lua").node_name()
check(first.node == this_node, "and the node it lives on: " .. tostring(first.node)
  .. " (this node is " .. tostring(this_node) .. ")")
local resumed = pending.wait(relay, { scope = scope }, first.op, { wait_s = 30 })
check(type(resumed) == "table" and resumed.state == "done",
  "wait(op) resumes it: " .. json.encode(resumed or {}):sub(1, 240))
check(tostring(type(resumed.result) == "table" and resumed.result.stdout or ""):find("rp-resumed", 1, true) ~= nil,
  "and answers the command's real output")

local cancel_raw = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "sleep 300", wait_s = 0 })
local cancel_first = pending.invoke(relay, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash", command = "sleep 300" }, cancel_raw, 0)
check(type(cancel_first) == "table" and cancel_first.state == "pending", "a long remote call is a handle")
local cancelled = pending.cancel(relay, { scope = scope }, cancel_first.op)
check(type(cancelled) == "table" and cancelled.cancelled ~= false,
  "cancel(op) stops a remote op by routing to its node: " .. json.encode(cancelled or {}):sub(1, 200))

-- 5. Never a half-run and never a double run: two adopted commands, two lines, and no replay anywhere.
check(lines_of(marker) == 2, "each adopted command appended exactly ONE line (got "
  .. tostring(lines_of(marker)) .. ")")

-- 6. Item 3: the relay-deadline note is no longer the whole story. A model that reads only "the call
-- stopped waiting" re-issues the same long call for ever, so the sentence now names the pending answer
-- and the two calls that route back to the peer. Pinned here as well as in
-- scripts/test-remote-call-shape.lua, which needs the selfloop component this node does not have
-- (measured: it aborts at its line 158 on the BASE worktree too - a pre-existing refusal, not this
-- change, and the report says so).
local nodes_lib = dofile("lua/core/nodes.lua")
local note = nodes_lib.relay_deadline_note({ name = "rp-scratch-peer" }, "relay_timeout")
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
check(has(note, "ADOPTED"), "the note says a long relayed bash is adopted, not killed")
check(has(note, 'state:"pending", op, node'), "and names the handle shape it answers")
check(has(note, "wait(op)") and has(note, "cancel(op)"), "and the calls that route back to that node")
check(nodes_lib.RELAY_PEER_BUDGET_MS > 0
  and nodes_lib.RELAY_PEER_BUDGET_MS < nodes_lib.RELAY_DEADLINE_SECONDS * 1000,
  "the budget a peer adopts by is inside the relay hold")

print("remote pending ok (" .. tostring(checks) .. " checks)")
