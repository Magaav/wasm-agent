-- A ROSTER ROW MUST NOT SLEEP 120 ms FOR A NUMBER IT ONLY DISPLAYS.
--
-- Brief (23/11): the remote round trip's caller paid 120.3 ms inside its own roster read. The cause is not
-- network and not the peer: `host.system_resources()` measures CPU as a delta between two /proc/stat reads
-- and therefore SLEEPS 120 ms on purpose (rust/wa-host-support, cpu_percent), and `nodes.list` sampled it
-- for the LOCAL roster entry - which `nodes.find` builds for every remote call.
--
-- This row pins the three things the fix owes:
--   * the quick sample answers memory, disk and cores, and says by name that the CPU figure was NOT
--     measured (used_percent null + cpu.unmeasured), because an absent number must never read as idle;
--   * it is quick: a bound of 100 ms against a 120 ms deliberate sleep;
--   * the full sample is unchanged for the callers that DECIDE on CPU (the rendezvous heartbeat), and the
--     roster's local row is the quick one.
--
-- Hermetic: a scratch home, no network (the roster read is answered by a stub), no live node.
do
  local home = tostring(host.getenv("WASM_AGENT_HOME") or "")
  local trimmed = home:gsub("[/\\]+$", "")
  local scratch = trimmed:find("scratch", 1, true) ~= nil or trimmed:find("tmp", 1, true) ~= nil
    or trimmed:find("temp", 1, true) ~= nil or trimmed:find("TMP", 1, true) ~= nil
    or trimmed:match("^/var/folders/") ~= nil
  local real_node = trimmed:match("[/\\]%.wasm%-agent$") ~= nil
  if home == "" or not scratch or real_node then
    print("refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own "
      .. "~/.wasm-agent (got " .. tostring(home) .. ")")
    os.exit(2)
  end
end

local json = dofile("lua/vendor/json.lua")
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function tonic_safe(value) return tonumber(value) ~= nil end
local function decode(text)
  local ok, value = pcall(json.decode, text or "")
  return ok and type(value) == "table" and value or nil
end

-- 1. THE QUICK SAMPLE: the same capacities, the CPU figure NAMED as unmeasured, and no 120 ms sleep.
local before = host.monotonic_ms()
local quick = decode(host.system_resources('{"quick":true}'))
local quick_ms = host.monotonic_ms() - before
check(type(quick) == "table", "the quick sample is a JSON object")
check(type(quick.memory) == "table" and tonic_safe(quick.memory.total_bytes),
  "it carries memory, got " .. tostring(quick.memory and quick.memory.total_bytes))
check(type(quick.disk) == "table" and quick.disk.total_bytes ~= nil, "and the disk capacities")
check(type(quick.cpu) == "table" and quick.cpu.logical_cores ~= nil, "and the core count")
check(quick.cpu.used_percent == nil,
  "and does NOT report a CPU percentage it did not measure, got " .. tostring(quick.cpu.used_percent))
check(type(quick.cpu.unmeasured) == "string" and quick.cpu.unmeasured ~= "",
  "and says why in the answer itself, got " .. tostring(quick.cpu.unmeasured))
check(quick_ms < 100, string.format("a quick sample answers inside 100 ms (the full one sleeps 120), took %.1f ms", quick_ms))

-- 2. THE FULL SAMPLE IS UNCHANGED: a caller that decides on CPU still gets a measured one.
local before_full = host.monotonic_ms()
local full = decode(host.system_resources())
local full_ms = host.monotonic_ms() - before_full
check(type(full) == "table" and type(full.cpu) == "table", "the full sample is still a JSON object")
check(type(full.cpu.used_percent) == "number",
  "and still carries a measured CPU percentage, got " .. tostring(full.cpu.used_percent))
check(full_ms >= 100, string.format("and still pays its own 120 ms window, took %.1f ms", full_ms))

-- 3. THE ROSTER'S LOCAL ROW IS THE QUICK ONE, so no remote call pays that window to build it.
host.operation = function(action) return json.encode({ error = "operation_disabled_for_test", action = action }) end
local real_http = host.http
host.http = function() return json.encode({ status = 503, body = "" }) end
local nodes = dofile('lua/core/nodes.lua')
local before_row = host.monotonic_ms()
local list = nodes.list({ live_capabilities = false })
local row_ms = host.monotonic_ms() - before_row
host.http = real_http
check(type(list) == "table" and type(list[1]) == "table", "the roster lists this node")
local resources = list[1].resources
check(type(resources) == "table", "and its row carries a resource sample")
check(type(resources.memory) == "table" and resources.memory.total_bytes ~= nil,
  "with the same memory facts, got " .. tostring(resources.memory and resources.memory.total_bytes))
check(resources.cpu and resources.cpu.used_percent == nil,
  "and no CPU percentage it did not measure, got " .. tostring(resources.cpu and resources.cpu.used_percent))
check(row_ms < 100, string.format("the roster row costs less than the 120 ms window, took %.1f ms", row_ms))

print("roster sample quick ok (" .. checks .. " checks)")
