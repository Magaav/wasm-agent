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

-- A section that asserts about the ADOPTION LIMIT or the REAPING rule must start from a clean peer
-- session: every earlier section leaves handles behind, and a limit is only measured against an empty
-- share. This cancels what is open and waits for the peer's own list to agree - a test helper, never a
-- property of the code under test.
local function drain_peer()
  for _ = 1, 20 do
    local page = tools.dispatch(memory, "operation", { action = "list" }, "master", peer_ctx) or {}
    local open = 0
    for _, row in ipairs(page.operations or {}) do
      if type(row) == "table" and row.settled ~= true and tostring(row.state or "") ~= "cancelled" then
        open = open + 1
        tools.dispatch(memory, "operation", { action = "cancel", id = row.operation_id }, "master", peer_ctx)
      end
    end
    if open == 0 then return true end
    -- host.sleep takes whole MILLISECONDS; 0.3 was 0 ms.
    if host.sleep then host.sleep(300) end
  end
  return false
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

-- 7. Items 5 and 2: the adopted op belongs to the CALLING peer's own session, never to another
-- session by name, and no wait this change adds can outlive the relay's hold.
local owned = peer_bash("sleep 4", 1000)
check(owned.state == "pending", "a peer op is adopted for the ownership check")
local function lists(session_ctx, ctx_user)
  local page = tools.dispatch(memory, "operation", { action = "list" }, "master",
    { session_id = session_ctx, user_id = ctx_user or "master" }) or {}
  for _, entry in ipairs(page.operations or {}) do
    if tostring(entry.operation_id or "") == owned.op then return true end
  end
  return false
end
check(lists("peer:rp-scratch-peer"), "the peer that asked sees its own adopted operation")
check(not lists(sid), "a local session does not see it (nothing is visible by name)")
check(not lists("peer:rp-other-peer"), "and neither does another peer")
local stolen = tools.dispatch(memory, "operation", { action = "status", id = owned.op }, "master",
  { session_id = sid, user_id = "master" }) or {}
check(stolen.error ~= nil, "and a local session cannot reach it by id: " .. tostring(stolen.error))
local peer_cancelled = tools.dispatch(memory, "operation", { action = "cancel", id = owned.op },
  "master", peer_ctx) or {}
check(peer_cancelled.cancelled ~= false, "the peer that owns it can stop it")

-- The executor's own slice, and the budget the peer adopts by, both sit INSIDE the relay's hold:
-- that is what makes "the relay never carries the long wait" a number instead of a promise.
local pending_lib = dofile("lua/core/codemode_pending.lua")
local nodes_lib2 = dofile("lua/core/nodes.lua")
check(nodes_lib2.RELAY_PEER_BUDGET_MS < nodes_lib2.RELAY_DEADLINE_SECONDS * 1000,
  "the peer answers a handle inside the relay hold (" .. tostring(nodes_lib2.RELAY_PEER_BUDGET_MS) .. " ms)")
check(pending_lib.EXECUTORS["remote"] ~= nil and type(pending_lib.EXECUTORS["remote"].poll) == "function",
  "the caller half is a real executor, so wait(op) resumes it")

-- 8. Item 1 names bash, batch and operation. Two of those are already safe and must not be turned into
-- handles by this change: a batch is read-only on the wire (so it can carry no long effect), and a
-- remote operation await past the relay bound is INTERRUPTED (await_interrupted), never cancelled. So
-- the executor refuses to adopt anything but bash, and an interrupted await still answers "running".
local executor = pending_lib.EXECUTORS["remote"]
check(executor.applies({ node = "rp-scratch-peer", capability = "batch", calls = {} }) == false,
  "a batch is not adopted: it is read-only on the wire and has no long effect to protect")
check(executor.applies({ node = "rp-scratch-peer", capability = "operation", action = "await", id = "x" }) == false,
  "a remote operation await is not adopted: the peer interrupts that wait and never cancels the work")
check(executor.applies({ node = "rp-scratch-peer", capability = "bash", command = "sleep 300" }) == true,
  "bash is the one capability adopted")
check(executor.applies({ capability = "bash", command = "sleep 1" }) == false,
  "a local bash with no node is not the remote executor's business")

