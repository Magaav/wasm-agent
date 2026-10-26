-- wa-vault: provider credentials this node *uses* and cannot *read* (docs/VAULT.md).
--
-- The agent has a shell running as the node's own user, so a key in this process's environment, its
-- files or its memory is a key the agent can print. With `WASM_AGENT_VAULT_URL` set, no key reaches
-- this process at all: a vaulted route sends its request to the vault with `PLACEHOLDER` where the
-- credential would be, and the vault - a separate process with its own storage - drops that header,
-- sets the real one and streams the upstream's answer back. Unset, nothing here is consulted and every
-- route behaves exactly as before.
--
-- This module is also the subscription wire's credential seam when vaulted (`token()`, the shape
-- `lua/core/subscription_wire.lua` asks `M.CREDENTIAL_MODULE` for): it answers presence from the
-- vault's `/status`, which never carries a value, and hands the wire the placeholder.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- What a vaulted route sends instead of a credential. Not a secret, and deliberately recognisable in
-- a log: the vault refuses to forward it, so seeing it upstream would itself be the bug.
M.PLACEHOLDER = "wa-vault-brokered"

-- The routes the vault serves, and the upstream host each one stands in for (for the attribution
-- rules in provider.lua, which belong to the service and not to the address we reach it by).
M.ROUTES = {
  ["opencode-go"] = { path = "/opencode-go/v1", upstream_host = "opencode.ai" },
  ["openai-sub"] = { path = "/openai-sub", upstream_host = "chatgpt.com" },
}

function M.url(provider_id)
  -- Explicit route overrides preserve a native subscription while Go moves to the broker.
  -- `native` opts this route out of the legacy global setting; errors never fall back.
  local variable = ({["opencode-go"]="WASM_AGENT_OPENCODE_GO_VAULT_URL",
    ["openai-sub"]="WASM_AGENT_OPENAI_SUB_VAULT_URL"})[provider_id]
  local specific = variable and host.getenv(variable)
  if specific == "native" then return nil end
  if type(specific) == "string" and specific ~= "" then return (specific:gsub("/+$", "")) end
  local ok, value = pcall(function() return host.getenv("WASM_AGENT_VAULT_URL") end)
  if not ok or type(value) ~= "string" or value == "" then return nil end
  return (value:gsub("/+$", ""))
end

-- The base URL a vaulted provider is reached at, or nil when there is no vault or no such route.
function M.base(provider_id)
  local url, route = M.url(provider_id), M.ROUTES[provider_id]
  if not url or not route then return nil end
  return url .. route.path
end

-- `{providers = {[id] = {configured, enabled, ...}}}` from the vault, or nil and a failure in the
-- credential lane's shape. Presence only: the vault has no endpoint that returns a value.
function M.status(provider_id)
  local url = M.url(provider_id)
  if not url then return nil, { code = "vault_unset", message = "WASM_AGENT_VAULT_URL is not set" } end
  local ok, raw = pcall(host.http, "GET", url .. "/status", json.encode({ Accept = "application/json" }), "")
  if not ok then return nil, { code = "vault_unreachable", message = tostring(raw) } end
  local decoded, response = pcall(json.decode, raw or "")
  if not decoded or type(response) ~= "table" or response.error then
    return nil, { code = "vault_unreachable",
      message = "wa-vault at " .. url .. " did not answer: " .. tostring(type(response) == "table" and response.error or raw) }
  end
  if tonumber(response.status) ~= 200 then
    return nil, { code = "vault_unreachable", message = "wa-vault /status answered HTTP " .. tostring(response.status) }
  end
  local parsed, payload = pcall(json.decode, response.body or "")
  if not parsed or type(payload) ~= "table" or type(payload.providers) ~= "table" then
    return nil, { code = "vault_unreachable", message = "wa-vault /status answered a body that is not its status" }
  end
  return payload, nil
end

-- The subscription credential seam, vaulted. `{access, account_id, expires}` where both values are
-- the placeholder; the vault owns the real token and its refresh.
function M.token(opts)
  local status, failure = M.status("openai-sub")
  if not status then return nil, failure end
  local entry = status.providers["openai-sub"]
  if opts and opts.expected_generation and (type(entry) ~= 'table' or entry.generation ~= opts.expected_generation) then
    return nil, {code='credential_changed',message='vault authentication changed since run start; no request sent'}
  end
  if type(entry) ~= "table" or not entry.configured then
    return nil, { code = "subscription_credentials_absent",
      message = "wa-vault holds no ChatGPT login - log in from the vault page (wa-vault-open)" }
  end
  if entry.enabled == false then
    return nil, { code = "vault_provider_disabled", message = "openai-sub is disabled on the vault page" }
  end
  return { access = M.PLACEHOLDER, account_id = M.PLACEHOLDER, expires = tonumber(entry.expires) or 0,
           refreshed = false, adopted = false, fingerprint = "wa-vault", store = M.url("openai-sub") }, nil
end

-- One JSON call to the vault's node-side door; the payload or nil and a sentence. The vault's
-- answers carry presence and the login state, never a value, so the payload is safe to print.
-- `provider_id` picks the route's vault, so a per-route URL (WASM_AGENT_OPENAI_SUB_VAULT_URL)
-- reaches the same vault the provider is brokered through.
local function call(method, path, body, provider_id)
  local url = M.url(provider_id)
  if not url then return nil, "no vault: WASM_AGENT_VAULT_URL is not set" end
  local ok, raw = pcall(host.http, method, url .. path,
    json.encode({ Accept = "application/json", ["Content-Type"] = "application/json" }),
    body and json.encode(body) or "")
  if not ok then return nil, tostring(raw) end
  local decoded, response = pcall(json.decode, raw or "")
  if not decoded or type(response) ~= "table" then return nil, "wa-vault answered something that is not JSON" end
  if response.error then return nil, "wa-vault at " .. url .. " is unreachable: " .. tostring(response.error) end
  local parsed, payload = pcall(json.decode, response.body or "")
  if not parsed or type(payload) ~= "table" then payload = {} end
  local status = tonumber(response.status) or 0
  if status < 200 or status >= 300 then
    local err = type(payload.error) == "table" and payload.error or {}
    return nil, tostring(err.message or ("HTTP " .. status)), tostring(err.code or status)
  end
  return payload
end

-- The node-side login door (vault/wa_vault.py, `ProxyHandler.login`): a *first* ChatGPT device
-- login, or a first opencode-go key. Replacing either is the operator's, on the vault page.
-- Starting while a device login is pending answers that same pending login, so `/login` resumes it.
function M.login_state() return call("GET", "/login", nil, "openai-sub") end
function M.start_subscription_login() return call("POST", "/login/openai-sub", nil, "openai-sub") end
function M.cancel_subscription_login() return call("DELETE", "/login/openai-sub", nil, "openai-sub") end
-- A pasted API key, straight to the vault's key file (`<data>/keys/<provider>.key`). Replaces the one
-- stored and turns the provider on; the answer is presence only.
function M.set_key(provider_id, key) return call("POST", "/login/" .. provider_id, { key = key }, provider_id) end

return M
