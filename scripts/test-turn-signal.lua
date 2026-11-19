-- change/turn-signal: the friction note kept, the hiccups that used to end a run, and the handles a
-- detached call must answer.
--
-- Why this test exists. Every item here is a place where a run could end rc=0 with its action
-- unexecuted, or cost an answer to keep a signal. Each check drives the real module against a scratch
-- ledger (WASM_AGENT_HOME) with no node, no provider and no network: the answer split, the journal row
-- and the clock are pure Lua, and the raw-code detector is the parser the loop itself calls.
--
--   #33  the <turn> block is KEPT and stripped from the visible answer into the run journal
--        (session, mission, build, mode, the three fields); the envelope says so.
--   #34  a code-mode script's effect is what its own calls did, so a read-only script is not gated.
--   #37  a pending handle always carries operation_id and its log paths as plain fields.
--   #43  operation list/await answer ids and state by default; a body only when asked, and bounded.
local json = dofile("lua/vendor/json.lua")
-- Item 3 (review 19/11): the guard that used to stand here compared WASM_AGENT_HOME with
-- HOME .. "/.wasm-agent", and that can never fire - the host resolves HOME FROM WASM_AGENT_HOME
-- (rust/wa-host-support/src/paths.rs), so the comparison saw <home>/.wasm-agent and never the home
-- itself. The rule is scripts/lib/test-home-guard.lua: an allow-list (the home must sit under
-- GATE_ROOT, else TMPDIR) plus a refusal of the live node's own markers. It is driven below with
-- injected probes, so the rule is checked here too, not only trusted.
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")") end
local memory = dofile("lua/core/memory.lua")
memory.setup()
local journal = dofile("lua/core/turn_journal.lua")
journal.setup()
local raw_code = dofile("lua/core/raw_code.lua")
local checks, failed = 0, 0
local function ok(value, label)
  checks = checks + 1
  if not value then print("FAIL " .. label); failed = failed + 1 end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    print(string.format("FAIL %s\n  expected: %s\n  actual:   %s", label, tostring(expected), tostring(actual)))
    failed = failed + 1
  end
end

-- ---- item 3: the home guard, driven with injected probes --------------------------------
-- Each case is the rule's whole point: a home it cannot prove safe refuses.
local function guard_case(label, opts, expect_refuse, why)
  local reason = home_guard.reason(opts)
  if expect_refuse then
    ok(reason ~= nil, "#3: refuses " .. label .. " (" .. why .. ")")
  else
    ok(reason == nil, "#3: allows " .. label .. " (got: " .. tostring(reason) .. ")")
  end
end
local no_files = function() return false end
guard_case("an unset home", { scratch = "/tmp", exists = no_files }, true, "nothing to write into")
guard_case("an unset scratch root", { home = "/tmp/wa-1", exists = no_files }, true,
  "a home cannot be told from a real one")
guard_case("the real home as the test home",
  { home = "/home/victor", scratch = "/tmp", exists = no_files }, true, "outside the scratch root")
guard_case("a home that does not sit under the scratch root",
  { home = "/home/victor/Work/scratch", scratch = "/tmp", exists = no_files }, true, "not under it")
guard_case("a sibling with the scratch root as a name prefix",
  { home = "/tmp/wa-10", scratch = "/tmp/wa-1", exists = no_files }, true, "a boundary, not a prefix")
-- Measured on this node: TMPDIR is <state>/tmp, so the gate's own scratch home lives INSIDE the
-- state root and that is the supported case - its .wasm-agent/ is its own, not the live one. What
-- the rule refuses is the LIVE home, and that is the markers' job, not the allow-list's.
guard_case("a scratch home under a scratch root inside the state root",
  { home = "/home/victor/.wasm-agent/tmp/wa-1", scratch = "/home/victor/.wasm-agent/tmp", exists = no_files },
  false, "this node's own TMPDIR is <state>/tmp")
guard_case("the live state root as the home",
  { home = "/home/victor/.wasm-agent", scratch = "/home/victor/.wasm-agent/tmp",
    exists = function(p) return p == "/home/victor/.wasm-agent/.wasm-agent/" .. home_guard.MARKERS[1] or
      p == "/home/victor/.wasm-agent/" .. home_guard.MARKERS[1] end },
  true, "outside the scratch root, and it carries a key")
guard_case("a scratch home with the node key in it",
  { home = "/tmp/wa-1", scratch = "/tmp",
    exists = function(p) return p == "/tmp/wa-1/.wasm-agent/" .. home_guard.MARKERS[1] end },
  true, "a live node's own key")
guard_case("a scratch home with the ledger in it",
  { home = "/tmp/wa-1", scratch = "/tmp",
    exists = function(p) return p == "/tmp/wa-1/.wasm-agent/" .. home_guard.MARKERS[2] end },
  true, "a live node's own ledger")