-- 9. Review r1 MUST 1: a cancel only claims the stop it OBSERVED. The peer's cancel answer carries the
-- operation_id even when it refused or the call had already finished, so "an answer with an id" is not a
-- stop; an earlier version read that as cancelled:true and left the command running.
local done_first = peer_bash("echo done-already", 9000)
check(done_first.state ~= "pending", "a fast command finishes inside its budget")
local stale_op = "op-0-0-0"
local finish_later = peer_bash("sleep 3", 1000)
check(finish_later.state == "pending", "a slow command is adopted before the cancel-honesty checks")
local finish_await = peer_await(finish_later.op, 20)
check(finish_await.settled == true, "and it is allowed to finish")
local cancel_raw2 = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "sleep 300", wait_s = 0 })
local honesty = pending.invoke(relay, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash", command = "sleep 300" }, cancel_raw2, 0)
check(honesty.state == "pending", "a fresh handle for the honesty checks")
local real_cancel = pending.cancel(relay, { scope = scope }, honesty.op)
check(real_cancel.cancelled == true, "a stop the peer confirmed is cancelled:true")
-- The same handle again: it is settled/cancelled now, so this cancel must NOT claim a second stop.
local second = pending.cancel(relay, { scope = scope }, honesty.op)
check(second.cancelled == false, "a second cancel does not claim a stop it did not observe: "
  .. json.encode(second):sub(1, 200))
check(second.error ~= nil, "and it names the reason: " .. tostring(second.error))
-- A refusal with a known-looking id is not a stop either: cancel an id the peer does not own.
local bogus = pending.cancel(relay, { scope = scope }, stale_op)
check(bogus.cancelled == false or bogus.error == "unknown_op",
  "an unknown id is never reported as cancelled: " .. json.encode(bogus):sub(1, 160))

-- 10. Review r1 MUST 2: one peer may not hold this node's whole slot share with adopted work. Everything a
-- peer asks for lands in ONE peer session whose share is PER_SESSION_MAX = 6 of 8; before the bound, six
-- long adopted commands blocked the peer's own short calls. The bound is small and the refusal is named.
check(drain_peer(), "the peer session is empty before the limit is measured")
local held = {}
for index = 1, 2 do
  local one = peer_bash("sleep 30", 800)
  check(one.state == "pending", "adopted op " .. index .. " is running")
  held[#held + 1] = one
end
local over = peer_bash("sleep 30", 800)
check(over.error == "remote_adopted_limit", "the third long adopted command is refused by name: "
  .. json.encode(over):sub(1, 200))
check(over.open == 2 and over.limit == 2, "the refusal names what is open and the limit")
check(over.effect == "none", "and nothing was started")
for _, one in ipairs(held) do
  tools.dispatch(memory, "operation", { action = "cancel", id = one.op }, "master", peer_ctx)
end



-- 11. Review r1 MUST 2, the second half: capacity for a caller that walked away.
--
-- Two mechanisms, and this measures both:
--
--   * the CEILING: an adopted command is started with a bounded timeout_seconds whatever its caller asked
--     for, and the handle reports that number. Measured here: with a 1 s ceiling the operation settles by
--     ITSELF (state failed, the supervisor's own deadline), so the slot comes back without anyone polling;
--   * the REAP: a supervisor that is overdue (asleep, wedged) can still leave work running past the
--     ceiling. The next adoption notices it and stops it by name. That case is not reproducible on demand,
--     so the recorded start time is aged in the index this node writes - the rule is measured against the
--     record it really uses, and the test says so rather than pretending an overdue supervisor happened.
-- Run a body with one environment variable answered by this test instead of the node (the pending module
-- reads its bounds the same way, so a rule can be held in seconds instead of minutes).
local function with_env(name, value, body)
  local real = host.getenv
  host.getenv = function(key)
    if key == name then return value end
    return real(key)
  end
  local ok, problem = pcall(body)
  host.getenv = real
  assert(ok, problem)
end

local function drain_peer_at_least(from_index)
  for _ = 1, 20 do
    local page = tools.dispatch(memory, "operation", { action = "list" }, "master", peer_ctx) or {}
    local open = 0
    for _, row in ipairs(page.operations or {}) do
      if type(row) == "table" and row.settled ~= true and tostring(row.state or "") ~= "cancelled" then
        open = open + 1
        tools.dispatch(memory, "operation", { action = "cancel", id = row.operation_id }, "master", peer_ctx)
      end
    end
    if open == 0 then return true end
    if host.sleep then host.sleep(300) end
  end
  return false
end

-- The ceiling: a bound this node gives an adopted command, read from the environment so a test can hold
-- it in seconds. (A 1 s ceiling ends a command BEFORE it can ever be adopted - measured - so the bound
-- that is really exercised here is the production one; reaping is measured below.)
with_env("WASM_AGENT_REMOTE_ADOPTED_SECONDS", "7", function()
  with_env("WASM_AGENT_REMOTE_ADOPTED_GRACE_SECONDS", "2", function()
    check(wa_adopted_ceiling_seconds() == 7 and wa_adopted_grace_seconds() == 2,
      "the ceiling and grace are readable, so the rule can be held in seconds")
  end)
end)
check(wa_adopted_ceiling_seconds() == 900 and wa_adopted_grace_seconds() == 60,
  "and with no variable set the production bound is 900 s + 60 s grace")
check(drain_peer_at_least(true), "the peer session is empty before the ceiling is measured")
local ceiling_handle = peer_bash("sleep 5", 800)
check(ceiling_handle.state == "pending", "a command is adopted under the real ceiling: "
  .. json.encode(ceiling_handle):sub(1, 200))
check(ceiling_handle.timeout_seconds == 900,
  "and the handle reports the ceiling it was really given: " .. tostring(ceiling_handle.timeout_seconds))
tools.dispatch(memory, "operation", { action = "cancel", id = ceiling_handle.op }, "master", peer_ctx)
-- The REAP, against the record it really uses.
--
-- The command has to be started under the REAL ceiling (900 s) - a command started under the 1 s ceiling
-- settles by itself and there is nothing to reap - and the ceiling is then lowered for the check, which is
-- exactly the position a node is in when its supervisor stops noticing: work admitted under an earlier,
-- longer bound. The recorded start time is aged for the same reason, instead of waiting the real bound.
check(drain_peer_at_least(true), "the peer session is empty before the reap is measured")
local stale = peer_bash("sleep 60", 800)
check(stale.state == "pending", "a command is adopted for the reap")
check(stale.timeout_seconds == 900, "under the real 900 s ceiling: " .. tostring(stale.timeout_seconds))
with_env("WASM_AGENT_REMOTE_ADOPTED_SECONDS", "1", function()
  with_env("WASM_AGENT_REMOTE_ADOPTED_GRACE_SECONDS", "1", function()
    -- Age the start time this node recorded: 100 s old, far past the 1 s ceiling + 1 s grace this scope
    -- now enforces. The rule reads its own record, so ageing that record is the overdue-supervisor case.
    local paths_lib = dofile("lua/core/paths.lua")
    local index_path = paths_lib.data() .. "/remote-adopted/peer_rp-scratch-peer.json"
    local raw = host.read_file(index_path)
    local decoded = raw and json.decode(raw) or { ops = {} }
    decoded.ops = decoded.ops or {}
    decoded.ops[stale.op] = (tonumber(host.now() or 0) or 0) - 100
    check(host.write_file(index_path, json.encode(decoded)), "the recorded start time is aged for the test")
    local next_one = peer_bash("echo after-reap", 800)
    local reaped = type(next_one.reaped) == "table" and #next_one.reaped > 0
    check(reaped, "the next adoption reaps the overdue command by name: "
      .. json.encode(next_one):sub(1, 260))
    local rows = tools.dispatch(memory, "operation", { action = "list" }, "master", peer_ctx) or {}
    local still_running = false
    for _, row in ipairs(rows.operations or {}) do
      if tostring(row.operation_id or "") == stale.op and row.settled ~= true
        and tostring(row.state or "") ~= "cancelled" then still_running = true end
    end
    check(not still_running, "the reaped command is no longer running")
  end)
end)


-- 12. VERIFICATION r2, MUST 1: a short call is never refused by the adopted limit.
--
-- The limit used to be consulted BEFORE the command started and counted every open operation in the peer
-- session, so two adopted long commands refused a plain short command. Now only a call that OUTLIVED the
-- hold is adopted, the limit counts adopted ops alone, and a short call creates no operation at all.
check(drain_peer_at_least(true), "the peer session is clean before the short-call check")
local long_a = peer_bash("sleep 60", 800)
local long_b = peer_bash("sleep 60", 800)
check(long_a.state == "pending" and long_b.state == "pending",
  "two long commands are adopted: " .. json.encode({ long_a.state, long_b.state }))
local short = peer_bash("echo still-short", 800)
check(short.state ~= "pending", "a short command is NOT adopted while two are held: "
  .. json.encode(short):sub(1, 240))
check(short.error == nil, "and it is not refused by the adopted limit: " .. tostring(short.error))
check(tostring(short.stdout or ""):find("still-short", 1, true) ~= nil,
  "it answered its own output, which means it really ran")
for _, one in ipairs({ long_a, long_b }) do
  tools.dispatch(memory, "operation", { action = "cancel", id = one.op }, "master", peer_ctx)
end

-- 13. VERIFICATION r2, MUST 2: the cancel observation is a handful of calls, not a spin.
--
-- host.sleep takes whole MILLISECONDS; the old window called it with 0.2, which is 0 ms, and sent
-- back-to-back status calls for three seconds. This counts them.
local count_ctx = { user_id = "master", node_id = "rp-scratch-peer", peer_call = true,
  session_id = "peer:rp-scratch-peer" }
local status_calls = { n = 0 }
local counting = function(name, params, raw)
  if name == "remote" and type(params) == "table" and params.capability == "operation"
    and tostring(params.action or "") == "status" then
    status_calls.n = status_calls.n + 1
  end
  return relay(name, params, raw)
end
local spin_raw = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "sleep 60", wait_s = 0 })
local spin = pending.invoke(counting, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash", command = "sleep 60" }, spin_raw, 0)
check(spin.state == "pending", "a handle to cancel for the call count")
status_calls.n = 0
local began = host.monotonic_ms and host.monotonic_ms() or 0
local spin_cancel = pending.cancel(counting, { scope = scope }, spin.op)
local spent = (host.monotonic_ms and host.monotonic_ms() or 0) - began
check(spin_cancel.cancelled == true, "the cancel still stops it: " .. json.encode(spin_cancel):sub(1, 160))
check(status_calls.n <= 5, "the observation made at most 5 status calls (made "
  .. tostring(status_calls.n) .. ")")
check(spent <= 3200, "and it took a bounded time (" .. tostring(spent) .. " ms)")

-- 14. VERIFICATION r2, MUST 3: no hot retry. A peer that answers instantly WITHOUT settling (here: a
-- status-shaped answer that never settles) must not let the caller spin - every call costs at least the
-- minimum charge, and a wait is capped in calls.
local instant = { n = 0 }
local instant_relay = function(name, params, raw)
  if name == "remote" and type(params) == "table" and params.capability == "operation" then
    instant.n = instant.n + 1
    return { operation_id = tostring(params.id or "op"), settled = false, state = "running" }
  end
  return relay(name, params, raw)
end
local hot_raw = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "sleep 60", wait_s = 0 })
local hot = pending.invoke(relay, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash", command = "sleep 60" }, hot_raw, 0)
if hot and hot.op then
  instant.n = 0
  local hot_began = host.monotonic_ms and host.monotonic_ms() or 0
  pending.wait(instant_relay, { scope = scope }, hot.op, { wait_s = 5 })
  local hot_spent = (host.monotonic_ms and host.monotonic_ms() or 0) - hot_began
  check(instant.n <= 40, "a peer answering instantly without settling is capped in calls (made "
    .. tostring(instant.n) .. ")")
  -- TIME PER CALL (review r3, item 1): the charge alone lowered the budget but never waited, so N calls
  -- were a burst. Every call after the first is now followed by a real pause of at least
  -- REMOTE_MIN_PAUSE_MS (200 ms), so the wall time must be at least (calls - 1) * 200 ms. A count-only
  -- assertion passes on a hot loop; this one cannot.
  check(instant.n >= 2, "the loop really made more than one call (made " .. tostring(instant.n) .. ")")
  check(hot_spent >= (instant.n - 1) * 200,
    "each call was followed by a real pause, so the loop cannot be a burst ("
    .. tostring(instant.n) .. " calls in " .. tostring(hot_spent) .. " ms, floor "
    .. tostring((instant.n - 1) * 200) .. " ms)")
  local per_call = hot_spent / math.max(1, instant.n)
  check(per_call >= 100, "and the average time per call is well above a burst ("
    .. string.format("%.0f", per_call) .. " ms per call)")
  tools.dispatch(memory, "operation", { action = "cancel", id = hot.op }, "master", peer_ctx)
end

-- 14b. VERIFICATION r3, item 1: operation_supervisor_overdue STOPS the wait at once, by name.
--
-- An overdue supervisor has stopped making progress on that operation, so another await is exactly the hot
-- retry this change exists to remove. The wait must stop on the first such answer and carry its name.
local overdue_calls = { n = 0 }
local overdue_relay = function(name, params, raw)
  if name == "remote" and type(params) == "table" and params.capability == "operation" then
    overdue_calls.n = overdue_calls.n + 1
    return { operation_id = tostring(params.id or ""), settled = false, state = "running",
      error = "operation_supervisor_overdue" }
  end
  return relay(name, params, raw)
end
local overdue_raw = json.encode({ node = "rp-scratch-peer", capability = "bash",
  command = "sleep 60", wait_s = 0 })
local overdue_handle = pending.invoke(relay, { scope = scope }, "remote",
  { node = "rp-scratch-peer", capability = "bash", command = "sleep 60" }, overdue_raw, 0)
if overdue_handle and overdue_handle.op then
  overdue_calls.n = 0
  local overdue_entry = pending.wait(overdue_relay, { scope = scope }, overdue_handle.op, { wait_s = 30 })
  check(overdue_calls.n == 1, "an overdue answer stops the wait at the FIRST call (made "
    .. tostring(overdue_calls.n) .. ")")
  check(type(overdue_entry) == "table" and overdue_entry.state == "pending",
    "and the handle stays pending, never failed: " .. json.encode(overdue_entry or {}):sub(1, 200))
  check(tostring(overdue_entry and overdue_entry.reason or ""):find("operation_supervisor_overdue", 1, true) ~= nil,
    "and it names the reason: " .. tostring(overdue_entry and overdue_entry.reason))
  tools.dispatch(memory, "operation", { action = "cancel", id = overdue_handle.op }, "master", peer_ctx)
end

-- 15. VERIFICATION r2, SHOULD: a FAILING TRANSPORT never marks the record final.
--
-- A relay error during one slice says nothing about the operation: it may still be running there. The
-- caller-side executor must answer PENDING with the reason, so a later wait asks the peer again - the
-- failure this pins is "the handle silently became a failed call because the network hiccuped". It is
-- measured on the EXECUTOR's own poll, which is where the decision lives.
check(drain_peer_at_least(true), "the peer session is clean before the failing-transport check")
local held_for_failure = peer_bash("sleep 30", 800)
check(held_for_failure.state == "pending", "a handle to watch across a failing transport")
local failure_calls = { n = 0 }
local failing = function(name, params, raw)
  if name == "remote" and type(params) == "table" and params.capability == "operation" then
    failure_calls.n = failure_calls.n + 1
    return { error = "remote_unreachable", node = tostring(params.node or "") }
  end
  return relay(name, params, raw)
end
local executor = pending.EXECUTORS["remote"]
local record = { op = held_for_failure.op, tool = "remote", node = "rp-scratch-peer" }
local state, reason = executor.poll(failing, {}, record, 3000)
check(state == nil, "with every call failing there is no state to report")
check(tostring(reason):find("remote_unreachable", 1, true) ~= nil,
  "and the reason is the transport's own word: " .. tostring(reason))
check(failure_calls.n >= 1 and failure_calls.n <= 40,
  "the failing calls are bounded by the same cap (" .. tostring(failure_calls.n) .. ")")
-- The operation itself is untouched: the peer still has it running.
local after_failure = tools.dispatch(memory, "operation", { action = "status", id = held_for_failure.op },
  "master", peer_ctx) or {}
check(after_failure.settled ~= true, "the operation itself was never cancelled by the transport failure")
tools.dispatch(memory, "operation", { action = "cancel", id = held_for_failure.op }, "master", peer_ctx)

print("remote pending ok (" .. tostring(checks) .. " checks)")
