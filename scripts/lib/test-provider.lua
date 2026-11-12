-- A test fixture that sets its own provider must never be answered by the operator's vault (11/11).
--
-- Measured, speed.log: a fixture set `WASM_AGENT_LLM_BASE_URL` to a dead port (127.0.0.1:9) and the child
-- it spawned was answered by the operator's REAL provider anyway - because the process inherited
-- `WASM_AGENT_VAULT_URL` from the session's environment, and `provider.providers()` prefers the vault's
-- route over the base-URL variable *on purpose* (a vaulted node must not be steerable by an env var,
-- docs/VAULT.md). A test made a model call with the operator's credentials and nothing said so.
--
-- Two halves, because clearing is not enough on its own:
--   * `M.getenv(values)` is the getenv a fixture installs: the vault variables are ALWAYS nil, then the
--     fixture's own values, then the real environment. A fixture built on it cannot reach a vault.
--   * `M.vault_in_environment()` and `M.refuse_vault()` report a vault the ambient environment carried
--     anyway - a row run by hand inside a node session. `M.refuse_vault()` fails such a row by name
--     (`fixture_provider_vault_url`) instead of letting it pass quietly on the operator's credentials.
-- `scripts/fast.sh` also removes those variables from every row's environment, and
-- `scripts/test-fast-row-environment.lua` proves from inside a row that it did.
--
-- Usage in a fixture row:
--
--   local fixture = dofile('scripts/lib/test-provider.lua')
--   fixture.refuse_vault('my-row')          -- clear: nothing to refuse; a hand-run row fails by name
--   host.getenv = fixture.getenv({ WASM_AGENT_LLM_API_KEY = 'test-only',
--                                  WASM_AGENT_LLM_BASE_URL = 'http://127.0.0.1:9/fixture' })
local M = {}

-- Every variable that can point this process at a vault. `WASM_AGENT_VAULT_URL` is the one that
-- redirects the provider; the others name the directory and the keystore, which a test must not touch.
M.VARS = {
  'WASM_AGENT_VAULT_URL',
  'WASM_AGENT_VAULT_DIR',
  'WASM_AGENT_VAULT_KEYSTORE',
  'WASM_AGENT_VAULT_PASSPHRASE',
}

-- Read through the host at call time (never captured here), so a fixture that stubs `host.getenv`
-- afterwards still gets the real environment through `real`.
local function real() return host.getenv end

-- The vault URL the ambient environment carries, or nil. `getenv` lets a caller pass the real one it
-- captured before it stubbed anything.
function M.vault_in_environment(getenv)
  local read = getenv or real()
  local url = read('WASM_AGENT_VAULT_URL')
  if type(url) == 'string' and url ~= '' then return url end
  return nil
end

-- Fail a fixture by name when the environment it is running in has a vault. `where` names the row.
function M.refuse_vault(where, getenv)
  local url = M.vault_in_environment(getenv)
  if not url then return end
  error(string.format(
    'fixture_provider_vault_url: %s sets its own provider, but this environment has WASM_AGENT_VAULT_URL=%s. '
      .. 'provider.providers() prefers the vault route over any base-URL variable, so this row would call '
      .. 'the operator\'s real provider instead of its fixture. Run the rows through `bash scripts/fast.sh` '
      .. '(it removes the vault variables), or unset WASM_AGENT_VAULT_URL for this one.',
    tostring(where or 'this test'), tostring(url)), 0)
end

-- The getenv a fixture installs. `values` are served as given (nil means "not set"), the vault variables
-- are always nil, and anything else is the real environment.
function M.getenv(values, getenv)
  local read = getenv or real()
  values = values or {}
  local cleared = {}
  for _, name in ipairs(M.VARS) do cleared[name] = true end
  return function(key)
    if cleared[key] then return nil end
    local value = values[key]
    if value ~= nil then return value end
    return read(key)
  end
end

-- True when `url` is the base URL a fixture set, i.e. this process is not routed through a vault.
function M.is_fixture_url(url)
  return type(url) == 'string' and url ~= ''
end

return M
