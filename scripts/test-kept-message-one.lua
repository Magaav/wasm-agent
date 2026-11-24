-- ONE KEPT MESSAGE PER SESSION (r8c 2, Fable 24/11).
--
-- MEASURED on the live node: session 99946441 had SEVEN pending rows reading "kept: the start was refused, so this
-- message is the session's next turn" between 16:35Z and 16:49Z. The writer is lua/core/chat.lua's
-- keep_refused_message (r8a/12 - a message a refused start would have eaten must not be dropped), and it
-- scheduled a NEW wake per refusal, so a runner retrying the same message queued the same promise seven times.
-- r8a3's merge/withdraw could not fold them: M.withdraw_siblings folds RESUMES and `handle:` wakes, and a kept
-- message is neither.
--
-- This row drives the REAL writer end to end (chat.keep_refused_message -> selfloop.keep_pending_message -> the
-- ledger) in a scratch home, and pins the rule: a session has at most ONE pending kept message; a later refusal
-- re-arms that row with the words as they stand now; and once the wake runs, the next refusal arms a fresh one.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local chat = dofile("lua/core/chat.lua")

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end
local KEPT = "kept: the start was refused, so this message is the session's next turn"
local function kept_rows(session)
  return rows("SELECT * FROM self_wakes WHERE session_id=? AND reason=? ORDER BY created_at", { session, KEPT })
end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)
local session = memory.start_session("local", "chat", { id = "r8c-kept", user_id = "master", title = "kept" })

-- ---- 1. seven refusals of the SAME message are one row -----------------------------------------
local ids = {}
for i = 1, 7 do
  local id = chat.keep_refused_message(session, "finish the mission step", "master", "deploy_waiting: a build waits")
  check(type(id) == "string" and id ~= "", "refusal " .. i .. " was kept and named (" .. tostring(id) .. ")")
  ids[i] = id
  selfloop.set_test_clock(function() return T0 + i end)   -- seven refusals over seven seconds, as measured