guard_case("a scratch home with no markers",
  { home = "/tmp/wa-1", scratch = "/tmp", exists = no_files }, false, "a scratch ledger is safe")
guard_case("a symlinked scratch root, when resolved",
  { home = "/private/tmp/wa-1", scratch = "/tmp", exists = no_files,
    resolve = function(p) if p:find("/private/tmp") then return (p:gsub("/private/tmp", "/tmp")) end return p end },
  false, "resolving both sides keeps /tmp/.. under /tmp")
-- The comparison that used to guard this row, measured: the host resolves HOME from
-- WASM_AGENT_HOME, so HOME .. "/.wasm-agent" is always <home>/.wasm-agent and never <home>.
eq(test_home, os.getenv("HOME"), "#3: HOME already IS the test home here, so the old comparison never fired")
ok(test_home ~= os.getenv("HOME") .. "/.wasm-agent",
  "#3: the old right-hand side is not the home, and could never equal it")
-- ---- #33: the split, the note, and the journal row --------------------------------------------
local answer = table.concat({
  "42",
  "",
  "<turn>",
  "- **what hurt** - the run block tag was not read, so a step was redone.",
  "- **what it buys** - 2 fewer steps: the block runs the first time.",
  "- **focus** - the run-block parser's tag rule.",
  "</turn>",
}, "\n")
local split = journal.split(answer)
eq(split.visible, answer, "added: the visible answer IS the answer, block and all")
ok(split.note ~= nil, "#33: the note is parsed")
eq(split.note.hurt, "the run block tag was not read, so a step was redone.", "#33: what hurt is kept")
eq(split.note.focus, "the run-block parser's tag rule.", "#33: focus is kept")
ok(split.block ~= nil and split.block:find("<turn>", 1, true) == 1, "#33: the block itself is kept whole")

-- Item 3 (review 19/11): every byte of answer text survives, before AND after the block.
-- ITEM ADDED (Victor, 19/11 09:15): THE BLOCK STAYS IN THE ANSWER.
--
-- Why these replaced the strip-era assertions. change/turn-signal removed the <turn> block from the
-- visible answer so it could not compete with an exact output format; Victor called that
-- over-engineering for a temporary signal - "once we mature the harness we just remove it" - and
-- asked for the strip to be undone. What must hold now:
--   * split().visible is the text it was handed, BYTE FOR BYTE, with the block still in it;
--   * the note is still parsed, and still journaled with its run's own facts;
--   * an answer that is only a block is that block, not an empty string.
-- The parse rules that were never about stripping - a tag that opens a line, a fence, an unclosed tag
-- - are asserted exactly as before: they decide whether there is a NOTE, not whether there is text.
local kept = journal.split(answer)
eq(kept.visible, answer, "added: the answer keeps its block, byte for byte")
ok(kept.visible:find("<turn>", 1, true) ~= nil, "added: and the block is really still in it")
eq(kept.note.hurt, split.note.hurt, "added: the note is parsed exactly as before")
eq(kept.block, split.block, "added: and the block is still returned as evidence")
local only_block = journal.split("<turn>\n- **focus** - x\n</turn>")
eq(only_block.visible, "<turn>\n- **focus** - x\n</turn>",
  "added: an answer that was only the block is still the block")
ok(only_block.note ~= nil and only_block.note.focus == "x", "added: and it is still a note")
local tail_after = journal.split("<turn>\n- **focus** - the parser\n</turn>\n\n42")
eq(tail_after.visible, "<turn>\n- **focus** - the parser\n</turn>\n\n42",
  "added: a leading block stays, and so does the text after it")
ok(tail_after.note ~= nil, "added: and the block is still the note")
local ps = journal.split("Answer\n<turn>\n- **focus** - the parser\n</turn>\nP.S.")
eq(ps.visible, "Answer\n<turn>\n- **focus** - the parser\n</turn>\nP.S.",
  "added: a postscript after the block stays, and so does the block")
local unclosed = journal.split("Answer\n<turn>\n- **focus** - the parser")
eq(unclosed.visible, "Answer\n<turn>\n- **focus** - the parser",
  "added: an unclosed <turn> is text, and it is returned unchanged")
ok(unclosed.note == nil, "added: and it carries no note")
local two = journal.split("<turn>\n- **focus** - a\n</turn>\nmid\n<turn>\n- **focus** - b\n</turn>\ntail")
eq(two.visible, "<turn>\n- **focus** - a\n</turn>\nmid\n<turn>\n- **focus** - b\n</turn>\ntail",
  "added: two blocks stay, and the text between them stays")
ok(two.note and two.note.focus:find("a", 1, true) and two.note.focus:find("b", 1, true),
  "added: and both notes are collected")
local number_only = journal.split("42")
eq(number_only.visible, "42", "added: an answer with no tag is unchanged")

