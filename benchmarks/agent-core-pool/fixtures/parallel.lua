-- One concurrent caller's turn (the pool's concurrency test). Silent on purpose: four of these run in
-- parallel and the harness, not the scripts, is what says the four leases were distinct.
local started = host.monotonic_ms()
assert(type(started) == "number")
assert(POOL_LEASE_LEAK == nil, "leases must not share one interpreter's globals")
POOL_LEASE_LEAK = true
