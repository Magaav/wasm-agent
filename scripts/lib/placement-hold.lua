-- Hold session A's run claim the way an attended turn does, and keep holding it while the node decides what to
-- do with A's resume. `host.sleep` keeps the claim alive; exiting releases it (resources.finish), which is what a
-- real turn does when it ends. Prints the claim it took so the caller can see the holder is real.
local resources = dofile("lua/core/resources.lua")
local hold_ms = tonumber(os.getenv("PLACEMENT_HOLD_MS") or "25000") or 25000
local ctx = { session_id = "placement-a", user_id = "master", run_id = "run-attended-a" }
local held = resources.begin(ctx)
if not held or not held.ok then
  print("hold_failed=" .. tostring(held and held.error))
  os.exit(1)
end
print("held=placement-a")
host.sleep(hold_ms)
resources.finish(ctx)
print("released=placement-a")
