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
local home = os.getenv("WASM_AGENT_HOME") or ""
if home == "" or home == os.getenv("HOME") .. "/.wasm-agent" or home:find("/%.wasm%-agent$") then
  error("this test writes a ledger: it refuses to run against a real node home (" .. home .. ")")
end
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
eq(split.visible, "42", "#33: the visible answer is the answer alone, never the note")
ok(split.note ~= nil, "#33: the note is parsed")
eq(split.note.hurt, "the run block tag was not read, so a step was redone.", "#33: what hurt is kept")
eq(split.note.focus, "the run-block parser's tag rule.", "#33: focus is kept")
ok(split.block ~= nil and split.block:find("<turn>", 1, true) == 1, "#33: the block itself is kept whole")

-- Item 3 (review 19/11): every byte of answer text survives, before AND after the block.
local tail_after = journal.split("<turn>\n- **focus** - the parser\n</turn>\n\n42")
eq(tail_after.visible, "42", "#3: the text after a leading block is still the answer")
ok(tail_after.note ~= nil, "#3: and the block is still the note")
local ps = journal.split("Answer\n<turn>\n- **focus** - the parser\n</turn>\nP.S.")
eq(ps.visible, "Answer\n\nP.S.", "#3: a postscript after the block is kept")
local unclosed = journal.split("Answer\n<turn>\n- **focus** - the parser")
eq(unclosed.visible, "Answer\n<turn>\n- **focus** - the parser",
  "#3: an unclosed <turn> is not stripped - it is text")
ok(unclosed.note == nil, "#3: and it carries no note")
local two = journal.split("<turn>\n- **focus** - a\n</turn>\nmid\n<turn>\n- **focus** - b\n</turn>\ntail")
eq(two.visible, "mid\n\ntail", "#3: two blocks are both removed, the text between them kept")
ok(two.note and two.note.focus:find("a", 1, true) and two.note.focus:find("b", 1, true),
  "#3: and both notes are collected")
local number_only = journal.split("42")
eq(number_only.visible, "42", "#3: an answer with no tag is untouched, byte for byte")

local plain = journal.split("just an answer, no note")
eq(plain.visible, "just an answer, no note", "#33: an answer without a note is unchanged")
ok(plain.note == nil, "#33: and carries no note")

local mention = journal.split("The harness asks for a <turn> block at the end of every answer.")
ok(mention.note == nil, "#33: a sentence that MENTIONS the tag is not a note")
eq(mention.visible, "The harness asks for a <turn> block at the end of every answer.",
  "#33: and such a sentence is not stripped from the answer")

local one_line = journal.split("TOOLS_OK\n\n<turn>\nnothing hurt, nothing to increment\n</turn>")
eq(one_line.visible, "TOOLS_OK", "#33: an exact output format survives the note")
ok(one_line.note and one_line.note.hurt:find("nothing hurt", 1, true), "#33: a one-line note is a note")

-- the journal row: session, mission, build, mode and the three fields
local session_id = memory.start_session("", "turn-signal", { user_id = "master", node_id = "",
  title = "turn signal" })
local note_id, note_error = journal.record(split.note, { session_id = session_id, run_id = "run-1",
  message_id = "msg-1", mission = "make the note cost nothing", build = "abc123", mode = "only",
  model = "deepseek", block = split.block })
ok(note_id ~= nil, "#33: the note is journaled: " .. tostring(note_error))
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
local today = os.date("%Y-%m-%d")
local from, to = journal.day_bounds(today)
ok(from ~= nil and to == from + 86400, "#33: a day is a half-open 24h window")
ok(row.at >= from and row.at < to, "#33: today's note falls inside today's window")
local bad, bad_error = journal.day_bounds("18/11/2026")
ok(bad == nil and bad_error == "turn_day_must_be_YYYY-MM-DD",
  "#33: a malformed day is refused by name, never read as the last N notes")

-- the envelope says the harness removes the block
local agent_source = host.read_file("lua/core/agent.lua") or ""
ok(agent_source:find("The harness removes this block from the answer it shows", 1, true) ~= nil,
  "#33: the envelope states that the harness removes the block")

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

-- ---- #34: a script's effect is what its calls did ---------------------------------------------
local tools_lib = dofile("lua/core/tools.lua")
local function script_effect(output)
  -- the rule agent.lua applies to a codemode result
  if type(output) ~= "table" then return true end
  local calls = output.calls
  if type(calls) ~= "table" or #calls == 0 then return not (output.ok == true) end
  for _, inner in ipairs(calls) do
    local name = type(inner) == "table" and tostring(inner.name or "") or ""
    if name == "" or tools_lib.has_effect(name, nil) then return true end
  end
  return false
end
ok(script_effect({ ok = true, calls = { { name = "ls" }, { name = "grep" }, { name = "read" } } }) == false,
  "#34: a script that only read is not an effect")