-- The shapes the old seam cleanup could have mangled: each now comes back byte for byte for the
-- simplest possible reason - nothing is cut at all.
local untouched = {
  { name = "indented code (the leading spaces ARE the code)", text = "    local x = 1\n        return x" },
  { name = "trailing spaces", text = "a line with trailing spaces   \nnext line  " },
  { name = "a markdown hard break (two trailing spaces)", text = "first line  \nsecond line, same paragraph" },
  { name = "leading whitespace and a blank first line", text = "\n    indented start\nplain" },
  { name = "blank lines inside the answer", text = "para\n\n\n\npara" },
  { name = "trailing blank lines and spaces", text = "answer\n\n  \n" },
}
for _, case in ipairs(untouched) do
  local got = journal.split(case.text)
  eq(got.visible, case.text, "added: an answer without a block keeps " .. case.name)
  ok(got.note == nil and got.block == nil, "added: and " .. case.name .. " carries no note")
end

local plain = journal.split("just an answer, no note")
eq(plain.visible, "just an answer, no note", "added: an answer without a note is unchanged")
ok(plain.note == nil, "added: and carries no note")

local mention = journal.split("The harness asks for a <turn> block at the end of every answer.")
ok(mention.note == nil, "added: a sentence that MENTIONS the tag is not a note")
eq(mention.visible, "The harness asks for a <turn> block at the end of every answer.",
  "added: and such a sentence is returned unchanged")

local one_line = journal.split("TOOLS_OK\n\n<turn>\nnothing hurt, nothing to increment\n</turn>")
eq(one_line.visible, "TOOLS_OK\n\n<turn>\nnothing hurt, nothing to increment\n</turn>",
  "added: an exact output format keeps its block, right where the model put it")
ok(one_line.note and one_line.note.hurt:find("nothing hurt", 1, true), "added: a one-line note is a note")
-- Item 2 (review 19/11): the build is the SOURCE COMMIT the binary was built from, never the crate
-- version. version is "0.1.0" for every build of this repo, so recording it claimed a known build
-- that identified nothing.
eq(journal.build_of({ version = "0.1.0" }), "",
  "#2: a host that only knows its version records an UNKNOWN build, never 0.1.0")
eq(journal.build_of({ version = "0.1.0", commit = "deadbeef", build = "v9" }), "",
  "#2: commit/build are not the build's source commit either - they are not guessed at")
eq(journal.build_of({ runtime_info = function() return '{"version":"0.1.0","build_source_commit":"c0ffee12"}' end }),
  "c0ffee12", "#2: runtime_info's build_source_commit is the build")
eq(journal.build_of({ runtime_info = function() return { build_source_commit = "t4ble" } end }), "t4ble",
  "#2: a table answer is read the same way")
eq(journal.build_of({ build_identity = function() return { build_source_commit = "b1d" } end,
  runtime_info = function() return '{"build_source_commit":"other"}' end }), "b1d",
  "#2: host.build_identity() is asked first, when the host has one")
eq(journal.build_of({ build_identity = function() return "5tr1ng" end }), "5tr1ng",
  "#2: build_identity may answer the commit directly")
eq(journal.build_of({ build_identity = function() return { build_source_commit = "" } end,
  runtime_info = function() return '{"build_source_commit":"fallback"}' end }), "fallback",
  "#2: an empty build_identity falls through to runtime_info, never short-circuits to nothing")
eq(journal.build_of({ build_identity = function() error("no identity here") end,
  runtime_info = function() return '{"build_source_commit":"kept"}' end }), "kept",
  "#2: a build_identity that raises does not lose the build")
eq(journal.build_of({}), "", "#2: a host that says nothing yields empty")
eq(journal.build_of({ runtime_info = function() return "not json" end }), "",
  "#2: an unreadable answer is UNKNOWN, never a guess")
