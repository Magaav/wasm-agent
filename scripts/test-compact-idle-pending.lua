-- Idle compaction never fires while the session it targets still has work.
--
-- With always-available a session is idle while its own work still runs, and the idle maintenance
-- path (docs/CONTEXT-COMPACTION.md, "Idle maintenance (40%)": the onStale job on `node.run_finished`
-- posts /compact with min_percent:40) used to rewrite that history in the middle of it - breaking
-- the provider prefix cache and dropping the detail the pending work is about to be read against.
-- The rule (Victor, 21/11) is: an IDLE /compact is refused, by name, while the target session has
--
--   1. a pending code-mode handle (lua/core/codemode_pending.lua, state running/unknown/pending),
--   2. a pending self-wake (the `self_wakes` table, status pending/dispatching), or
--   3. a child run still queued or running for it.
--
-- The checks below drive the route itself (wa_compact, the function the listener calls) with the
-- body scripts/on-stale.sh posts (`idle:true`) and with an explicit operator body (no `idle`), so
-- both halves of the rule are measured: the idle path refuses, the operator path is unchanged, and
-- once all three are clear the same idle request is admitted, selects the session and measures it.
-- Nothing here calls a model: min_percent 95 leaves even the system prompt under the trigger, so a
-- request that is admitted writes no summary.
--
-- Every store is the node's own (the pending index directory, the self_wakes table, the sessions and
-- agent_control rows), not a stub, so the answer is the one the installed node would give.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger and a pending index: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local users = dofile("lua/core/users.lua")
local pending = dofile("lua/core/codemode_pending.lua")
local selfloop = dofile("lua/core/selfloop.lua")
local control = dofile("lua/core/agent_control.lua")
local paths = dofile("lua/core/paths.lua")
dofile("lua/core/server.lua")

local checks = 0
local function ok(value, label)
  assert(value, label)
  checks = checks + 1
end
local function joined(list)
  if type(list) ~= "table" then return "" end
  return table.concat(list, ", ")
end
-- The shape scripts/on-stale.sh posts; an explicit operator /compact carries no `idle`.
local function idle_compact(master, session_id)
  local body = { idle = true, min_percent = 95 }
  if session_id then body.session_id = session_id end
  return json.decode(wa_compact(json.encode(body), master))
end
local function explicit_compact(master, session_id)
  return json.decode(wa_compact(json.encode({ session_id = session_id, min_percent = 95 }), master))
end

local master = users.login("master")
ok(master ~= nil, "master credentials issued")
local sid = memory.start_session("", "chat", { user_id = "master", title = "compact-idle-pending" })
memory.append_turn(sid, { role = "user", content = "a session that leaves work running" })

-- 0. Nothing is pending yet: the idle request is admitted and measured, which is the baseline every
--    refusal below is measured against (a refusal that fires on a clear session would compact never).
local clear = idle_compact(master, sid)
ok(clear.ok == true and clear.error == nil, "a session with no pending work admits the idle compaction: "
  .. tostring(clear.error))
ok(type(clear.percent) == "number" and clear.percent > 0, "and it measured the session")
ok(clear.compacted == false, "95% leaves this small context alone (no model call, no summary written)")

-- 1. One pending code-mode handle, as the node records it for a call that outlived its wait.
local scope = host.sha256(json.encode({ session = sid, user = "master", role = "master" }))
local function save_handle(session_id, state)
  local ops = {}
  if session_id then
    ops["op-fixture"] = { op = "op-fixture", tool = "bash", kind = "operation", scope = scope,
      session = session_id, started_at = host.now(), state = state or "running", reported = false }
  end
  assert(pending.save(scope, { ops = ops }), "the pending index was written")
end
save_handle(sid)
local refused = idle_compact(master, sid)
ok(refused.ok == false and refused.error == "work_pending",
  "one pending code-mode handle refuses the idle compaction by name: " .. tostring(refused.error))
ok(tostring(refused.session_id) == tostring(sid), "the refusal names the session it refused for")
ok(joined(refused.pending):find("code%-mode handle") ~= nil,
  "and says what is pending: " .. joined(refused.pending))
