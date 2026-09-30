-- The live evidence for the credential lane: the real provider, the real store, and Pi's package
-- moved out of the way. Not part of the gate - it needs an account, the network and a human - and
-- it is here so the claims in the delivery can be re-derived by anyone with those three things.
--
--   WA_SCRIPT=scripts/test-openai-sub-auth-live.lua wa --db <scratch.db> [--login-seconds 45]
--
-- What it does, in order, and what each step is evidence *for*:
--
--   1. records what was there before (wasm-agent's store, Pi's auth file: bytes kept in a run
--      directory, sha256 printed), because one thing below is not reversible - a refresh *spends* a
--      rotating token on the provider's side, and a token that has been spent cannot be un-spent;
--   2. imports Pi's credential once (`M.import_from_pi`), or reports that our store already holds one;
--   3. **independence**: moves Pi's installed package directory aside and makes Pi's auth file
--      unreadable (moved aside, so it reads as absent and comes back byte-identical), then calls
--      `M.token()` and makes a real subscription request with the token it returned. Both are
--      restored immediately afterwards and the restoration is verified against its sha256;
--   4. **rotation**: writes the store back with the same access/refresh pair but an expiry in the
--      past, calls `M.token()`, and reports the refresh token's fingerprint before and after, the
--      provider's answer and the new expiry - no token is ever printed;
--   5. **login**: starts the real device-code flow, prints the URL and the user code, and waits for
--      the configured budget. Nobody authorizes it, so it must end in `flow_expired` - which is the
--      point: the URL and the code are what a human needs, and a fake success would be the one
--      unacceptable outcome;
--   6. leaves wasm-agent's store holding the credential this run ended with (`--restore-store` puts
--      the pre-run bytes back instead, and says plainly that the token in them may be spent).
--
-- Everything printed is a fingerprint, a length, a timestamp or an HTTP status. The tokens
-- themselves never leave the process.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local auth = dofile("lua/core/openai_sub_auth.lua")

local argv = args or {}
local options = {}
for index, value in ipairs(argv) do
  if value == "--restore-store" then options.restore = true
  elseif value == "--login-seconds" then options.login_seconds = tonumber(argv[index + 1]) end
end

