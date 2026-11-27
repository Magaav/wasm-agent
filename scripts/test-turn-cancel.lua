-- STOPPING A TURN A SERVED NODE OWNS (mission turn-survives-a-provider-stall, item 3 / C2b).
--
-- `host.run_cancelled` is process-local (host.rs:593) and `scheduler.cancel_run` is in-process memory
-- (scheduler.rs:376), so a terminal cannot stop a run another process owns by flipping a flag. The door is
-- the node's own route - `POST /runs` with an `action` body (serve.rs:2931 / :2453), authenticated with
-- `X-WA-Session` (the credential the window already sends, ui/app.js:230-233) - on the node's documented
-- port (`WASM_AGENT_PORT`, 8799 by default, docs/INSTANCES.md:18). Literal loopback only.
--
-- What is pinned here: the URL (the port from the environment, and the documented default when it is
-- absent), the method, the session header, the action body with the run id, an answer that is not JSON
-- named rather than guessed, and an unreachable node refused by name. The HTTP call is replaced in this
-- row: what crosses the wire is what is asserted, and no node is started.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local turn_tail = dofile('lua/core/turn_tail.lua')
local json = dofile('lua/vendor/json.lua')

local native_getenv = host.getenv
local env = {}
host.getenv = function(key) if env[key] ~= nil then return env[key] end return native_getenv(key) end

local failed, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then return end
  failed = failed + 1
  print('FAIL ' .. label)
end

local seen = nil
host.http = function(method, url, headers, body)
  seen = { method = method, url = url, headers = headers, body = body }
  return json.encode({ ok = true, cancel_requested = true, run_id = 7, state = 'running' })
end

-- ---- the documented default port ---------------------------------------------------------
check(turn_tail.cancel_url() == 'http://127.0.0.1:8799/runs', 'no port named: the documented 8799: ' .. turn_tail.cancel_url())
check(turn_tail.cancel_url('9123') == 'http://127.0.0.1:9123/runs', 'a node on its own port passes it in: ' .. turn_tail.cancel_url('9123'))
check(turn_tail.cancel_url(9500) == 'http://127.0.0.1:9500/runs', 'and a number too')

-- ---- the request the node receives -------------------------------------------------------
seen = nil
local answer = turn_tail.cancel('session-abc', 7, { owner = 'master', port = 9123 })
check(seen ~= nil, 'one request was made')
check(seen and seen.method == 'POST', 'by POST')
check(seen and seen.url == 'http://127.0.0.1:9123/runs', 'to /runs on the node port')
check(seen and type(seen.headers) == 'table' and seen.headers['X-WA-Session'] == 'session-abc',
  'carrying the session credential')
local body = seen and json.decode(seen.body) or {}
check(body.action == 'cancel', 'the body asks to cancel')
check(tonumber(body.run_id) == 7, 'naming the run (' .. tostring(body.run_id) .. ')')
check(body.conversation == 'session-abc', 'and the conversation')
check(type(answer) == 'table' and answer.ok == true and answer.cancel_requested == true,
  'the answer is the node\'s, not a guess')

-- ---- refusals are named ------------------------------------------------------------------
host.http = function() error('connection refused') end
local down = turn_tail.cancel('session-abc', 7, {})
check(type(down) == 'table' and down.ok == false and down.error == 'cancel_unreachable',
  'an unreachable node is refused by name: ' .. tostring(down and down.error))
host.http = function() return 'not json' end
local odd = turn_tail.cancel('session-abc', 7, {})
check(type(odd) == 'table' and odd.ok == false and odd.error == 'cancel_answer_unreadable',
  'and an unreadable answer too: ' .. tostring(odd and odd.error))

host.getenv = native_getenv
print(string.format('ok turn-cancel: %d checks, %d failed', checks, failed))
if failed > 0 then error('turn-cancel failed') end

