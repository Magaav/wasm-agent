-- Session recovery: what an interrupted thread is, and what recovering does.
--
--   WA_SCRIPT=scripts/test-recovery.lua wa --db /tmp/wa-recovery.db
--
-- Run by scripts/test.sh (the cloud gate) and by scripts/test-windows.ps1 (a
-- node's own suite), so it is one test rather than two that drift. It needs no
-- model: everything asserted here is the ledger, the derived state and the
-- context the agent would send - the three places an interruption is decided.
--
-- The cases are built by hand instead of by killing a process: a killed process
-- leaves a specific shape in the ledger, and that shape is the contract. A test
-- that kills a child would assert the timing of a signal, not the contract.

local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()

local function session(title)
  return memory.start_session("", "chat", { user_id = "master", node_id = "", title = title })
end
local function state(id, opts) return memory.session_state(id, opts) end
local function call(id, name)
  return { id = id, type = "function", ["function"] = { name = name, arguments = "{}" } }
end
-- Which threads does a reader see as waiting, and what does it claim about them?
local function waiting(id)
  for _, found in ipairs(memory.interrupted(nil, 100, { stranded_after = 45 })) do
    if found.session_id == id then return found end
  end
end

-- ------------------------------------------------------------- what it looks like
-- empty: nothing said yet. Not an interruption - there is nothing to recover.
local empty = session("empty")
assert(state(empty).state == "empty", "a fresh session must be empty")
assert(waiting(empty) == nil, "an empty session is not waiting for anything")
assert(state("no-such-session") == nil, "an unknown session must resolve to nil")

-- answered: the settled shape. Silence about a thread must mean this.
local settled = session("settled")
memory.append_turn(settled, { role = "user", content = "what is 2+2" })
memory.append_turn(settled, { role = "assistant", content = "4" })
assert(state(settled).state == "answered", "a reply must settle the thread, got " .. state(settled).state)
assert(waiting(settled) == nil, "a settled thread must not be reported as waiting")

-- failed: the model call errored. This is a *landed* outcome, and calling it an
-- interruption would send the reader looking for work that never started.
local failed = session("failed")
memory.append_turn(failed, { role = "user", content = "hello" })
memory.append_turn(failed, { role = "assistant", content = "", ok = false })
assert(state(failed).state == "failed", "an errored model call is not an interruption")
assert(waiting(failed) == nil, "a failed turn must not be listed as interrupted")
assert((tonumber(memory.session(failed).interrupted_count) or 0) == 0,
  "a failed turn must not be recorded as an interruption")

-- unfinished (1): asked, never answered. The process died between the question
-- and the model's reply.
local asked = session("asked")
memory.append_turn(asked, { role = "user", content = "make the test pass" })
local asked_state = state(asked)
assert(asked_state.state == "unfinished",
  "an unanswered question is unfinished, not proven interrupted: " .. asked_state.state)
assert(asked_state.question == "make the test pass", "the question must be carried for the report")
assert(asked_state.detail:find("not answered", 1, true), "the detail must say what is missing")
-- The claim, made by a reader that knows the process is gone.
local claimed = state(asked, { claimed = true })
assert(claimed.state == "interrupted", "a claimed unfinished tail reads as interrupted")
assert(claimed.detail:find("interrupted", 1, true), "the claim must be visible in the detail")
assert(waiting(asked) and waiting(asked).session_id == asked, "the thread must be listed as waiting")

-- unfinished (2): a decision whose tools never reported.
local mid = session("mid-tools")
memory.append_turn(mid, { role = "user", content = "run two things" })
memory.append_turn(mid, { role = "assistant", content = "", tool_calls = { call("c1", "bash"), call("c2", "read") } })
local mid_state = state(mid)
assert(mid_state.state == "unfinished", "a decision with no results is unfinished")
assert(#mid_state.pending == 2, "both calls must be reported unfinished, got " .. #mid_state.pending)
assert(mid_state.detail:find("2 tool call(s)", 1, true), "the detail must count the calls: " .. mid_state.detail)

-- unfinished (3): the sharp case. Two calls, one result - the process died
-- *between* the tool calls, so exactly one of them is unfinished. Reporting both
-- (or neither) would misdescribe the work that is actually missing.
local partial = session("partial-tools")
memory.append_turn(partial, { role = "user", content = "run two things" })
memory.append_turn(partial, { role = "assistant", content = "",
  tool_calls = { call("p1", "bash"), call("p2", "read") } })
memory.append_turn(partial, { role = "tool", tool_call_id = "p1", tool_name = "bash", content = '{"code":0}' })
local partial_state = state(partial)
assert(partial_state.state == "unfinished", "a half-written exchange is unfinished")
assert(#partial_state.pending == 1 and partial_state.pending[1] == "read",
  "only the call with no result may be reported unfinished")
assert(partial_state.detail:find("batch", 1, true),
  "the detail must say which of the batch is missing: " .. partial_state.detail)

-- unfinished (4): died after the result. The exchange is complete but nothing
-- followed it, so there is no answer to read - different missing work from (2),
-- and it must not be reported as a call that never ran.
local after = session("after-tool")
memory.append_turn(after, { role = "user", content = "run it" })
memory.append_turn(after, { role = "assistant", content = "", tool_calls = { call("a1", "bash") } })
memory.append_turn(after, { role = "tool", tool_call_id = "a1", tool_name = "bash", content = '{"code":0}' })
local after_state = state(after)
assert(after_state.state == "unfinished", "a tool result with nothing after it is unfinished")
assert(#after_state.pending == 0, "a call that reported is not unfinished")
assert(after_state.detail:find("tool result", 1, true), "the detail must say where it stopped")

print("state derivation ok")

-- ------------------------------------------------- live turn vs lost turn
-- The reason the state is called `unfinished` and not `interrupted`: from the
-- ledger a turn in flight in a *live* process is identical to one whose process was
-- killed, because a tool result lands when it lands. This is not hypothetical - a
-- status run described the tool call it was itself running as a lost one, and
-- called a healthy process a crashed thread. The classification must not make that
-- claim on its own; the reader must add it.
--
-- Age is the one part of the claim the ledger does support: no tool call runs for
-- 45 seconds, so a tail that old is stranded.
local now_state = state(mid)
assert(now_state.state == "unfinished",
  "a fresh tail must never be reported as interrupted without a claim: " .. now_state.state)
assert(now_state.detail:find("never reported", 1, true),
  "the detail must describe what is missing, not assert a death: " .. now_state.detail)
assert(not now_state.detail:find("died", 1, true), "the detail must not claim the process died")
assert(not now_state.detail:find("interrupted", 1, true), "the detail must not claim an interruption")
local fresh = waiting(mid)
assert(fresh and not fresh.stranded, "a just-written tail is not stranded")
assert(fresh.state == "unfinished", "the listing must not upgrade a fresh tail on its own")
-- The same tail, but old: now the reader can say it is not still running.
local stale = session("stale")
memory.append_turn(stale, { role = "user", content = "run it" })
memory.append_turn(stale, { role = "assistant", content = "", tool_calls = { call("s1", "bash") } })
local conn = dofile("lua/core/memory.lua")
-- Backdate the tail by writing the turn's timestamp directly: the only way to
-- build an aged tail without waiting, and it is the *reader's* threshold - not the
-- turn - that is under test.
memory.exec("UPDATE turns SET created_at=? WHERE session_id=? AND seq=(SELECT MAX(seq) FROM turns WHERE session_id=?)",
  { host.now() - 3600, stale, stale })
local aged = state(stale)
assert(aged.at and (host.now() - aged.at) > 45, "the tail must be old enough to be stranded")
local reported = waiting(stale)
assert(reported and reported.stranded, "an aged tail must be reported as stranded")
assert(reported.detail:find("stranded", 1, true), "the report must say stranded: " .. reported.detail)

print("live turn vs lost turn ok")

-- ------------------------------------------------------- the durable record
-- Deriving is enough to *see* an unfinished tail, but it forgets: once the thread is
-- resumed the tail is an answer again. The record is what survives, and it must
-- count interruption points, not observations.
assert(memory.session(asked).interrupted_at == nil, "reading a state must not write anything")
local recorded = memory.mark_interrupted(asked, { reason = claimed.detail })
assert(recorded ~= nil, "marking an interruption must report what it recorded")
assert(memory.session(asked).interrupted_seq == claimed.seq,
  "the record must point at the turn that stopped")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 1, "the first mark counts once")
assert(memory.mark_interrupted(asked) == nil, "the same interruption point must not be recorded twice")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 1,
  "re-claiming the same tail must not inflate the count")

-- A second, later interruption is a second point: the agent was cut off twice.
memory.append_turn(asked, { role = "tool", tool_call_id = "x", tool_name = "bash", content = "{}" })
assert(state(asked).state == "unfinished", "still unfinished after the result")
assert(memory.mark_interrupted(asked) ~= nil, "a new interruption point must record")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 2, "two points, two marks")
assert(memory.mark_interrupted("no-such-session") == nil, "an unknown session cannot be marked")

