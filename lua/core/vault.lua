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

function M.url()
  local ok, value = pcall(function() return host.getenv("WASM_AGENT_VAULT_URL") end)
  if not ok or type(value) ~= "string" or value == "" then return nil end
  return (value:gsub("/+$", ""))
end

-- The base URL a vaulted provider is reached at, or nil when there is no vault or no such route.
function M.base(provider_id)
  local url, route = M.url(), M.ROUTES[provider_id]
  if not url or not route then return nil end
  return url .. route.path
end

-- `{providers = {[id] = {configured, enabled, ...}}}` from the vault, or nil and a failure in the
-- credential lane's shape. Presence only: the vault has no endpoint that returns a value.
function M.status()
  local url = M.url()
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
function M.token()
  local status, failure = M.status()
  if not status then return nil, failure end
  local entry = status.providers["openai-sub"]
  if type(entry) ~= "table" or not entry.configured then
    return nil, { code = "subscription_credentials_absent",
      message = "wa-vault holds no ChatGPT login - log in from the vault page (wa-vault-open)" }
  end
  if entry.enabled == false then
    return nil, { code = "vault_provider_disabled", message = "openai-sub is disabled on the vault page" }
  end
  return { access = M.PLACEHOLDER, account_id = M.PLACEHOLDER, expires = tonumber(entry.expires) or 0,
           refreshed = false, adopted = false, fingerprint = "wa-vault", store = M.url() }, nil
end

-- One JSON call to the vault's node-side door; `{status, payload}` or nil and a sentence. The vault's
-- answers carry presence and the login state, never a value, so the payload is safe to print.
local function call(method, path, body)
  local url = M.url()
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
    return nil, tostring(err.message or ("HTTP " .. status))
  end
  return payload
end

function M.login_state() return call("GET", "/login") end
function M.start_subscription_login() return call("POST", "/login/openai-sub") end
function M.cancel_subscription_login() return call("DELETE", "/login/openai-sub") end
function M.set_key(provider_id, key) return call("POST", "/login/" .. provider_id, { key = key }) end

-- What `/login` offers, in the order it lists them, and what the vault calls each one.
M.LOGINS = {
  { id = "openai-sub", label = "OpenAI subscription (ChatGPT login)" },
  { id = "opencode-go", label = "OpenCode Go (API key)" },
}

local function describe(entry)
  if type(entry) ~= "table" or not entry.configured then return "not set" end
  local text = entry.enabled == false and "set, disabled on the vault page" or "set"
  if type(entry.account) == "string" then text = text .. " - account " .. tostring(entry.account) end
  return text
end

-- `/login`, the way pi does it: pick a provider, then either a device code to enter in a browser or a
-- key to paste. The credential goes from the vault (device login) or from the reader's keyboard
-- straight to the vault; this process never stores it, and nothing it prints contains it.
--
-- `io` is the REPL's: `print(text)`, `ask(prompt) -> line|nil` (echoed, for the choice),
-- `ask_private(prompt) -> line|nil` (not written to the transcript, for the key), and
-- `wait(ms) -> line|nil` (returns early when the reader presses Enter). `select(id)` makes the
-- provider active. Returns true when a credential was stored.
function M.login(io)
  if not M.url() then
    io.print("  /login stores credentials in wa-vault, and this node has none (WASM_AGENT_VAULT_URL is unset).")
    io.print("  without a vault: `wa subscription login` (ChatGPT), or OPENCODE_GO_API_KEY in the environment.")
    return false
  end
  local state, failure = M.login_state()
  if not state then io.print("  " .. tostring(failure)); return false end
  local providers = state.providers or {}
  io.print("  sign in to a provider (stored in wa-vault; the agent can use it, never read it):")
  for index, item in ipairs(M.LOGINS) do
    io.print(string.format("    %d. %-38s %s", index, item.label, describe(providers[item.id])))
  end
  local answer = io.ask("  provider [1-" .. #M.LOGINS .. ", Enter to cancel]: ")
  answer = answer and answer:gsub("^%s+", ""):gsub("%s+$", "") or ""
  local choice
  for index, item in ipairs(M.LOGINS) do
    if answer == tostring(index) or answer == item.id then choice = item end
  end
  if not choice then io.print("  cancelled."); return false end

  if choice.id == "opencode-go" then
    local key = io.ask_private("  paste the OpenCode Go API key (not shown in the transcript; Enter alone cancels): ")
    key = key and key:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if key == "" then io.print("  cancelled."); return false end
    local stored, store_failure = M.set_key("opencode-go", key)
    key = nil
    if not stored then io.print("  not stored: " .. tostring(store_failure)); return false end
    io.print("  opencode-go key stored in wa-vault.")
  else
    local started, start_failure = M.start_subscription_login()
    if not started then io.print("  could not start the ChatGPT login: " .. tostring(start_failure)); return false end
    local login = started.login or {}
    io.print("  open " .. tostring(login.verification_url))
    io.print("  and enter the code:  " .. tostring(login.user_code))
    io.print("  waiting for you to finish in the browser (Enter stops waiting; the code stays valid ~15 min)...")
    local done = false
    while true do
      if io.wait(3000) ~= nil then
        io.print("  stopped waiting. finish in the browser, then run /login again to check, or use the vault page.")
        return false
      end
      local current, poll_failure = M.login_state()
      if not current then io.print("  " .. tostring(poll_failure)); return false end
      local now = current.login or {}
      if now.state == "done" then done = true; break end
      if now.state == "error" then io.print("  login failed: " .. tostring(now.error)); return false end
      if now.state ~= "pending" then io.print("  the login was cancelled."); return false end
    end
    if done then
      local after = M.login_state() or {}
      io.print("  logged in to ChatGPT: " .. describe((after.providers or {})["openai-sub"]) .. ".")
    end
  end
  if io.select then
    local ok, err = io.select(choice.id)
    io.print(ok and ("  provider is now " .. choice.id .. ".") or ("  could not select " .. choice.id .. ": " .. tostring(err)))
  end
  return true
end

return M
