-- The self-wake fact gets a row of its own, directly above the session status bar.
--
-- Victor, 13/11: "the status bar today shows `N wakes · next HH:MM` squeezed into the session status
-- line. Move it to its OWN line directly ABOVE the session status bar, pushing the content above it up one
-- line (never overlapping output, never wrapping the status bar). The line only appears when at least one
-- wake is scheduled, and disappears when none is."
--
-- What is pinned here: the fact is not in the numbers on the status bar any more; it is handed to its own
-- row (`host.editor_wakes`, drawn by `rust/wa-term`'s `Editor`); the fallback layout reserves exactly one
-- row for it directly above the status bar and moves the output region up by that row; and the row is
-- absent, not blank, when nothing is scheduled.
--
-- Hermetic: the ledger is this row's own scratch database; no model, no network, no node.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
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

-- One clock for the whole row, so the fact's "next HH:MM" is a number in a snapshot and not the moment the
-- test happened to run.
local CLOCK = 1762700000
host.now = function() return CLOCK end

local session = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "wake row" })

-- ---- the fact, and where it is NOT --------------------------------------------------------------
local wake_row_calls = {}
local native = host.editor_wakes
host.editor_wakes = function(text) wake_row_calls[#wake_row_calls + 1] = tostring(text); return true end

local out = {}
local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false,
  limit = 80, session_id = session })
-- A screen, because `live_footer` only speaks to a layout that has rows: the boxed one, which is the one a
-- reader on a terminal has.
view.screen = cli_view.screen_rows(24, true)

ok(cli_view.wake_text(session) == "", "no wake scheduled: there is no fact at all")
view:live_footer()
ok(#wake_row_calls == 1 and wake_row_calls[1] == "", "the row is handed the empty fact: it disappears, not blank")
ok(not has(view.last_summary, "\226\143\176"), "the numbers on the status bar carry no clock glyph: " .. tostring(view.last_summary))
ok(not has(view.last_summary, "wakes"), "and no wake count either: " .. tostring(view.last_summary))

local scheduled = selfloop.schedule({ session_id = session, owner = "master", reason = "test wake",
  prompt = "look at the machine", in_seconds = 120 }, { session_id = session, user_id = "master" })
ok(scheduled and scheduled.ok == true, "a wake can be scheduled for this session: " .. json.encode(scheduled or {}))
local fact = cli_view.wake_text(session)
ok(has(fact, "1 wake"), "the fact says how many wakes: " .. tostring(fact))
ok(has(fact, "\226\143\176"), "and starts with the clock glyph: " .. tostring(fact))

wake_row_calls = {}
view:live_footer()
ok(#wake_row_calls == 1 and wake_row_calls[1] == fact, "the fact goes to its own row, whole: " .. tostring(wake_row_calls[1]))
ok(not has(view.last_summary, fact), "and not into the status bar's numbers")
ok(not has(view.last_summary, "1 wake"), "not even the count: " .. tostring(view.last_summary))

-- ---- the fallback layout: one row, directly above the status bar --------------------------------
-- The boxed layout is the default; this is the canonical fallback (no native editor), which draws its own
-- rows and must reserve the same one row in the same place.
local plain = cli_view.new({ out = function() end, live = true, limit = 80, session_id = session })
plain.rows = function() return 24 end
plain.screen = cli_view.screen_rows(24, false)
plain.wakes = ""
local none = plain:layout()
ok(none.wake == nil, "with no wake there is no wake row at all")
plain.wakes = fact
local with = plain:layout()
ok(with.wake == with.status - 1, "the wake row is the row directly above the status bar: " ..
  tostring(with.wake) .. " / " .. tostring(with.status))
ok(with.region == none.region - 1, "the output region moved up one line: " .. tostring(none.region) .. " → " .. tostring(with.region))
ok(with.session == none.session - 1, "and so did the session-status-content row")
ok(with.bottom < with.session, "the chat's last row is above the rows that carry the facts: nothing is drawn over")
ok(with.region == none.region - 1 and with.bottom == none.bottom - 2,
  "the two rows the fact takes come off the output region, and nowhere else")

-- ---- the fallback draw: the text on that row, and nothing on the status bar ---------------------
local controls = {}
plain.out = function(text) controls[#controls + 1] = text end
plain.live = true
plain.wakes = fact
plain:wake_draw()
local drawn = table.concat(controls, "")
ok(has(drawn, "\27[" .. with.wake .. ";1H"), "the fact is written on the wake row: " .. drawn:gsub("\27", "^["))
ok(has(drawn, fact), "and it is the fact itself")

controls = {}
plain.wakes = ""
plain.wake_shown = true
plain:wake_draw()
ok(has(table.concat(controls, ""), "\27[" .. with.wake .. ";1H"), "with no wake the row is ERASED, not left blank")

-- ---- the status bar's own text, as a snapshot at 80x24 ------------------------------------------
-- `last_summary` is the left half of the session status bar (the numbers); the model is the right half.
-- The snapshot is the two rows as they are drawn, without colour, for the two states.
local function screen_text(summary, wake)
  return table.concat({
    string.format("row %d (status bar): %s", with.status, summary),
    string.format("row %d (wake row):  %s", with.status - 1, wake ~= "" and wake or "(no row - the chat keeps it)"),
  }, "\n")
end
local without = screen_text(view.last_summary, "")
ok(not has(without, "\226\143\176") and not has(without, "1 wake"),
  "the 80x24 screen with no wake carries no wake fact: " .. without)

local with_text = screen_text(view.last_summary, fact)
local stored_path = "tests/snapshots/balloon/wakes-80x24.txt"
local handle = io.open(stored_path, "rb")
ok(handle ~= nil, "the snapshot of the wake row is in the tree: " .. stored_path)
if handle then
  local stored = handle:read("a"); handle:close()
  local want = without .. "\n\n" .. with_text .. "\n"
  ok(stored == want, "the snapshot matches what is drawn now:\n" .. tostring(stored) .. "\n--- want ---\n" .. want)
  for _, row in ipairs(lines_of(stored)) do
    ok(#row <= 80, "no snapshot row is wider than 80 columns: " .. #row .. " " .. row)
  end
end

if native then host.editor_wakes = native end

if failed > 0 then
  print("cli wake row: " .. failed .. " failed of " .. checks .. " checks")
  os.exit(1)
end
print("cli wake row ok (" .. checks .. " checks)")
