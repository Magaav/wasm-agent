-- scripts/lib/row-checks.lua
-- A row's checks, reported so that a reader learns WHERE the failing check is and EVERY failure.
--
-- The measured hurt (refusals-that-help (g), notes 99 and 222): every row defines its own
--   local function check(v,label) assert(v,label); checks=checks+1 end
-- so a failure names the LINE OF THE HELPER - the same line for all forty checks in the row - and the
-- row stops at the first failure, which means "it fails on the old code" names the first assertion in
-- the file, not the one the test was written for.
--
-- This helper:
--   * records the CALLER's file:line (debug.getinfo level 2) for every failed check;
--   * collects ALL failures instead of raising on the first;
--   * finish() prints each one and then raises with the count and the list, so a runner that greps the
--     first assertion line still sees every failure on the lines it prints.
--
--   local rc = dofile((os.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/scripts/lib/row-checks.lua')
--   rc.check(value == want, 'the value matches what the row asked for')
--   rc.finish()            -- prints "FAIL <file>:<line>: <label>" per failure, then errors
--
-- A row that wants its own counters keeps them: rc.checks and rc.failures are plain values.

local M = { checks = 0, failures = {} }

local function caller_site(level)
  local info = debug.getinfo(level + 1, 'Sl')
  if not info then return '<unknown>' end
  local src = info.short_src or info.source or '<row>'
  return string.format('%s:%d', src, info.currentline or 0)
end

function M.check(cond, label)
  M.checks = M.checks + 1
  if not cond then
    M.failures[#M.failures + 1] = caller_site(2) .. ': ' .. tostring(label or '(no label)')
    return false
  end
  return true
end

-- eq is the shape most rows want; it names both values so the message is the report.
function M.eq(got, want, label)
  return M.check(got == want, string.format('%s (got %s, wanted %s)', tostring(label),
    type(got) == 'string' and string.format('%q', got) or tostring(got),
    type(want) == 'string' and string.format('%q', want) or tostring(want)))
end

function M.finish()
  if #M.failures == 0 then
    print(string.format('row-checks: %d check(s), 0 failed', M.checks))
    return
  end
  for _, f in ipairs(M.failures) do
    io.stderr:write('FAIL ' .. f .. '\n')
  end
  error(string.format('%d of %d check(s) failed: %s', #M.failures, M.checks,
    table.concat(M.failures, ' | ')), 0)
end

return M
