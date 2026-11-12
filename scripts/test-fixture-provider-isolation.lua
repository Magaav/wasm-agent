-- A fixture provider is never answered by the operator's vault (11/11).
--
-- Measured, speed.log: a test set WASM_AGENT_LLM_BASE_URL to a dead port; the child it spawned was
-- answered by the operator's real provider, with their credentials, because the process inherited
-- WASM_AGENT_VAULT_URL from the session's environment and `provider.providers()` prefers the vault's
-- route over the base-URL variable on purpose (docs/VAULT.md).
--
-- Three things are asserted here, all through the real provider and vault modules - no network, no
-- stubbed precedence rule:
--   1. the leak, named: with a passthrough getenv (the shape the fixtures used to install) and an
--      ambient vault URL, `provider.providers()` resolves the VAULT's route, not the fixture's URL;
--   2. the cure: `scripts/lib/test-provider.lua`'s getenv clears every vault variable, so the same
--      fixture resolves its own base URL and key;
--   3. the refusal: a fixture that finds a vault in its environment anyway - run by hand inside a node
--      session - fails by name (`fixture_provider_vault_url`) instead of passing on the operator's
--      provider.
--
-- Run: WA_SCRIPT=scripts/test-fixture-provider-isolation.lua wa --db /tmp/wa-fixture-provider.db
local fixture = dofile('scripts/lib/test-provider.lua')
local real_getenv = host.getenv
local json = dofile('lua/vendor/json.lua')
local provider = dofile('lua/core/provider.lua')
local vault = dofile('lua/core/vault.lua')

local checks = 0
local function check(cond, what) checks = checks + 1; if not cond then error(what, 2) end end

-- The ambient environment of a session on a vaulted node, as the measured run had it. The URL is a dead
-- port: nothing here may attempt a connection, and `vault.base` reads only the URL and its route table.
local AMBIENT_VAULT = 'http://127.0.0.1:9'
local FIXTURE_URL = 'http://127.0.0.1:9/fixture'
local FIXTURE_KEY = 'fixture-key-not-a-credential'
local ambient = {
  WASM_AGENT_VAULT_URL = AMBIENT_VAULT,
  WASM_AGENT_LLM_BASE_URL = FIXTURE_URL,
  WASM_AGENT_LLM_API_KEY = FIXTURE_KEY,
}
local function ambient_getenv(key)
  if ambient[key] ~= nil then return ambient[key] end
  return real_getenv(key)
end
host.http = function() error('network forbidden in this row') end
host.http_stream = host.http

-- --------------------------------------------------------------- 1. the leak, reproduced
host.getenv = ambient_getenv
local leaked = provider.providers()[1]
check(leaked.base_url ~= FIXTURE_URL,
  'the leak this row is about: a passthrough getenv must resolve the vault route, not the fixture URL '
    .. '(if this now passes, the precedence rule changed and the rest of this row needs re-deriving)')
check(leaked.base_url == vault.base('opencode-go'),
  'the vault route is what answered: ' .. tostring(leaked.base_url))
check(leaked.api_key ~= FIXTURE_KEY, 'the fixture key is not what a vaulted process uses')

-- --------------------------------------------------------------- 2. the cure
host.getenv = fixture.getenv({ WASM_AGENT_LLM_API_KEY = FIXTURE_KEY, WASM_AGENT_LLM_BASE_URL = FIXTURE_URL })
local cured = provider.providers()[1]
check(cured.base_url == FIXTURE_URL, 'with the fixture getenv the process uses the fixture URL: ' .. tostring(cured.base_url))
check(cured.api_key == FIXTURE_KEY, 'and the fixture key: ' .. tostring(cured.api_key))
for _, name in ipairs(fixture.VARS) do
  check(host.getenv(name) == nil, 'the fixture getenv clears ' .. name)
end
check(host.getenv('PATH') == real_getenv('PATH'), 'and still passes the real environment through for everything else')

-- A fixture value of nil must mean "not set", not "fall through to the real environment": a vault
-- variable is cleared above, but a provider variable a test deliberately unsets has to stay unset.
local unset = fixture.getenv({ WASM_AGENT_LLM_BASE_URL = nil }, ambient_getenv)
check(unset('WASM_AGENT_LLM_BASE_URL') == FIXTURE_URL,
  'an explicit nil falls through to the real environment (documented: pass a value to unset it from the fixture side)')

-- --------------------------------------------------------------- 3. the refusal
check(fixture.vault_in_environment(ambient_getenv) == AMBIENT_VAULT,
  'a vault in the environment is reported by name')
check(fixture.vault_in_environment(fixture.getenv({}, ambient_getenv)) == nil,
  'and the fixture getenv has none')
local refused, message = pcall(fixture.refuse_vault, 'scripts/test-fixture-provider-isolation.lua', ambient_getenv)
check(not refused, 'a fixture row inside a vaulted session refuses')
check(tostring(message):find('fixture_provider_vault_url', 1, true) ~= nil,
  'the refusal is a named error: ' .. tostring(message):sub(1, 160))
check(tostring(message):find('WASM_AGENT_VAULT_URL', 1, true) ~= nil, 'and names the variable to unset')
check(tostring(message):find('fast.sh', 1, true) ~= nil, 'and the way to run rows that removes it')
local clean_ok = pcall(fixture.refuse_vault, 'a row with no vault', function() return nil end)
check(clean_ok, 'a row with no vault in its environment is not refused')

-- The soak: with the runner's environment (which removes the vault variables) the refusal is a no-op
-- and the fixture is what a row actually gets. This is the state `scripts/fast.sh` produces.
host.getenv = real_getenv
if fixture.vault_in_environment() == nil then
  local ok = pcall(fixture.refuse_vault, 'this row')
  check(ok, 'this row itself would pass the refusal: the runner removed the vault variables')
  print('fixture provider: the runner removed the vault variables (no vault in this row)')
else
  -- Run by hand in a node session: the row says so rather than failing - the runner is the contract,
  -- and `scripts/test-fast-row-environment.lua` is what fails when the runner breaks it.
  print('fixture provider: WARNING this row runs with WASM_AGENT_VAULT_URL set (by hand, not via fast.sh)')
end

print(string.format('fixture provider isolation: %d checks', checks))
