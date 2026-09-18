-- Session recovery: what an unfinished thread is, and what recovering does.
--
--   WA_SCRIPT=scripts/test-recovery.lua wa --db /tmp/wa-recovery.db
--
-- Run by scripts/test.sh (the cloud gate) and by scripts/test-windows.ps1 (a
-- node's own suite), so it is one test rather than two that drift. It needs no
-- model: everything asserted here is the ledger, the derived state and the
-- context the agent would send - the three places an unfinished tail is decided.
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
local function state(id) return memory.session_state(id) end
local function call(id, name)
  return { id = id, type = "function", ["function"] = { name = name, arguments = "{}" } }
end
-- Is this thread among the ones waiting? Negative controls need to ask.
local function waiting(id)
  for _, found in ipairs(memory.unfinished(nil, 100)) do
    if found.session_id == id then return found end
  end
end

-- ------------------------------------------------------------- what it looks like
-- empty: nothing said yet. Not unfinished - there is nothing to recover.
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
-- unfinished tail would send the reader looking for work that never started.
local failed = session("failed")
memory.append_turn(failed, { role = "user", content = "hello" })
memory.append_turn(failed, { role = "assistant", content = "", ok = false })
assert(state(failed).state == "failed", "an errored model call is not unfinished")
assert(waiting(failed) == nil, "a failed turn must not be listed as unfinished")
assert((tonumber(memory.session(failed).interrupted_count) or 0) == 0,
  "a failed turn must not be recorded as unfinished")

-- unfinished (1): asked, never answered. The process stopped between the question
-- and the model's reply.
local asked = session("asked")
memory.append_turn(asked, { role = "user", content = "make the test pass" })
local asked_state = state(asked)
assert(asked_state.state == "unfinished", "an unanswered question is unfinished")
assert(asked_state.question == "make the test pass", "the question must be carried for the report")
assert(asked_state.detail:find("unanswered", 1, true), "the detail must say what is missing")
assert(waiting(asked) and waiting(asked).session_id == asked, "the thread must be listed as waiting")

-- unfinished (2): a decision whose tools have no recorded result.
local mid = session("mid-tools")
memory.append_turn(mid, { role = "user", content = "run two things" })
memory.append_turn(mid, { role = "assistant", content = "", tool_calls = { call("c1", "bash"), call("c2", "read") } })
local mid_state = state(mid)
assert(mid_state.state == "unfinished", "a decision with no results is unfinished")
assert(#mid_state.pending == 2, "both calls must be reported unfinished, got " .. #mid_state.pending)
assert(mid_state.detail:find("2 tool call(s)", 1, true), "the detail must count the calls: " .. mid_state.detail)

-- unfinished (3): the sharp case. Two calls, one result - the process stopped
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

-- unfinished (4): stopped after the result. The exchange is complete but nothing
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

-- ------------------------------------------------------- the durable record
-- Deriving is enough to *see* an unfinished tail, but it forgets: once the thread is
-- resumed the tail is an answer again. The record is what survives, and it must
-- count pick-up points, not observations.
assert(memory.session(asked).interrupted_at == nil, "reading a state must not write anything")
local recorded = memory.mark_unfinished(asked, { reason = asked_state.detail })
assert(recorded ~= nil, "marking an unfinished thread must report what it recorded")
assert(memory.session(asked).interrupted_seq == asked_state.seq,
  "the record must point at the turn that stopped")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 1, "the first mark counts once")
assert(memory.mark_unfinished(asked) == nil, "the same point must not be recorded twice")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 1,
  "re-observing the same tail must not inflate the count")

-- A second, later stop is a second point: the agent was cut off twice.
memory.append_turn(asked, { role = "tool", tool_call_id = "x", tool_name = "bash", content = "{}" })
assert(state(asked).state == "unfinished", "still unfinished after the result")
assert(memory.mark_unfinished(asked) ~= nil, "a new point must record")
assert((tonumber(memory.session(asked).interrupted_count) or 0) == 2, "two points, two marks")
assert(memory.mark_unfinished("no-such-session") == nil, "an unknown session cannot be marked")

-- Recovering must not erase the evidence: settle the thread by hand and check the
-- state is now clean *and* the history is still there.
memory.append_turn(asked, { role = "assistant", content = "done" })
local recovered = state(asked)
assert(recovered.state == "answered", "the thread must be settled after a reply")
assert(recovered.interruptions == 2 and recovered.recorded_reason ~= "",
  "the recorded history must survive being recovered from")
assert(memory.turn_count(asked) == #memory.session_turns(asked, { limit = 100 }),
  "turn_count must agree with the ledger, got " .. memory.turn_count(asked))

print("durable record ok")

-- ------------------------------------------------ what the agent is told
-- The transcript of an unfinished thread just ends. The model would otherwise
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
  if event.type == "status" and tostring(event.text):find("unfinished", 1, true) then announced = true end
end
assert(announced, "the user must see the recovery, not only the model")
-- Once per process: the second call in the same process returns the cached notice.
assert(bot:note_interruption() == notice, "the notice must be computed once and kept")
assert((tonumber(memory.session(notice_session).interrupted_count) or 0) == 1,
  "noticing an unfinished thread must record it exactly once")

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
assert(calm:note_interruption() == false, "a settled thread must not be announced as unfinished")
for _, message in ipairs(calm:build_context()) do
  if message.role == "system" then
    assert(not message.content:find("Recovery notice", 1, true),
      "a settled thread must not carry a recovery notice")
  end
end
assert((tonumber(memory.session(quiet).interrupted_count) or 0) == 0,
  "a settled thread must not be recorded as unfinished")

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
