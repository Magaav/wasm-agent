-- The measured fixture (docs/KERNEL.md, "A2.3"): its FIRST statement is a host call, which is what
-- makes "time to first Lua statement" an observation at the bridge boundary instead of an inference
-- from stdout. After it: one module read through EMBEDDED (the answer the guest caches per instance)
-- and a little Lua, so a run is long enough to measure and short enough to repeat.
local started = host.monotonic_ms()
assert(type(started) == "number", "host.monotonic_ms must cross the bridge")

local module = dofile("bench/pool-fixture-module.lua")
assert(type(module) == "table" and type(module.total) == "function", "the fixture module must resolve")
assert(module.total(100) == 5050, "the fixture module must run")
