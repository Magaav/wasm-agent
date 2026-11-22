
-- A terminal resize, in the components that draw a rule, a box or a right-aligned part.
--
-- The finding (Victor, 18/11): maximising the terminal stretched the input rule and the footer - the
-- host redraws those from its own size - while the welcome header box and its top rule, the code-mode
-- box and the rest of the framed components kept the old width. Shrinking it left them WIDER than the
-- window, where the terminal wraps them into a second row and everything below moves: the bounce.
--
-- The width was measured once, before the welcome box was printed, and cached for the life of the
-- process. So the test is the property, not a component: render each one at 80, at 200 and back at 60,
-- and assert that no drawn row is wider than the terminal it is drawn in, and that a rule is exactly as
-- wide as it.
--
-- No console and no node: the view takes `columns`, the probe that stands in for the console
-- (`METHODS:refresh_limit`).
local cli_view = dofile("lua/core/cli_view.lua")
local codemode_block = dofile("lua/core/codemode_block.lua")
local markdown = dofile("lua/core/markdown.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end

-- The visible text of a drawn row: colour is not width, and a rule's cells are what is counted.
local function visible(text)
  return (tostring(text):gsub("\27%[[%d;]*m", ""):gsub("\27%]2;[^\7]*\7", ""))
end
local function width_of(text) return cli_view.columns(visible(text)) end

-- ---- ITEM F: a painted row carries no padding for a shrink to re-wrap ---------------------------
--
-- The finding (Victor, 19/11 11:20): shrinking the terminal broke already-printed backgrounded blocks
-- into ragged lines. The cause was that a band painted its rest with SPACES, and padding is
-- characters - so a narrower terminal wraps them into rows of their own. The rows now end with EL
-- (ESC[K), which erases in the row's background colour and stops at the screen edge, whatever the
-- width is. This asserts the property twice: no painted row carries trailing pad spaces, and the
-- printed text of a row is never wider than the terminal it was drawn for.
do
  local band_rows = {}
  local model = codemode_block.new({ code = "const a = await tools.ls({path: 'lua/core'});" }, 0)
  codemode_block.finish(model, { ok = true, value = 1 }, 0.1)
  -- LIVE and syntax-highlighted, which is what puts the block on its band: a plain (captured) render
  -- carries no colour at all and could not show what a backgrounded block does on a resize.
  local opts = { columns = cli_view.columns, live = true, syntax = markdown.scan_code,
    paint = function(text, style) return cli_view.paint(text, style, true) end }
  for _, row in ipairs(codemode_block.lines(model, 120, opts)) do band_rows[#band_rows + 1] = row end
  local painted = 0
  for _, row in ipairs(band_rows) do
    if row:find("\27%[48;2;", 1) then painted = painted + 1 end
    ok(not row:find("%s+\27%[K"), "a painted row carries no pad space before the erase: " .. row:sub(1, 60))
    ok(not row:find("\27%[K%s"), "and nothing but the reset follows the erase")
    local text = visible((row:gsub("\27%[K", "")))
    ok(text:match("%s*$") == "", "the row ends on its last character, so a narrow terminal has nothing to wrap: [" .. text:sub(-12) .. "]")
  end
  ok(painted > 0, "the block really draws painted rows, so the checks above are not vacuous")
  -- No row is wider than the terminal it was drawn for, so reflowing one at 60 cannot split it.
  local too_wide = 0
  for _, row in ipairs(band_rows) do
    if width_of(row:gsub("\27%[K", "")) > 120 then too_wide = too_wide + 1 end
  end
  ok(too_wide == 0, "and no row is wider than the width it was drawn for, so reflowing it at 60 cannot split it")
end




-- Every component this mission names, as the rows it draws at the width the view has NOW. Each is a
-- function of the view, so the same list is re-rendered after every resize.
local function components(view)
  local out = {}
  local banner = cli_view.banner({ live = view.live, limit = view.limit,
    version = "e5ba9089",
    model = "deepseek-v4.1-flash @ http://127.0.0.1:1/v1",
    session = "abc", workspace = "~/work/wasm-agent", branch = "change/tui-polish-2" })
  out["welcome box"] = {}
  for line in banner:gmatch("[^\n]*") do out["welcome box"][#out["welcome box"] + 1] = line end
  local model = codemode_block.new({ code = "const a = await tools.bash({command: 'echo hi'})\nreturn a" }, 0)
  codemode_block.begin_call(model, "call-1", "bash", { command = "echo hi" })
  codemode_block.settle(model, "call-1", { ok = true, ms = 12 })
  codemode_block.finish(model, "hi", 1.2)
  out["code-mode block"] = codemode_block.rows(model, view.limit, view:codemode_opts())
  out["status row"] = { view:status_text(false) }
  out["footer"] = { cli_view.footer({ rounds = 3, tools = 5, prompt = 1200, completion = 340, cached = 900 },
    { context = 45000, budget = 128000 }) }
  -- The between-runs summary row, which this view DOES draw (status_template's dim line). It stood
  -- for a "node: 2 ops elsewhere" aggregate until round 3: that row belongs to
  -- change/session-isolation, and this tree draws nothing about other sessions, so a fixture of it
  -- here would size text nothing puts on a screen.
  local between = cli_view.new({ out = function() end, live = false, now = function() return 1000 end,
    columns = function() return 80 end, limit = 80 })
  between.screen = { footer = true }
  between.last_summary = "bash 9483 12s 9483 a long line of the node's own output so the row is wide"
  out["summary row"] = { between:status_text(false) }
  return out
end

-- The widths a window is driven through, in the order Victor drove them: start, maximise, shrink.
local widths = { 80, 200, 60 }
local view = cli_view.new({ out = function() end, live = false, now = function() return 1000 end,
  columns = function() return widths[1] end, limit = widths[1] })

for _, width in ipairs(widths) do
  -- What a resize does: the console reports a new width, and the next frame reads it.
  view.columns_probe = function() return width end
  view:refresh_limit()
  ok(view.limit == width, "the view reads the terminal at " .. width .. " (got " .. tostring(view.limit) .. ")")
  for name, rows in pairs(components(view)) do
    for index, row in ipairs(rows) do
      local cells = width_of(row)
      ok(cells <= view.limit, name .. " row " .. index .. " is not wider than " .. width
        .. " (drawn " .. cells .. ")")
    end
  end
  -- The rule is the component that is nothing BUT its width: it must be the whole of it, not a narrower
  -- line that leaves the box looking cut off.
  local banner = cli_view.banner({ live = false, limit = view.limit, version = "e5ba9089" })
  local rule = banner:match("^([^\n]*)")
  ok(width_of(rule) == view.limit, "the welcome rule is exactly " .. width .. " wide (drawn "
    .. width_of(rule) .. ")")
  ok(not banner:find(cli_view.RULE, 1, true), "no rule marker reaches the screen at " .. width)
end

-- The terminal is unanswerable (a pipe, a CI log): the width the view already had stands, rather than
-- collapsing to a guess. A resize that reports nothing must not redraw the chat narrow.
view.columns_probe = function() return nil end
view:refresh_limit()
ok(view.limit == widths[3], "an unanswerable console keeps the width the view had")
view.columns_probe = function() return -1 end
view:refresh_limit()
ok(view.limit == widths[3], "a nonsense width keeps the width the view had")
-- A console narrower than any layout can be drawn in takes the floor, so a box is never all border.
view.columns_probe = function() return 4 end
view:refresh_limit()
ok(view.limit == cli_view.MIN_COLUMNS, "a 4-column terminal is drawn at the floor, not at 4")

-- ---- THE REAL VIEW PATH (round 4, item 1) --------------------------------------------
--
-- Everything above drives refresh_limit() by hand, which is exactly what production did NOT do:
-- the function was committed and called by nothing, so the width a component drew with was still
-- the one the view was built with. This section never calls refresh_limit itself. It renders
-- through the framed methods the chat's event loop calls, changes the columns the console reports,
-- and renders again - so it fails on any tree where the frame boundary does not read the console.
-- The console this section drives: a number the test moves between renders, exactly as a resize does.
local framed_width = 100
-- What reached the console, in the order it went out; render() empties it per call.
local captured = {}
local framed = cli_view.new({ out = function(text) captured[#captured + 1] = text end,
  live = false, now = function() return 1000 end,
  columns = function() return framed_width end, limit = framed_width })

-- One paragraph long enough to wrap, so the rows it draws are a function of the width and not of the
-- text: a body narrower than the terminal is drawn at its own width whatever the limit is.
local BODY = table.concat({ "the components must follow a terminal resize, so this sentence is long",
  "enough that a narrow terminal wraps it into several rows and a wide one does not" }, " ")

-- Render through the FRAME path and return the rows that reached the console.
local function render()
  captured = {}
  framed:line("a line")
  framed:topic_block("heading", "accent", BODY, "text")
  framed:warn("a warning")
  local rows = {}
  for _, chunk in ipairs(captured) do
    for line in (tostring(chunk) .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = line end
  end
  return rows
end

for _, width in ipairs({ 100, 40, 160 }) do
  framed_width = width
  local rows = render()
  -- The frame boundary read the console: the view's own width followed, with no refresh_limit call.
  ok(framed.limit == width, "a framed render reads the console: the view is at " .. width
    .. " (got " .. tostring(framed.limit) .. ")")
  ok(#rows > 1, "the real view path drew something at " .. width .. " (" .. #rows .. " rows)")
  local widest, widest_row = 0, ""
  for _, row in ipairs(rows) do
    local cells = width_of(row)
    if cells > widest then widest, widest_row = cells, row end
  end
  ok(widest <= width, "every framed row fits the terminal it was drawn in at " .. width
    .. " (widest " .. widest .. ": " .. widest_row:sub(1, 60) .. ")")
end

-- The width follows DOWN as well as up, and the wrap does too: the same paragraph is more rows at 40
-- than at 160. A cached width cannot pass both.
framed_width = 160
local wide_rows = #render()
framed_width = 40
local narrow_rows = #render()
ok(narrow_rows > wide_rows, "a narrow terminal wraps the same text into more rows (" .. narrow_rows
  .. " at 40 vs " .. wide_rows .. " at 160)")

-- The rule a component draws is the width the terminal has NOW, through the view's own method.
framed_width = 120
render()
ok(width_of(framed:rule()) == 120, "the view's rule is the terminal's width after a framed render ("
  .. width_of(framed:rule()) .. ")")

-- ---- THE RECORDED TERMINAL: what the TERMINAL does with what was written (item 1 of tui-fit) -----
--
-- Everything above asserts that a freshly drawn row fits the width it is drawn for. The defect Victor
-- photographed in foot is the other half of the problem: `wa chat` printed the welcome box ONCE, into
-- the terminal, and it owned those characters from that moment - so a rule of 80 columns stayed 80
-- columns, and shrinking the window made foot re-wrap it into 60 columns plus an orphan row of 20
-- under the rule: the stray "─". No later write can reflow a row the terminal already holds.
--
-- So this drives the REAL view through the widths he drove (80 -> 200 -> 60), feeds every byte it wrote
-- into a recorded terminal (scripts/lib/recorded_terminal.lua: a grid, a scroll region, the erase and
-- clear sequences, and the reflow a resize performs), and asserts on the FINAL screen:
--   * no row is wider than the terminal it is shown in;
--   * the welcome rule is on that screen exactly once, exactly the final width - no orphan fragment of
--     an older width hiding under it;
--   * and the banner is still there: the redraw puts back what the view owns, it does not wipe it.
local recorded = dofile("scripts/lib/recorded_terminal.lua")
local recorded_width = 80
local bytes = {}
local drive = cli_view.new({ out = function(text) bytes[#bytes + 1] = text end, live = true,
  now = function() return 1000 end, rows = function() return 24 end,
  columns = function() return recorded_width end, limit = recorded_width, register = false })
local term = recorded.new({ width = recorded_width, height = 24, columns = cli_view.columns })
local function replay()
  local text = table.concat(bytes, "")
  bytes = {}
  term:feed(text)
end
drive:screen_on()
drive:welcome({ live = true, version = "e5ba9089",
  model = "deepseek-v4.1-flash @ http://127.0.0.1:1/v1", session = "abc",
  workspace = "~/work/wasm-agent", branch = "change/tui-fit" })
replay()
drive:line("the reader's first line")
replay()
local WIDTHS = { 200, 60 }
for _, width in ipairs(WIDTHS) do
  -- What a resize is: the console reports a new size and the terminal re-wraps what it holds.
  recorded_width = width
  term:resize(width, 24)
  -- The next frame - a line, a tool call, the status row - is where the view reads the console.
  drive:line("a line written after the window became " .. width .. " columns")
  replay()
end
local RULE_CHAR = "\226\148\128"
local widest_row = 0
for index = 1, 24 do widest_row = math.max(widest_row, term:cells(index)) end
ok(widest_row <= 60, "no row of the final 60-column screen is wider than 60 (widest " .. widest_row .. ")")
local rules = {}
for index, row in ipairs(term:screen()) do
  if row ~= "" and (row:gsub(RULE_CHAR, "")) == "" then rules[#rules + 1] = index end
end
ok(#rules == 1, "the welcome rule is on the final screen exactly once, so no fragment of an older width "
  .. "is left under it (found " .. #rules .. ")")
if #rules == 1 then
  ok(term:cells(rules[1]) == 60, "and it is exactly the terminal's width (drawn "
    .. term:cells(rules[1]) .. " of 60)")
  local under = term:screen()[rules[1] + 1] or ""
  ok(under:find("Welcome to wasm-agent", 1, true) ~= nil,
    "with the greeting directly under it, not an orphan piece of rule: " .. under:sub(1, 40))
end
ok(#term:find("Welcome to wasm-agent") == 1, "the banner is on the final screen, once (not wiped by "
  .. "the redraw)")

-- ---- the OTHER layout: the banner becomes a block the host redraws ---------------------------------
--
-- With the native editor, drawing again is not this view's job: the host owns the transcript as a
-- model and repaints every block at the frame's width on a resize (host.rs REPAINT_CLEAR, and
-- rust/wa-term/src/transcript.rs `a_block_written_once_draws_its_rule_at_the_width_of_the_frame` proves
-- the marker follows the frame). What is asserted here is the ROUTING, because that is what this side
-- decides: the banner goes through the transcript channel, with the rule left as the marker, so the
-- width is decided where the row is drawn and nowhere earlier.
local wrote = {}
local saved_transcript_write, saved_transcript_block = host.transcript_write, host.transcript_block
host.transcript_write = function(text) wrote[#wrote + 1] = tostring(text); return true end
host.transcript_block = function() wrote[#wrote + 1] = "<block>"; return true end
-- `stdout` is what opens the transcript channel (`METHODS:transcript`: the host's own writer, which
-- exists because this process draws on its terminal); the bytes it would write are captured here.
local routed = cli_view.new({ out = function(text) wrote[#wrote + 1] = tostring(text) end, live = true,
  stdout = true, now = function() return 1000 end, rows = function() return 24 end,
  columns = function() return 80 end, limit = 80, register = false })
routed.editor, routed.editor_ready = true, true
routed:screen_on()
wrote = {}
routed:welcome({ live = true, version = "e5ba9089", workspace = "~/work/wasm-agent" })
local joined = table.concat(wrote, "")
ok(joined:find(cli_view.RULE, 1, true) ~= nil,
  "with a native editor the banner keeps the rule marker for the host to expand")
ok(joined:find(string.rep("\226\148\128", 40), 1, true) == nil,
  "and measures no width of its own")
-- The greeting is painted word by word ("wasm-agent" is bold), so the sequence to look for is the
-- one with no colour inside it.
ok(joined:find("Welcome to ", 1, true) ~= nil, "the block itself goes to the transcript")
host.transcript_write, host.transcript_block = saved_transcript_write, saved_transcript_block

if failed == 0 then print("resize ok (" .. checks .. " checks)") else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)

