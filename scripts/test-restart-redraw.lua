-- A RESTART, A RESUME AND A SESSION SWITCH DRAW THE SAME TRANSCRIPT A LIVE TURN DOES.
--
-- Victor, 27/11 (restart-redraws-with-the-current-tui): after an install the open TUI restarted and the
-- history ABOVE "continued here" was drawn by a legacy renderer - a "Commentary" heading over the text
-- between tool calls, the reasoning as plain grey text, and the turn note with its literal tags. A live turn
-- shows none of those, so the replay had a drawing of its own. This row is the one that says it must not.
--
-- THE SHAPE IT PINS: one stored turn - the reader's line, thinking, a sentence beside a tool call, the call,
-- its result, and an answer that ends with the model's <turn> note - is drawn twice:
--   * LIVE, through the events agent.lua emits for that same turn;
--   * through EVERY replay path: the restart / --continue ({}), a node-run wake ({answer=true, rule=false}),
--     and a /sessions switch ({skipped=N}).
-- The screens must agree on the three things the bug was about, in all of them: no Commentary heading, no
-- reasoning as bare grey text, and never the literal note tags.
--
-- IT MUST FAIL ON THE LEGACY DRAWING: before this change the replay produced all three, which is why the
-- assertions name them rather than only comparing the screens.
local view_lib = dofile("lua/core/cli_view.lua")

local failed, checks = 0, 0
local function ok(condition, what)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. what) end
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

local function capture(opts)
  local buffer = {}
  local view = view_lib.new({ out = function(t) buffer[#buffer + 1] = t end, live = false,
    limit = 100, now = function() return 7 end, opts = opts })
  return view, function() return table.concat(buffer) end
end

local ANSWER = "I read the config and fixed it.\n\n" ..
  "<turn>\n**what hurt** - the note\n**what it buys** - nothing\n**focus** - nothing\n</turn>"

-- The stored transcript, as agent.lua writes it (role, phase, reasoning, tool_calls, content).
local ROWS = {
  { role = "user", content = "fix the config" },
  { role = "assistant", phase = "commentary", reasoning = "the file is probably stale",
    content = "Looking at the config first.",
    tool_calls = '[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"config/node.json\\"}"}}]' },
  { role = "tool", tool_call_id = "c1", name = "read", ok = 1, ms = 30,
    content = '{"text":"{\\"model\\":\\"x\\"}"}' },
  { role = "assistant", phase = "answer", content = ANSWER, tool_calls = "[]", reasoning = "" },
}

-- The same turn, as events - what agent.lua emitted while it happened.
local function draw_live()
  local view, text = capture()
  view:run_started()
  view:event({ type = "reasoning", text = "the file is probably stale" })
  view:event({ type = "commentary", text = "Looking at the config first." })
  view:event({ type = "tool", name = "read", arguments = { path = "config/node.json" } })
  view:event({ type = "tool_result", name = "read", result = { text = '{"model":"x"}' } })
  view:answered(ANSWER)
  return text()
end

local live = draw_live()
ok(has(live, "I read the config and fixed it."), "the live turn says the answer")
ok(not has(live, "Commentary"), "the live turn puts no Commentary heading over the sentence beside a call")

local paths = {
  { name = "the restart / --continue", opts = {} },
  { name = "a node-run wake", opts = { answer = true, rule = false } },
  { name = "a /sessions switch", opts = { skipped = 3 } },
}
for _, path in ipairs(paths) do
  local view, text = capture()
  view:replay(ROWS, path.opts)
  local drawn = text()
  ok(has(drawn, "I read the config and fixed it."), path.name .. " draws the answer")
  ok(has(drawn, "fix the config"), path.name .. " draws the reader's own line")
  ok(has(drawn, "read"), path.name .. " draws the tool call")
  ok(not has(drawn, "Commentary"), path.name .. " shows no Commentary heading a live turn never shows")
  ok(not has(drawn, "<turn>") and not has(drawn, "</turn>"), path.name .. " never prints the note's literal tags")
  ok(not has(drawn, "theme is probably stale"), path.name .. " draws no reasoning the live turn would not")
end

-- THE ANSWER IS THE SAME TEXT IN BOTH: the sentence a reader sees must not change shape at a restart.
local function answer_line(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if has(line, "I read the config and fixed it.") then return line end
  end
  return ""
end
local view, text = capture()
view:replay(ROWS, {})
ok(answer_line(text()) == answer_line(live), "the replayed answer is the same line the live turn drew")

if failed == 0 then
  print(string.format("restart redraw ok (%d checks)", checks))
else
  print(string.format("restart redraw: %d failed of %d checks", failed, checks))
end
if failed > 0 then os.exit(1) end