ok(refused.percent == nil, "nothing was measured and no summary was written")
local held, unreadable = pending.session_open(sid)
ok(held == 1, "the session's own pending handle is counted by the reader (" .. tostring(held) .. ")")
ok(unreadable == 0, "and nothing in the index was unreadable")
local via_fallback = json.decode(wa_compact(json.encode({ idle = true, min_percent = 95 }), master))
ok(via_fallback.ok == false and via_fallback.error == "work_pending",
  "onStale's session-less fallback shape is refused the same way: " .. tostring(via_fallback.error))
local operator = explicit_compact(master, sid)
ok(operator.ok == true, "an explicit operator /compact is unchanged: it is not this check's business ("
  .. tostring(operator.error) .. ")")
ok(type(operator.percent) == "number", "the explicit request still measured the session")
-- A handle of ANOTHER session is not this session's work: the answer is scoped, not node-wide.
save_handle("someone-elses-session")
ok(pending.session_open(sid) == 0, "another session's handle is not counted for this one")
ok(idle_compact(master, sid).ok == true, "so it does not block this session's idle compaction")
save_handle(nil)

-- 2. A pending self-wake: due in ten minutes, so nothing dispatches here - the row is what counts.
local scheduled = selfloop.schedule({ session_id = sid, reason = "fixture wake", prompt = "fixture",
  in_seconds = 600 }, { user_id = "master", session_id = sid })
ok(scheduled and scheduled.ok == true, "a self-wake is scheduled for the session")
ok(tonumber(selfloop.summary(sid).total) == 1, "the session has one pending wake")
refused = idle_compact(master, sid)
ok(refused.ok == false and refused.error == "work_pending", "a pending self-wake refuses it too: "
  .. tostring(refused.error))
ok(joined(refused.pending):find("self%-wake") ~= nil, "and names the wake: " .. joined(refused.pending))
-- `dispatching` is the other half of the brief's rule: a wake already handed to the scheduler.
host.sql_exec("UPDATE self_wakes SET status='dispatching' WHERE session_id=?", json.encode({ sid }))
refused = idle_compact(master, sid)
ok(refused.ok == false and refused.error == "work_pending", "a dispatching wake refuses it as well: "
  .. tostring(refused.error))
host.sql_exec("UPDATE self_wakes SET status='cancelled' WHERE session_id=?", json.encode({ sid }))
ok(tonumber(selfloop.summary(sid).total) == 0, "cancelling the wake clears the session")
ok(idle_compact(master, sid).ok == true, "and the idle compaction is admitted again")

-- 3. A child run queued or running for the session. The child is a real session row and a real
--    agent_control row; `children_of` is the same reader the control API answers `tree` from.
local child = memory.start_session("subagent", "subagent",
  { user_id = "master", title = "fixture child", parent_session_id = sid })
host.sql_exec("CREATE TABLE IF NOT EXISTS agent_control(child_id TEXT PRIMARY KEY, parent_session TEXT,"
  .. " parent_run TEXT, kind TEXT, source_session TEXT, source_seq INTEGER, node TEXT, created_at REAL)",
  json.encode({}))
host.sql_exec("INSERT INTO agent_control(child_id,parent_session,parent_run,kind,source_session,source_seq,node,created_at)"
  .. " VALUES(?,?,?,?,?,?,?,?)",
  json.encode({ child, sid, "", "fork", sid, 1, "", host.now() }))
local children = control.children_of(sid, { user_id = "master", session_id = sid })
local running = 0
for _, item in ipairs(children) do if item.state == "running" then running = running + 1 end end
ok(running == 1, "the session has one running child (" .. tostring(running) .. ")")
refused = idle_compact(master, sid)
ok(refused.ok == false and refused.error == "work_pending", "a running child refuses it too: "
  .. tostring(refused.error))
