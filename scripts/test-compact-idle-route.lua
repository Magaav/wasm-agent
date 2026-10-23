-- /compact after a main run has settled.
--
-- The listener admits /compact node-wide: a queued or running scheduler run is answered
-- before this handler is called (rust/wa-host/src/serve.rs compact_begin). The handler's
-- own cached `agent` is only the object this node-thread built, and agent.lua leaves the
-- last run's id on it as that run's identity. Before this test existed, wa_compact treated
-- that settled id as liveness: after the first chat it returned node_busy forever, so
-- onStale never compacted an idle node. This is a route test, not a claim about the
-- scheduler: the queued/running refusal is proved by Rust's compact_admission tests.
--
-- No model is called. min_percent 95 keeps even the system prompt well under the trigger,
-- so the handler selects and measures the session but writes no summary.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local users = dofile("lua/core/users.lua")
dofile("lua/core/server.lua")

local checks = 0
local function ok(value, label)
  assert(value, label)
  checks = checks + 1
end

local master = users.login("master")
local guest = users.login("guest")
ok(master ~= nil and guest ~= nil, "master and guest credentials issued")

local sid = memory.start_session("", "chat", { user_id = "master", title = "compact-idle" })
memory.append_turn(sid, { role = "user", content = "a short main session" })

-- The state a cached agent is in when its main run has settled: run_id names the run that
-- just finished and is not cleared (agent.lua:1184 sets it at every start).
local cached = wa_agent_for(master, "", sid)
ok(cached ~= nil and cached.session_id == sid, "the main session's agent is cached")
ok(cached.run_id == nil, "no run has started in this process yet")
cached.run_id = "settled-main-run"
ok(wa_agent_for(master, "", sid) == cached, "the same agent object stays cached with that id")

-- 1. The regression. An idle node must not be refused because the cached agent remembers
--    a run that already finished. The old guard answered {ok=false,error=node_busy} here.
local explicit = json.decode(wa_compact(json.encode({ session_id = sid, min_percent = 95 }), master))
ok(explicit.ok == true, "idle /compact is not refused after a settled run")
ok(explicit.error ~= "node_busy", "the settled run's id is not liveness")
ok(explicit.compacted == false, "95% leaves this small context alone")
ok(type(explicit.percent) == "number" and explicit.percent > 0 and explicit.percent < 95,
  "the handler measured the selected session")
ok(type(explicit.capacity) == "number" and explicit.capacity > 0, "the context window is known")

-- 2. The onStale shape posts no session_id and relies on latest-main selection. It must
--    reach the same session and stay equally free of the stale refusal.
local selected = json.decode(wa_compact(json.encode({ min_percent = 95 }), master))
ok(selected.ok == true, "onStale's session-less /compact is admitted while idle")
ok(selected.error ~= "node_busy", "latest-main selection takes no node_busy route")
ok(selected.compacted == false, "the selected session is still below the 95% threshold")
ok(selected.before == explicit.before and selected.capacity == explicit.capacity,
  "both request shapes selected the same latest main session")

-- 3. The parts of the handler the Rust gate does not own are unchanged.
ok(json.decode(wa_compact(json.encode({ session_id = sid, min_percent = 95 }), guest)).error == "forbidden",
  "master authorization still refuses a guest")
local child = memory.start_session("subagent", "subagent", { user_id = "master", parent_session_id = sid })
ok(json.decode(wa_compact(json.encode({ session_id = child, min_percent = 95 }), master)).error
  == "subagent_compaction_refused", "subagent threads are still never summarized")
ok(json.decode(wa_compact(json.encode({ session_id = sid, min_percent = 96 }), master)).error
  == "invalid_compact_percent", "the 40..95 threshold range is still enforced")
ok(json.decode(wa_compact('{"session_id":', master)).error == "invalid_compact_request",
  "malformed bodies are still refused")

print("compact idle route ok (" .. checks .. " checks, 0 skipped)")
