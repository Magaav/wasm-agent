-- The ChatGPT-subscription credential: our own store, our own refresh, our own login.
--
-- Why this file exists: `lua/core/openai_sub_bridge.lua` handed credential work to Pi's
-- `dist/core/auth-storage.js` and Pi's `models.getAuth`, because "Pi owns OAuth refresh, locking
-- and the subscription wire protocol". This module takes back the credential half, so wasm-agent
-- can serve the subscription route with no third-party package on disk. The transport half is a
-- sibling lane's; the two meet at exactly one seam:
--
--   local token, failure = M.token()
--   -- token   = {access=<bearer>, account_id=<ChatGPT-Account-Id>, expires=<ms since epoch>,
--   --            refreshed=<bool, this call performed the token POST>,
--   --            adopted=<bool, another process's refresh was adopted under the lock>,
--   --            fingerprint=<12 hex of the access token, for logs>, store=<path>}
--   -- failure = {code=<taxonomy code>, message=<human sentence>, status=<http status or nil>}
--
-- `failure` is never a bare string and never contains a credential: a caller distinguishes cases
-- by `code`, an operator reads `message`. `M.status()`, `M.login(mode)`, `M.import_from_pi()` and
-- `M.store_path()` are the rest of the surface; `lua/core/openai_sub.lua` and the transport lane
-- call these and never read `~/.pi` themselves.
--
-- The mechanism is *measured from Pi 0.87.1 (MIT)*, not invented: `CLIENT_ID`, the auth host, the
-- token endpoint's form body, `expires = now + expires_in*1000`, the access token's
-- `https://api.openai.com/auth` -> `chatgpt_account_id` claim, the device-code endpoints and their
-- pending/slow_down answers, and the browser authorize parameters. What is deliberately *not*
-- reproduced is Pi's implementation: its `proper-lockfile` lease, its non-atomic store write, and
-- its one-process store.
--
-- Four rules this file is built around, each one a failure that has happened:
--
--   1. **The refresh token rotates on every refresh, so it is a single-use credential.** Two
--      concurrent refreshes with the same token are not a wasted request: the second one spends a
--      token the server has already invalidated and the store can end up holding a dead pair. So
--      every read-modify-write of the store happens under one cross-process lock, and the store is
--      re-read *after* the lock is taken - N concurrent callers issue one HTTP POST, not N.
--   2. **Errors are a taxonomy.** `subscription_credentials_absent`, `refresh_rejected:<status>`,
--      `locked`, `flow_expired`, `lock_unavailable`, `store_corrupt`, `import_already_present`,
--      `login_pending`, `cancelled`, `flow_failed:<status>`, `flow_state_mismatch`,
--      `invalid_response`, `http_unavailable`. A rejected refresh is **never retried**: the only
--      token there is to retry is the one the server just rejected.
--   3. **No secret leaves the process in a printable form.** A token never goes on a command line,
--      never into a log line, never into an error message; anything derived from a provider
--      response passes `redact.text` before it can reach a log. `M.status()` is safe to print.
--   4. **Pi is read exactly once.** `M.import_from_pi()` is the only reader of `~/.pi` in this
--      module; afterwards every read and write is our own file. With neither store populated the
--      error is `subscription_credentials_absent`, naming the login to run - an absent credential
--      is a state to explain, never a crash.
--
-- The lock is `host.resource`, the host's durable exclusive claim: the claim is a row keyed by
-- resource name, and liveness is an OS-held SQLite lease, not an elapsed-time guess. A claim held
-- by a process that has exited is taken over with `reconcile` and stated evidence; a claim held by
-- a live process is *not* - the waiter re-reads the store instead, which is what makes the
-- single-flight real. That is strictly stronger than Pi's mtime-based lockfile (30 s stale), and it
-- is why no new host capability was needed for this lane.
--
-- Risk, stated: these endpoints are OpenAI's private subscription surface, so this follows Pi's
-- measured use of them rather than a published contract, and a change on OpenAI's side shows up
-- here as `flow_failed:<status>` / `refresh_rejected:<status>` rather than as a schema error. Two
-- environment variables exist so a test can aim the module at a local fixture instead of
-- auth.openai.com and its own home - `WASM_AGENT_OPENAI_SUB_AUTH_BASE` and
-- `WASM_AGENT_OPENAI_SUB_STORE`; they are the only way it is ever pointed elsewhere.
--
-- Limitation, stated: mode restriction is applied with the platform's own tool (`chmod 600` on
-- POSIX, `icacls` on Windows) because the host has no chmod capability, and a provider whose
-- answer lacks `expires_in`/`refresh_token` is refused rather than patched. Access tokens are
-- refreshed only on hard expiry - there is no clock-skew margin - so a caller that holds a token
-- across its expiry sees it expire, exactly as it would with Pi's own store.

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
local redact = dofile("lua/core/redact.lua")

local M = {}

-- --- the measured contract (Pi 0.87.1, MIT) -----------------------------------------------
local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local DEFAULT_AUTH_BASE_URL = "https://auth.openai.com"
local SCOPE = "openid profile email offline_access"
-- Pi sends `originator=pi`; this identifies the caller, and ours is not Pi.
local ORIGINATOR = "wasm-agent"
local JWT_CLAIM_PATH = "https://api.openai.com/auth"
local BROWSER_REDIRECT_URI = "http://localhost:1455/auth/callback"
local DEVICE_REDIRECT_URI = DEFAULT_AUTH_BASE_URL .. "/deviceauth/callback"
local DEVICE_VERIFICATION_URI = DEFAULT_AUTH_BASE_URL .. "/codex/device"
-- Pi's own ceiling for the device flow; ours is the same ceiling but a lower default (below),
-- because this one blocks the interpreter that is driving it.
local DEVICE_CODE_TIMEOUT_SECONDS = 900
local DEFAULT_LOGIN_TIMEOUT_SECONDS = 300
local DEFAULT_LOCK_WAIT_MS = 30000
-- The state machine answer for "the human has not finished yet", in both spellings the server uses.
local PENDING_CODES = { deviceauth_authorization_pending = true, authorization_pending = true }

