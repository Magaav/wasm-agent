-- What this agent is running on, from the host.
--
-- The `bash` tool is `sh -c` on Linux and `cmd /C` on Windows, so the model has
-- to be told which dialect it is in. Without this it guesses POSIX, runs `pwd`,
-- `ls` and `grep`, and spends its tool budget on "not recognized as an internal
-- or external command".
local json = dofile("lua/vendor/json.lua")

local M = {}

local cached = nil

function M.info()
  if cached then return cached end
  local ok, value = pcall(host.platform)
  if ok and type(value) == "table" then
    cached = value
    return cached
  end
  cached = { os = "unknown", arch = "unknown", shell = "sh -c", pathSeparator = "/", cwd = "." }
  return cached
end

function M.os() return M.info().os end
function M.shell() return M.info().shell end
function M.cwd() return M.info().cwd or "." end

-- The node's own OS clock, not UTC.
--
-- `os.date` is the C runtime's localtime, which is the zone the user's OS shows; `%z`/`%Z` name its
-- offset and zone. A platform whose `strftime` does not implement `%z` still gets a numeric offset:
-- `os.time` of a broken-down local time is that instant, while `os.time` of the same fields read as
-- UTC is the instant shifted by the offset, so the difference is the offset. The fallback is written
-- out because "no offset" must not silently read as "UTC" - that is the defect this answers.
--
-- Which is why the reading goes through the host first: the C runtime of a wasm guest is wasi-libc,
-- which has no zone database at all, so `os.date` there is UTC however the node is configured
-- (`host.local_tz`, docs/KERNEL.md "the node's own zone"). Native, with no such call, still reads the
-- runtime directly and answers exactly what it always answered.
local function offset_text(minutes)
  local sign = minutes < 0 and "-" or "+"
  minutes = math.abs(minutes)
  return string.format("%s%02d:%02d", sign, math.floor(minutes / 60), minutes % 60)
end

