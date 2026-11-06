-- The node's own zone, on both cores.
--
-- What this covers: the agent-core guest's C runtime is wasi-libc, which ships no zone database, so
-- `os.date` inside the component core is UTC whatever zone the node it serves is in. `platform.local_clock`
-- answers from `host.local_tz(epoch)` where the host provides it and from the C runtime otherwise
-- (docs/KERNEL.md, "the node's own zone"), and both must describe the same instant the same way.
--
-- The values are printed, not only asserted: `scripts/test-core-parity.sh` diffs the native and the
-- component core's output, so a core whose offset, local timestamp or zone abbreviation drifts fails
-- there as well as here. The zone's *identifier* (`zone_id`) is deliberately not printed - a native run
-- has no way to read the OS's zone name, so printing it would put a difference between the cores that
-- is not a defect. It is asserted here where the host can answer it, and checked end to end by
-- `cargo test -p wa-capabilities` (`the_same_instant_reads_the_same_on_both_cores`).
local platform = dofile('lua/core/platform.lua')

-- A fixed instant, so two runs are comparable: 2026-01-15T12:00:00Z.
local EPOCH = 1768478400

local clock = platform.local_clock(EPOCH)

-- The shape a caller may rely on.
assert(clock.epoch == EPOCH, 'local_clock must answer the epoch it was given, got ' .. tostring(clock.epoch))
assert(clock.utc_iso == '2026-01-15T12:00:00Z', 'utc_iso must be the UTC instant, got ' .. tostring(clock.utc_iso))
assert(type(clock.local_iso) == 'string' and
  clock.local_iso:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$'),
  'local_iso must carry a numeric offset, got ' .. tostring(clock.local_iso))
assert(type(clock.utc_offset_minutes) == 'number' and
  clock.utc_offset_minutes == math.floor(clock.utc_offset_minutes),
  'the offset is a whole number of minutes, got ' .. tostring(clock.utc_offset_minutes))

-- No zone is 14 hours or more from UTC: a wrong sign, or seconds where minutes were meant, lands here.
assert(math.abs(clock.utc_offset_minutes) <= 14 * 60,
  'implausible offset ' .. tostring(clock.utc_offset_minutes))

-- `local_iso` is the UTC instant shifted by the reported offset and nothing else, so the two fields
-- cannot disagree - and a host that answered the offset without the timestamp it belongs to fails here.
local shifted = os.date('!%Y-%m-%dT%H:%M:%S', EPOCH + clock.utc_offset_minutes * 60) .. clock.utc_offset
assert(clock.local_iso == shifted,
  'local_iso must be the instant in the reported offset: ' .. clock.local_iso .. ' vs ' .. shifted)

-- The weekday is the *local* one: near midnight UTC and a zone in another day, the two differ.
assert(clock.weekday == os.date('%A', EPOCH + clock.utc_offset_minutes * 60),
  'weekday must be the local weekday, got ' .. tostring(clock.weekday))

-- Where the host answers the zone, the offset it answered is the one used above, and the OS's
-- identifier for the zone comes with it (or an honest word saying the OS has none).
if type(host.local_tz) == 'function' then
  local tz = host.local_tz(EPOCH)
  assert(type(tz) == 'table', 'host.local_tz must answer the node zone')
  assert(tonumber(tz.utc_offset_minutes) == clock.utc_offset_minutes,
    'the host offset and the clock offset must agree: ' .. tostring(tz.utc_offset_minutes) ..
    ' vs ' .. tostring(clock.utc_offset_minutes))
  assert(tz.zone_id or tz.zone_source == 'none',
    'the host must name the zone or say it cannot: zone_source=' .. tostring(tz.zone_source))
  assert(clock.zone_id == tz.zone_id and clock.zone_source == tz.zone_source,
    'the clock must carry the identifier the host answered')
  -- Per call, not a boot snapshot: two instants half a year apart are asked separately, which is what
  -- makes a DST change a different answer instead of the offset the process started with. A zone
  -- without DST answers the same offset twice, which is correct and not a stale cache.
  local winter, summer = host.local_tz(EPOCH), host.local_tz(EPOCH + 26 * 7 * 24 * 3600)
  assert(tonumber(winter.utc_offset_minutes) and tonumber(summer.utc_offset_minutes),
    'the host must answer both instants')
end

print(string.format('tz epoch=%d minutes=%d offset=%s zone=%s weekday=%s local=%s utc=%s',
  clock.epoch, clock.utc_offset_minutes, clock.utc_offset, tostring(clock.zone or 'none'),
  tostring(clock.weekday), clock.local_iso, clock.utc_iso))
print('node local time zone ok')