-- --- the store and the lock -----------------------------------------------------------------
local STORE_SUBDIR = "openai-sub"
local STORE_FILE = "credentials.json"
local FLOW_FILE = "login-flow.json"
-- The claim name is visible in `host.resource('list')` and in the resource store's history, so it
-- says what it is guarding rather than naming an implementation.
local LOCK_KEY = "openai-sub:credentials"
local LOCK_PRINCIPAL = "openai-sub"
local LOCK_SESSION = "openai-sub"

local function env(name)
  local ok, value = pcall(host.getenv, name)
  if not ok or type(value) ~= "string" or value == "" then return nil end
  return value
end

local function auth_base_url()
  return (env("WASM_AGENT_OPENAI_SUB_AUTH_BASE") or DEFAULT_AUTH_BASE_URL):gsub("/+$", "")
end
local function token_url() return auth_base_url() .. "/oauth/token" end
local function authorize_url() return auth_base_url() .. "/oauth/authorize" end
local function device_user_code_url() return auth_base_url() .. "/api/accounts/deviceauth/usercode" end
local function device_token_url() return auth_base_url() .. "/api/accounts/deviceauth/token" end
local function device_verification_uri() return auth_base_url() .. "/codex/device" end
local function device_redirect_uri() return auth_base_url() .. "/deviceauth/callback" end

function M.store_path()
  return env("WASM_AGENT_OPENAI_SUB_STORE") or (paths.data() .. "/" .. STORE_SUBDIR .. "/" .. STORE_FILE)
end
local function store_dir()
  local path = M.store_path():gsub("\\", "/")
  return path:match("^(.*)/[^/]+$") or path
end
local function flow_path() return store_dir() .. "/" .. FLOW_FILE end

-- The one place Pi's agent directory is named, and it is read by exactly one function
-- (`M.import_from_pi`). Same default and same override as `openai_sub.lua`'s `auth_path()`, so the
-- import reads the file the bridge reads; `WASM_AGENT_PI_AUTH` is the fixture seam that lets a
-- test put a stand-in file here.
function M.pi_auth_path()
  if env("WASM_AGENT_PI_AUTH") then return env("WASM_AGENT_PI_AUTH") end
  local directory = env("PI_CODING_AGENT_DIR") or (paths.home() .. "/.pi/agent")
  return directory .. "/auth.json"
end

-- The login entry point named in every "you have no credential" message. It is a file this lane
-- ships, so the name is true today; the coordinator's cutover adds the REPL command in front of it.
local LOGIN_COMMAND = "WA_SCRIPT=scripts/openai-sub-login.lua wa"

-- --- time -----------------------------------------------------------------------------------
local function now_ms()
  local seconds = host.now()
  if type(seconds) ~= "number" then
    -- A host too old to answer: refuse rather than invent a time. A wrong clock silently disables
    -- expiry, and an expiry that cannot be checked is worse than a visible refusal.
    error("openai_sub_auth requires host.now()")
  end
  return math.floor(seconds * 1000)
end

-- --- errors ---------------------------------------------------------------------------------
-- A code plus a sentence, with an optional HTTP status. The `__tostring` is what makes
-- `error(failure)` and `("%s"):format(failure)` read like a sentence in a log or a trace, while
-- `failure.code` stays exact for a caller that branches.
local function failure(code, message, extra)
  local value = { code = code, message = message or code }
  if extra then
    for key, item in pairs(extra) do value[key] = item end
  end
  return setmetatable(value, { __tostring = function(self)
    return tostring(self.code) .. (self.message and (": " .. tostring(self.message)) or "")
  end })
end
M.failure = failure

local function absent_failure()
  return failure("subscription_credentials_absent",
    "no ChatGPT-subscription credential at " .. M.store_path() ..
    " and no credential to import from " .. M.pi_auth_path() ..
    "; log in with: " .. LOGIN_COMMAND .. " (device code), then retry")
end

-- --- http -----------------------------------------------------------------------------------
local function http_json(method, url, headers, body, timeout_note)
  if type(host.http) ~= "function" then
    return nil, failure("http_unavailable", "this host has no host.http capability")
  end
  local ok, raw = pcall(host.http, method, url, json.encode(headers or {}), body or "")
  if not ok then
    -- The call itself failed (an old host, a Lua error). Redacted: a transport message can quote
    -- the request line, and the request line of a refresh carries no token (our body does), but
    -- there is no reason to trust that of every caller.
    return nil, failure("http_unavailable", redact.text(tostring(raw)))
  end
  local decoded, value = pcall(json.decode, raw or "")
  if not decoded or type(value) ~= "table" then
    return nil, failure("invalid_response", "host.http did not answer with a JSON object")
  end
  if value.error then
    -- A transport error (DNS, TLS, timeout). The body was never sent-and-rejected, so this is not
    -- `refresh_rejected`: a caller may retry it by hand. It is never retried here.
    return nil, failure("unreachable", redact.text(tostring(value.error)), { note = timeout_note })
  end
  return { status = tonumber(value.status) or 0, body = tostring(value.body or "") }, nil
end