ok(joined(refused.pending):find("child run") ~= nil, "and names the child: " .. joined(refused.pending))
local closed = memory.finish_session(child)
ok(closed == true, "the child's own run is settled")
children = control.children_of(sid, { user_id = "master", session_id = sid })
local live = 0
for _, item in ipairs(children) do
  if item.state == "running" or item.state == "queued" or item.state == "cancelling" then live = live + 1 end
end
ok(live == 0, "no child of the session is still queued or running")

-- 4. Every one of the three is clear: the same idle request is performed - admitted, the session
--    selected, the context measured. (No model is called: 95% is above this context.)
local performed = idle_compact(master, sid)
ok(performed.ok == true and performed.error == nil, "with all three clear the idle compaction runs: "
  .. tostring(performed.error))
ok(type(performed.percent) == "number" and type(performed.capacity) == "number" and performed.capacity > 0,
  "and it measured the selected session against a known window")
ok(performed.compacted == false, "still no summary at 95%, so this test spent nothing")

-- 5. Unknown is not yes: an index file whose contents cannot be decoded is not read as "no handles".
local dir = paths.data() .. "/codemode-pending"
local broken = dir .. "/fixture-unreadable.json"
ok(host.write_file(broken, "{not json") == true, "a corrupt index file was put in the pending directory")
local corrupt = idle_compact(master, sid)
ok(corrupt.ok == false and corrupt.error == "work_pending",
  "an index that cannot be read refuses the compaction rather than reading as clear: "
  .. tostring(corrupt.error))
ok(joined(corrupt.unknown):find("could not be read") ~= nil,
  "and it says which state is unknown: " .. joined(corrupt.unknown))
ok(host.write_file(broken, json.encode({ ops = {} })) == true, "the same file is repaired")
ok(idle_compact(master, sid).ok == true, "and the idle compaction is admitted once nothing is unknown")

-- 6. THE SETTLE RETRY. A settled handle, a fired self-wake and a returned child all reach the node
--    as a background completion run, and none of them is a /chat run: no `node.run_finished` is
--    emitted, so `onStale` is never asked again and the idle compaction the same work had refused
--    was lost until the person typed. The node asks again where the work settled
--    (rust/wa-capabilities/src/serve.rs, `settle_idle_compaction`), under the same maintenance gate
--    `/compact` takes, and this is the function it asks: the same three states, the same names.
ok(type(wa_idle_settled) == "function", "the node's settle retry has an entry point to call")
local function settle(session_id)
  return json.decode(wa_idle_settled(json.encode({ session_id = session_id })))
end

-- 6a. A pending code-mode handle refuses the settle retry by name, exactly as the idle request is.
save_handle(sid)
local settled_refused = settle(sid)
ok(settled_refused.ok == false and settled_refused.error == "work_pending",
  "a pending handle refuses the settle retry by name: " .. tostring(settled_refused.error))
ok(tostring(settled_refused.session_id) == tostring(sid), "and it names the session it refused for")
ok(joined(settled_refused.pending):find("code%-mode handle") ~= nil,
  "and says what is still pending: " .. joined(settled_refused.pending))
ok(settled_refused.percent == nil, "nothing was measured and no summary was written")
save_handle(nil)

-- 6b. A pending self-wake refuses it too - the state the settle retry is most likely to meet: the
--     wake that just fired settles while the next one is still scheduled.
local next_wake = selfloop.schedule({ session_id = sid, reason = "fixture wake 2", prompt = "fixture",
  in_seconds = 600 }, { user_id = "master", session_id = sid })
ok(next_wake and next_wake.ok == true, "a second self-wake is scheduled for the session")
settled_refused = settle(sid)
ok(settled_refused.ok == false and settled_refused.error == "work_pending",
  "a pending self-wake refuses the settle retry: " .. tostring(settled_refused.error))
ok(joined(settled_refused.pending):find("self%-wake") ~= nil,
  "and names the wake: " .. joined(settled_refused.pending))
host.sql_exec("UPDATE self_wakes SET status='cancelled' WHERE session_id=?", json.encode({ sid }))

