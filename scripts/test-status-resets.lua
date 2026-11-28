-- THE RESET TIME HAS TO SURVIVE THE PANEL (27/11, Victor's P0: `/status` no longer says when limits reset).
--
-- Measured before writing this: the data carries `resetsAt` (cache/limits/<provider>.json), and BOTH drawers build
-- the words - lua/core/status.lua (session_lines) and rust/wa-capabilities/src/limits.rs (row_texts). The row is
-- therefore about the LAST step, the draw: the console panel renders a row with clip_cells(text, width - BOX_CHROME),
-- and the reset text is the LAST thing on the line, so a narrow panel cuts exactly the part that went missing. The
-- repo already records that shape (status.lua: 'measured 55 cells on his screen and - measured in a pty at 100
-- columns on 23/11 - is CUT by the panel').
--
-- This row says: at the room a panel really gives (PANEL_ROOM cells after the box chrome), a limits row still ends
-- with its reset time. It is a measurement of the drawn line, not of the words: the words are already pinned by
-- scripts/test-status-midrun.lua.

local status = dofile('lua/core/status.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- The cell width of a string: one cell per printable rune (the bar's blocks and the middle dot are one cell each).
local function cells(text)
  local n = 0
  for _ in tostring(text):gmatch('[%z\1-\127\194-\244][\128-\191]*') do n = n + 1 end
  return n
end

-- The panel's room: the console passes its own width and wa-term takes BOX_CHROME (2) off it.
local PANEL_ROOM = 52

-- The row the provider draws, built by the ONE owner. The numbers are a real reading's shape (percent + resetsAt).
check(type(status.limit_rows) == 'function',
  'one named owner builds a limits row (status.limit_rows), so a row can be measured without a session')
if type(status.limit_rows) ~= 'function' then
  print('status resets FAILED: there is no named builder for a limits row')
  return
end
-- TWO COLUMNS (Victor, 28/11): the words 'resets in' are the second column's HEADER now, and each row carries a
-- countdown. The always-drawn assertion below still holds: the countdown is the last thing on the row, so cutting
-- the row must not cut it.
local block = status.limit_block({ rolling = { percent = 4, resetsAt = os.time() + 10800 } }, { title = 'p  (in use)' })
check(type(block) == 'table' and #block == 2, 'one window makes a header and a row: ' .. tostring(block and #block))
check(block[1]:find('resets in', 1, true) ~= nil, 'the header names the second column: ' .. tostring(block[1]))
local row = block[2]
check(row:sub(-1) == 's' or row:find('now', 1, true) ~= nil or row:find('unknown', 1, true) ~= nil,
  'the row ends with a countdown: ' .. tostring(row))
check(row:find('resets in', 1, true) == nil, 'and does not repeat the header words: ' .. tostring(row))

-- THE ASSERTION THAT WAS MISSING: the row still says it AFTER the panel cuts it to the room it has.
local function clip(text, room)
  if cells(text) <= room then return text end
  local out, used = {}, 0
  for rune in tostring(text):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if used + 1 > room - 1 then break end
    out[#out + 1] = rune; used = used + 1
  end
  return table.concat(out) .. '\226\128\166'
end
local drawn = clip(row, PANEL_ROOM)
check(cells(row) <= PANEL_ROOM or drawn:find('unknown', 1, true) ~= nil or drawn:find('%d%s*$') ~= nil,
  string.format('a limits row (%d cells) still names its reset after the panel cuts it to %d: %s',
    cells(row), PANEL_ROOM, tostring(drawn)))

print(string.format('status resets ok (%d checks; row %d cells, panel room %d)', checks, cells(row), PANEL_ROOM))

