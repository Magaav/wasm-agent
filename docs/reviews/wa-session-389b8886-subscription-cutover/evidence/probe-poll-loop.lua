-- Reviewer probe 4: what the device poll loop actually does per iteration.
-- Wraps host.sleep and host.http so the values the loop passes are visible. Bounded output:
-- the caller pipes this through counts, never a dump.
local real_sleep = host.sleep
local sleeps = {}
host.sleep = function(ms) sleeps[#sleeps + 1] = tostring(ms); return real_sleep(ms) end

local real_http = host.http
local http_calls = 0
host.http = function(...) http_calls = http_calls + 1; return real_http(...) end

local auth = dofile('lua/core/openai_sub_auth.lua')
local t0 = host.monotonic_ms()
local ok, result, failure = pcall(auth.login, 'device', { timeout_seconds = 2 })
local elapsed = host.monotonic_ms() - t0
print('login ok: ' .. tostring(ok))
print('login failure: ' .. tostring(failure))
print('elapsed_ms: ' .. tostring(math.floor(elapsed)))
print('http calls (polls + the one usercode POST): ' .. tostring(http_calls))
local counts = {}
for _, value in ipairs(sleeps) do counts[value] = (counts[value] or 0) + 1 end
local keys = {}
for key in pairs(counts) do keys[#keys + 1] = key end
table.sort(keys)
for _, key in ipairs(keys) do print('sleep(' .. key .. ') x' .. tostring(counts[key])) end
os.exit(0)
