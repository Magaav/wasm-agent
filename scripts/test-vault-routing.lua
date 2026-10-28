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
  local status, failure = vault.status("opencode-go")
  ok(status == nil and type(failure) == "table" and failure.code == "vault_unreachable",
     "an unreachable vault is a vault_unreachable failure, not a status (got " ..
     tostring(failure and failure.code) .. ")")
  ok(vault.base("openai-sub") == nil, "the vault has no ChatGPT route")
else
  ok(go.api_key ~= vault.PLACEHOLDER, "without a vault, opencode-go never carries the placeholder")
  ok(not tostring(go.base_url):find("/opencode-go/v1", 1, true), "without a vault, the base URL is the provider's")
  local status, failure = vault.status("opencode-go")
  ok(status == nil and failure.code == "vault_unset", "the vault refuses when no vault is set")
end

print(string.format("vault routing (%s): %d checks, %d failed", url and "vaulted" or "direct", checks, failed))
os.exit(failed == 0 and 0 or 1)