-- A provider's error body is not ours, and the shape of it is not a contract: a 4xx from the
-- token endpoint can quote the request, which is where a refresh token or a bearer token lives.
-- So the body is *parsed* and only the documented OAuth fields are ever reported - never echoed.
-- Anything else becomes a byte count, which is still enough to tell "a server said no" from
-- "something else answered".
local function provider_error(body)
  local text = tostring(body or "")
  local decoded, payload = pcall(json.decode, text)
  local code, description
  if decoded and type(payload) == "table" then
    local raw = payload.error
    if type(raw) == "string" then code = raw
    elseif type(raw) == "table" and type(raw.code) == "string" then code = raw.code end
    if type(payload.error_description) == "string" then description = payload.error_description end
    if not code and type(payload.code) == "string" then code = payload.code end
  end
  if not code and not description then
    return "body of " .. tostring(#text) .. " bytes with no OAuth error field"
  end
  local parts = {}
  if code then parts[#parts + 1] = "error=" .. code end
  if description then parts[#parts + 1] = "description=" .. description:sub(1, 160) end
  return table.concat(parts, ", ")
end

-- A host or shell error string, redacted and clipped.
local function safe_detail(text)
  return redact.text(tostring(text or "")):gsub("%s+", " "):sub(1, 240)
end

-- `host.run_cancelled()` answers a JSON object, not a boolean - reading it as a boolean made every
-- login "cancelled" the first time this ran, which is what a test is for.
local function cancelled()
  if type(host.run_cancelled) ~= "function" then return false end
  local ok, raw = pcall(host.run_cancelled)
  if not ok then return false end
  local decoded, value = pcall(json.decode, raw or "")
  if decoded and type(value) == "table" then return value.cancelled == true end
  return raw == true
end

local function url_encode(value)
  -- Everything outside the unreserved set, which is what a form body requires. `-._~` are left
  -- alone (the refresh token is base64url and contains `-` and `_`), and everything else is
  -- percent-encoded byte-wise so non-ASCII survives.
  return (tostring(value or ""):gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function form_body(fields)
  local parts = {}
  for _, name in ipairs({ "grant_type", "refresh_token", "client_id", "code", "code_verifier",
                          "redirect_uri" }) do
    if fields[name] ~= nil then
      parts[#parts + 1] = name .. "=" .. url_encode(fields[name])
    end
  end
  return table.concat(parts, "&")
end

local function post_form(url, fields)
  return http_json("POST", url, { ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Accept"] = "application/json" }, form_body(fields))
end

local function post_json(url, value)
  return http_json("POST", url, { ["Content-Type"] = "application/json",
    ["Accept"] = "application/json" }, json.encode(value))
end

-- --- base64url, PKCE and the access token's own claims ---------------------------------------
-- `memory.lua` owns the repository's base64 (and its encoder is the one its own test compares
-- against `base64 -d`), so it is reused here rather than reimplemented - loaded lazily, because
-- only the browser login needs it and a credential store should not pull the memory module into
-- every process that asks for a token.
local function base64()
  local ok, module = pcall(dofile, "lua/core/memory.lua")
  if not ok or type(module) ~= "table" or type(module.base64_decode) ~= "function" then
    return nil
  end
  return module
end

local function b64url_decode(text)
  local module = base64()
  if not module then return nil, failure("invalid_response", "base64 helper unavailable") end
  local standard = tostring(text or ""):gsub("-", "+"):gsub("_", "/")
  return module.base64_decode(standard)
end

local function b64url_encode(bytes)
  local module = base64()
  if not module then return nil, failure("invalid_response", "base64 helper unavailable") end
  return (module.base64_encode(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

-- Random bytes. `host.uuid` is the host's only OS-random source (it fills from `SystemRandom`),
-- so two v4 UUIDs are decoded to their 32 bytes; six of those bits are fixed by the UUID layout,
-- which leaves ~250 bits of entropy - more than PKCE needs and far more than can be searched.
local function random_bytes(count)
  local hex = tostring(host.uuid() or ""):gsub("%-", "") ..
              tostring(host.uuid() or ""):gsub("%-", "")
  local bytes = {}
  for pair in hex:gmatch("%x%x") do bytes[#bytes + 1] = string.char(tonumber(pair, 16)) end
  local value = table.concat(bytes)
  if #value < count then error("openai_sub_auth requires host.uuid()") end
  return value:sub(1, count)
end

local function sha256_bytes(text)
  local digest = host.sha256(text)
  if type(digest) ~= "string" or #digest ~= 64 then return nil end
  return (digest:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

-- PKCE S256, byte for byte what Pi builds: the verifier is base64url(32 random bytes) - 43
-- characters of the verifier alphabet - and the challenge is base64url(sha256(verifier)).
-- `scripts/test-openai-sub-auth.lua` pins the RFC 7636 appendix-B vector against `M.challenge`, so
-- the encoder and the digest are checked against a published answer rather than against each other.
function M.challenge(verifier)
  local bytes = sha256_bytes(tostring(verifier or ""))
  if not bytes then
    return nil, failure("invalid_response", "host.sha256 did not answer with a digest")
  end
  return b64url_encode(bytes)
end

function M.pkce()
  local verifier, encode_failure = b64url_encode(random_bytes(32))
  if not verifier then return nil, encode_failure end
  local challenge, challenge_failure = M.challenge(verifier)
  if not challenge then return nil, challenge_failure end
  return { verifier = verifier, challenge = challenge }
end

local function random_state()
  -- Pi's `createState`: 16 random bytes, hex, compared on the callback.
  return (random_bytes(16):gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end))
end

-- The access token is a JWT and the account id lives in it; nothing else needs the signature, and
-- nothing here can verify it locally - the request that uses the token is the verification.
local function jwt_payload(access)
  if type(access) ~= "string" then return nil end
  local encoded = access:match("^[^.]+%.([^.]+)%.")
  if not encoded then return nil end
  local decoded_text, decode_failure = b64url_decode(encoded)
  if not decoded_text then return nil end
  local ok, payload = pcall(json.decode, decoded_text)
  if not ok or type(payload) ~= "table" then return nil end
  return payload
end

function M.account_id_from_access(access)
  local payload = jwt_payload(access)
  local claim = payload and payload[JWT_CLAIM_PATH]
  local account_id = type(claim) == "table" and claim.chatgpt_account_id or nil
  if type(account_id) == "string" and account_id ~= "" then return account_id end
  return nil
end

-- A 12-hex-character fingerprint: enough to say "this changed", and only ever printed for a
-- credential whose value is already in the same file - a 48-bit prefix of a 1 KB token is not
-- usable as a credential and is not brute-forceable from the print.
local function fingerprint(secret)
  if type(secret) ~= "string" or secret == "" then return nil end
  local digest = host.sha256(secret)
  if type(digest) ~= "string" then return nil end
  return digest:sub(1, 12)
end
M.fingerprint = fingerprint

-- --- the store file -------------------------------------------------------------------------
local function read_store()
  local text = host.read_file(M.store_path())
  if text == nil then
    -- `host.read_file` is the only reader we have, so a file that exists but cannot be read looks
    -- exactly like a missing one (the same honest degradation `paths.config_file_present`
    -- documents). "Absent" is therefore reported for both, and the message names the path.
    return nil, absent_failure()
  end
  local decoded, value = pcall(json.decode, text)
  if not decoded or type(value) ~= "table" then
    return nil, failure("store_corrupt", "the credential store at " .. M.store_path() ..
      " is not a JSON object; remove it and log in again with: " .. LOGIN_COMMAND)
  end
  if type(value.access) ~= "string" or value.access == ""
     or type(value.refresh) ~= "string" or value.refresh == ""
     or type(value.expires) ~= "number"
     or type(value.account_id) ~= "string" or value.account_id == "" then
    return nil, failure("store_corrupt", "the credential store at " .. M.store_path() ..
      " is missing access/refresh/expires/account_id; log in again with: " .. LOGIN_COMMAND)
  end
  return value, nil
end

-- The mode a credential file is written with, applied with the platform's own tool and reported
-- as it answered rather than as it was asked for. The host's `write_file` is an atomic
-- temp+rename, and on POSIX it carries the target's existing permissions across the rename, so
-- this is applied after each write and survives the next one.
local last_mode = nil
-- A single quote in a path (or a user name) would end the shell word and let the rest of the path
-- run as a command, so it is escaped in the one form both `sh` and the Windows tools accept.
local function quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end
local function restrict_mode(path)
  local os_name = tostring(platform.os() or "")
  local command, method
  if os_name == "windows" then
    local user = env("USERNAME") or ""
    if user == "" then return { method = "icacls", code = nil, error = "username_unknown" } end
    method = "icacls"
    command = "icacls " .. quote(path) .. " /inheritance:r /grant:r " .. quote(user .. ":F")
  else
    method = "chmod"
    command = "chmod 600 " .. quote(path)
  end
  local ok, raw = pcall(host.exec, command, "", 15)
  if not ok or type(raw) ~= "string" then
    return { method = method, code = nil, error = "exec_failed" }
  end
  local decoded, value = pcall(json.decode, raw)
  if not decoded or type(value) ~= "table" then
    return { method = method, code = nil, error = "exec_unreadable" }
  end
  return { method = method, code = tonumber(value.code), ok = value.ok == true,
           error = value.ok == true and nil or safe_detail(value.stderr) }
end

local function write_store(value)
  value.mode = last_mode
  local text = json.encode(value)
  if not host.write_file(M.store_path(), text) then
    return nil, failure("store_write_failed", "could not write " .. M.store_path())
  end
  local mode = restrict_mode(M.store_path())
  last_mode = mode
  if mode.ok ~= true then
    -- Visible, never fatal: the credential exists, the file's mode is what the platform said.
    host.log("openai-sub: credential store mode not restricted (" ..
      tostring(mode.method) .. " exit " .. tostring(mode.code) .. " " .. tostring(mode.error) .. ")")
  end
  return true, nil
end

local function clear_flow()
  -- No delete capability exists, so a consumed flow is *retired* by writing it empty: the file
  -- always exists and always means "nothing pending" when it says so.
  host.write_file(flow_path(), json.encode({ version = 1, pending = false, retired_at = now_ms() }))
end
M.flow_path = flow_path

local function read_flow()
  local text = host.read_file(flow_path())
  if text == nil then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" or value.pending ~= true then return nil end
  -- A pending flow that has outlived its own window is not pending any more: resuming one would
  -- poll a device_auth_id the server has forgotten, and report *that* instead of the honest
  -- "there is no login in flight". The provider's own ceiling is 900s (Pi's
  -- DEVICE_CODE_TIMEOUT_SECONDS), and it is written into the file when the flow starts.
  local expires_at = tonumber(value.expires_at)
  if expires_at and now_ms() > expires_at then return nil end
  return value
end

local function write_flow(value)
  value.version = 1
  value.pending = true
  if not host.write_file(flow_path(), json.encode(value)) then
    return nil, failure("store_write_failed", "could not write " .. flow_path())
  end
  restrict_mode(flow_path())
  return true, nil
end

-- --- the lock -------------------------------------------------------------------------------
-- One claim per process instance: the run id is fresh per interpreter, so two interpreters inside
-- one process (two node-threads, one process boot) contend through the host exactly like two
-- processes do. The host compares (run, principal, boot) and refuses a claim held by any other
-- run, consulting the OS lease only when asked to reconcile - which is the takeover path for a
-- holder that has exited.
local lock_run_id = nil
local function lock_run()
  if not lock_run_id then
    lock_run_id = "openai-sub:" .. tostring(host.uuid())
  end
  return lock_run_id
end

local function resource(action, args)
  if type(host.resource) ~= "function" then
    return nil, failure("lock_unavailable", "this host has no host.resource capability, so the " ..
      "rotating refresh token cannot be spent safely; refusing to refresh")
  end
  local ok, raw = pcall(host.resource, action, json.encode(args or {}))
  if not ok then
    return nil, failure("lock_unavailable", redact.text(tostring(raw)))
  end
  local decoded, value = pcall(json.decode, raw or "")
  if not decoded or type(value) ~= "table" then
    return nil, failure("lock_unavailable", "host.resource did not answer with a JSON object")
  end
  return value, nil
end

function M.lock_state()
  local listed, list_failure = resource("list", {})
  if not listed then return { error = list_failure.code } end
  for _, claim in ipairs(listed.claims or {}) do
    if claim.key == LOCK_KEY then
      return { held = true, principal = claim.principal, run = claim.run,
               boot = claim.boot, uncertain = claim.uncertain == true }
    end
  end
  return { held = false }
end

-- Acquire the credential lock, or explain why not. Returns `release, nil` or `nil, failure`.
-- `locked` is the answer when a *live* holder keeps the claim past the caller's patience - the
-- honest one, because the alternative (proceeding) is the double-spend this exists to prevent.
function M.acquire_lock(wait_ms)
  local deadline = host.monotonic_ms() + (tonumber(wait_ms) or DEFAULT_LOCK_WAIT_MS)
  local attempt = 0
  local last_holder = nil
  while true do
    attempt = attempt + 1
    local claimed, claim_failure = resource("claim", { principal = LOCK_PRINCIPAL,
      session = LOCK_SESSION, run = lock_run(), keys = { LOCK_KEY } })
    if not claimed then return nil, claim_failure end
    if claimed.ok == true then
      local released = false
      return function()
        if released then return true end
        released = true
        resource("finish", { principal = LOCK_PRINCIPAL, run = lock_run() })
        return true
      end, nil
    end
    if claimed.error == "resource_busy" and type(claimed.claim) == "table" then
      last_holder = claimed.claim
      -- The holder may be gone. `reconcile` is the host's refusal-protected takeover: it reads the
      -- holder's OS lease and refuses while that process lives, so this can only succeed over a
      -- claim whose process has exited. The evidence is recorded in the resource store's history
      -- and is readable afterwards through `host.resource('list')`, which M.status() reports.
      local takeover = resource("reconcile", { key = LOCK_KEY, principal = claimed.claim.principal,
        run = claimed.claim.run,
        evidence = "openai-sub credential lock: holder's process no longer holds its OS lease; " ..
                   "the refresh it was performing left no settled write (no effect replayed)" })
      if takeover and takeover.ok == true then
        -- The claim is gone; loop and race for it like any other waiter. Nothing is done here on
        -- purpose: the winner of that race re-reads the store, so a takeover cannot spend the
        -- rotating token a second time either.
      else
        -- A live holder, or a claim that changed under us. Both mean "wait", and waiting is what
        -- makes the second caller adopt the first one's token instead of spending the same
        -- rotating token twice.
      end
    elseif type(claimed.claim) == "table" then
      last_holder = claimed.claim
    else
      return nil, failure("locked", "the credential lock was refused: " ..
        safe_detail(claimed.error or "unknown"))
    end
    if host.monotonic_ms() >= deadline then
      return nil, failure("locked",
        "another wasm-agent process holds the credential lock past " ..
        tostring(tonumber(wait_ms) or DEFAULT_LOCK_WAIT_MS) .. "ms; held by run " ..
        tostring(last_holder and last_holder.run or "unknown") .. " (it is alive - the lock is " ..
        "refused, not timed out, only when the holder's process has exited)",
        { holder_run = last_holder and last_holder.run, holder_boot = last_holder and last_holder.boot })
    end
    -- Backoff bounded by 10 s (`host.sleep`'s own ceiling is 10 000 ms); a refresh takes a second
    -- or two, so the first waits are short and the later ones are cheap.
    local remaining = deadline - host.monotonic_ms()
    host.sleep(math.max(20, math.min(250 * attempt, remaining, 2000)))
  end
end

-- --- the seam: a usable token ---------------------------------------------------------------
local function token_of(credential, refreshed, adopted)
  return { access = credential.access, account_id = credential.account_id,
           expires = credential.expires, refreshed = refreshed == true,
           adopted = adopted == true, fingerprint = fingerprint(credential.access),
           store = M.store_path() }
end

local function record_last_error(credential, code, detail)
  -- Kept in the store so a rejected credential is *durable*: the next status() shows it, and an
  -- operator can see what the provider said without a refresh having to be spent again to
  -- rediscover it. `provider_error` extracts only the OAuth fields - a store is as public as a log.
  credential.last_error = { code = code, at = now_ms(), detail = detail }
  write_store(credential)
end

local function refresh_locked(credential)
  -- Under the lock, and immediately after taking it: the holder before us may have refreshed, and
  -- *that* token is the one to use. This re-read is what turns N concurrent callers into one POST.
  local current, read_failure = read_store()
  if not current then
    -- The store vanished (or was corrupted) while we waited. Fall back to what we entered with
    -- only if it is still unexpired, otherwise report the read failure as itself.
    if credential and now_ms() < credential.expires then return token_of(credential, false, false), nil end
    return nil, read_failure
  end
  if now_ms() < current.expires then
    return token_of(current, false, current.refresh ~= (credential and credential.refresh)), nil
  end
  local response, request_failure = post_form(token_url(), { grant_type = "refresh_token",
    refresh_token = current.refresh, client_id = CLIENT_ID })
  if not response then return nil, request_failure end
  if response.status < 200 or response.status >= 300 then
    -- The rotating token was spent, or the account cannot refresh. Never retried here: a retry
    -- would re-send a token the server has already answered about.
    local code = "refresh_rejected:" .. tostring(response.status)
    local detail = provider_error(response.body)
    record_last_error(current, code, detail)
    return nil, failure(code, "the token endpoint refused the refresh (" .. tostring(response.status) ..
      "): " .. detail, { status = response.status })
  end
  local decoded, payload = pcall(json.decode, response.body)
  if not decoded or type(payload) ~= "table" then
    return nil, failure("invalid_response", "the token endpoint answered 200 with a body that is " ..
      "not JSON", { status = response.status })
  end
  local access, refresh, expires_in = payload.access_token, payload.refresh_token, payload.expires_in
  if type(access) ~= "string" or access == "" or type(refresh) ~= "string" or refresh == ""
     or type(expires_in) ~= "number" then
    -- Pi refuses the same way (`readTokenResponse`), and for the same reason: a rotation that did
    -- not arrive in full must not be persisted as if it had, or the *new* refresh token would be
    -- lost while the old one is already invalid.
    return nil, failure("invalid_response",
      "the token endpoint answered 200 without access_token/refresh_token/expires_in",
      { status = response.status })
  end
  local account_id = M.account_id_from_access(access) or current.account_id
  local next_value = { version = 1, provider = "openai-codex", type = "oauth",
    access = access, refresh = refresh, expires = now_ms() + math.floor(expires_in * 1000),
    account_id = account_id, obtained_at = now_ms(), refreshes = (tonumber(current.refreshes) or 0) + 1,
    access_fingerprint = fingerprint(access), refresh_fingerprint = fingerprint(refresh),
    previous_refresh_fingerprint = current.refresh_fingerprint or fingerprint(current.refresh),
    source = current.source or "login", last_error = nil }
  local written, write_failure = write_store(next_value)
  if not written then return nil, write_failure end
  return token_of(next_value, true, false), nil
end

-- The seam. `{access, account_id, expires}` and the single-flight refresh behind it; opts may
-- carry `lock_wait_ms` for a caller with a shorter budget than the default.
function M.token(opts)
  opts = opts or {}
  local credential, read_failure = read_store()
  if not credential then return nil, read_failure end
  if now_ms() < credential.expires then return token_of(credential, false, false), nil end
  local release, lock_failure = M.acquire_lock(opts.lock_wait_ms)
  if not release then return nil, lock_failure end
  local ok, token, refresh_failure = pcall(refresh_locked, credential)
  local released, release_failure = pcall(release)
  if not ok then return nil, failure("refresh_failed", redact.text(tostring(token))) end
  if not released then
    -- The lock could not be released. The token, if we got one, is still valid and the store is
    -- written; the lease is released when this process exits, so the next caller reconciles it.
    host.log("openai-sub: credential lock release failed: " .. redact.text(tostring(release_failure)))
  end
  if not token then return nil, refresh_failure end
  return token, nil
end

-- --- status ---------------------------------------------------------------------------------
-- Everything an operator needs and nothing a caller could spend. Safe to print: no access token,
-- no refresh token, only fingerprints, timestamps and the lock's owner.
function M.status()
  local report = { store = M.store_path(), flow = flow_path(), pi_auth = M.pi_auth_path(),
    lock = M.lock_state(), lock_key = LOCK_KEY, login = LOGIN_COMMAND }
  local credential, read_failure = read_store()
  if not credential then
    report.present = false
    report.state = "absent"
    report.code = read_failure.code
    report.message = read_failure.message
    return report
  end
  local now = now_ms()
  report.present = true
  report.state = now < credential.expires and "valid" or "expired"
  report.account_id = credential.account_id
  report.expires = credential.expires
  report.expires_in_ms = credential.expires - now
  report.obtained_at = credential.obtained_at
  report.refreshes = credential.refreshes
  report.source = credential.source
  report.access_fingerprint = credential.access_fingerprint
  report.refresh_fingerprint = credential.refresh_fingerprint
  report.previous_refresh_fingerprint = credential.previous_refresh_fingerprint
  report.mode = credential.mode
  report.last_error = credential.last_error
  return report
end

-- --- the one-time import --------------------------------------------------------------------
-- Pi's store, read once: `~/.pi/agent/auth.json`, key `openai-codex`, value
-- `{type='oauth', access, refresh, expires, accountId}`. After this call nothing here reads Pi
-- again - and a second import is refused rather than silently overwriting a credential that may
-- have been refreshed since (a live token is not something to trade for a stale copy).
function M.import_from_pi()
  local existing = read_store()
  if existing then
    return nil, failure("import_already_present", "wasm-agent already holds a credential for " ..
      "account " .. tostring(existing.account_id) .. " in " .. M.store_path() ..
      "; the import from Pi is a one-time move, not a re-read")
  end
  local text = host.read_file(M.pi_auth_path())
  if text == nil then return nil, absent_failure() end
  local decoded, pi_store = pcall(json.decode, text)
  if not decoded or type(pi_store) ~= "table" then
    return nil, failure("store_corrupt", "the Pi auth file at " .. M.pi_auth_path() ..
      " is not a JSON object")
  end
  local credential = pi_store["openai-codex"]
  if type(credential) ~= "table" or type(credential.access) ~= "string" or credential.access == ""
     or type(credential.refresh) ~= "string" or credential.refresh == ""
     or type(credential.expires) ~= "number" then
    return nil, absent_failure()
  end
  local account_id = type(credential.accountId) == "string" and credential.accountId or nil
  if not account_id or account_id == "" then account_id = M.account_id_from_access(credential.access) end
  if not account_id then
    return nil, failure("store_corrupt", "the Pi credential for openai-codex carries no accountId " ..
      "and its access token carries no chatgpt_account_id claim")
  end
  local value = { version = 1, provider = "openai-codex", type = "oauth",
    access = credential.access, refresh = credential.refresh, expires = credential.expires,
    account_id = account_id, obtained_at = now_ms(), refreshes = 0,
    access_fingerprint = fingerprint(credential.access),
    refresh_fingerprint = fingerprint(credential.refresh),
    source = "import:pi", imported_at = now_ms() }
  local written, write_failure = write_store(value)
  if not written then return nil, write_failure end
  return { ok = true, imported = true, account_id = account_id, store = M.store_path(),
           expires = value.expires, fingerprint = value.access_fingerprint }, nil
end

-- --- login ----------------------------------------------------------------------------------
local function emitter(opts)
  local sink = opts and opts.on_event
  return function(kind, fields)
    local line = fields and fields.line or kind
    if sink then
      local ok, err = pcall(sink, { kind = kind, line = line, fields = fields })
      if ok then return end
      host.log("openai-sub: login event sink failed: " .. redact.text(tostring(err)))
    end
    -- A human reads stdout; the durable record goes through host.log, which masks credentials.
    print(line)
    io.stdout:flush()
    host.log(line)
  end
end

local function store_token_response(payload, source)
  local access, refresh, expires_in = payload.access_token, payload.refresh_token, payload.expires_in
  if type(access) ~= "string" or access == "" or type(refresh) ~= "string" or refresh == ""
     or type(expires_in) ~= "number" then
    return nil, failure("invalid_response",
      "the token exchange answered without access_token/refresh_token/expires_in")
  end
  local account_id = M.account_id_from_access(access)
  if not account_id then
    return nil, failure("invalid_response",
      "the access token carries no chatgpt_account_id claim under " .. JWT_CLAIM_PATH)
  end
  local value = { version = 1, provider = "openai-codex", type = "oauth", access = access,
    refresh = refresh, expires = now_ms() + math.floor(expires_in * 1000), account_id = account_id,
    obtained_at = now_ms(), refreshes = 0, access_fingerprint = fingerprint(access),
    refresh_fingerprint = fingerprint(refresh), source = source }
  local written, write_failure = write_store(value)
  if not written then return nil, write_failure end
  clear_flow()
  return { ok = true, account_id = account_id, expires = value.expires, source = source,
           fingerprint = value.access_fingerprint, store = M.store_path() }, nil
end

local function exchange_authorization_code(code, verifier, redirect_uri)
  local response, request_failure = post_form(token_url(), { grant_type = "authorization_code",
    code = code, code_verifier = verifier, client_id = CLIENT_ID, redirect_uri = redirect_uri })
  if not response then return nil, request_failure end
  if response.status < 200 or response.status >= 300 then
    return nil, failure("flow_failed:" .. tostring(response.status),
      "the authorization-code exchange was refused (" .. tostring(response.status) .. "): " ..
      provider_error(response.body), { status = response.status })
  end
  local decoded, payload = pcall(json.decode, response.body)
  if not decoded or type(payload) ~= "table" then
    return nil, failure("invalid_response", "the token exchange answered 200 with a body that is " ..
      "not JSON", { status = response.status })
  end
  return payload, nil
end

local function login_timeout_seconds()
  local configured = tonumber(env("WASM_AGENT_OPENAI_SUB_LOGIN_TIMEOUT"))
  if configured and configured > 0 then return math.min(configured, DEVICE_CODE_TIMEOUT_SECONDS) end
  return DEFAULT_LOGIN_TIMEOUT_SECONDS
end

-- Device-code login: the one that works headless, which is the one a node needs. Returns
-- `{ok=true, account_id=...}` once the store holds a credential, or a failure. While a human is
-- needed it *prints* the URL and the code - that is the whole point of this flow - and then waits.
local function login_device(opts)
  local emit = emitter(opts)
  local budget_seconds = tonumber(opts.timeout_seconds) or login_timeout_seconds()
  local pending = read_flow()
  local device_auth_id, user_code, interval
  if pending and pending.flow == "device" and pending.device_auth_id and pending.user_code then
    device_auth_id, user_code = pending.device_auth_id, pending.user_code
    interval = tonumber(pending.interval) or 5
    -- A resumed flow cannot be waited on longer than its own window, whatever the caller asked for.
    local left = (tonumber(pending.expires_at) or 0) - now_ms()
    if left > 0 then budget_seconds = math.min(budget_seconds, math.floor(left / 1000)) end
    emit("resume", { line = "openai-sub: resuming the pending device login from " .. flow_path() })
  else
    local response, request_failure = post_json(device_user_code_url(), { client_id = CLIENT_ID })
    if not response then return nil, request_failure end
    if response.status < 200 or response.status >= 300 then
      local code = "flow_failed:" .. tostring(response.status)
      if response.status == 404 then
        return nil, failure(code, "the device-code endpoint answered 404: device-code login is not " ..
          "enabled for " .. auth_base_url() .. " (use the browser login instead)", { status = 404 })
      end
      return nil, failure(code, "the device-code request was refused (" .. tostring(response.status) ..
        "): " .. provider_error(response.body), { status = response.status })
    end
    local decoded, payload = pcall(json.decode, response.body)
    if not decoded or type(payload) ~= "table" then
      return nil, failure("invalid_response", "the device-code endpoint answered 200 with a body " ..
        "that is not JSON", { status = response.status })
    end
    device_auth_id, user_code = payload.device_auth_id, payload.user_code
    -- Pi accepts an interval that arrives as a numeric *string* (`typeof==="string"` -> Number);
    -- this server has done both, so both are accepted and a nonsense value falls back to 5 s.
    interval = tonumber(payload.interval) or 5
    if type(device_auth_id) ~= "string" or device_auth_id == ""
       or type(user_code) ~= "string" or user_code == "" or interval < 0 then
      return nil, failure("invalid_response",
        "the device-code response carried no device_auth_id/user_code/interval")
    end
    local written, write_failure = write_flow({ flow = "device", device_auth_id = device_auth_id,
      user_code = user_code, interval = interval, started_at = now_ms(),
      expires_at = now_ms() + DEVICE_CODE_TIMEOUT_SECONDS * 1000 })
    if not written then return nil, write_failure end
  end
  emit("device_code", { line = "openai-sub: open " .. device_verification_uri() ..
    " and enter the code " .. user_code .. "  (waiting up to " .. tostring(budget_seconds) .. "s)",
    verification_url = device_verification_uri(), user_code = user_code, interval = interval })

  local deadline = host.monotonic_ms() + budget_seconds * 1000
  local polls = 0
  while host.monotonic_ms() < deadline do
    if host.run_cancelled and cancelled() then
      return nil, failure("cancelled", "the run was cancelled while waiting for the device login; " ..
        "the code " .. tostring(user_code) .. " is still valid - re-run the login to resume")
    end
    local response, request_failure = post_json(device_token_url(),
      { device_auth_id = device_auth_id, user_code = user_code })
    if not response then
      -- A transport failure mid-poll is not the flow dying (the flow lives on the server); it is
      -- reported as itself, and the pending flow file survives so a resume can continue.
      return nil, request_failure
    end
    polls = polls + 1
    if response.status >= 200 and response.status < 300 then
      local decoded, payload = pcall(json.decode, response.body)
      if not decoded or type(payload) ~= "table" then
        return nil, failure("invalid_response", "the device-token endpoint answered 200 with a " ..
          "body that is not JSON", { status = response.status })
      end
      if type(payload.authorization_code) ~= "string" or payload.authorization_code == ""
         or type(payload.code_verifier) ~= "string" or payload.code_verifier == "" then
        return nil, failure("invalid_response", "the device-token response carried no " ..
          "authorization_code/code_verifier", { status = response.status })
      end
      emit("authorized", { line = "openai-sub: device authorized after " .. tostring(polls) ..
        " polls; exchanging the authorization code" })
      local granted, exchange_failure = exchange_authorization_code(payload.authorization_code,
        payload.code_verifier, device_redirect_uri())
      if not granted then return nil, exchange_failure end
      local stored, store_failure = store_token_response(granted, "login:device")
      if not stored then return nil, store_failure end
      emit("stored", { line = "openai-sub: logged in - account " .. tostring(stored.account_id) ..
        ", expires in " .. tostring(math.floor((stored.expires - now_ms()) / 1000)) .. "s" })
      return stored, nil
    end
    -- Pending is the normal answer while the human types; 403/404 is how Pi reads it, and the
    -- structured error code is the other spelling. Anything else is a real refusal.
    local error_code = response.body:match('"code"%s*:%s*"([%w_]+)"') or
      response.body:match('"error"%s*:%s*"([%w_]+)"')
    local pending_here = response.status == 403 or response.status == 404
      or (error_code ~= nil and PENDING_CODES[error_code] == true)
    if not pending_here then
      if error_code == "slow_down" then
        interval = interval + 5
        emit("slow_down", { line = "openai-sub: the server asked us to slow down; polling every " ..
          tostring(interval) .. "s" })
      else
        local code = "flow_failed:" .. tostring(response.status)
        return nil, failure(code, "the device-token poll was refused (" ..
          tostring(response.status) .. "): " .. provider_error(response.body), { status = response.status })
      end
    end
    -- A poll is a unit of progress for the human; saying so every time keeps a five-minute wait
    -- legible instead of looking like a hang.
    if polls % 6 == 0 then
      emit("waiting", { line = "openai-sub: still waiting for the code " .. tostring(user_code) ..
        " (" .. tostring(polls) .. " polls, " ..
        tostring(math.max(0, math.floor((deadline - host.monotonic_ms()) / 1000))) .. "s left)" })
    end
    -- `host.sleep` is capped at 10 000 ms and the loop needs a cancelled run to be noticed, so the
    -- wait is taken in bounded steps rather than one long sleep.
    local step = math.max(1, math.min(interval * 1000, 5000, deadline - host.monotonic_ms()))
    host.sleep(step)
  end
  return nil, failure("flow_expired", "the device login for code " .. tostring(user_code) ..
    " expired after " .. tostring(budget_seconds) .. "s without authorization; the pending flow is " ..
    "kept at " .. flow_path() .. " - re-run the login to resume, or open " ..
    device_verification_uri() .. " and enter " .. tostring(user_code))
end

-- Browser login, secondary and two-phase: this process cannot open a listener on 1455 (the host
-- has no server socket), so phase one prints the authorize URL and keeps the PKCE verifier beside
-- the credential store, and phase two takes the redirect URL - or just the code - the human
-- pasted back.
local function login_browser(opts)
  local emit = emitter(opts)
  local pending = read_flow()
  local pasted = opts.code or opts.callback
  if not pasted then
    if pending and pending.flow == "browser" and pending.verifier then
      emit("pending", { line = "openai-sub: a browser login is already pending; open the URL " ..
        "printed earlier and paste the redirect URL back (state " ..
        tostring(pending.state):sub(1, 8) .. "…)" })
      return { ok = false, pending = true, flow = "browser", url = pending.url,
               state = pending.state, resume = true }, nil
    end
    local pkce, pkce_failure = M.pkce()
    if not pkce then return nil, pkce_failure end
    local state = random_state()
    local query = { response_type = "code", client_id = CLIENT_ID,
      redirect_uri = BROWSER_REDIRECT_URI, scope = SCOPE, code_challenge = pkce.challenge,
      code_challenge_method = "S256", state = state, id_token_add_organizations = "true",
      codex_cli_simplified_flow = "true", originator = ORIGINATOR }
    local parts = {}
    for _, name in ipairs({ "response_type", "client_id", "redirect_uri", "scope", "code_challenge",
                            "code_challenge_method", "state", "id_token_add_organizations",
                            "codex_cli_simplified_flow", "originator" }) do
      parts[#parts + 1] = name .. "=" .. url_encode(query[name])
    end
    local url = authorize_url() .. "?" .. table.concat(parts, "&")
    local written, write_failure = write_flow({ flow = "browser", verifier = pkce.verifier,
      state = state, url = url, redirect_uri = BROWSER_REDIRECT_URI, started_at = now_ms(),
      expires_at = now_ms() + DEVICE_CODE_TIMEOUT_SECONDS * 1000 })
    if not written then return nil, write_failure end
    emit("browser_url", { line = "openai-sub: open this URL, sign in, then paste the address you " ..
      "land on (it starts with " .. BROWSER_REDIRECT_URI .. "):\n" .. url,
      url = url, state = state })
    return { ok = false, pending = true, flow = "browser", url = url, state = state }, nil
  end
  if not (pending and pending.flow == "browser" and pending.verifier) then
    return nil, failure("flow_expired", "there is no pending browser login to complete; run the " ..
      "login again to get a fresh authorize URL")
  end
  local code, state = pasted, nil
  local from_url = tostring(pasted):match("[?&]code=([^&%s]+)")
  if from_url then
    code = from_url
    state = tostring(pasted):match("[?&]state=([^&%s]+)")
  elseif tostring(pasted):match("^[^%s&]+#[^%s&]+$") then
    code, state = tostring(pasted):match("^([^#]+)#(.+)$")
  end
  if state ~= nil and state ~= pending.state then
    return nil, failure("flow_state_mismatch", "the pasted state does not match this login's state; " ..
      "the callback belongs to another flow (or was tampered with) - start the login again")
  end
  local granted, exchange_failure = exchange_authorization_code(code, pending.verifier,
    pending.redirect_uri or BROWSER_REDIRECT_URI)
  if not granted then return nil, exchange_failure end
  local stored, store_failure = store_token_response(granted, "login:browser")
  if not stored then return nil, store_failure end
  emit("stored", { line = "openai-sub: logged in - account " .. tostring(stored.account_id) })
  return stored, nil
end

-- `M.login(mode)` with mode "device" (the default, the one that works headless) or "browser".
-- A human step is not a failure: the device flow prints the URL and code and waits inside its
-- budget, while the browser flow returns `{pending=true, url=...}` and completes on the next call
-- with `code=`/`callback=`. Success means the store holds a credential that `M.token()` can use -
-- never an assertion that it does.
function M.login(mode, opts)
  opts = opts or {}
  if type(mode) == "table" then opts, mode = mode, opts end
  mode = mode or opts.mode or "device"
  if mode == "device" or mode == "device_code" then return login_device(opts) end
  if mode == "browser" then return login_browser(opts) end
  return nil, failure("unsupported_mode", "unknown login mode " .. tostring(mode) ..
    "; expected 'device' (default) or 'browser'")
end

-- Exposed for the login entry point and for tests: the exact endpoints this module talks to,
-- so a fixture can prove it is aimed at itself rather than at the real auth host.
function M.endpoints()
  return { auth_base = auth_base_url(), token = token_url(), authorize = authorize_url(),
    device_user_code = device_user_code_url(), device_token = device_token_url(),
    device_verification = device_verification_uri(), device_redirect = device_redirect_uri(),
    browser_redirect = BROWSER_REDIRECT_URI, client_id = CLIENT_ID, scope = SCOPE,
    originator = ORIGINATOR, claim_path = JWT_CLAIM_PATH }
end

-- One line for a caller that wants to show what state the route is in. Never a credential.
function M.describe()
  local report = M.status()
  if not report.present then
    return "openai-sub credential: absent (" .. tostring(report.code) .. ") at " .. report.store
  end
  return "openai-sub credential: " .. report.state .. " for account " .. tostring(report.account_id) ..
    ", expires in " .. tostring(math.floor(report.expires_in_ms / 1000)) .. "s, refreshes " ..
    tostring(report.refreshes) .. ", refresh " .. tostring(report.refresh_fingerprint)
end

return M
