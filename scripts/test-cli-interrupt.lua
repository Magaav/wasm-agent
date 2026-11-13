-- A user interrupt is not a failure: one line, and no `run_failed` anywhere.
--
-- Victor, 13/11: interrupting (Esc / Ctrl-C) a self-wake run printed three lines -
--   `⏰ self-wake: run failed: run_cancelled`
--   `! run_failed: run_cancelled - the run was cancelled before it answered: run_cancelled`
--   `⎿ Interrupted by user`
-- Two of them were `lua/core/run_failure.lua` treating the reader's own choice as a failure: it wrote a
-- failure row, announced an error on the stream, and scheduled a rerun of a run the reader had just
-- cancelled - which is what printed the third line's `⏰ self-wake: run failed: ...` a minute later.
--
-- What is pinned here: a cancel records ONE sentence ("Interrupted by user", with "(self-wake)" when the
-- run was one), announces nothing on the stream, schedules no wake; the view says exactly one line and
-- never the words `run_failed` or `run_cancelled`; and a real failure still gets its row, its event and its
-- wake, because this must not have turned every failure quiet.
--
-- Hermetic: a scratch ledger, a fake emitter, no model and no network.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local run_failure = dofile("lua/core/run_failure.lua")
local cli_view = dofile("lua/core/cli_view.lua")
local selfloop = dofile("lua/core/selfloop.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end
local function lines_of(text)
  local rows = {}
  for row in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
  return rows
end

host.now = function() return 1762700000 end
local session = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "interrupt" })

-- ---- what the ending does with a cancel ---------------------------------------------------------
local emitted, recorded = {}, nil
local ending = run_failure.handle("run_cancelled", {
  session_id = session, user_id = "master", run_id = "run-1", self_wake = true,
  emit = function(event) emitted[#emitted + 1] = event end,
  record = function(turn) recorded = turn; return 7 end,
})
ok(ending.cancelled == true, "a cancel is classified as a cancel, not as a failure")
ok(recorded ~= nil, "one row is still written: the thread keeps a record of the run")
ok(recorded and recorded.content == "Interrupted by user (self-wake)",
  "and it says what happened, once: " .. tostring(recorded and recorded.content))
ok(recorded and not has(recorded.content, "run_failed"), "the row carries no run_failed")
ok(recorded and not has(recorded.content, "run_cancelled"), "and not the harness's code word")
ok(#emitted == 0, "nothing is written on the reader's stream: " .. json.encode(emitted))
ok(ending.wake_id == nil and ending.wake_reason == "cancelled",
  "no wake is scheduled: a run the reader stopped must not start itself again ("
  .. tostring(ending.wake_reason) .. ")")

-- The wake is refused by name too, so no other caller can schedule one for a cancel.
local wake_id, why = run_failure.wake({ code = "run_cancelled", retryable = true, detail = "x" },
  { session_id = session, user_id = "master" })
ok(wake_id == nil and why == "cancelled", "run_failure.wake refuses a cancel: " .. tostring(why))
local listed = selfloop.list({}, { session_id = session, user_id = "master" })
ok(type(listed) == "table" and (listed.count or 0) == 0, "and the session has no wake waiting: "
  .. tostring(listed and listed.count))

-- ---- what the reader sees: exactly one line ------------------------------------------------------
local function screen(opts)
  local out = {}
  local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false, limit = 80,
    session_id = session })
  view:failed("run_cancelled: the run was cancelled before it answered", opts)
  return table.concat(out, "")
end
local plain = screen(nil)
local as_wake = screen({ self_wake = true })
for label, text in pairs({ ["an ordinary run"] = plain, ["a self-wake run"] = as_wake }) do
  ok(#lines_of(text:gsub("%s+$", "")) == 1, "an interrupted " .. label .. " says one line: " .. text:gsub("\n", "\\n"))
  ok(not has(text, "run_failed"), "and no run_failed: " .. text:gsub("\n", "\\n"))
  ok(not has(text, "run_cancelled"), "and the word run_cancelled appears zero times: " .. text:gsub("\n", "\\n"))
  ok(has(text, "Interrupted by user"), "the line is the reader's sentence: " .. text)
end
ok(has(as_wake, "(self-wake)"), "an interrupted wake run names the wake it stopped: " .. as_wake)
ok(not has(plain, "(self-wake)"), "and an ordinary run does not: " .. plain)
ok(#lines_of(as_wake:gsub("%s+$", "")) == 1 and select(2, as_wake:gsub("run_cancelled", "")) == 0,
  "run_cancelled at most once - here, never")

-- ---- a real failure is untouched ------------------------------------------------------------------
emitted, recorded = {}, nil
local broken = run_failure.handle("provider_error: upstream said no", {
  session_id = session, user_id = "master", run_id = "run-2",
  emit = function(event) emitted[#emitted + 1] = event end,
  record = function(turn) recorded = turn; return 8 end,
})
ok(broken.cancelled ~= true, "a provider error is still a failure")
ok(recorded and has(recorded.content, "run_failed"), "it keeps its run_failed row: " .. tostring(recorded and recorded.content))
ok(#emitted >= 2, "and its events on the stream: " .. tostring(#emitted))
ok(broken.wake_id ~= nil, "and its one rerun: " .. tostring(broken.wake_id))

-- ---- and the flag really reaches the ending in a live chat ---------------------------------------
local chat = io.open("lua/core/agent.lua", "rb")
ok(chat ~= nil, "the agent is readable")
if chat then
  local source = chat:read("a"); chat:close()
  ok(has(source, "self_wake=self.self_wake and true or false"),
    "the agent tells the ending whether the run was a self-wake")
end
local wake_turn = io.open("lua/core/chat.lua", "rb")
if wake_turn then
  local source = wake_turn:read("a"); wake_turn:close()
  ok(has(source, 'view:failed(redact.text(tostring(reply)), { self_wake = true })'),
    "and the wake turn hands the view the same fact")
end

if failed > 0 then
  print("cli interrupt: " .. failed .. " failed of " .. checks .. " checks")
  os.exit(1)
end
print("cli interrupt ok (" .. checks .. " checks)")
