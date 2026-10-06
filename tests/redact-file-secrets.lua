-- The node's signing key and stored OAuth credentials are redacted from tool output exactly, like the
-- configured API keys. Run with WASM_AGENT_OPENAI_SUB_STORE pointing at a throwaway file and a
-- throwaway HOME: WA_SCRIPT=tests/redact-file-secrets.lua wa
local redact = dofile("lua/core/redact.lua")
local paths = dofile("lua/core/paths.lua")
local key = string.rep("ab12", 16)
host.write_file(paths.config() .. "/node.key", key)
local refresh = "rt_" .. string.rep("Z9", 20)
local store=assert(host.getenv("WASM_AGENT_OPENAI_SUB_STORE"),'private fixture store required')
assert(host.write_file(store,
  '{"openai-codex":{"access_token":"at_' .. string.rep("Q7", 20) .. '","refresh_token":"' .. refresh .. '","account":"acct"}}'))
local out, hits = redact.value({ stdout = "key=" .. key .. "\nrefresh " .. refresh .. "\naccount acct" })
assert(not out.stdout:find(key, 1, true), "the node key is redacted")
assert(not out.stdout:find(refresh, 1, true), "the refresh token is redacted")
assert(out.stdout:find("account acct", 1, true), "ordinary text is left alone")
assert(hits.NODE_KEY == 1 and hits.OPENAI_SUB_CREDENTIAL == 1, "and the hits are named")
local rotated='rt_'..string.rep('X4',20)
assert(host.write_file(store,'{"refresh_token":"'..rotated..'"}'))
local next=redact.value({stdout=rotated})
assert(not next.stdout:find(rotated,1,true),'rotation is redacted at the next boundary without stale cache')
print("redact file secrets ok (5 checks, 0 skipped)")