end
local kept = kept_rows(session)
eq(#kept, 1, "seven refused starts leave ONE pending kept message (the measured seven rows are the bug)")
eq(tostring(kept[1].id), ids[1], "and it is the row the first refusal armed")
for i = 2, 7 do eq(ids[i], ids[1], "refusal " .. i .. " re-armed that same row instead of queueing another") end
eq(tostring(kept[1].prompt), "finish the mission step", "the kept words are the message itself")
check(tonumber(kept[1].due_at) and tonumber(kept[1].due_at) > (tonumber(kept[1].created_at) or 0),
  "and the row is armed ahead of its own creation time (the promise is still fresh): " .. tostring(kept[1].due_at))

-- ---- 2. a DIFFERENT message is APPENDED, and it is still one row -------------------------------
-- Fable 24/11: replacing the kept prompt with the newest one loses a person's earlier message silently. Two DIFFERENT
-- messages from a person are two things they said; the row keeps both, in the order they arrived.
local again = chat.keep_refused_message(session, "and then report", "master", "deploy_waiting: still waiting")
eq(again, ids[1], "a later, different message reuses the same kept turn")
kept = kept_rows(session)
eq(#kept, 1, "still ONE row")
eq(tostring(kept[1].prompt), "finish the mission step\n\nand then report",
  "both messages are kept, in the order they arrived (the newest alone would drop the earlier one silently)")
-- AND THE SAME NUDGE AGAIN ADDS NOTHING: a runner retrying one message must not grow the row it already has.
local repeat_id = chat.keep_refused_message(session, "and then report", "master", "deploy_waiting: still waiting")
eq(repeat_id, ids[1], "the same nudge again reuses the row")
eq(tostring(kept_rows(session)[1].prompt), "finish the mission step\n\nand then report",
  "and adds no copy of itself to the kept prompt")

-- ---- 3. once it runs, the next refusal arms a fresh one ----------------------------------------
local later = os.time() + 600   -- the writer's instance runs on the real clock (chat loads its own copy)
local claimed = selfloop.claim_due(session, "master", { now = later })
check(claimed and tostring(claimed.reason) == KEPT, "the kept turn is claimable when it is due: " .. json.encode(claimed))
selfloop.settle_interrupted(claimed, { now = later + 1 })
local fresh = chat.keep_refused_message(session, "a new request", "master", "deploy_waiting: another build")
check(fresh ~= ids[1], "after the kept turn ran, a new refusal arms a new one (" .. tostring(fresh) .. ")")
eq(#kept_rows(session), 2, "the ledger has the ran row and the new one, and no third")

-- ---- 4. IT ALSO COLLAPSES WHAT IS ALREADY QUEUED (Fable 24/11: a session held 27 kept rows) ----------
local legacy = memory.start_session("local", "chat", { id = "r8c-kept-legacy", user_id = "master", title = "kept" })
for i = 1, 5 do
  host.sql_exec([[INSERT INTO self_wakes (id, owner, session_id, status, reason, prompt, due_at, created_at, updated_at)
    VALUES (?, 'master', ?, 'pending', ?, ?, ?, ?, ?)]],
    json.encode({ "kept-legacy-" .. i, legacy, KEPT, "old " .. i, T0 + 300, T0 + i, T0 + i }))
end
eq(#kept_rows(legacy), 5, "five kept rows already in the queue (the shape the live session had, at 27)")
local collapsed = chat.keep_refused_message(legacy, "the newest words", "master", "deploy_waiting: a build waits")
check(type(collapsed) == "string", "the refusal is kept (" .. tostring(collapsed) .. ")")
eq(#kept_rows(legacy), 5, "no new row is added to the five")
local pending = 0
for _, row in ipairs(kept_rows(legacy)) do if tostring(row.status) == "pending" then pending = pending + 1 end end
eq(pending, 1, "and exactly ONE of them is still pending: the rest are superseded")


-- ---- 5. THE KEPT PROMPT IS BOUNDED, AND IT SAYS WHEN THE BOUND CUT ---------------------------------
-- A person can hand over more than a prompt can hold. The bound is the module's (M.KEPT_PROMPT_LIMIT), and a kept
-- prompt that had to drop something must SAY so: a session reading part of what was kept as if it were all of it is
-- the same silent loss the append rule exists to stop.
local bound_session = memory.start_session("local", "chat", { id = "r8c-kept-bound", user_id = "master", title = "bound" })
local first_words = "first: " .. string.rep("a", 5000)
local cut_id = chat.keep_refused_message(bound_session, first_words, "master", "deploy_waiting: a build waits")
check(type(cut_id) == "string", "the first message is kept (" .. tostring(cut_id) .. ")")
local newest_words = "newest: " .. string.rep("z", 4000)
local too_big = chat.keep_refused_message(bound_session, newest_words, "master", "deploy_waiting: a build waits")
eq(too_big, cut_id, "a second message that would overflow the row reuses it")
local bounded = kept_rows(bound_session)
eq(#bounded, 1, "and the session still has ONE kept row")
local bounded_text = tostring(bounded[1].prompt)
check(#bounded_text <= selfloop.KEPT_PROMPT_LIMIT,
  "the kept prompt is bounded at " .. tostring(selfloop.KEPT_PROMPT_LIMIT) .. " characters (got " .. #bounded_text .. ")")
check(bounded_text:find("newest: zzzz", 1, true) ~= nil, "and the newest message is kept whole")
check(bounded_text:find(string.format(selfloop.KEPT_CUT_TEXT, selfloop.KEPT_PROMPT_LIMIT), 1, true) ~= nil,
  "with the module's own line saying the earlier kept messages were cut: " .. bounded_text:sub(1, 120))
check(bounded_text:find("first: ", 1, true) == nil, "and the oldest part is what went")


print("kept-message-one ok (" .. checks .. " checks): one kept turn per session, re-armed, never queued seven times")
