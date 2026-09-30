-- Item 1/4: does M.token() answer from our own store with Pi unreachable, and does a real request
-- with that token succeed? Prints status codes, paths and fingerprints - never a token value.
local json = dofile("lua/vendor/json.lua")
local auth = dofile("lua/core/openai_sub_auth.lua")

local store = auth.store_path()
local pi_path = auth.pi_auth_path()
print("LIVE store=" .. store)
print("LIVE pi_auth=" .. pi_path .. " readable=" .. tostring(host.read_file(pi_path) ~= nil))

local token, failure = auth.token()
if not token then
  print("LIVE token_error code=" .. tostring(failure and failure.code))
  os.exit(1)
end
print("LIVE token account=" .. tostring(token.account_id) .. " access_fp=" .. tostring(token.fingerprint) ..
  " refreshed=" .. tostring(token.refreshed) .. " adopted=" .. tostring(token.adopted))

local headers = json.encode({ Authorization = "Bearer " .. token.access,
  ["ChatGPT-Account-Id"] = tostring(token.account_id), ["User-Agent"] = "wasm-agent-reviewer" })
local reply = json.decode(host.http("GET", "https://chatgpt.com/backend-api/wham/usage", headers, ""))
print("LIVE usage status=" .. tostring(reply.status) .. " body_len=" .. tostring(#tostring(reply.body or "")) ..
  " error=" .. tostring(reply.error))
io.stdout:flush()
