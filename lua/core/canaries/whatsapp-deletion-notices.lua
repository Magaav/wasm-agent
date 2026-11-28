-- CANARY: the WhatsApp deletion notices (host.whatsapp_* health line, deletion-notices row).
--
-- WHAT THIS IS ABOUT (owner's decision, 23/11): WhatsApp tells a node when a message is deleted. A node that
-- cannot attach that notice to the message it holds has a DEFECT - and the chat hold it used to cause was a
-- silence. The component counts both halves and the bound is PER DAY (UNMATCHED_PER_DAY = 5, measured against
-- the account's busiest day: 7 notices in a day).
--
-- READ-ONLY: it reads the component's own health line. No send, no read of a chat, no media, nothing of the
-- user's is touched, and no id or text leaves this file - counts only.
--
-- THE STAGES, so a red row sends its reader to the right place:
--   no_health_line   the component says nothing about notices - the counters are not being reported
--   never_matched    notices exist and NONE was ever matched: the index or the tombstone is broken, not busy
--   over_bound       unmatched_today is past the daily bound, which is the defect this row exists for
local M = { mode = 'read' }

-- The bound is the component's own (rust/components/wa-whatsapp/src/notices.rs, UNMATCHED_PER_DAY = 5).
M.BOUND_PER_DAY = 5

-- Judge one health line. Separated from the reading so a test can hand it the numbers without a component.
function M.judge(health)
  if type(health) ~= 'table' then
    return false, 'no_health_line', 'the component answered no health line at all'
  end
  local unmatched_today = tonumber(health.unmatched_today)
  if unmatched_today == nil then
    return false, 'no_health_line', 'the health line carries no unmatched_today: the day counter is not reported'
  end
  local matched = tonumber(health.notices_matched) or 0
  local unmatched = tonumber(health.notices_unmatched) or 0
  if unmatched_today > M.BOUND_PER_DAY then
    return false, 'over_bound', string.format('%d unmatched deletion notice(s) today, past the bound of %d (total %d matched / %d unmatched)',
      unmatched_today, M.BOUND_PER_DAY, matched, unmatched)
  end
  if unmatched > 0 and matched == 0 then
    return false, 'never_matched', string.format('%d deletion notice(s) and not one matched: the tombstone or the index is broken, not busy',
      unmatched)
  end
  return true, 'within_bound', string.format('matched %d, unmatched %d (%d today, bound %d)',
    matched, unmatched, unmatched_today, M.BOUND_PER_DAY)
end

-- The counters, parsed from the component's line exactly as lua/core/whatsapp_posting.lua parses them, plus the
-- day fields this row added to that line.
function M.counters(line)
  line = tostring(line or '')
  if not line:find('notices matched=', 1, true) then return nil end
  return {
    notices_matched = tonumber(line:match('matched=(%d+)') or '') or 0,
    notices_unmatched = tonumber(line:match('unmatched=(%d+)') or '') or 0,
    last_notice = line:match('last_notice=(%S+)'),
    last_unmatched = line:match('last_unmatched=(%S+)'),
    -- Absent on a component older than this row: nil, so the judge says no_health_line rather than 0, which
    -- would read as "nothing unmatched today" - the exact false comfort this mission is against.
    unmatched_today = tonumber(line:match('unmatched_today=(%d+)') or '') or nil,
    -- THE SPACE MATTERS: 'unmatched_today=2' also ends in 'day=', so a pattern without the leading space
    -- reads the today count as the day number. The component's own reader (whatsapp_posting.parse_health)
    -- matches ' day=' for the same reason.
    day = tonumber(line:match(' day=(%-?%d+)') or '') or nil,
  }
end

function M.run()
  -- THE COMPONENT'S OWN READER (lua/core/whatsapp_posting.lua M.health): this canary adds no transport and no
  -- second parser, so a change in how the line is produced reaches both or neither.
  local posted = dofile('lua/core/whatsapp_posting.lua')
  local ok, health, why = pcall(posted.health)
  if not ok or type(health) ~= 'table' then
    return false, 'no_health_line',
      'this node could not read the component health line (' .. tostring(ok and why or health) .. ')'
  end
  return M.judge(health)
end

return M
