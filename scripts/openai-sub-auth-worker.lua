-- One caller of the credential seam, in its own process: the concurrency fixture.
--
-- `scripts/test-openai-sub-auth.lua` starts two of these at once against one store, so the
-- single-flight property is measured across processes rather than argued inside one interpreter.
-- It prints exactly one machine-readable line and nothing else - no token, no store contents:
--
--   WA-AUTH-WORKER ok refreshed=<true|false> adopted=<true|false> account=<id> access_fp=<12 hex>
--                   refresh_fp=<12 hex> expires=<ms>
--   WA-AUTH-WORKER error code=<taxonomy code>
local auth = dofile("lua/core/openai_sub_auth.lua")

local token, failure = auth.token()
if token then
  local report = auth.status()
  print(string.format("WA-AUTH-WORKER ok refreshed=%s adopted=%s account=%s access_fp=%s " ..
    "refresh_fp=%s expires=%s", tostring(token.refreshed), tostring(token.adopted),
    tostring(token.account_id), tostring(token.fingerprint), tostring(report.refresh_fingerprint),
    tostring(token.expires)))
else
  print("WA-AUTH-WORKER error code=" .. tostring(failure and failure.code))
end
io.stdout:flush()
