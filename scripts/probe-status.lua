local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'probe', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local started = tools.dispatch(memory, 'operation', { action = 'start', command = 'sleep 3' }, 'master', ctx)
print('start keys: ' .. json.encode(started):sub(1, 300))
local t0 = host.monotonic_ms and host.monotonic_ms() or os.time() * 1000
local answer = tools.dispatch(memory, 'operation', { action = 'status', id = started.operation_id, wait_ms = 4000 }, 'master', ctx)
local ms = (host.monotonic_ms and host.monotonic_ms() or os.time() * 1000) - t0
print('status ms=' .. ms .. ' answer=' .. json.encode(answer):sub(1, 400))
local src = ''
local f = io.open('lua/core/tools.lua', 'r')
if f then src = f:read('*a') or ''; f:close() end
print('tree tools.lua has the wait branch: ' .. tostring(src:find('WA_OPERATION_STATUS_WAIT_MS') ~= nil))
