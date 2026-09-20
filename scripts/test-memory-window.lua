-- Reading a session is a window, and the window is the newest turns.
--
-- The old shape - ORDER BY seq ASC LIMIT 200 - returned the oldest 200 of a long
-- thread and said nothing about it. A reader looking for the end of a run got its
-- opening moves, and a model asking for a session's recent state got ancient history
-- presented as if it were current. Both happened: an audit of a 367-turn run read
-- turns 187-200 and drew the wrong conclusion about what the agent was doing, and the
-- `session` tool handed the model the same head-truncated view.
--
-- This pins the window to the tail, pins that the tool says what it dropped, and pins
-- that an explicit large limit still returns everything - the window is a default, not
-- a ceiling.
--
-- Run from the repo root:  WA_SCRIPT=scripts/test-memory-window.lua wa --db /tmp/x.db
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
memory.setup()

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

-- Every fixture ends on an assistant reply. A thread whose tail is a question is
-- *unfinished*, and this test runs in the same database as the recovery assertions -
-- leaving 260-turn unfinished threads behind would make those assert on this file's
-- debris. Settled fixtures leave the ledger as they found it.
local user = "memory-window-test"
local id = memory.ensure_session(user, "local", "window")
for i = 1, 259 do
  memory.append_turn(id, { role = "user", content = "turn " .. i })
end
memory.append_turn(id, { role = "assistant", content = "turn 260" })

ok(memory.message_count(id) == 260, "the fixture must have 260 messages", memory.message_count(id))

-- The default window is the newest 200, in order, starting 60 turns into the thread.
local rows = memory.session_messages(id)
ok(#rows == 200, "the default window is 200 messages", #rows)
ok(tonumber(rows[1].seq) == 61, "the window starts at turn 61, not turn 1", rows[1].seq)
ok(tonumber(rows[#rows].seq) == 260, "the window ends at the newest turn", rows[#rows].seq)
ok(rows[1].content == "turn 61", "the rows stay in order", rows[1].content)

-- after_seq moves the start of the window, and the window is still the newest part
-- of that span rather than its beginning.
local after = memory.session_messages(id, { after_seq = 250 })
ok(#after == 10 and tonumber(after[1].seq) == 251 and tonumber(after[#after].seq) == 260,
  "after_seq must return the newest messages of the span", tostring(#after))

-- An explicit limit is a choice, not a ceiling.
local everything = memory.session_messages(id, { limit = 1000 })
ok(#everything == 260, "an explicit limit large enough must return the whole thread", #everything)

-- The model-facing tool must say it is showing a window.
local result = tools.dispatch(memory, "session",
  { session_id = id }, "master", { session_id = id, user_id = user, node_id = "local" })
ok(type(result) == "table" and type(result.messages) == "table", "the session tool must return messages")
ok(#result.messages == 200, "the tool window is 200 messages", #result.messages)
ok(type(result.note) == "string" and result.note:find("newest 200 of 260", 1, true),
  "the tool must say what it dropped", result.note)
ok(tonumber(result.messages[1].seq) == 61, "the tool must show the newest messages, not the oldest",
  result.messages[1].seq)

-- A short thread is not a window: no note, no suggestion that anything is missing.
-- A different user on purpose: ensure_session hands back the newest *open* session for
-- a (user, node) pair, so a second session for the same user would be the big one - which
-- is exactly what this fixture did the first time and what the assertion below caught.
local other = user .. "-short"
local small = memory.ensure_session(other, "local", "small")
for i = 1, 4 do memory.append_turn(small, { role = "user", content = "s " .. i }) end
memory.append_turn(small, { role = "assistant", content = "s 5" })
local short = tools.dispatch(memory, "session",
  { session_id = small }, "master", { session_id = small, user_id = other, node_id = "local" })
ok(#short.messages == 5, "a short thread must come back whole", #short.messages)
ok(short.note == nil, "a short thread must not claim to be truncated", short.note)

print(string.format("memory window ok (%d checks)", checks))
