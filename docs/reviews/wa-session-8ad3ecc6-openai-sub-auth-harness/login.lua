-- The reviewer's own login driver: device code first, browser PKCE second, exactly the two entry
-- points the task asks about. Fingerprints/URLs only.
local json = dofile("lua/vendor/json.lua")
local auth = dofile("lua/core/openai_sub_auth.lua")
local mode = host.getenv("VERIFY_LOGIN_MODE") or "device"
local timeout = tonumber(host.getenv("VERIFY_LOGIN_TIMEOUT") or "10")
local callback = host.getenv("VERIFY_LOGIN_CALLBACK")
local result, failure = auth.login(mode, { timeout_seconds = timeout, callback = callback })
if result then
  print("LOGIN ok mode=" .. mode .. " account=" .. tostring(result.account_id) ..
    " source=" .. tostring(result.source) .. " pending=" .. tostring(result.pending))
  if result.url then print("LOGIN url=" .. tostring(result.url)) end
else
  print("LOGIN error mode=" .. mode .. " code=" .. tostring(failure and failure.code))
end
io.stdout:flush()
