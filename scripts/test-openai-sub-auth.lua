-- The ChatGPT-subscription credential, tested where it can be: against a fixture of the auth host,
-- with no OpenAI account, no Pi installation and no model in the loop.
--
--   WA_SCRIPT=scripts/test-openai-sub-auth.lua wa --db <scratch.db>
--
-- What this file is for, in the order it proves it:
--
--   1. the store is ours - absent/import/refreshed are distinguishable states, and an absent one
--      names the login instead of raising;
--   2. a refresh is one HTTP POST with the measured wire shape, and the *rotating* refresh token in
--      the store is the new one afterwards (fingerprints, never values);
--   3. a rejected refresh is a taxonomy code, is never retried, and cannot leak the credential it
--      was carrying into the message a caller logs;
--   4. the lock refuses while a live holder holds it (`locked`) and refuses to refresh at all when
--      the host can offer no lock (`lock_unavailable`);
--   5. device login is driven end to end through the pending -> authorized -> exchange sequence, and
--      its URL and user code reach the human; browser login is two-phase and PKCE-correct against
--      the RFC 7636 vector;
--   6. two *processes* refreshing one expired credential issue one POST - counted by the fixture,
--      not asserted about our own code - and the second one adopts the first one's token;
--   7. a second spend of the same rotating token is refused by the server's own `invalid_grant`.
--
-- The only network this file touches is 127.0.0.1, and the only files are under a scratch
-- directory of its own; there is no OpenAI account and no Pi package in the picture.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")