ok(script_effect({ ok = true, calls = { { name = "ls" }, { name = "write" } } }) == true,
  "#34: a script that wrote is an effect")
ok(script_effect({ ok = true, calls = {} }) == false, "#34: a script that called nothing changed nothing")
ok(script_effect({ ok = false, error = "codemode_close_failed" }) == true,
  "#34: an unreadable answer is unknown, and unknown is an effect")

-- ---- #37: a pending handle answers plain fields ----------------------------------------------
local pending_source = host.read_file("lua/core/codemode_pending.lua") or ""
ok(pending_source:find("operation_id = record.op", 1, true) ~= nil,
  "#37: a pending handle carries operation_id as a plain field")
ok(pending_source:find("out.stdout_path", 1, true) ~= nil,
  "#37: and the log paths beside it")
ok(pending_source:find("function M.wait", 1, true) ~= nil, "#37: wait(op) is the resume path")

-- ---- #43: list/await answer ids and state by default -----------------------------------------
-- The rule above is the one agent.lua applies; this asserts the dispatcher really carries it, so a
-- change that drops the branch fails here rather than passing against a copy of itself.
ok(agent_source:find('elseif function_.name == "codemode" then', 1, true) ~= nil,
  "#34: the dispatcher classifies a script's effect from its own calls")
ok(agent_source:find("unknown is an effect", 1, true) ~= nil
  or agent_source:find("unknown counts as an effect", 1, true) ~= nil,
  "#34: and an unreadable answer is treated as unknown, never as a read")
local operation_source = host.read_file("lua/core/tools.lua") or ""
ok(operation_source:find("output_omitted", 1, true) ~= nil,
  "#43: a list/await answer drops the body by default and says how much it dropped")
ok(operation_source:find('args.output == true', 1, true) ~= nil,
  "#43: and returns it when the caller asks")
ok(operation_source:find('record[key .. "_truncated"]', 1, true) ~= nil,
  "#43: with a byte cap when the body is large")

-- ---- item 4: the stored block is ONE dim line under the answer, expandable ---------------------
-- The view is the real module, driven by the same events the agent emits, with a captured writer: no
-- terminal, no transcript host. What is asserted is what the reader sees and where - the block never
-- competes with the answer, and the row still says which note it is.
local cli_view = dofile("lua/core/cli_view.lua")
local function view_recorder()
  local written = {}
  return { out = function(text) written[#written + 1] = tostring(text) end,
    text = function() return table.concat(written) end }
end
local rec = view_recorder()
local view = cli_view.new({ out = rec.out, live = false, now = function() return 5 end, limit = 80 })
view:run_started()
view:event({ type = "turn_note", note_id = "note-1", text = "the parser's tag rule.",
  hurt = "the run block tag was not read.", buys = "a smaller envelope.",
  focus = "the parser's tag rule.", block = "<turn>\n- **focus** - the parser's tag rule.\n</turn>" })
view:answered("42")
local drawn = rec.text()
ok(drawn:find("42", 1, true) ~= nil, "item 4: the answer is still the answer")
ok(drawn:find("turn", 1, true) ~= nil and drawn:find("the parser's tag rule.", 1, true) ~= nil,
  "item 4: the stored note is one line under the answer")
ok(drawn:find("<turn>", 1, true) == nil, "item 4: the raw block is not pasted into the transcript")
ok(drawn:find("42", 1, true) < drawn:find("turn ", 1, true), "item 4: the note comes after the answer, never above it")
-- The row is built by a pure function, so its shape is asserted without a terminal at all: an empty
-- note still says something exists, and the block is what the fold opens.
local line = cli_view.turn_note_line({ text = "the parser's tag rule.", block = "<turn>\nx\n</turn>" }, 80,
  { expandable = true })
ok(line.row:find("turn", 1, true) ~= nil, "item 4: the row names the note")
ok(line.expand ~= nil and line.expand:find("<turn>", 1, true) == 1, "item 4: the fold opens the whole block")
local empty = cli_view.turn_note_line({}, 80, {})
ok(empty.row ~= "" and empty.expand == nil, "item 4: a note with no field still draws a row, and nothing to open")
local folded = cli_view.turn_note_line({ text = string.rep("word ", 60) }, 60, { expandable = true })
ok(folded.row:find("chars", 1, true) ~= nil, "item 4: a long note is folded to one row with its size")
-- A note that arrives on a failed run is the same row: the evidence exists either way.
local rec2 = view_recorder()
local view2 = cli_view.new({ out = rec2.out, live = false, now = function() return 5 end, limit = 80 })
view2:run_started()
view2:event({ type = "turn_note", text = "the tool schema's name rule." })
view2:failed("provider_timeout")
local drawn2 = rec2.text()
ok(drawn2:find("turn", 1, true) ~= nil, "item 4: a run that failed still shows the note it stored")

print(string.format("turn-signal: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
