-- A live holder of the credential lock, so a second caller must meet `locked` rather than proceed.
local json = dofile("lua/vendor/json.lua")
local run = "verify-holder-" .. tostring(host.uuid())
local claimed = json.decode(host.resource("claim", json.encode({ principal = "openai-sub",
  session = "openai-sub", run = run, keys = { "openai-sub:credentials" } })))
print("HOLDER claimed=" .. tostring(claimed.ok) .. " run=" .. run)
io.stdout:flush()
local held = 0
while held < tonumber(host.getenv("VERIFY_HOLD_MS") or "12000") do
  host.sleep(1000)
  held = held + 1000
end
local released = json.decode(host.resource("finish", json.encode({ principal = "openai-sub", run = run })))
print("HOLDER released=" .. tostring(released.ok))