local long = journal.build_of({ build_identity = function() return string.rep("a", 500) end })
eq(#long, journal.MAX_BUILD, "#2: a recorded build is bounded")
-- the journal row: session, mission, build, mode and the three fields
local session_id = memory.start_session("", "turn-signal", { user_id = "master", node_id = "",
  title = "turn signal" })
local note_id, note_error = journal.record(split.note, { session_id = session_id, run_id = "run-1",
  message_id = "msg-1", mission = "make the note cost nothing", build = "abc123", mode = "only",
  model = "deepseek", block = split.block })
ok(note_id ~= nil, "#33: the note is journaled: " .. tostring(note_error))
-- Item 2: the row a host with only a version writes. Recorded AFTER session_id exists, read back
-- THROUGH a session filter, and in a session of its own so the row count asserted below stays
-- exactly the one note this section is about (the first version named an undeclared local, which
-- inserted a row with an empty session and then read whatever was newest).
local unknown_session = memory.start_session("", "turn-signal-build", { user_id = "master",
  node_id = "", title = "turn signal build" })
local unknown_id = journal.record(plain.note or split.note, { session_id = unknown_session,
  build = journal.build_of({ version = "0.1.0" }) })
local unknown_rows = journal.recent({ session_id = unknown_session, limit = 5 })
ok(unknown_id ~= nil and #unknown_rows == 1 and unknown_rows[1].build == "",
  "#2: a row on a host that knows only its version reads as an unknown build")
local rows = journal.recent({ session_id = session_id, limit = 10 })
eq(#rows, 1, "#33: one row for one note")
local row = rows[1]
eq(row.session_id, session_id, "#33: the row names its session")
eq(row.mission, "make the note cost nothing", "#33: the row names the mission")
eq(row.build, "abc123", "#33: the row names the build")
eq(row.mode, "only", "#33: the row names the mode")
eq(row.hurts, split.note.hurt, "#33: what hurt is stored")
eq(row.buys, split.note.buys, "#33: what it buys is stored")
eq(row.focus, split.note.focus, "#33: focus is stored")
ok(row.block:find("<turn>", 1, true) == 1, "#33: the block rides with its row as the evidence")

-- item 4 (/turns): the session's recent notes come back newest LAST and bounded, through the same
-- call the /turns arm makes - so a listing that silently dropped the newest, or ignored its count,
-- fails here rather than in a reader's terminal.
for index = 1, 6 do
  journal.record({ hurt = "hurt " .. index, buys = "", focus = "focus " .. index },
    { session_id = session_id, run_id = "run-" .. index, block = "<turn>\nx\n</turn>" })
end
local listed = journal.recent({ session_id = session_id, limit = 5 })
eq(#listed, 5, "item 4: /turns asks for N and gets N")
-- Seven rows exist by now (the #33 note and focus 1..6), so the newest five are focus 2..6: the two
-- oldest are the ones a bounded listing drops, and the newest is always in it.
eq(listed[1].focus, "focus 2", "item 4: a bounded listing starts at the oldest of the newest N")
eq(listed[5].focus, "focus 6", "item 4: and ends at the newest note")
local clock = dofile("lua/core/platform.lua").local_clock(tonumber(listed[5].at) or 0)
ok(tostring(clock.local_iso or ""):match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d") ~= nil,
  "item 4: the row has a time the listing can print")

-- the day roll-up: the bounds of one local day, and a note inside it
-- The day bounds and "today" come from the SAME clock (item 4): the guest's own os.date is UTC,
-- so os.date("%Y-%m-%d") disagrees with day_bounds for part of every day. local_day asks the
-- clock day_bounds asks.
local today = journal.local_day()
eq(today, journal.local_day(host.now()), "item 4: today is one answer from one clock")
local from, to = journal.day_bounds(today)
ok(from ~= nil and to == from + 86400, "#33: a day is a half-open 24h window")
ok(row.at >= from and row.at < to, "#33: today's note falls inside today's window")
local bad, bad_error = journal.day_bounds("18/11/2026")
ok(bad == nil and bad_error == "turn_day_must_be_YYYY-MM-DD",
  "#33: a malformed day is refused by name, never read as the last N notes")

-- the envelope says the harness removes the block
-- The source is read through WASM_AGENT_LUA_ROOT when it is set: these two checks read the
-- tree under test, not the process's cwd, so they cannot fail because a runner started
-- somewhere else (measured: they did, from a shell outside the worktree).
local lua_root = os.getenv("WASM_AGENT_LUA_ROOT") or "."
local function source_of(path)
  return host.read_file(lua_root .. "/" .. path) or host.read_file(path) or ""
end
local agent_source = source_of("lua/core/agent.lua")
ok(agent_source:find("The block stays in your answer exactly where you write it", 1, true) ~= nil,
  "added: the envelope tells the model its block is NOT removed from the answer")

-- ---- #2: wa turns --day answers the day it was asked for ---------------------------------------
-- The real dispatcher, not a copy of its rule: M.run is what "wa turns" calls, and the defect this
-- pins was that a leading --day went to the all-time report and the day was silently ignored.
local cli = dofile("lua/core/turnfeed_cli.lua")
local function captured(fn)
  local printed, real = {}, print
  print = function(line) printed[#printed + 1] = tostring(line) end
  local ok, value = pcall(fn)
  print = real
  return table.concat(printed, "\n"), ok and value or nil, ok and nil or value
end
local day_out, day_code = captured(function() return cli.run({ "wa", "turns", "--day", today }) end)
eq(day_code, 0, "#2: wa turns --day exits 0 for a day it can answer")
ok(day_out:find("wa turns --day " .. today, 1, true) ~= nil,
  "#2: and answers THAT day, not the all-time report: " .. day_out:gsub("\n", " | "):sub(1, 160))
local json_out = captured(function() return cli.run({ "wa", "turns", "--day", today, "--json" }) end)
local decoded_ok, decoded = pcall(json.decode, json_out)
ok(decoded_ok and type(decoded) == "table" and decoded.day == today,
  "#2: --json answers a JSON object for the same day, even as the last flag")
local bad_out, bad_code = captured(function() return cli.run({ "wa", "turns", "--day", "18/11/2026" }) end)
eq(bad_code, 2, "#2: a malformed day is refused with a non-zero exit")
ok(bad_out:find("turn_day_must_be_YYYY-MM-DD", 1, true) ~= nil,
  "#2: and the refusal names the format")

-- ---- ADDED (Victor, 19/11 09:15): the answer keeps the block, and the journal row exists ---------
-- The whole point of undoing the strip, asserted through the REAL agent loop with a stubbed provider
-- (no network, no paid call) - the same fixture shape scripts/test-raw-code-answer.lua uses.
--
-- Two halves, and both have to hold together:
--   1. what the run ANSWERS contains the <turn> block VERBATIM - same bytes, same place, block and
--      all, so an operator reading the answer never has to learn that a section was cut from it;
--   2. the run JOURNAL still has the row, with the session, the mission, the build, the mode and the
--      three parsed fields - so the turns report keeps working on evidence nobody sees in the answer.
-- A test of only the first half would pass while the journal stopped recording; only the second while
-- the strip quietly came back.
local answer_json = json
local answer_real_getenv = host.getenv
local answer_overrides = { WASM_AGENT_PROVIDER = "opencode-go", WASM_AGENT_LLM_API_KEY = "answer-fixture",
  WASM_AGENT_LLM_MODEL = "deepseek-v4.1-flash", WASM_AGENT_PI_MODELS_STORE = "missing-test-store",
  WASM_AGENT_CONTEXT_BUDGET = "0", WASM_AGENT_MAX_TOOL_ROUNDS = "2" }
local answer_real_http = host.http
host.getenv = function(k)
  if answer_overrides[k] ~= nil then return answer_overrides[k] end
  return answer_real_getenv(k)
end
host.http = function() error("network forbidden in the turn-signal answer fixture") end

-- The answer the model "gives": a number, then the block. The number is what an operator asked for;
-- the block is the friction, and it is the LAST thing in the message, exactly as the envelope asks.
local BLOCK = table.concat({ "<turn>",
  "- **what hurt** - the run block tag was not read, so a step was redone.",
  "- **what it buys** - 2 fewer steps: the block runs the first time.",
  "- **focus** - the run-block parser's tag rule.", "</turn>" }, "\n")
local REPLY = "42\n\n" .. BLOCK
host.http_stream = function()
  return answer_json.encode({ status = 200, content = REPLY, stream_complete = true, finish_reason = "stop",
    usage = { prompt_tokens = 100, completion_tokens = 20, total_tokens = 120 }, tool_calls = {} })
end

local answer_memory = dofile("lua/core/memory.lua")
answer_memory.setup()
local answer_agent = dofile("lua/core/agent.lua")
local answer_session = answer_memory.start_session("", "turn-answer", { user_id = "master",
  node_id = "", title = "the answer keeps its block" })
local answer_events, answer_reply, answer_ok = {}, nil, false
answer_ok, answer_reply = pcall(function()
  return answer_agent.new(answer_session, function(event) answer_events[#answer_events + 1] = event end,
    "master", "master", ""):run("compute it")
end)
host.getenv = answer_real_getenv
host.http = answer_real_http

ok(answer_ok, "added: the run with a <turn> block answers instead of failing: "
  .. tostring(answer_reply):sub(1, 240))
-- (1) THE ANSWER, VERBATIM. Not "contains the words" - the block's exact bytes, in order, in the
-- answer the run returned, and the operator's 42 still in front of it.
if answer_ok then
  local reply_text = tostring(answer_reply or "")
  eq(reply_text:find(BLOCK, 1, true), 5,
    "added: the answer carries the whole block verbatim, right after the 42 and its blank line")
  ok(reply_text:sub(1, 2) == "42", "added: and the operator's own answer is still first: "
    .. reply_text:sub(1, 40))
  eq(reply_text, REPLY, "added: the answer the run reports is the reply it was given, byte for byte")
  ok(reply_text:find("\n\n<turn>", 1, true) == 3, "added: the blank line before the block survives")
  -- The event still carries the parsed fields, for a consumer that wants them without the journal.
  local saw_note = false
  for _, event in ipairs(answer_events) do
    if event.type == "turn_note" then
      saw_note = true
      eq(event.focus, "the run-block parser's tag rule.", "added: the note event carries focus")
    end
  end
  ok(saw_note, "added: the note event is still emitted, so its fields travel with the run")
end

-- (2) THE JOURNAL ROW, read back through the session filter the turns report itself uses.
local answer_rows = journal.recent({ session_id = answer_session, limit = 5 })
eq(#answer_rows, 1, "added: exactly one journal row for the one note in the answer")
if #answer_rows == 1 then
  local got = answer_rows[1]
  eq(got.session_id, answer_session, "added: the journal row names its session")
  eq(got.focus, "the run-block parser's tag rule.", "added: and the focus, parsed out of the block")
  eq(got.hurts, "the run block tag was not read, so a step was redone.", "added: and what hurt")
  eq(got.buys, "2 fewer steps: the block runs the first time.", "added: and what it buys")
  ok(got.block:find("<turn>", 1, true) == 1, "added: the journal row keeps the block itself as evidence")
end

-- ---- #34: the done gate, through the rule agent.lua itself applies -----------------------------
-- `M.script_effect` is the function the dispatch loop calls at the codemode boundary, so these
-- drive the gate's own code. A local copy of the rule is how a test keeps passing while the loop
-- does something else, which is the defect this section replaces.
local agent_lib = dofile("lua/core/agent.lua")
local tools_lib = dofile("lua/core/tools.lua")
ok(type(agent_lib.script_effect) == "function", "#34: agent.lua exposes the rule its loop applies")
if type(agent_lib.script_effect) == "function" then
  ok(agent_lib.script_effect({ ok = true, calls = { { name = "ls" }, { name = "grep" }, { name = "read" } } }) == false,
    "#34: a script that only read is not an effect")
  ok(agent_lib.script_effect({ ok = true, calls = { { name = "ls" }, { name = "write" } } }) == true,
    "#34: a script that wrote is an effect")
  ok(agent_lib.script_effect({ ok = true, calls = {} }) == false,
    "#34: a script that called nothing changed nothing")
  ok(agent_lib.script_effect({ ok = false, error = "codemode_close_failed" }) == true,
    "#34: an unreadable answer is unknown, and unknown is an effect")
  ok(agent_lib.script_effect(nil) == true, "#34: no result at all is unknown too, never a read")
  -- The one fact that ties the rule to the loop: the loop asks THIS function.
  ok(source_of("lua/core/agent.lua"):find("effect = M.script_effect(output)", 1, true) ~= nil,
    "#34: the codemode branch of the dispatch loop answers with that function")
end

-- ---- #37: a pending call, through the real invoke path -----------------------------------------
-- `codemode_pending.invoke` is what a script's call goes through; with wait_s 0 a call that cannot
-- finish answers the handle the script actually receives. The work is cancelled before this block
-- ends, so the test leaves nothing running on the node.
local pending_lib = dofile("lua/core/codemode_pending.lua")
local ctx = { session_id = session_id, user_id = "master", run_id = "run-pending" }
local function dispatch_here(name, params, raw)
  return tools_lib.dispatch(memory, name, params, "master", ctx)
end
local pending_answer = pending_lib.invoke(dispatch_here,
  { scope = session_id, session_id = session_id, ctx = ctx, background = true },
  "bash", { command = "sleep 30" }, nil, 0)
ok(type(pending_answer) == "table" and pending_answer.state == "pending",
  "#37: a call nobody waited for answers a pending handle")
if type(pending_answer) == "table" and pending_answer.state == "pending" then
  ok(type(pending_answer.operation_id) == "string" and pending_answer.operation_id ~= "",
    "#37: the handle carries operation_id as a plain field")
  ok(type(pending_answer.stdout_path) == "string" and pending_answer.stdout_path:find("stdout", 1, true) ~= nil,
    "#37: and stdout_path, the file the answer will be in")
  ok(type(pending_answer.stderr_path) == "string" and pending_answer.stderr_path:find("stderr", 1, true) ~= nil,
    "#37: and stderr_path, the file the failure will be in")
  ok(pending_answer.op == pending_answer.operation_id,
    "#37: op stays beside operation_id for every script and wait(op) already written")
  ok(type(pending_answer.progress) == "table",
    "#37: with progress beside the plain fields, never instead of them")
  local stopped = pending_lib.cancel(dispatch_here,
    { scope = session_id, session_id = session_id, ctx = ctx }, pending_answer.op)
  ok(type(stopped) == "table", "#37: the call is cancelled, so this test leaves nothing running")
end

-- ---- #43: list/await answer ids and state, and a body only when asked --------------------------
-- The real `operation` tool, through the real dispatcher: no source text, no copy of the rule.
local started = tools_lib.dispatch(memory, "operation",
  { action = "start", command = "echo item-43-body" }, "master", ctx)
ok(type(started) == "table" and type(started.operation_id) == "string",
  "#43: a real operation starts and answers its id")
local op_id = type(started) == "table" and started.operation_id or nil
if op_id then
  local settled = tools_lib.dispatch(memory, "operation",
    { action = "await", id = op_id, wait_s = 30 }, "master", ctx)
  ok(type(settled) == "table" and settled.operation_id == op_id, "#43: an await answers the id it was asked about")
  ok(type(settled) == "table" and settled.stdout == nil,
    "#43: and NOT the output body by default")
  eq(type(settled) == "table" and settled.stdout_omitted, #"item-43-body\n",
    "#43: while saying how many bytes it dropped")
  ok(type(settled) == "table" and settled.state ~= nil, "#43: with the state beside it")
  local with_body = tools_lib.dispatch(memory, "operation",
    { action = "await", id = op_id, wait_s = 30, output = true }, "master", ctx)
  ok(type(with_body) == "table" and type(with_body.stdout) == "string"
    and with_body.stdout:find("item-43-body", 1, true) ~= nil,
    "#43: output=true returns the body")
end
-- A body larger than the floor: max_bytes below 1 KiB is still 1 KiB, and the record says how
-- much was cut. The bytes are the operation's own (3000 x's, no newline).
local big = tools_lib.dispatch(memory, "operation",
  { action = "start", command = "head -c 3000 /dev/zero | tr \"\\0\" x" }, "master", ctx)
local big_id = type(big) == "table" and big.operation_id or nil
if big_id then
  local full = tools_lib.dispatch(memory, "operation",
    { action = "await", id = big_id, wait_s = 30, output = true, max_bytes = 8192 }, "master", ctx)
  ok(type(full) == "table" and type(full.stdout) == "string" and #full.stdout == 3000,
    "#43: a body under the cap is returned whole")
  local cut = tools_lib.dispatch(memory, "operation",
    { action = "await", id = big_id, wait_s = 30, output = true, max_bytes = 4 }, "master", ctx)
  ok(type(cut) == "table" and type(cut.stdout) == "string" and #cut.stdout == 1024,
    "#43: a body over the cap is cut to the 1 KiB floor")
  eq(type(cut) == "table" and cut.stdout_truncated, 3000, "#43: and the record says how large it was")
end
-- The view is the real module, driven by the same events the agent emits, with a captured writer: no
-- terminal, no transcript host. Used by the row-order checks below.
local view_recorder = function()
  local written = {}
  return { out = function(text) written[#written + 1] = tostring(text) end,
    text = function() return table.concat(written) end }
end
local cli_view = dofile("lua/core/cli_view.lua")

-- ---- item 8: the done-gate notice is its own row, never glued onto other text ---------------
-- Measured on the view before the fix: a notice arriving while the answer was still a partial
-- line came out ABOVE that line, which was then reordered after it - the reader saw the gate
-- answer first and its own notice inside the sentence. What is asserted is the row order.
local rec8 = view_recorder()
local view8 = cli_view.new({ out = rec8.out, live = false, now = function() return 5 end, limit = 80 })
view8:run_started()
view8:event({ type = "delta", text = "The answer is 42" })
view8:event({ type = "status", text = "done gate: 1 recorded check(s) still failing - continuing" })
view8:event({ type = "delta", text = " and more" })
-- The run's end, because the tail of a streamed answer is written there (answered) - the
-- order being asserted is the one the reader ends up with.
view8:answered("")
local drawn8 = rec8.text()
local before = drawn8:find("The answer is 42", 1, true)
local notice = drawn8:find("done gate: 1 recorded check(s)", 1, true)
local after = drawn8:find("and more", 1, true)
ok(before ~= nil, "item 8: the interrupted text is written, not swallowed")
ok(notice ~= nil, "item 8: the notice is written")
ok(before and notice and before < notice, "item 8: the text comes first, the notice after it")
ok(notice and after and notice < after, "item 8: and the rest of the text follows the notice")
ok(drawn8:find("42done gate", 1, true) == nil and drawn8:find("and more! done gate", 1, true) == nil,
  "item 8: the notice is never glued onto the words it interrupted")
local notice_row = drawn8:match("([^\n]*)done gate: 1 recorded check")
ok(notice_row ~= nil and notice_row:gsub("^%s+", ""):sub(1, 2) == "! ",
  "item 8: the notice has a row of its own, opening with its own mark")

-- ---- item 4 (review 19/11): the day report and the page it reads -------------------------
-- A row on a day of its own, with an explicit `at`, so a day can be tested without waiting for
-- one. It writes through the same statement M.record writes (and the same JSON params).
local function seed_on(day, offset_s, hurt, focus)
  local from = journal.day_bounds(day)
  if not from then error("seed_on needs a real day: " .. tostring(day)) end
  journal.setup()
  local id = host.uuid()
  host.sql_exec([[INSERT INTO turn_notes(id,session_id,run_id,message_id,mission,build,mode,model,
      hurts,buys,focus,block,at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)]],
    json.encode({ id, "seed", "seed-run", "", "", "", "", "", hurt or "", "", focus or "", "",
      from + offset_s }))
  return id
end
-- (a) a day whose notes carry no countable word is a day, not a crash.
seed_on("2020-01-01", 3600, "the a an and it is", "of to in on at")
local quiet_day, quiet_code, quiet_err = captured(function()
  return cli.run({ "wa", "turns", "--day", "2020-01-01" }) end)
eq(quiet_code, 0, "item 4: a day with no themes answers, it does not crash: " .. tostring(quiet_err))
ok(quiet_day:find("themes: none", 1, true) ~= nil,
  "item 4: and says so rather than printing an empty theme list")
-- (b) a bounded page says it stopped, and how much it did not read.
for index = 1, 3 do seed_on("2020-01-02", index * 60, "trailing " .. index, "") end
local capped, capped_code = captured(function()
  return cli.run({ "wa", "turns", "--day", "2020-01-02", "--limit", "2" }) end)
eq(capped_code, 0, "item 4: a capped day report still answers")
ok(capped:find("read the newest 2 of 3 note(s)", 1, true) ~= nil,
  "item 4: the report says how many notes it did not read: " .. capped:gsub("\n", " | "):sub(1, 160))
local capped_json = captured(function()
  return cli.run({ "wa", "turns", "--day", "2020-01-02", "--limit", "2", "--json" }) end)
local capped_ok, capped_body = pcall(json.decode, capped_json)
ok(capped_ok and capped_body.total == 3 and capped_body.notes == 2 and capped_body.truncated == true,
  "item 4: --json carries the day's real total and says the page was truncated")
-- (c) an inner bash call is judged by the SAME rule as a direct one.
ok(agent_lib.script_effect({ ok = true, calls = { { name = "bash", read_only = true } } }) == false,
  "item 4: a read-only bash inside a script is not an effect, like the direct path")
ok(agent_lib.script_effect({ ok = true, calls = { { name = "bash" } } }) == true,
  "item 4: a bash call with no verdict is an effect - unknown is not yes")
ok(agent_lib.script_effect({ ok = true, calls = { { name = "write", read_only = true } } }) == true,
  "item 4: the read-only bit only speaks for bash/shell; any other name with it is unknown")
ok(agent_lib.command_effect("bash", { command = "git status" }) == false,
  "item 4: the direct path calls git status a read")
ok(agent_lib.command_effect("bash", { command = "rm -rf /tmp/x" }) == true,
  "item 4: and rm an effect")
-- (d) one page size: 24 KiB, the number the Rust page reads at, in the module and the schema.
local pages_lib = dofile("lua/core/codemode_pending.lua")
eq(pages_lib.STDOUT_PAGE_BYTES, 24 * 1024, "item 4: the stdout page is the Rust page (24 KiB)")
eq(pages_lib.STDERR_PAGE_BYTES, 8 * 1024, "item 4: and stderr 8 KiB")
ok(source_of("lua/core/tools.lua"):find("maximum = " .. pages_lib.STDOUT_PAGE_BYTES, 1, true) ~= nil,
  "item 4: the operation schema ceiling is that same byte")
-- (e) the handle fields the view reads are documented, not only emitted.
local codemode_doc = source_of("docs/CODEMODE.md")
for _, field in ipairs({ "log_path", "output_bytes", "settled", "state_name", "stdout_path", "stderr_path" }) do
  ok(codemode_doc:find("`" .. field .. "`", 1, true) ~= nil,
    "item 4: CODEMODE.md names the handle field " .. field)
end
-- (g) a <turn> inside a code fence is code being shown, never the answer's note.
local fence = string.rep(string.char(96), 3)
local shown = "Example:\n\n" .. fence .. "\n<turn>\n- **focus** - x\n</turn>\n" .. fence .. "\n\ndone"
local fenced = journal.split(shown)
ok(fenced.block == nil, "item 4: a <turn> inside a fence is not stripped as a note")
eq(fenced.visible, shown, "item 4: and the answer it was shown in is unchanged")
local after_fence = journal.split(fence .. "\n<turn>code</turn>\n" .. fence
  .. "\n<turn>\n- **focus** - real\n</turn>\n42")
eq(after_fence.visible, fence .. "\n<turn>code</turn>\n" .. fence
  .. "\n<turn>\n- **focus** - real\n</turn>\n42",
  "added: the fenced one stays AND the real one after it stays; only the note is taken")
ok(after_fence.note ~= nil and after_fence.note.focus == "real",
  "added: and the real block after the fence is still the note")
ok(after_fence.note and after_fence.note.focus:find("real", 1, true) ~= nil,
  "item 4: and the real block is the note")
print(string.format("turn-signal: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
