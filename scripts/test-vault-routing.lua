-- wa-vault routing (docs/VAULT.md): with WASM_AGENT_VAULT_URL set, no route holds a credential.
--
-- Run twice, once with the variable and once without, because the routing is decided from the
-- environment and this interpreter cannot change its own:
--   WASM_AGENT_VAULT_URL=http://127.0.0.1:9 WA_SCRIPT=scripts/test-vault-routing.lua wa --db <db>
--   WA_SCRIPT=scripts/test-vault-routing.lua wa --db <db>
-- Port 9 (discard) is chosen so the vault is unreachable: the seam must say so rather than invent a
-- credential.
local vault = dofile("lua/core/vault.lua")
local provider = dofile("lua/core/provider.lua")
local wire = dofile("lua/core/subscription_wire.lua")
local subscription = dofile("lua/core/openai_sub.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end

local function profile(id)
  for _, candidate in ipairs(provider.providers()) do
    if candidate.id == id then return candidate end
  end
end

local url = vault.url()
local go = profile("opencode-go")
local gaps = provider.attribution_gaps()
ok(#gaps == 0, "every shipped profile has an attribution rule: " .. table.concat(gaps, ", "))

if url then
  ok(go.base_url == url .. "/opencode-go/v1", "opencode-go is reached through the vault route")
  ok(go.api_key == vault.PLACEHOLDER, "opencode-go carries the placeholder, not a key")
  local rule = provider.attribution_rule(go)
  ok(rule and rule.host == "opencode.ai" and rule.session == "x-opencode-session",
     "the vaulted route keeps opencode's session header rule")
  ok(wire.ENDPOINT == url .. "/openai-sub/codex/responses", "the subscription wire posts to the vault")
  ok(wire.USAGE_ENDPOINT == url .. "/openai-sub/wham/usage", "the usage endpoint goes through the vault")
  ok(wire.CREDENTIAL_MODULE == "lua/core/vault.lua", "the subscription seam is the vault")
  ok(subscription.transport() == "native", "a vaulted node uses the native wire")
  local credential, failure = wire.credential()
  ok(credential == nil and type(failure) == "table" and failure.code == "vault_unreachable",
     "an unreachable vault is a vault_unreachable failure, not a credential (got " ..
     tostring(failure and failure.code) .. ")")
  ok(subscription.configured() == false, "an unreachable vault leaves openai-sub unconfigured")
else
  ok(go.api_key ~= vault.PLACEHOLDER, "without a vault, opencode-go never carries the placeholder")
  ok(not tostring(go.base_url):find("/opencode-go/v1", 1, true), "without a vault, the base URL is the provider's")
  ok(wire.ENDPOINT == "https://chatgpt.com/backend-api/codex/responses", "without a vault, the wire is chatgpt.com")
  ok(wire.CREDENTIAL_MODULE == "lua/core/openai_sub_auth.lua", "without a vault, the seam is the local store")
  local credential, failure = vault.token()
  ok(credential == nil and failure.code == "vault_unset", "the vault seam refuses when no vault is set")
end

print(string.format("vault routing (%s): %d checks, %d failed", url and "vaulted" or "direct", checks, failed))
os.exit(failed == 0 and 0 or 1)
