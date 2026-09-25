-- Which conversation a turn lands in.
--
-- Until this existed the client had no say: `agent_for` always passed nil, so the node
-- ran `memory.ensure_session` and every turn from every window landed in the newest open
-- session for (user, node). A window could neither start a thread nor return to one, and
-- that single thread grew without end - which is what `/new` in the UI is for.
--
-- What is asserted here is the selection and its *refusal*, because the refusal is the
-- part that did not previously exist to be wrong: the code's own comment said a guest
-- naming a master's thread was "not something the node checks for yet". That was safe
-- only while the name was ignored. Now that the name is obeyed, it must be checked.
--
-- No model is involved: building the agent touches the ledger, never the provider.
local memory = dofile("lua/core/memory.lua")
local users = dofile("lua/core/users.lua")
dofile("lua/core/server.lua") -- defines wa_agent_for / wa_parse_run_body as globals

local failed = 0
local skipped = 0
local function ok(condition, label)
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end
local function skip(label)
  print("SKIP " .. label)
  skipped = skipped + 1
end

local function fresh() return host.uuid() end

-- 1. A name the node has never seen starts a thread *under that name*.
local mine = fresh()
local bot = wa_agent_for("", "", mine)
ok(bot ~= nil, "naming an unknown thread must start it, not refuse it")
ok(bot and bot.session_id == mine, "the thread must be the one the caller named, not a new id")
local row = memory.session(mine)
ok(row ~= nil, "the named thread must exist in the ledger")
ok(row and row.user_id == "master", "the thread is owned by the caller who started it")
ok(row and row.node_id == "", "the thread is scoped to the node it was started on")

-- 2. The same name is the same thread, and the same agent: the name is part of the
--    cache key, so a second turn does not rebuild and does not fork a second thread.
local again = wa_agent_for("", "", mine)
ok(again == bot, "the same thread name must reuse the agent rather than rebuild it")
ok(again and again.session_id == mine, "and must still be that thread")

-- 3. A different name is a different thread. Without this the feature would appear to
--    work while quietly writing every conversation into one.
local other = fresh()
local third = wa_agent_for("", "", other)
ok(third ~= bot, "a different thread name must not reuse the other thread's agent")
ok(third and third.session_id == other, "and must resolve to the name it was given")
ok(memory.session(other) ~= nil, "the second named thread must exist too")

-- 4. Unnamed turns are unchanged. This is the whole existing surface: the CLI, the peer
--    relay and every window that says nothing still land where they always did.
local unnamed = wa_agent_for("", "", "")
ok(unnamed ~= nil, "an unnamed turn must still resolve a session")
ok(unnamed and unnamed.thread == "", "and must be marked as unnamed, not as a named thread")
ok(unnamed ~= third, "an unnamed turn must not be served by a named thread's agent")

-- 5. What a body means. Text stays text, even when it parses as JSON - otherwise a
--    message someone typed as {"text":"hi"} would silently arrive as "hi".
local text, images, problem, thread = wa_parse_run_body('{"text":"hi"}')
ok(text == '{"text":"hi"}', 'a JSON body with no pictures and no thread must stay verbatim text')
ok(thread == nil, "and must not be read as naming a thread")
ok(problem == nil and #images == 0, "and must carry no images")

local text2, _, _, thread2 = wa_parse_run_body('{"text":"hi","thread":"abc"}')
ok(text2 == "hi", "a body naming a thread is structured: its text is the text")
ok(thread2 == "abc", "and the thread it names is returned")

local text3, _, _, thread3 = wa_parse_run_body("just words")
ok(text3 == "just words" and thread3 == nil, "a plain body is unchanged")

-- Automatic recovery carries the exact tail it read. A second window's queued
-- continuation must not run after the first has already advanced the ledger.
local recovery = fresh()
memory.start_session("", "chat", { id = recovery, user_id = "master", node_id = "", title = "recovery" })
memory.append_turn(recovery, { role = "user", content = "run it" })
memory.append_turn(recovery, { role = "assistant", content = "", tool_calls = {
  { id = "call-one", type = "function", ["function"] = { name = "bash", arguments = "{}" } },
} })
local unfinished_seq = memory.session_state(recovery).seq
ok(not wa_resume_guard(recovery, unfinished_seq), "a missing tool result cannot auto-resume")
memory.append_turn(recovery, { role = "tool", tool_call_id = "call-one", tool_name = "bash", content = "done" })
local recorded_seq = memory.session_state(recovery).seq
local parsed, _, _, parsed_thread, parsed_seq = wa_parse_run_body(
  '{"text":"continue where you stopped","thread":"' .. recovery .. '","resume_seq":' .. recorded_seq .. '}')
ok(parsed == "continue where you stopped" and parsed_thread == recovery and parsed_seq == recorded_seq,
  "a guarded continuation must carry its thread and observed sequence")
ok(wa_resume_guard(recovery, recorded_seq), "a fully recorded tool batch may auto-resume")
ok(not wa_resume_guard(recovery, recorded_seq - 1), "a stale sequence must not resume")
ok(not wa_resume_guard(recovery, "bad"), "an invalid sequence must be refused")
memory.append_turn(recovery, { role = "user", content = "continue where you stopped" })
ok(not wa_resume_guard(recovery, recorded_seq), "the same recovery must not run twice")
local stale = dofile("lua/vendor/json.lua").decode(wa_reply(
  '{"text":"continue where you stopped","thread":"' .. recovery .. '","resume_seq":' .. recorded_seq .. '}', "", ""))
ok(stale.error == "resume_tail_changed", "the chat route must reject a stale continuation before inference")
ok(wa_resume_guard(recovery, nil), "ordinary requested turns remain unchanged")

-- 6. A foreign thread is refused, and the refusal is the safety boundary.
--
-- The login must go through `wa_login`, not `users.login`: `dofile` re-executes a module,
-- so a second `dofile("lua/core/users.lua")` here would be a *different* instance with a
-- different session table, and `agent_for` would never see the session it registered.
local logged = dofile("lua/vendor/json.lua").decode(wa_login("guest"))
local guest_session = logged and logged.session
if not guest_session then
  skip("foreign-thread refusal (no `guest` user in users.json)")
else
  local theirs = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "chat" })
  local refused, reason = wa_agent_for(guest_session, "", theirs)
  ok(refused == nil, "a non-master must not be served another user's thread")
  ok(reason == "forbidden_thread", "and must be refused with a reason, not silently redirected")

  -- ...but a guest's *own* thread is theirs, and starting one must still work, or the
  -- refusal would have broken guests rather than protected anyone.
  local own = fresh()
  local guest_bot = wa_agent_for(guest_session, "", own)
  ok(guest_bot ~= nil, "a non-master naming a thread of their own must be served")
  local own_row = memory.session(own)
  ok(own_row and own_row.user_id == "guest", "and the thread must be owned by them")

  local back = wa_agent_for(guest_session, "", own)
  ok(back == guest_bot, "and returning to it must reuse it, not refuse it as foreign")
end

if failed > 0 then
  print(string.format("thread selection: %d failed", failed))
  os.exit(1)
end
print(string.format("thread selection ok (%d skipped)", skipped))
