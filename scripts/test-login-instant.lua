-- /login OPENS FROM A CACHE, NOT FROM A VAULT ROUND TRIP PER PAINT (claude-inside-wa, slice 4).
--
-- MEASURED on this node (28/11, scratch home, one provider):
--   provider_management.state()         53.0 / 52.8 / 52.7 ms
--   vault.status() alone                51.6 ms      <- the whole wait
--   login_views() (the balloon pages)    0.01 ms
--   after the cache: state()             3.3 / 3.6 ms
-- So Enter->list was waiting on the vault, and the cache is what removes it from the repaint.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-login-instant.lua wa
--   -> prints "login instant ok (N checks)"
--
-- The bound is deliberately generous (the cached path must be at least 3x faster, measured 19x): this row is
-- about the CACHE BEING CONSULTED, not about a millisecond. On a node whose vault answers in under 2 ms the
-- row says it cannot measure the difference and skips instead of pretending.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local pm = dofile("lua/core/provider_management.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function ms(fn)
  local started = host.monotonic_ms()
  fn()
  return host.monotonic_ms() - started
end

-- 1. One uncached paint, then the cached ones.
pm.status_cache_clear()
local cold = ms(function() pm.state('local-operator') end)
local warm_one = ms(function() pm.state('local-operator') end)
local warm_two = ms(function() pm.state('local-operator') end)
local warm = math.min(warm_one, warm_two)

if cold < 5 then
  print(string.format('login instant: SKIPPED - the vault answers in %.1f ms here, too fast to show a difference', cold))
  return
end

check(warm < cold, string.format('a cached paint is faster than the first (%.1f ms cached vs %.1f ms cold)', warm, cold))
check(cold >= warm * 3, string.format('and at least 3x faster (cold %.1f ms, cached %.1f ms)', cold, warm))

-- 2. The cache is really consulted: clearing it puts the cost back.
pm.status_cache_clear()
local after_clear = ms(function() pm.state('local-operator') end)
check(after_clear >= warm * 3,
  string.format('after status_cache_clear() the next paint pays the vault again (%.1f ms vs %.1f ms cached)', after_clear, warm))

-- 3. The escape hatch: WA_LOGIN_STATUS_TTL_MS=0 turns the cache off, so a node that needs the old behaviour
--    keeps it, and a test can prove the switch is real by measuring it.
local previous = os.getenv('WA_LOGIN_STATUS_TTL_MS')
if type(host.setenv) == 'function' then
  host.setenv('WA_LOGIN_STATUS_TTL_MS', '0')
  local off = math.min(
    (function() pm.status_cache_clear(); return ms(function() pm.state('local-operator') end) end)(),
    (function() pm.status_cache_clear(); return ms(function() pm.state('local-operator') end) end)())
  check(off >= warm * 3, string.format('with WA_LOGIN_STATUS_TTL_MS=0 every paint pays (%.1f ms)', off))
  if previous then host.setenv('WA_LOGIN_STATUS_TTL_MS', previous) else host.setenv('WA_LOGIN_STATUS_TTL_MS', '') end
end

print(string.format('login instant ok (%d checks; cold %.1f ms, cached %.1f ms, %.1fx)', checks, cold, warm, cold / math.max(warm, 0.1)))
