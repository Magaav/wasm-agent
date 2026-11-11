-- `wa-whatsapp` is pinned in components.lock, so EVERY node's deploy installs it. That is only safe
-- while installing it does nothing: no service definition, no instance, no WhatsApp connection.
--
-- Two facts are asserted here, and they are different facts:
--   1. the lock pins it (so a deploy will install it everywhere), with a well-formed pin;
--   2. a node that holds the bytes but has not ENABLED a definition starts nothing, asks the
--      supervisor for nothing, and touches no socket.
--
-- Hermetic: a scratch WASM_AGENT_HOME and the runner's own --db, a stubbed `host.service` that records
-- what it was asked, HTTP stubbed to fail. No node, no network, no account.
--   WASM_AGENT_LUA_ROOT=<checkout> WA_SCRIPT=scripts/test-whatsapp-inert.lua wa --db /tmp/x.db
local json = dofile('lua/vendor/json.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('WHATSAPP INERT CHECK FAILED: ' .. label) end
end

-- 1. The pin. A name is shipped by being pinned here and nothing else decides it, so the test reads
--    the same file the deploy reads.
local lock = host.read_file and host.read_file('components.lock')
check(type(lock) == 'string' and lock ~= '', 'components.lock is readable')
local pin_sha, pin_bytes
for line in lock:gmatch('[^\n]+') do
  local name, sha, bytes = line:match('^%s*([%w%-%.]+)%s+(%x+)%s+(%d+)%s*$')
  if name == 'wa-whatsapp' then pin_sha, pin_bytes = sha, tonumber(bytes) end
end
check(pin_sha ~= nil, 'wa-whatsapp is pinned in components.lock')
check(#pin_sha == 64, 'the pin is a sha256, got ' .. tostring(#pin_sha) .. ' hex chars')
check(pin_bytes ~= nil and pin_bytes > 1024 * 1024, 'the pin names a real artifact size, got ' .. tostring(pin_bytes))

-- 2. The store. `services.lua` keeps definitions in the `meta` table under `services.v1`; the deploy
--    writes no row at all, which is the whole reason a pinned component stays inert.
local services = dofile('lua/core/services.lua')

local function sql(statement, params)
  local answer = host.sql_exec(statement, json.encode(params or {}))
  return answer
end

-- What a deploy leaves behind: the bytes on disk and NO definition. Prove that state first.
local began = sql('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)')
check(began ~= nil, 'the meta table is available')
local absent = services.autostart()
check(absent and absent.ok, 'autostart succeeds with no definitions')
check(type(absent.started) == 'table' and next(absent.started) == nil,
  'autostart starts nothing when the component is merely installed')

-- 3. Now the definition an operator would create for pairing, left DISABLED - the state between
--    "installed" and "enabled". It must be visible in inventory and still inert.
local calls = {}
local native_service = host.service
host.service = function(request)
  local decoded = json.decode(request) or {}
  calls[#calls + 1] = tostring(decoded.action)
  if decoded.action == 'status' then return '[]' end
  -- Anything that would run the component is a failure of this test, not an answer to inspect.
  error('the supervisor was asked to ' .. tostring(decoded.action) .. ' an un-enabled component')
end
local http_calls = 0
local native_http, native_http_stream = host.http, host.http_stream
host.http = function() http_calls = http_calls + 1; error('a socket was opened') end
host.http_stream = host.http

local seed = json.encode({ schema = 1, revision = 0, services = {
  ['wa-whatsapp'] = { definition = { name = 'wa-whatsapp' }, enabled = false },
} })
sql('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', { 'services.v1', seed })

local inert = services.autostart()
check(inert and inert.ok, 'autostart succeeds with a disabled definition')
check(type(inert.started) == 'table' and next(inert.started) == nil,
  'a disabled definition is not started')
local started_anything = false
for _, action in ipairs(calls) do
  if action ~= 'status' then started_anything = true end
end
check(not started_anything, 'the supervisor was never asked to start or supervise')
check(http_calls == 0, 'no socket was opened')
check(#calls == 0, 'autostart returned before it consulted the supervisor at all')

-- The definition is still there, and it is visibly off - "installed but not enabled" is an observable
-- state, not an absence the operator has to infer.
local inventory = services.inventory()
check(inventory and inventory.ok, 'inventory is readable')
local row
for _, entry in ipairs(inventory.services) do
  if entry.name == 'wa-whatsapp' then row = entry end
end
check(row ~= nil, 'the definition is listed')
check(row.enabled == false, 'the definition is listed as disabled')
check(row.live and row.live.state == 'not_running', 'the definition is not running')
check(http_calls == 0, 'reading the registry opened no socket either')

host.service, host.http, host.http_stream = native_service, native_http, native_http_stream
print('whatsapp inert: ' .. checks .. ' checks passed')
