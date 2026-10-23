-- The node's own OS clock, not UTC.
--
-- The defect this covers: an agent quoting a log line stamped `...Z` as if it were the user's local
-- time, and a model with no way to ask what time it is on this node. The contract here is the shape
-- a caller can rely on - a local ISO string with a numeric offset, the same offset the C runtime
-- reports for that instant, and the same clock exposed through the `time` tool.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local platform = dofile('lua/core/platform.lua')
local tools = dofile('lua/core/tools.lua')

local clock = platform.local_clock()
assert(type(clock.local_iso) == 'string' and
  clock.local_iso:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$'),
  'local_iso must carry a numeric offset, got ' .. tostring(clock.local_iso))
assert(type(clock.utc_iso) == 'string' and clock.utc_iso:match('Z$'),
  'utc_iso must be UTC and labelled so')
assert(clock.local_iso:sub(1, 19) == os.date('%Y-%m-%dT%H:%M:%S', clock.epoch),
  'local fields disagree with os.date for the same instant')

-- %z is the C runtime's own answer; when the platform provides it, it is the authority.
local z = os.date('%z', clock.epoch)
if type(z) == 'string' and z:match('^[+-]%d%d%d%d$') then
  local want = (z:sub(1, 1) == '-' and -1 or 1) * (tonumber(z:sub(2, 3)) * 60 + tonumber(z:sub(4, 5)))
  assert(clock.utc_offset_minutes == want,
    string.format('offset %d disagrees with %%z %s', clock.utc_offset_minutes, z))
end

-- The environment line the model reads names the zone numerically, so it never has to guess.
assert(platform.describe():find('local time [%+%-]%d%d:%d%d', 1, false),
  'environment line must name the local UTC offset: ' .. platform.describe())

-- The tool surface is offered to every role and returns the same contract.
local function catalog_has(role)
  for _, item in ipairs(tools.catalog(role)) do
    if item['function'] and item['function'].name == 'time' then return true end
  end
  return false
end
assert(catalog_has('master') and catalog_has('guest'), 'time must be a shared tool for every role')

local now = tools.dispatch(memory, 'time', {}, 'master', { user_id = 'master', role = 'master' })
assert(type(now) == 'table' and type(now.local_iso) == 'string' and
  now.local_iso:match('[+-]%d%d:%d%d$') and now.utc_iso:match('Z$'),
  'time tool must return local_iso with an offset and utc_iso: ' .. tostring(now and now.local_iso))

print('node local time ok')
