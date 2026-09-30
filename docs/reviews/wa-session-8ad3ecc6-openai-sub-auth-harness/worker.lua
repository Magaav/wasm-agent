-- One caller of the seam, in its own process. Prints fingerprints only, never a token value.
local auth = dofile("lua/core/openai_sub_auth.lua")
local wait = tonumber(host.getenv("VERIFY_LOCK_WAIT_MS") or "")
local token, failure = auth.token(wait and { lock_wait_ms = wait } or nil)
if token then
  local report = auth.status()
  print(string.format("VERIFY ok refreshed=%s adopted=%s account=%s access_fp=%s refresh_fp=%s expires=%s",
    tostring(token.refreshed), tostring(token.adopted), tostring(token.account_id),
    tostring(token.fingerprint), tostring(report.refresh_fingerprint), tostring(token.expires)))
  print("VERIFY pi_auth_path=" .. tostring(auth.pi_auth_path()))
else
  print("VERIFY error code=" .. tostring(failure and failure.code) ..
    " status=" .. tostring(failure and failure.status))
end
io.stdout:flush()
