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
local rows = status.limit_rows({ rolling = { percent = 4, resetsAt = os.time() + 10800 } }, {})
check(type(rows) == 'table' and #rows == 1, 'one window makes one row: ' .. tostring(rows and #rows))
local row = rows[1]
check(row:find('resets in', 1, true) ~= nil, 'the row names when it resets: ' .. tostring(row))

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
check(drawn:find('resets', 1, true) ~= nil,
  string.format('a limits row (%d cells) still names its reset after the panel cuts it to %d: %s',
    cells(row), PANEL_ROOM, tostring(drawn)))

print(string.format('status resets ok (%d checks; row %d cells, panel room %d)', checks, cells(row), PANEL_ROOM))