-- 6c. A running child refuses it, and that child settling is what clears the session.
host.sql_exec("UPDATE sessions SET ended_at=NULL WHERE id=?", json.encode({ child }))
host.sql_exec("DELETE FROM agent_control WHERE child_id=?", json.encode({ child }))
host.sql_exec("INSERT INTO agent_control(child_id,parent_session,parent_run,kind,source_session,source_seq,node,created_at)"
  .. " VALUES(?,?,?,?,?,?,?,?)", json.encode({ child, sid, "", "fork", sid, 2, "", host.now() }))
local child_live = 0
for _, item in ipairs(control.children_of(sid, { user_id = "master", session_id = sid })) do
  if item.state == "running" or item.state == "queued" then child_live = child_live + 1 end
end
ok(child_live == 1, "the session has one running child again (" .. tostring(child_live) .. ")")
settled_refused = settle(sid)
ok(settled_refused.ok == false and settled_refused.error == "work_pending",
  "a running child refuses the settle retry: " .. tostring(settled_refused.error))
ok(joined(settled_refused.pending):find("child run") ~= nil,
  "and names the child: " .. joined(settled_refused.pending))
ok(memory.finish_session(child) == true, "the child's run is settled")

-- 6d. All three clear: the settle retry measures the session itself, at the idle threshold (40%),
--     with nothing to summarize at this size - so this test still spends no model call.
local settled = settle(sid)
ok(settled.ok == true and settled.error == nil, "with all three clear the settle retry runs: "
  .. tostring(settled.error))
ok(tostring(settled.session_id) == tostring(sid), "and it measured the session that settled")
ok(type(settled.percent) == "number" and settled.percent > 0 and settled.percent < 40,
  "and says how full it is (" .. tostring(settled.percent) .. "%), under the idle threshold")
ok(settled.compacted == false, "so no summary is written at this size")

-- 6e. A parked session is stopped on purpose (lua/core/session_park.lua): maintenance does not
--     rewrite its history either, and it says why. Releasing it is what lets the next settle compact.
local parked = dofile("lua/core/selfloop.lua").park(sid, "master", "fixture park")
ok(parked and parked.ok == true, "the session is parked")
local settled_parked = settle(sid)
ok(settled_parked.ok == false and settled_parked.error == "session_parked",
  "a parked session is not compacted by the settle retry: " .. tostring(settled_parked.error))
ok(tostring(settled_parked.note):find("wa session release") ~= nil,
  "and the refusal names the one verb that lets it resume: " .. tostring(settled_parked.note))
dofile("lua/core/selfloop.lua").release(sid)
ok(selfloop.hold(sid) == nil, "the park is released")
ok(settle(sid).ok == true, "and the settle retry is admitted again")

-- 6f. Unknown is not yes on this path too, and the answers that are not a refusal of the work are
--     named: a subagent thread, a session that does not exist, and a body with no session at all.
local settled_subagent = settle(child)
ok(settled_subagent.ok == false and settled_subagent.error == "subagent_compaction_refused",
  "a subagent thread is never compacted by the settle retry: " .. tostring(settled_subagent.error))
local settled_missing = settle("no-such-session")
ok(settled_missing.ok == false and settled_missing.error == "session_not_found",
  "an unknown session is refused by name: " .. tostring(settled_missing.error))
ok(json.decode(wa_idle_settled("{}")).error == "invalid_settle_request",
  "a settle request with no session is refused rather than picking one")
save_handle(sid, "running")
ok(host.write_file(broken, "still not json") == true, "a corrupt index file is left in the pending directory")
local settled_corrupt = settle(sid)
ok(settled_corrupt.ok == false and settled_corrupt.error == "work_pending",
  "an unreadable pending index refuses the settle retry rather than reading as clear: "
  .. tostring(settled_corrupt.error))
ok(joined(settled_corrupt.unknown):find("could not be read") ~= nil,
  "and says which state is unknown: " .. joined(settled_corrupt.unknown))
ok(host.write_file(broken, json.encode({ ops = {} })) == true, "the index is repaired")
save_handle(nil)
ok(settle(sid).ok == true, "and the settle retry is admitted once nothing is unknown")

print("compact idle pending ok (" .. checks .. " checks, 0 skipped)")