-- Everything the test prints about the login is captured, so it can be asserted; a FAIL still goes
-- to the real stdout, because a swallowed failure line is a green gate that lies.
local native_print = print
local printed = {}
local function clear_printed() printed = {} end
local function printed_text() return table.concat(printed, "\n") end
print = function(...)
  local parts = {}
  for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
  printed[#printed + 1] = table.concat(parts, "\t")
end

local checks, failures = 0, 0
local function ok(value, label, detail)
  checks = checks + 1
  if value then return true end
  failures = failures + 1
  native_print("FAIL " .. label .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
  return false
end
local function equal(actual, expected, label)
  return ok(actual == expected, label,
    "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function contains(haystack, needle, label)
  return ok(tostring(haystack):find(needle, 1, true) ~= nil, label,
    "missing " .. tostring(needle) .. " in " .. tostring(haystack))
end

-- --- fixtures ------------------------------------------------------------------------------
-- The environment seam is documented in the module: a test aims the credential at its own store,
-- its own auth base and its own Pi file, and nothing here can reach the real ones.
local native_getenv = host.getenv
local overrides = {}
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  return native_getenv(key)
end

local dir = paths.temp() .. "/wa-openai-sub-auth-" .. tostring(host.uuid()):sub(1, 8)
local store = dir .. "/credentials.json"
overrides.WASM_AGENT_OPENAI_SUB_STORE = store
overrides.WASM_AGENT_OPENAI_SUB_AUTH_BASE = "http://127.0.0.1:1"
overrides.WASM_AGENT_OPENAI_SUB_LOCK_WAIT_MS = "400"
overrides.WASM_AGENT_PI_AUTH = dir .. "/pi-auth.json"

local auth = dofile("lua/core/openai_sub_auth.lua")

-- The fixture's HTTP host. The module calls `host.http`, so replacing it in-process is the same
-- seam the transport lane sits on - and it records the exact request, which is how the wire shape
-- is asserted rather than assumed.
local requests = {}
local responder = function() return { error = "no fixture armed" } end
local native_http = host.http
host.http = function(method, url, headers, body)
  -- The module passes headers as JSON text (that is host.http's signature); a stub that kept the
  -- string would "prove" the header was missing.
  local decoded_headers = json.decode(headers or "{}")
  requests[#requests + 1] = { method = method, url = url,
    headers = type(decoded_headers) == "table" and decoded_headers or {}, body = body }
  return json.encode(responder(method, url, headers, body))
end
local function request_count() return #requests end

local function b64url(text)
  return (memory.base64_encode(text):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end
local function fixture_access(account_id)
  return b64url('{"alg":"none","typ":"JWT"}') .. "." ..
    b64url('{"https://api.openai.com/auth":{"chatgpt_account_id":"' .. account_id .. '"}}') .. ".sig"
end
local function now_ms() return math.floor(host.now() * 1000) end
local function write_store_at(path, fields)
  assert(host.write_file(path, json.encode(fields)), "the store fixture must be written")
end
local function read_store_at(path)
  local decoded, value = pcall(json.decode, host.read_file(path) or "")
  return decoded and value or nil
end
local function write_store(fields) write_store_at(store, fields) end
local function read_store() return read_store_at(store) end
local function credential(refresh, account_id, expires)
  return { version = 1, provider = "openai-codex", type = "oauth",
    access = fixture_access(account_id or "acct-old"), refresh = refresh,
    expires = expires or (now_ms() - 1000), account_id = account_id or "acct-old",
    refreshes = 0, source = "test" }
end
local function expired_store(refresh, account_id) write_store(credential(refresh, account_id)) end
local function token_grant(account_id, refresh, expires_in)
  return { status = 200, body = json.encode({ access_token = fixture_access(account_id),
    refresh_token = refresh, expires_in = expires_in or 3600 }) }
end

-- --- 1. absent: a state to explain, never a crash ------------------------------------------
do
  local token, failure = auth.token()
  ok(token == nil, "an absent store yields no token")
  equal(failure and failure.code, "subscription_credentials_absent", "absent is its own code")
  contains(failure and failure.message, "openai-sub-login.lua", "and it names the login to run")
  contains(failure and failure.message, store, "and the store it looked at")
  contains(tostring(failure), "subscription_credentials_absent", "and tostring reads as the code")
  equal(request_count(), 0, "an absent credential attempts no HTTP")
  local report = auth.status()
  equal(report.present, false, "status agrees the store is absent")
  equal(report.state, "absent", "status names the state")
  equal(report.store, store, "status names the store path")
  contains(report.login, "openai-sub-login.lua", "status names the login")
end

-- --- 2. the one-time import from Pi --------------------------------------------------------
do
  assert(host.write_file(overrides.WASM_AGENT_PI_AUTH, json.encode({ ["openai-codex"] = {
    type = "oauth", access = fixture_access("acct-pi"), refresh = "PI-REFRESH-0",
    expires = now_ms() + 3600000, accountId = "acct-pi" } })))
  local imported, import_failure = auth.import_from_pi()
  ok(imported ~= nil, "a Pi credential imports once", tostring(import_failure))
  equal(imported and imported.account_id, "acct-pi", "the imported account travels")
  local stored = read_store()
  equal(stored and stored.source, "import:pi", "the store records where it came from")
  equal(stored and stored.refresh, "PI-REFRESH-0", "and holds Pi's refresh token")
  local again, again_failure = auth.import_from_pi()
  ok(again == nil, "a second import is refused")
  equal(again_failure and again_failure.code, "import_already_present", "by its own code")
  -- Pi is read once and never again: overwriting the Pi file changes nothing for a token().
  assert(host.write_file(overrides.WASM_AGENT_PI_AUTH, "{}"))
  local token, failure = auth.token()
  ok(token ~= nil, "a token still comes out of our store with Pi's file emptied", tostring(failure))
  equal(token and token.account_id, "acct-pi", "from our own copy")
  equal(request_count(), 0, "and without any refresh while it is valid")
  ok(token and token.refresh == nil, "the seam never carries the refresh token")
end

-- --- 3. a refresh: one POST, the measured wire shape, and the rotated token -----------------
do
  expired_store("ROTATE-0")
  responder = function() return token_grant("acct-old", "ROTATE-1") end
  local before = request_count()
  local token, failure = auth.token()
  ok(token ~= nil, "an expired credential refreshes", tostring(failure))
  equal(request_count() - before, 1, "exactly one token POST")
  local request = requests[request_count()]
  equal(request.method, "POST", "the refresh is a POST")
  contains(request.url, "/oauth/token", "to the token endpoint")
  contains(request.headers["Content-Type"], "application/x-www-form-urlencoded", "form-encoded")
  contains(request.body, "grant_type=refresh_token", "with the refresh grant")
  contains(request.body, "client_id=app_EMoamEEZ73f0CkXaXp7hrann", "and the client id")
  contains(request.body, "refresh_token=ROTATE-0", "spending the token the store held")
  ok(not request.body:find("ROTATE-1", 1, true), "and never the token it did not have yet")
  equal(token.refreshed, true, "the caller is told this call refreshed")
  equal(token.adopted, false, "and did not merely adopt one")
  local stored = read_store()
  equal(stored.refresh, "ROTATE-1", "the store holds the *new* rotating token")
  equal(stored.refreshes, 1, "and counts the refresh")
  equal(stored.refresh_fingerprint, auth.fingerprint("ROTATE-1"), "recorded by fingerprint")
  equal(stored.previous_refresh_fingerprint, auth.fingerprint("ROTATE-0"), "and the one it replaced")
  equal(stored.account_id, "acct-old", "the account id comes from the access token's claim")
  ok(math.abs(stored.expires - (now_ms() + 3600000)) < 5000, "expires = now + expires_in*1000")
  local again = auth.token()
  ok(again ~= nil and again.refreshed == false, "a valid token needs no second POST")
  equal(request_count(), before + 1, "the count did not move")
  local report = auth.status()
  ok(not json.encode(report):find(stored.access, 1, true), "status never carries the access token")
  ok(not json.encode(report):find(stored.refresh, 1, true), "status never carries the refresh token")
end

-- --- 4. errors are a taxonomy, and a rejection is never retried ----------------------------
do
  expired_store("REJECT-0")
  responder = function() return { status = 401, body = json.encode({ error = "invalid_grant",
    detail = "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig refresh_token=REJECT-0" }) } end
  local before = request_count()
  local token, failure = auth.token()
  ok(token == nil, "a rejected refresh yields no token")
  equal(failure and failure.code, "refresh_rejected:401", "the status is part of the code")
  equal(failure and failure.status, 401, "and carried as a field")
  equal(request_count() - before, 1, "a rejection is not retried")
  contains(failure.message, "invalid_grant", "the provider's own error code is reported")
  ok(not failure.message:find("REJECT-0", 1, true), "the message cannot leak the refresh token")
  ok(not failure.message:find("eyJhbGci", 1, true), "nor a token quoted in the provider's body")
  -- The store's own access token is a JWT too, so this names the header the hostile body used.
  ok(not json.encode(read_store()):find("eyJhbGciOiJIUzI1NiJ9", 1, true),
    "and neither does the receipt the store keeps")
  local stored = read_store()
  equal(stored.refresh, "REJECT-0", "the credential is kept, not erased")
  equal(stored.last_error and stored.last_error.code, "refresh_rejected:401", "with the receipt on the store")
  equal(auth.status().last_error and auth.status().last_error.code, "refresh_rejected:401",
    "which status reports")

  responder = function() return { error = "connection refused" } end
  local _, unreachable = auth.token()
  equal(unreachable and unreachable.code, "unreachable", "a transport failure is not a rejection")

  responder = function() return { status = 200, body = json.encode({ access_token = "x" }) } end
  local _, incomplete = auth.token()
  equal(incomplete and incomplete.code, "invalid_response", "a 200 missing fields is refused, not patched")

  assert(host.write_file(store, "this is not json"))
  local _, corrupt = auth.token()
  equal(corrupt and corrupt.code, "store_corrupt", "an unparseable store is its own code")
  write_store({ version = 1 })
  local _, partial = auth.token()
  equal(partial and partial.code, "store_corrupt", "and so is one missing its fields")
end

-- --- 5. the lock ---------------------------------------------------------------------------
do
  expired_store("LOCK-0")
  responder = function() return token_grant("acct-old", "LOCK-1") end
  -- A live holder: another run in this same process holds the claim, and the host's own liveness
  -- rule refuses to reconcile it away.
  local foreign = "openai-sub:foreign-" .. tostring(host.uuid())
  local claimed = json.decode(host.resource("claim", json.encode({ principal = "openai-sub",
    session = "openai-sub", run = foreign, keys = { "openai-sub:credentials" } })))
  ok(claimed.ok == true, "the fixture holds the credential lock")
  equal(auth.lock_state().held, true, "and status can see it held")
  local before = request_count()
  local token, failure = auth.token()
  ok(token == nil, "a lock held by a live process is not taken over")
  equal(failure and failure.code, "locked", "it is reported as locked")
  equal(request_count(), before, "and no refresh is attempted while it is held")
  ok(json.decode(host.resource("finish", json.encode({ principal = "openai-sub",
    run = foreign }))).ok == true, "the fixture releases the lock")
  equal(auth.lock_state().held, false, "status agrees it is free")
  local after_release = auth.token()
  ok(after_release ~= nil and after_release.refreshed == true, "and then the refresh proceeds")

  -- No lock capability at all: refuse to spend the rotating token rather than risk a double-spend.
  expired_store("LOCK-2")
  local native_resource = host.resource
  host.resource = nil
  local before_nolock = request_count()
  local _, unavailable = auth.token()
  equal(unavailable and unavailable.code, "lock_unavailable", "no lock capability is its own code")
  equal(request_count(), before_nolock, "and refuses to refresh without one")
  host.resource = native_resource
end

-- --- 6. the login we own: device code ------------------------------------------------------
do
  local polls = 0
  responder = function(method, url)
    if url:find("/deviceauth/usercode", 1, true) then
      local body = json.decode(requests[request_count()].body)
      ok(body.client_id == "app_EMoamEEZ73f0CkXaXp7hrann", "the device request carries the client id")
      return { status = 200, body = json.encode({ device_auth_id = "DEVICE-1",
        user_code = "FIXTURE-CODE", interval = 0 }) }
    end
    if url:find("/deviceauth/token", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return { status = 403, body = json.encode({ error = "deviceauth_authorization_pending" }) }
      end
      if polls == 2 then
        return { status = 400, body = json.encode({ error = { code = "deviceauth_authorization_pending" } }) }
      end
      if polls == 3 then return { status = 400, body = json.encode({ error = "slow_down" }) } end
      return { status = 200, body = json.encode({ authorization_code = "CODE-A",
        code_verifier = "VERIFIER-A" }) }
    end
    return token_grant("acct-device", "DEVICE-REFRESH-1")
  end
  clear_printed()
  local result, failure = auth.login("device", { timeout_seconds = 30 })
  ok(result ~= nil, "the device login completes against the fixture", tostring(failure))
  equal(result and result.account_id, "acct-device", "the account comes from the access token")
  equal(result and result.source, "login:device", "and the store records the login that made it")
  equal(polls, 4, "two pending answers and one slow_down were polled through, not failed on")
  local text = printed_text()
  contains(text, "http://127.0.0.1:1/codex/device", "the human is given the verification URL")
  contains(text, "FIXTURE-CODE", "and the user code")
  contains(text, "slow down", "a slow_down answer is reported as backing off")
  local exchange = requests[request_count()]
  contains(exchange.body, "grant_type=authorization_code", "the code is exchanged, not refreshed")
  contains(exchange.body, "code=CODE-A", "with the authorization code")
  contains(exchange.body, "code_verifier=VERIFIER-A", "and the verifier the device flow returned")
  contains(exchange.body, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fdeviceauth%2Fcallback",
    "and the device redirect uri")
  equal(read_store().source, "login:device", "the credential is in our store afterwards")
  contains(host.read_file(auth.flow_path()), '"pending":false',
    "and the pending flow is retired, not left to be resumed by accident")

  -- A flow nobody finishes expires as its own code, keeps the pending flow, and can be resumed.
  responder = function(method, url)
    if url:find("/deviceauth/usercode", 1, true) then
      return { status = 200, body = json.encode({ device_auth_id = "DEVICE-2",
        user_code = "CODE-2", interval = 1 }) }
    end
    if url:find("/deviceauth/token", 1, true) then
      return { status = 403, body = json.encode({ error = "deviceauth_authorization_pending" }) }
    end
    return token_grant("acct-resume", "DEVICE-REFRESH-2")
  end
  write_store({ version = 1 })
  assert(host.write_file(auth.flow_path(), json.encode({ version = 1, pending = false })))
  clear_printed()
  local expired, expired_failure = auth.login("device", { timeout_seconds = 1 })
  ok(expired == nil, "an unfinished device flow does not claim success")
  equal(expired_failure and expired_failure.code, "flow_expired", "it expires as flow_expired")
  contains(expired_failure and expired_failure.message, "CODE-2", "naming the code the human was given")
  contains(printed_text(), "CODE-2", "which was printed before the wait")
  contains(host.read_file(auth.flow_path()), '"pending":true', "the pending flow survives for a resume")
  responder = function(method, url)
    if url:find("/deviceauth/token", 1, true) then
      return { status = 200, body = json.encode({ authorization_code = "CODE-R",
        code_verifier = "VERIFIER-R" }) }
    end
    return token_grant("acct-resumed", "DEVICE-REFRESH-3")
  end
  local resumed, resume_failure = auth.login("device", { timeout_seconds = 10 })
  ok(resumed ~= nil, "and resuming it completes the login", tostring(resume_failure))
  equal(resumed and resumed.account_id, "acct-resumed", "for the account the flow authorized")
end

-- --- 7. browser login (secondary) and PKCE --------------------------------------------------
do
  -- RFC 7636 appendix B: the published answer, so the encoder and the digest are pinned to
  -- something outside this repository rather than to each other.
  equal(auth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE S256 matches the RFC 7636 vector")
  local pkce = auth.pkce()
  equal(#pkce.verifier, 43, "a generated verifier is 43 characters, as Pi's is")
  equal(pkce.challenge, auth.challenge(pkce.verifier), "and its challenge is its own digest")

  write_store({ version = 1 })
  assert(host.write_file(auth.flow_path(), json.encode({ version = 1, pending = false })))
  clear_printed()
  local pending, pending_failure = auth.login("browser")
  ok(pending ~= nil and pending.pending == true, "the browser login starts and waits for the human",
    tostring(pending_failure))
  local url = pending and pending.url or ""
  contains(url, "/oauth/authorize?", "the authorize URL")
  contains(url, "response_type=code", "with the code response")
  contains(url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann", "our client id")
  contains(url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback", "the localhost callback")
  contains(url, "scope=openid%20profile%20email%20offline_access", "the offline scope")
  contains(url, "code_challenge_method=S256", "PKCE S256")
  contains(url, "id_token_add_organizations=true", "the organization claim request")
  contains(url, "codex_cli_simplified_flow=true", "the simplified flow")
  contains(url, "originator=wasm-agent", "and our own originator, not Pi's")
  local state = url:match("state=(%x+)")
  ok(state ~= nil and #state == 32, "a 32-hex-character state")
  local flow = json.decode(host.read_file(auth.flow_path()))
  equal(url:match("code_challenge=([^&]+)"), auth.challenge(flow.verifier),
    "the URL pins the verifier kept beside the store")
  contains(printed_text(), "/oauth/authorize?", "the URL reaches the human")
  -- The wrong state is refused before anything is exchanged.
  local _, mismatch = auth.login("browser",
    { callback = "http://localhost:1455/auth/callback?code=C&state=deadbeef" })
  equal(mismatch and mismatch.code, "flow_state_mismatch", "a callback from another flow is refused")
  responder = function() return token_grant("acct-browser", "BROWSER-REFRESH-1") end
  local done, done_failure = auth.login("browser",
    { callback = "http://localhost:1455/auth/callback?code=CODE-B&state=" .. tostring(state) })
  ok(done ~= nil, "the pasted callback completes the login", tostring(done_failure))
  equal(done and done.account_id, "acct-browser", "for the pasted flow's account")
  equal(read_store().source, "login:browser", "recorded as a browser login")
  contains(requests[request_count()].body, "code=CODE-B", "the pasted code is what is exchanged")
end

-- --- 8. two processes, one token POST ------------------------------------------------------
-- The property this lane exists for, measured from outside our own code: the fixture counts the
-- POSTs, and it refuses a token it has already spent - so a double-spend would appear as the
-- server's own `invalid_grant` rather than as a count our own process could have got wrong.
do
  host.http = native_http -- the children do their own HTTP; this process is done with the stub.

  local function lua_root()
    local root = native_getenv("WASM_AGENT_LUA_ROOT")
    if root and root ~= "" then return (root:gsub("\\", "/"):gsub("/+$", "")) end
    return nil
  end
  local function find_binary()
    local candidates = {}
    local explicit = native_getenv("WASM_AGENT_BIN")
    if explicit and explicit ~= "" then candidates[#candidates + 1] = explicit end
    -- `ipairs` stops at the first nil, so an absent root must not be *placed* in the list: the
    -- literal `{ lua_root(), cwd }` is an empty list whenever WASM_AGENT_LUA_ROOT is unset - which
    -- is how the gate runs it - and then this file reports that it cannot find the binary it is
    -- supposed to have just built. The root is appended only when there is one.
    local roots = {}
    local explicit_root = lua_root()
    if explicit_root then roots[#roots + 1] = explicit_root end
    roots[#roots + 1] = (platform.cwd() or ""):gsub("\\", "/"):gsub("/+$", "")
    for _, root in ipairs(roots) do
      if root and root ~= "" then
        candidates[#candidates + 1] = root .. "/rust/target/release/wa"
        candidates[#candidates + 1] = root .. "/rust/target/release/wa.exe"
      end
    end
    for _, path in ipairs(candidates) do
      if host.canonical_path(path) then return path end
    end
    return nil
  end
  local function finish()
    print = native_print
    if failures > 0 then
      error("openai-sub auth: " .. tostring(failures) .. " of " .. tostring(checks) .. " checks failed")
    end
    print("openai-sub auth ok (" .. tostring(checks) .. " checks)")
  end

  local binary = find_binary()
  -- Not a skip: the gate builds this binary before any Lua test runs, so a missing one means this
  -- file cannot prove what it exists for.
  if not ok(binary ~= nil, "the test binary is findable",
      "looked under WASM_AGENT_BIN, WASM_AGENT_LUA_ROOT and the working directory") then
    return finish()
  end
  local root = lua_root() or (platform.cwd() or "."):gsub("\\", "/"):gsub("/+$", "")
  local mock_script = root .. "/scripts/lib/openai-sub-auth-mock.mjs"
  local worker_script = root .. "/scripts/openai-sub-auth-worker.lua"
  local mock_dir = dir .. "/mock"
  local concurrent_store = dir .. "/concurrent.json"
  local seed_refresh = "SEED-" .. tostring(host.uuid()):sub(1, 8)
  write_store_at(mock_dir .. "/seed.json", seed_refresh)
  write_store_at(concurrent_store, credential(seed_refresh, "acct-concurrent"))

  local launch = json.decode(host.operation("start", json.encode({ program = "node",
    args = { mock_script, "--dir", mock_dir, "--delay-ms", "2500" }, timeout_seconds = 180 })))
  local mock_id = launch.operation_id
  if not ok(mock_id ~= nil, "the fixture auth host starts", json.encode(launch)) then return finish() end
  local port, waited = nil, 0
  while port == nil and waited < 30000 do
    local page = json.decode(host.operation("read", json.encode({ id = mock_id, stream = "stdout",
      offset = 0, limit = 4096 })))
    port = tostring(page.content or ""):match("ready%s+(%d+)")
    if not port then host.sleep(100); waited = waited + 100 end
  end
  if not ok(port ~= nil, "the fixture auth host reports its port",
      "no 'ready <port>' line within 30s") then
    json.decode(host.operation("cancel", json.encode({ id = mock_id })))
    return finish()
  end
  local base = "http://127.0.0.1:" .. tostring(port)

  local function quote(value) return "'" .. tostring(value) .. "'" end
  local function start_worker(index, store_path)
    local command = table.concat({
      "WASM_AGENT_OPENAI_SUB_STORE=" .. quote(store_path),
      "WASM_AGENT_OPENAI_SUB_AUTH_BASE=" .. quote(base),
      "WASM_AGENT_OPENAI_SUB_LOCK_WAIT_MS=20000",
      "WA_SCRIPT=" .. quote(worker_script),
      quote(binary), "--db", quote(dir .. "/worker" .. tostring(index) .. ".db"), "&",
    }, " ")
    local receipt = json.decode(host.exec(command, platform.cwd(), 120))
    return receipt.operation_id
  end
  local function settle(id, deadline_ms)
    local waited_ms = 0
    while waited_ms < deadline_ms do
      local state = json.decode(host.operation("status", json.encode({ id = id })))
      if state.state == "completed" or state.state == "failed" or state.state == "cancelled" then
        if not state.stdout then
          state.stdout = json.decode(host.operation("read", json.encode({ id = id,
            stream = "stdout", offset = 0, limit = 4096 }))).content
        end
        return state
      end
      host.sleep(200)
      waited_ms = waited_ms + 200
    end
    return { state = "timeout" }
  end
  local function worker_line(state)
    return tostring(state.stdout or ""):match("WA%-AUTH%-WORKER ([^\r\n]*)")
  end
  local function token_posts()
    local text = host.read_file(mock_dir .. "/posts.jsonl") or ""
    local count, refreshes, fingerprints = 0, 0, {}
    for line in text:gmatch("[^\r\n]+") do
      local record = json.decode(line)
      if record.path == "/oauth/token" then
        count = count + 1
        if record.grant_type == "refresh_token" then
          refreshes = refreshes + 1
          fingerprints[#fingerprints + 1] = record.refresh_fingerprint
        end
      end
    end
    return count, refreshes, fingerprints
  end

  local first_id = start_worker(1, concurrent_store)
  ok(first_id ~= nil, "the first caller starts")
  host.sleep(400)
  local second_id = start_worker(2, concurrent_store)
  ok(second_id ~= nil, "the second caller starts while the first is inside its refresh")
  local first = settle(first_id, 120000)
  local second = settle(second_id, 120000)
  local first_line, second_line = tostring(worker_line(first)), tostring(worker_line(second))

  local token_count, refresh_count, spent = token_posts()
  equal(token_count, 1, "two concurrent callers issue one token POST (the fixture's own count)")
  equal(refresh_count, 1, "and it is one refresh, not an exchange")
  equal(spent[1], auth.fingerprint(seed_refresh), "spending the token the store held")
  ok(first_line:find("^ok", 1) ~= nil, "the first caller succeeded",
    first_line .. " (" .. tostring(first.state) .. ")")
  ok(second_line:find("^ok", 1) ~= nil, "the second caller succeeded",
    second_line .. " (" .. tostring(second.state) .. ")")
  local refreshed = (first_line:find("refreshed=true", 1, true) and 1 or 0)
    + (second_line:find("refreshed=true", 1, true) and 1 or 0)
  local adopted = (first_line:find("adopted=true", 1, true) and 1 or 0)
    + (second_line:find("adopted=true", 1, true) and 1 or 0)
  equal(refreshed, 1, "exactly one caller performed the refresh")
  equal(adopted, 1, "and the other adopted it from the store under the lock")
  local first_fp = first_line:match("access_fp=(%x+)")
  local second_fp = second_line:match("access_fp=(%x+)")
  ok(first_fp ~= nil and first_fp == second_fp, "both callers were served the same access token",
    tostring(first_fp) .. " vs " .. tostring(second_fp))
  ok(not tostring(first.stdout):find("eyJ", 1, true)
     and not tostring(first.stdout):find("refresh_token", 1, true),
    "no credential shape on a caller's stdout")

  -- Rotation across processes: the store now holds the token the fixture issued, by fingerprint.
  local issued = json.decode((host.read_file(mock_dir .. "/issued.jsonl") or ""):match("([^\r\n]+)"))
  local stored = read_store_at(concurrent_store)
  equal(issued and issued.refresh_fingerprint, stored and stored.refresh_fingerprint,
    "the store holds the fixture's newest rotating token")
  ok(stored and stored.refresh_fingerprint ~= auth.fingerprint(seed_refresh),
    "which is not the one it started with")
  equal(stored and stored.refreshes, 1, "one refresh recorded")
  equal(auth.lock_state().held, false, "the lock is released when the callers finish")

  -- The provider's own answer to a double-spend, provoked on purpose: a *fresh* credential holding
  -- the token that was already spent. The fixture refuses it exactly as the provider does.
  local stale_store = dir .. "/stale.json"
  write_store_at(stale_store, credential(seed_refresh, "acct-stale"))
  local stale = settle(start_worker(3, stale_store), 120000)
  local stale_line = tostring(worker_line(stale))
  contains(stale_line, "error code=refresh_rejected:400",
    "a spent token is refused as refresh_rejected:400")
  local after = token_posts()
  equal(after, 2, "and that refusal was its own POST, not a retry of the first")

  -- The numbers themselves, on the real stdout: the gate log is where this lane's claim about
  -- single-flight has to be checkable without reading the test.
  native_print(string.format("openai-sub concurrency evidence: token POSTs=%d, refreshed=%d, " ..
    "adopted=%d, rotation %s -> %s, second spend of the same token=%s", token_count, refreshed,
    adopted, tostring(auth.fingerprint(seed_refresh)),
    tostring(stored and stored.refresh_fingerprint), tostring(stale_line:match("code=([^%s]+)"))))

  json.decode(host.operation("cancel", json.encode({ id = mock_id })))
  return finish()
end
