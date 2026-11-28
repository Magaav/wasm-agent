-- Does a row's failed check name the line where the CHECK is, and are ALL of them reported?
--
-- refusals-that-help (g), notes 99 and 222. Today every row writes
--   local function check(v,label) assert(v,label) end
-- so the failure names the helper's line (the same line for every check in the row), and the row stops
-- at the first failure: "it fails on the old code" then names the first assertion in the file, not the
-- one the test was written for.
--
-- This row asserts the behaviour, not the implementation: two checks fail at KNOWN call sites and it
-- reads back what was reported. On a tree without scripts/lib/row-checks.lua it falls back to the
-- assert() shape every row uses today, so it fails there as an assertion - which is what makes it a
-- discriminating row rather than a missing-symbol death.

-- RELATIVE on purpose: the row boot dofiles against WASM_AGENT_LUA_ROOT and PREFIXES that root,
-- so an absolute path here doubles it (measured: lua_root_unreadable: /root//root/scripts/lib/...).
local ok, M = pcall(dofile, 'scripts/lib/row-checks.lua')
local check, failures
if ok and type(M) == 'table' and type(M.check) == 'function' then
  check, failures = M.check, M.failures
else
  failures = {}
  check = function(v, label) assert(v, 'assertion failed: ' .. tostring(label)) end
end

local function myline() return debug.getinfo(2, 'l').currentline end

local line1 = myline() + 1
check(false, 'the first failing check')
local line2 = myline() + 1
check(false, 'the second failing check')
check(true, 'a passing check is not a failure')

local checks, failed = 0, 0
local function c(v, label) checks = checks + 1; if not v then failed = failed + 1; print('FAIL row-check-callsite: ' .. label) end end

c(#failures == 2, 'EVERY failed check is reported, not only the first: got ' .. #failures .. ' failure(s)')
if #failures == 2 then
  local got1 = failures[1]:match(':(%d+):')
  local got2 = failures[2]:match(':(%d+):')
  c(tostring(line1) == got1, string.format('the first failure names the CALL SITE (line %d), not the helper: %s', line1, failures[1]))
  c(tostring(line2) == got2, string.format('the second failure names its own call site (line %d): %s', line2, failures[2]))
  c(failures[1] ~= failures[2], 'the two failures are not collapsed into one line')
  c(failures[1]:find('first failing check', 1, true) ~= nil, 'the failure carries its label, so a reader knows which check: ' .. failures[1])
end

if failed == 0 then print(string.format('row-check-callsite: %d check(s), 0 failed', checks)) else print(string.format('row-check-callsite: %d check(s), %d FAILED', checks, failed)); os.exit(1) end
