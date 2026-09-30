-- Reviewer probe 3: is host.sleep honoured in the *CLI* host (the door's own context)?
-- The poll loop's step is max(1, min(interval*1000, 5000, deadline-now)) ms; if host.sleep is a
-- no-op here the loop spins and each iteration is a real HTTP poll of the auth host.
local t0 = host.monotonic_ms()
host.sleep(1000)
local t1 = host.monotonic_ms()
print('host.sleep(1000) advanced monotonic_ms by: ' .. tostring(t1 - t0))
local a = host.monotonic_ms()
host.sleep(50)
print('host.sleep(50) advanced monotonic_ms by: ' .. tostring(host.monotonic_ms() - a))
os.exit(0)