local checks, failures = 0, 0
local function ok(value, label, detail)
  checks = checks + 1
  if value then print("ok   " .. label) return true end
  failures = failures + 1
  print("FAIL " .. label .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
  return false
end
local function sha(text)
  if type(text) ~= "string" then return nil end
  return host.sha256(text)
end
local function short(text)
  local digest = sha(text)
  return digest and digest:sub(1, 12) or "-"
end
-- Paths reach a shell here, so they are normalized and single-quoted; a quote in a home directory
-- would otherwise end the word.
local function native(path) return (tostring(path):gsub("\\", "/")) end
local function quoted(path) return "'" .. native(path):gsub("'", "'\\''") .. "'" end

local run_dir = paths.temp() .. "/wa-openai-sub-live-" .. tostring(host.uuid()):sub(1, 8)
local store_path = auth.store_path()
local pi_path = auth.pi_auth_path()
local pi_package = nil
for _, candidate in ipairs({
  paths.home() .. "/AppData/Roaming/npm/node_modules/@earendil-works/pi-coding-agent",
  paths.home() .. "/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent",
  paths.home() .. "/.local/lib/node_modules/@earendil-works/pi-coding-agent",
}) do
  if host.canonical_path(candidate) then pi_package = candidate end
end

print("openai-sub live evidence")
print("  store        " .. store_path)
print("  pi auth      " .. pi_path)
print("  pi package   " .. tostring(pi_package))
print("  run dir      " .. run_dir)
print("  auth base    " .. tostring(auth.endpoints().auth_base))

-- --- 1. what was there before anything can spend anything -----------------------------------
local store_before = host.read_file(store_path)
local pi_before = host.read_file(pi_path)
assert(host.write_file(run_dir .. "/store-before.json", store_before or "null"))
assert(host.write_file(run_dir .. "/pi-auth-before.json", pi_before or "null"))
print("  store before: present=" .. tostring(store_before ~= nil) .. " sha256=" .. short(store_before))
print("  pi auth before: present=" .. tostring(pi_before ~= nil) .. " sha256=" .. short(pi_before))

-- --- 2. the one-time import -----------------------------------------------------------------
local imported, import_failure = auth.import_from_pi()
if imported then
  print("  imported from pi once: account " .. tostring(imported.account_id) ..
    " access fingerprint " .. tostring(imported.fingerprint))
elseif import_failure and import_failure.code == "import_already_present" then
  print("  wasm-agent's store already holds a credential; the one-time import was skipped")
else
  print("  import did not run: " .. tostring(import_failure and import_failure.code))
end
local status = auth.status()
ok(status.present, "wasm-agent's store holds a credential",
  tostring(status.code) .. " " .. tostring(status.message))
print("  " .. auth.describe())

-- --- 3. independence from Pi's package and Pi's file ----------------------------------------
local function move(from, to)
  local result = json.decode(host.exec("mv " .. quoted(from) .. " " .. quoted(to), "", 30))
  return result and result.ok == true, result
end

local package_aside = false
local message = nil
if pi_package then
  package_aside, message = move(pi_package, pi_package .. ".wa-aside")
  ok(package_aside, "pi's package directory moves aside (the independence window opens)",
    json.encode(message))
else
  print("  (no Pi package directory found; only the auth file is moved aside)")
end
local pi_aside = false
if pi_before then
  pi_aside, message = move(pi_path, pi_path .. ".wa-aside")
  ok(pi_aside, "pi's auth file is unreadable while the window is open (moved aside)", json.encode(message))
end

local endpoint_probe = json.decode(host.http("POST",
  auth.endpoints().token, json.encode({ ["Content-Type"] = "application/x-www-form-urlencoded" }),
  "grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
print("  (a deliberately token-less refresh against the live endpoint answered HTTP " ..
  tostring(endpoint_probe and endpoint_probe.status) .. " / " ..
  tostring(endpoint_probe and endpoint_probe.error) .. " - the endpoint is live)")

local token, token_failure = auth.token()
if ok(token ~= nil, "M.token() returns a token with Pi's package and file out of reach",
    tostring(token_failure and token_failure.code) .. " " .. tostring(token_failure and token_failure.message)) then
  print("  token: account " .. tostring(token.account_id) .. " access fingerprint " ..
    tostring(token.fingerprint) .. " expires " .. tostring(token.expires) ..
    " refreshed=" .. tostring(token.refreshed))
  local response = json.decode(host.http("GET", "https://chatgpt.com/backend-api/wham/usage",
    json.encode({ ["Accept"] = "application/json", ["Authorization"] = "Bearer " .. token.access,
      ["ChatGPT-Account-Id"] = token.account_id, ["User-Agent"] = "codex-cli" }), ""))
  local http_status = tonumber(response and response.status)
  ok(http_status == 200, "a real subscription request made with it succeeds (HTTP 200)",
    "status=" .. tostring(http_status) .. " " .. tostring(response and response.error))
end

if pi_aside then
  ok(move(pi_path .. ".wa-aside", pi_path), "pi's auth file comes back")
  local restored_bytes = host.read_file(pi_path)
  ok(sha(restored_bytes) == sha(pi_before), "byte-identical to what it was (sha256)",
    short(restored_bytes) .. " vs " .. short(pi_before))
end
if package_aside then
  ok(move(pi_package .. ".wa-aside", pi_package), "pi's package directory comes back")
  ok(host.canonical_path(pi_package .. "/dist/core/auth-storage.js") ~= nil,
    "and pi's own files are where they were")
end

-- --- 4. a real refresh, and the rotated token -----------------------------------------------
local current = json.decode(host.read_file(store_path) or "null")
if type(current) == "table" and current.refresh then
  local before_fingerprint = auth.fingerprint(current.refresh)
  local before_length = #current.refresh
  local forced = { version = current.version, provider = current.provider, type = current.type,
    access = current.access, refresh = current.refresh,
    expires = math.floor(host.now() * 1000) - 1000, account_id = current.account_id,
    refreshes = current.refreshes, source = current.source,
    access_fingerprint = current.access_fingerprint, refresh_fingerprint = current.refresh_fingerprint }
  current = nil
  assert(host.write_file(store_path, json.encode(forced)),
    "the store must be writable to force the refresh this evidence needs")
  local rotated, rotate_failure = auth.token()
  local after = json.decode(host.read_file(store_path) or "null")
  if ok(rotated ~= nil, "the live token endpoint accepts our refresh request",
      tostring(rotate_failure and rotate_failure.code) .. " " ..
      tostring(rotate_failure and rotate_failure.message)) then
    ok(rotated.refreshed == true, "and this call performed it")
    ok(type(after) == "table" and auth.fingerprint(after.refresh) ~= before_fingerprint,
      "the store now holds a *different* refresh token (fingerprints only)",
      short(before_fingerprint) .. " -> " .. tostring(after and auth.fingerprint(after.refresh)))
    print("  refresh fingerprint " .. tostring(before_fingerprint) .. " -> " ..
      tostring(after and auth.fingerprint(after.refresh)) .. " (length " .. tostring(before_length) ..
      " -> " .. tostring(after and #after.refresh) .. "), expires " ..
      tostring(after and after.expires) .. ", account " .. tostring(after and after.account_id))
    local response = json.decode(host.http("GET", "https://chatgpt.com/backend-api/wham/usage",
      json.encode({ ["Accept"] = "application/json", ["Authorization"] = "Bearer " .. rotated.access,
        ["ChatGPT-Account-Id"] = rotated.account_id, ["User-Agent"] = "codex-cli" }), ""))
    ok(tonumber(response and response.status) == 200,
      "and the rotated access token works against the provider",
      "status=" .. tostring(response and response.status))
  end
else
  ok(false, "a credential exists to refresh", "the store holds no refresh token")
end

-- --- 5. the device-code login, up to the point a human is needed -----------------------------
print("openai-sub live login: starting the real device-code flow")
local started, login_failure = auth.login("device", { timeout_seconds = options.login_seconds or 45 })
if started then
  ok(false, "the login completed unattended (a human authorized it - unexpected)")
elseif login_failure and login_failure.code == "flow_expired" then
  ok(true, "the device flow reached the human step and expired there, as designed")
  print("  " .. tostring(login_failure.message))
else
  ok(false, "the device flow failed before a human could act",
    tostring(login_failure and login_failure.code) .. " " .. tostring(login_failure and login_failure.message))
end

-- --- 6. the end state ------------------------------------------------------------------------
if options.restore and store_before then
  assert(host.write_file(store_path, store_before))
  print("  store restored to its pre-run bytes (sha256 " .. short(store_before) ..
    ") - note the refresh token in them may have been spent by the refresh above")
else
  print("  store left as this run ended it: " .. auth.describe())
end
print("  run directory (the pre-run bytes): " .. run_dir)
print("openai-sub live evidence: " .. tostring(checks - failures) .. " ok / " ..
  tostring(checks) .. " checks, failures " .. tostring(failures))
if failures > 0 then error("openai-sub live evidence: " .. tostring(failures) .. " checks failed") end
