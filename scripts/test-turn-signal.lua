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

print(string.format("turn-signal: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
