-- THE /status PROVIDER BLOCK IS TWO COLUMNS (Victor, 28/11). One owner: status.M.limit_block, which the page,
-- the mid-run snapshot and rust/wa-capabilities/src/limits.rs all draw.
--
-- WHAT HE SAW AND WHAT HE ASKED FOR:
--   now:  opencode-go  (in use)
--           5h  [bar]   5% resets 2026-11-28T13:25:55.000Z     <- the raw ISO: the parser could not read it
--   wanted: opencode-go  (in use)                resets in
--           5h  [bar]  5%                       28d 02h 08m 01s
--   with the freshness line ("just now") still under the block.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-status-columns.lua wa
--   -> prints "status columns ok (N checks)"
--
-- Costs about 1 s: no provider read (the limits are handed in), no network.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local status = dofile("lua/core/status.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %q\n  want: %q", what, tostring(got), tostring(want)), 2)
  end
end
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find '" .. tostring(needle) .. "' in: " .. tostring(text), 2)
  end
end
-- Cells, not bytes: the bar is drawn with block glyphs (3 bytes each).
local function cells(text)
  local n = 0
  for _ in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
  return n
end

-- 1. THE COUNTDOWN, at the values he named.
eq(status.countdown(0), '00s', "zero reads 00s")
eq(status.countdown(59), '59s', "59 s reads 59s")
eq(status.countdown(3600), '01h 00m 00s', "one hour reads 01h 00m 00s")
eq(status.countdown(86400), '1d 00h 00m 00s', "one day reads 1d 00h 00m 00s (days unpadded, the rest padded)")
eq(status.countdown(28 * 86400 + 2 * 3600 + 8 * 60 + 1), '28d 02h 08m 01s', "his exact example")
eq(status.countdown(65), '01m 05s', "a minute and five seconds keeps hh/mm/ss padding below a day")
eq(status.countdown(-5), '00s', "a time in the past does not read negative")

-- 2. THE BLOCK: two headers, the windows, the countdowns, and NO ISO TIMESTAMP ANYWHERE.
-- The clock is derived from the resets, so each window's countdown is the one asserted here.
local TARGET = '2026-11-28T13:25:55.000Z'
local iso_seconds = function(text)
  local y, mo, d, h, mi, s = text:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
end
local ISO = TARGET
local now = iso_seconds(ISO) - (28 * 86400 + 2 * 3600 + 8 * 60 + 1)
local limits = {
  rolling = { percent = 5, resetsAt = ISO },
  weekly = { percent = 12, resetsAt = '2026-12-26T15:34:56.000Z' },
  monthly = { percent = 40, resetsAt = '2027-01-10T00:00:01Z' },
}
local block = status.limit_block(limits, { title = 'opencode-go  (in use)', now = now, width = 120 })
local text = table.concat(block, "\n")
-- TWO HEADERS, ON THE FIRST LINE: the provider is column 1's header and 'resets in' column 2's.
contains(block[1], 'opencode-go', "the provider line is the first column's header")
contains(block[1], '(in use)', "and says it is the one in use")
contains(block[1], 'resets in', "the second column's header names what it holds")
check(not block[1]:find('5h', 1, true), "the header carries no window row")
-- THE ROWS: window, bar, percent, then a COUNTDOWN.
contains(text, '28d 02h 08m 01s', "the first window's countdown, at his format")
for _, window in ipairs({ '5h', '7d', '30d' }) do
  local found
  for i = 2, #block do if block[i]:find(window, 1, true) then found = block[i] end end
  check(found ~= nil, "a row for " .. window)
  check(found:find('resets', 1, true) == nil, "the row does not repeat the words 'resets in' (" .. window .. ")")
end
check(not text:find('T13:25:55', 1, true), "no ISO timestamp survives in the block")
check(not text:find('.000Z', 1, true), "no ISO fraction either")

-- 3. NO LEFT INDENT, and it fits: at 60 columns every line starts at cell 1 and is inside 60.
local narrow = status.limit_block(limits, { title = 'opencode-go  (in use)', now = now, width = 60 })
local widest = 0
for _, line in ipairs(narrow) do
  check(line:sub(1, 1) ~= ' ', "no line starts with a space at 60 columns: " .. line)
  check(cells(line) <= 60, string.format("the line fits 60 cells (%d): %s", cells(line), line))
  widest = math.max(widest, cells(line))
end
-- THE BAR SHRINKS FIRST and the columns keep their headers.
contains(table.concat(narrow, "\n"), 'resets in', "the second header survives 60 columns")
-- 60 columns already fits the full block (a 16-cell bar plus a 17-cell countdown column is 44), so the bar
-- shrinks only when the width really is short. The block's floor is its own title plus the countdown column
-- ('opencode-go  (in use)' + 2 + 15 = 39), so 36 could never fit it; 44 is a width where it can, and there the
-- bar is what gives way: the columns keep their headers and the BAR gives
-- way, which is the rule.
local tight = status.limit_block(limits, { title = 'opencode-go  (in use)', now = now, width = 40 })
local tight_text = table.concat(tight, "\n")
contains(tight_text, 'resets in', "the second header survives 40 columns")
for _, line in ipairs(tight) do
  check(cells(line) <= 40, string.format("the line fits 40 cells (%d): %s", cells(line), line))
end
local wide_bar, tight_bar = 0, 0
for _, line in ipairs(block) do wide_bar = math.max(wide_bar, select(2, line:gsub('\226\150', ''))) end
for _, line in ipairs(tight) do tight_bar = math.max(tight_bar, select(2, line:gsub('\226\150', ''))) end
check(wide_bar == 16, "the bar is its normal 16 cells when there is room (" .. wide_bar .. ")")
check(tight_bar < 16, string.format("the bar shrinks at 40 columns (%d -> %d block cells)", wide_bar, tight_bar))

-- 4. An unreadable reset says so in words: it never prints the timestamp.
local odd = status.limit_block({ rolling = { percent = 5, resetsAt = 'whenever' } }, { title = 'x', now = now })
contains(table.concat(odd, "\n"), 'unknown', "an unreadable reset is named 'unknown', not printed raw")
check(not table.concat(odd, "\n"):find('whenever', 1, true), "and the raw value does not leak into the block")

-- 5. The OLD one-row shape is gone: limit_rows still answers rows, with the countdown column.
local rows = status.limit_rows(limits, { now = now })
eq(#rows, 3, "three rows, no header")
contains(rows[1], '28d 02h 08m 01s', "and the countdown is in them")

print('status columns ok (' .. checks .. ' checks)')
