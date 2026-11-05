-- Same script native (wa WA_SCRIPT, real host) and in wasm (luarunner): times host.* round trips
-- vs a pure-Lua call, a pcall/error path, and json.lua encode/decode. Result is a JSON-ish line.
local N = 100000
local clock = function() return tonumber(host.monotonic_ms()) end
local t0 = clock()
for i = 1, N do host.sha256("x") end
local t1 = clock()
local f = function(s) return #s end
for i = 1, N do f("x") end
local t2 = clock()
local errs = 0
for i = 1, 10000 do if not pcall(error, "boom") then errs = errs + 1 end end
local t3 = clock()
local json_path = JSON_PATH or host.getenv("JSON_PATH")
local json = load(host.read_file(json_path), "=json.lua")()
local doc = {}
for i = 1, 200 do doc[i] = {id = i, name = "item" .. i, tags = {"a", "b", "c"}, nested = {x = i * 1.5, ok = true}} end
local t4 = clock()
local text
for i = 1, 50 do text = json.encode(doc); json.decode(text) end
local t5 = clock()
local per = function(ms, n) return string.format("%.2f", ms * 1000 / n) end
local line = string.format("host.sha256 x%d: %.1f ms (%s us/call) | pure lua call x%d: %.1f ms | pcall(error) x10000: %.1f ms (%d caught) | json encode+decode 200 items x50: %.1f ms (%d bytes)",
  N, t1 - t0, per(t1 - t0, N), N, t2 - t1, t3 - t2, errs, t5 - t4, #text)
print("bench: " .. line)
return line