-- Recovering must not erase the evidence: settle the thread by hand and check the
-- state is now clean *and* the history is still there.
memory.append_turn(asked, { role = "assistant", content = "done" })
local recovered = state(asked)
assert(recovered.state == "answered", "the thread must be settled after a reply")
assert(recovered.interruptions == 2 and recovered.recorded_reason ~= "",
  "the recorded interruptions must survive being recovered from")
assert(memory.turn_count(asked) == #memory.session_turns(asked, { limit = 100 }),
  "turn_count must agree with the ledger, got " .. memory.turn_count(asked))

print("durable record ok")

-- ------------------------------------------------ what the agent is told
-- The transcript of an interrupted thread just ends. The model would otherwise
-- assume its last step either succeeded or never ran, and both are wrong. The
-- notice goes into the request context only.
local notice_session = session("notice")
memory.append_turn(notice_session, { role = "user", content = "fix the failing test" })
memory.append_turn(notice_session, { role = "assistant", content = "",
  tool_calls = { call("n1", "bash") } })

local events = {}
local bot = agentlib.new(notice_session, function(event) events[#events + 1] = event end, "master", "master", "")
local before_turns = memory.turn_count(notice_session)
local notice = bot:note_interruption()
assert(type(notice) == "string", "an unfinished thread must produce a notice")
assert(notice:find("Recovery notice", 1, true), "the notice must announce itself")
assert(notice:find("bash", 1, true), "the notice must name the unfinished call")
assert(notice:find("1 tool call(s)", 1, true), "the notice must describe where it stopped")
assert(notice:find("git status", 1, true), "the notice must say to re-establish the real state")
assert(notice:find("may have run", 1, true), "the notice must warn the step may have run anyway")
local announced = false
for _, event in ipairs(events) do
  if event.type == "status" and tostring(event.text):find("interrupted", 1, true) then announced = true end
end
assert(announced, "the user must see the recovery, not only the model")
-- Once per process: the second call in the same process returns the cached notice.
assert(bot:note_interruption() == notice, "the notice must be computed once and kept")
assert((tonumber(memory.session(notice_session).interrupted_count) or 0) == 1,
  "noticing an interruption must record it exactly once")

local messages = bot:build_context()
local notices, systems = 0, 0
for _, message in ipairs(messages) do
  if message.role == "system" then
    systems = systems + 1
    if message.content:find("Recovery notice", 1, true) then notices = notices + 1 end
  end
end
assert(notices == 1, "the notice must reach the context exactly once, saw " .. notices)
assert(systems >= 2, "the notice must be added, not replace the system prompt")
-- Position matters: the first message is the stable prefix the provider caches,
-- and the notice is per-turn. Putting it there would bust the cache every turn.
assert(not messages[1].content:find("Recovery notice", 1, true),
  "the notice must not sit in the cached system prefix")
-- Rebuilding mid-turn (compaction does exactly that) must not stack notices up.
local rebuilt = bot:build_context()
local again = 0
for _, message in ipairs(rebuilt) do
  if message.role == "system" and message.content:find("Recovery notice", 1, true) then again = again + 1 end
end
assert(again == 1, "rebuilding the context must not duplicate the notice, saw " .. again)

-- The transcript is what was said, and memory is indexed from it: a synthetic
-- turn in the ledger would be replayed to every later request as if the agent had
-- said it, and would be found by search_turns.
assert(memory.turn_count(notice_session) == before_turns,
  "the notice must not be written to the transcript")
for _, turn in ipairs(memory.session_turns(notice_session, { limit = 100 })) do
  assert(turn.role ~= "system", "a system turn must never enter the transcript")
end
assert(#memory.search_turns("Recovery notice", nil, 10) == 0,
  "the notice must not be searchable as if the agent had said it")

-- Negative control: a settled thread gets no notice and no record, so the whole
-- mechanism above cannot pass by always firing.
local quiet = session("quiet")
memory.append_turn(quiet, { role = "user", content = "hi" })
memory.append_turn(quiet, { role = "assistant", content = "hello" })
local calm = agentlib.new(quiet, function() end, "master", "master", "")
assert(calm:note_interruption() == false, "a settled thread must not be announced as interrupted")
for _, message in ipairs(calm:build_context()) do
  if message.role == "system" then
    assert(not message.content:find("Recovery notice", 1, true),
      "a settled thread must not carry a recovery notice")
  end
end
assert((tonumber(memory.session(quiet).interrupted_count) or 0) == 0,
  "a settled thread must not be recorded as interrupted")

print("recovery notice ok")

-- ------------------------------------------------------------ the engine view
-- The sessions list travels with each thread's state, or the view shows two
-- identical rows for "answered" and "the process died here". It is one query:
-- a per-row state lookup would be an N+1 on a list of 50.
local listed = {}
for _, row in ipairs(memory.list_sessions(nil, 200, { states = true })) do listed[row.id] = row end
assert(listed[mid] and listed[mid].state == "unfinished", "the list must mark an unfinished thread")
assert(listed[mid].state_detail and listed[mid].state_detail:find("read", 1, true) ~= nil,
  "the list must carry the reason, so a reader does not open every session")
assert(listed[settled] and listed[settled].state == "answered", "the list must mark a settled thread")
-- Without the flag the old row shape is preserved: the field is opt-in.
for _, row in ipairs(memory.list_sessions(nil, 5)) do
  assert(row.state == nil, "state must be opt-in, not a silent change to every caller")
end

print("recovery ok")