-- The C runtime's own answer for `stamp`: the offset, its text, and the zone abbreviation `%Z` names.
--
-- It is one function because two callers need it and they must agree. `local_clock` calls it when the
-- host cannot answer (the native interpreter, whose C runtime is the OS's), and the *kernel* calls it
-- on that same native interpreter to answer a guest's `host.local_tz` - a guest's C runtime is
-- wasi-libc, which has no zone database, so `os.date` inside the component core is UTC whatever the
-- node's zone is (docs/KERNEL.md, "the node's own zone"). Two implementations of "the local offset"
-- would agree almost always; "almost" is not a property a timestamp quoted to a user can have.
--
-- `zone` is nil, not "", when the C runtime does not name its zone (WASI's libc has no zone at all,
-- and a `strftime` without `%Z` answers nothing): that is an absence to report, never a name to invent.
function M.runtime_clock(stamp)
  stamp = math.floor(tonumber(stamp) or os.time())
  local offset = tostring(os.date("%z", stamp) or "")
  local zone = tostring(os.date("%Z", stamp) or "")
  local minutes
  local sign, hours, mins = offset:match("^([+-])(%d%d)(%d%d)$")
  if sign then
    minutes = (tonumber(hours) * 60 + tonumber(mins)) * (sign == "-" and -1 or 1)
  else
    local local_t, utc_t = os.date("*t", stamp), os.date("!*t", stamp)
    minutes = math.floor((os.time(local_t) - os.time(utc_t)) / 60 + 0.5)
  end
  return {
    epoch = stamp,
    utc_offset_minutes = minutes,
    utc_offset = offset_text(minutes),
    zone = zone ~= "" and zone or nil,
  }
end

-- The node's zone as the *host* answers it, or nil when this host has no such call.
--
-- A native run has no `host.local_tz` (the capability list is the native registry's, and the node's
-- C runtime already knows the zone), so it keeps reading the runtime directly: nothing about the
-- native clock changes. The guest gets the offset, the abbreviation *and* the OS's own identifier for
-- the zone (`zone_id`: `America/Sao_Paulo`, `E. South America Standard Time`) with the word saying
-- where that came from (`zone_source`), which the native interpreter has no way to read.
--
-- Deliberately not wrapped in `pcall`: a host that has the call and cannot answer it must fail loudly,
-- because silently falling back to the guest's own UTC `os.date` is exactly the +00:00 this answers.
local function host_clock(stamp)
  if type(host.local_tz) ~= "function" then return nil end
  local answer = host.local_tz(stamp)
  local minutes = type(answer) == "table" and tonumber(answer.utc_offset_minutes) or nil
  if not minutes then return nil end
  return {
    epoch = stamp,
    utc_offset_minutes = minutes,
    utc_offset = offset_text(minutes),
    zone = answer.zone,
    zone_id = answer.zone_id,
    zone_source = answer.zone_source,
  }
end

function M.local_clock(epoch)
  local stamp = math.floor(tonumber(epoch) or os.time())
  local clock = host_clock(stamp)
  if clock then
    -- The guest's own `os.date` is UTC, so the local wall clock is the UTC fields of the instant the
    -- node's offset puts it at. The offset was asked for *this* stamp, so a DST change mid-session is
    -- a different answer rather than the same stale one.
    local shifted = stamp + clock.utc_offset_minutes * 60
    return {
      epoch = stamp,
      local_iso = os.date("!%Y-%m-%dT%H:%M:%S", shifted) .. clock.utc_offset,
      utc_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", stamp),
      utc_offset_minutes = clock.utc_offset_minutes,
      utc_offset = clock.utc_offset,
      zone = clock.zone,
      zone_id = clock.zone_id,
      zone_source = clock.zone_source,
      weekday = os.date("%A", shifted),
    }
  end
  local fields = M.runtime_clock(stamp)
  return {
    epoch = stamp,
    local_iso = os.date("%Y-%m-%dT%H:%M:%S", stamp) .. fields.utc_offset,
    utc_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", stamp),
    utc_offset_minutes = fields.utc_offset_minutes,
    utc_offset = fields.utc_offset,
    zone = fields.zone,
    weekday = os.date("%A", stamp),
  }
end

-- The terminal's width in columns: the console's own answer, then `$COLUMNS`, then 80.
--
-- The order is the point. `COLUMNS` is a *shell* variable on most machines and is not exported to
-- children, so it is absent in exactly the place the CLI runs - measured: a 120-column terminal with
-- `COLUMNS` empty - and when it is present it can be stale after a resize. The console knows; the
-- environment is the fallback for a caller that has one and no console.
--
-- `host.terminal_size` may be missing (an older binary), and it returns nil when it cannot ask, so
-- both absences fall through to the same answer rather than to a width of zero.
--
-- `environment` and `probe` are injectable: the rule is worth a test, and a test has no terminal.
function M.columns(environment, probe)
  probe = probe or function()
    local ok, raw = pcall(host.terminal_size)
    if not ok or type(raw) ~= "string" then return nil end
    local decoded
    local read = pcall(function() decoded = json.decode(raw) end)
    if not read or type(decoded) ~= "table" then return nil end
    return decoded
  end
  local size = probe() or {}
  local columns = tonumber(size.columns) or tonumber(environment) or 0
  if columns <= 0 then return 80 end
  return math.floor(columns)
end

-- One line for the system prompt, and a short form for tool descriptions.
function M.describe()
  local info = M.info()
  -- Say which shell, and only warn about the dialect when it actually is cmd:
  -- with Git Bash present the POSIX habits the model already has are correct,
  -- and a hint to use dir/type/findstr would push it the wrong way.
  local shell = tostring(info.shell or "")
  local hint
  if shell:find("cmd", 1, true) then
    hint = "shell commands run through cmd /C, so use dir, type, findstr and copy rather than ls, cat, grep and cp"
  elseif shell:find("bash", 1, true) then
    hint = "shell commands run through bash -c"
  else
    hint = "shell commands run through " .. shell
  end
  local clock = M.local_clock()
  -- The zone's *name* when the platform has one, else the OS's identifier for the zone (a guest gets
  -- it from the host, a native run has only the abbreviation), else say it is unknown rather than
  -- leaving the model to assume UTC.
  return string.format("%s (%s); %s; local time %s (%s)", info.os, info.arch, hint,
    clock.utc_offset, clock.zone or clock.zone_id or "zone name unknown")
end

function M.shell_name()
  return M.info().shell
end

return M
