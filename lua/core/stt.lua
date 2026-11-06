-- The speech queue's node role (docs/QUEUE.md "Phase 2", docs/WHATSAPP-TRANSCRIPTION.md
-- "Remote workers"): a producing node enqueues `stt.requests` and falls back to its own warm
-- recognizer, and a node whose role is `stt_worker` long-polls that queue over the signed relay.
--
-- This file owns only the *node's* decisions, and even those are few: which role the environment
-- asks for, which node is the producer, and the pump that lets the worker thread make a signed call
-- (the signature is Lua's - `nodes.lua` holds the key; the freshness rule, the lease cadence, the
-- segment stream and the settle are `rust/wa-stt-remote`'s `RemoteWorker`/`Decoder`, so they are the
-- same code the two-node simulation proves).
--
-- Configuration, one file and the environment (environment wins):
--
--   ~/.wasm-agent/node.stt      producer | worker | both | off   (an optional second line: producer)
--   WASM_AGENT_STT_ROLE         producer (default) | worker | stt_worker | both | off
--   WASM_AGENT_STT_PRODUCER     the producer's node name or id, on a worker node
--   WASM_AGENT_STT_LEASE_MS     default 60000, the lease every worker takes and extends
--   WASM_AGENT_STT_HEARTBEAT_MS default 15000, how often a streaming worker extends it
--   WASM_AGENT_STT_GRACE_MS     default 3000, how long the local worker holds back for a remote
--   WASM_AGENT_STT_FRESH_MS     default 300000, the freshness window (`WA_WHATSAPP_FRESH_SECONDS`)
--   WASM_AGENT_STT_LATENCY_TTL_MS default 600000, how long a decode measurement is evidence
--
-- Nothing here logs audio or text: the pump forwards envelopes, and the answers it forwards are the
-- library's fixed refusals (`{"refused":"lease_lost"}`), never a payload.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local nodes = dofile('lua/core/nodes.lua')
local M = {}

local PUMP_MAX = 8          -- relay calls per tick, so one pump cannot hold the node thread for long
local CONFIGURE_EVERY = 30  -- seconds between peer-list refreshes (Admission needs the current ids)

local state = { configured = false, at = 0, signature = '', pumping = false, last_error = nil, last_failure = nil }

local function env_number(name, fallback)
  local raw = tonumber(host.getenv(name))
  if not raw or raw <= 0 then return fallback end
  return math.floor(raw)
end

-- `producer`, `worker`/`stt_worker`, `both`, `off`. The environment wins over the file, and an
-- unreadable value is the default (`producer`), never "off": a typo must not silently stop a node
-- from transcribing - the same rule `nodes.role` keeps.
function M.role()
  local raw = tostring(host.getenv('WASM_AGENT_STT_ROLE') or ''):lower():gsub('%s+', '')
  if raw == '' then
    local file = host.read_file(paths.config() .. '/node.stt')
    if type(file) == 'string' then raw = file:lower():match('^[^\r\n]*') or '' end
    raw = tostring(raw):gsub('%s+', '')
  end
  if raw == 'off' or raw == 'none' or raw == 'disabled' then return 'off' end
  if raw == 'worker' or raw == 'stt_worker' or raw == 'sttworker' then return 'worker' end
  if raw == 'both' then return 'both' end
  return 'producer'
end

function M.produce() local role = M.role(); return role == 'producer' or role == 'both' end
function M.work() local role = M.role(); return role == 'worker' or role == 'both' end

-- The producer's selector: the environment, else a second line in `node.stt`, else nothing (a worker
-- with no producer named is idle and says so, rather than guessing a peer).
function M.producer_selector()
  local named = host.getenv('WASM_AGENT_STT_PRODUCER')
  if type(named) == 'string' and named ~= '' then return named end
  local file = host.read_file(paths.config() .. '/node.stt')
  if type(file) == 'string' then
    local _, rest = file:match('^[^\r\n]*[\r\n]+([^\r\n]*)')
    rest = tostring(rest or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if rest ~= '' then return rest end
  end
  return ''
end

-- The owner's own node ids: this node plus everything the rendezvous lists. That is the set a
-- producing node admits (`Admission`), and the same set the operator sees in `nodes`. A rendezvous
-- that cannot be reached answers only this node, so the queue stays closed to strangers.
local function owners()
  -- Fresh from the rendezvous, never the 15 s display cache: a worker that joined a moment ago must
  -- be admittable now, and a node removed there must stop being one at once.
  nodes.invalidate()
  local ids = {}
  local seen = {}
  for _, node in ipairs(nodes.list()) do
    local id = node.node_id or node.id
    if type(id) == 'string' and id ~= '' and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function call_admin(request)
  if type(host.stt_admin) ~= 'function' then return { error = 'stt_unavailable' } end
  local ok, raw = pcall(host.stt_admin, json.encode(request))
  if not ok then return { error = 'stt_admin_failed' } end
  local decoded = pcall(json.decode, raw)
  return decoded and json.decode(raw) or { error = 'stt_answer_unreadable' }
end

local function request_of()
  return {
    action = 'configure',
    me = (nodes.identity() or {}).node_id or '',
    owner_nodes = owners(),
    producer = M.produce(),
    worker = M.work(),
    producer_name = M.producer_selector(),
    producer_id = '',
    lease_ms = env_number('WASM_AGENT_STT_LEASE_MS', 60000),
    heartbeat_every_ms = env_number('WASM_AGENT_STT_HEARTBEAT_MS', 15000),
    fallback_after_ms = env_number('WASM_AGENT_STT_GRACE_MS', 3000),
    fresh_ms = env_number('WASM_AGENT_STT_FRESH_MS', 300000),
    sample_ttl_ms = env_number('WASM_AGENT_STT_LATENCY_TTL_MS', 600000),
    wait_ms = 0,
  }
end

-- Read the role and hand it to the node (which starts the producer/worker threads). Returns the
-- node's answer, or `{error=...}` when the binary has no speech queue (an older node: nothing is
-- started, and `service_stt` keeps its direct path).
function M.configure(reason)
  if type(host.stt_admin) ~= 'function' then return { error = 'stt_unavailable' } end
  local request = request_of()
  if request.worker and request.producer_name ~= '' then
    local node = nodes.find(request.producer_name)
    if node and node.node_id then request.producer_id = node.node_id end
  end
  local signature = table.concat({ request.me, request.producer and 'p' or '-', request.worker and 'w' or '-',
    request.producer_id, tostring(#request.owner_nodes) }, '|')
  local answer = call_admin(request)
  if answer and answer.ok then
    state.configured = true
    state.signature = signature
    state.at = host.now()
    state.last_error = nil
    state.refused_unknown = (call_admin({ action = 'counters' }).ok or {}).refused_unknown or 0
    state.producer_id = (answer.producer_id and answer.producer_id ~= '') and answer.producer_id or ''
    state.producer_at = host.now()
  else
    state.last_error = (answer and (answer.error or answer.refused)) or 'stt_configure_failed'
  end
  if type(host.log) == 'function' then
    host.log('[stt] role=' .. M.role() .. ' producer=' .. tostring(answer and answer.producer) ..
      ' worker=' .. tostring(answer and answer.worker) .. ' owners=' .. tostring(#request.owner_nodes) ..
      ' source=' .. tostring(request.producer_name) .. '->' .. tostring(request.producer_id) ..
      (reason and (' (' .. reason .. ')') or ''))
  end
  return answer
end

-- Pump one pending call: the worker thread built a `stt.requests` envelope and is waiting for the
-- answer. Lua signs with this node's key and calls the producer; the answer goes back to the thread,
-- which returns the next call, so one tick drains a whole settle sequence.
-- Every `host.stt_*` answers a JSON *string* (the host's one answer shape), so a pump step is a
-- decode: `null` is the "nothing pending" answer, not a table.
local function answer_of(raw)
  if type(raw) ~= 'string' then return nil end
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == 'table' then return value end
  return nil
end

local function pump()
  if type(host.stt_pending) ~= 'function' or type(host.stt_deliver) ~= 'function' then return 0 end
  if state.pumping then return 0 end
  state.pumping = true
  local calls = 0
  local pending = answer_of(host.stt_pending())
  while pending and calls < PUMP_MAX do
    calls = calls + 1
    local answer
    local selector = M.producer_selector()
    local node = selector ~= '' and nodes.find(selector) or nil
    if selector ~= '' and not node then
      nodes.invalidate()
      node = nodes.find(selector)
    end
    if not node then
      answer = { error = 'stt_producer_unknown' }
    else
      -- `remote_call` resolves the selector, builds and signs the outer call
      -- (`call|node|ts|sha256(body)`) and returns the producer's answer: our handler's `{ok:...}`
      -- or `{refused:...}`. A selector the fabric does not list answers `unknown_node:...`, which
      -- the worker thread reports as an unreachable producer (a lease it never took).
      local reply = nodes.remote_call(selector, 'stt', json.decode(pending.envelope) or {})
      answer = reply or { error = 'stt_no_answer' }
    end
    pending = answer_of(host.stt_deliver(pending.id, json.encode(answer)))
  end
  state.pumping = false
  return calls
end

-- Does the node's role need the peer list to have moved? `configure` rebuilds `Admission`, so a
-- worker that joined since the last configure must be learned before it can take a job.
local function refresh_due()
  return (host.now() - (state.at or 0)) >= CONFIGURE_EVERY
end

-- One tick from the node's housekeeping loop (`wa_stt_tick` in `server.lua`). Cheap when idle: no
-- rendezvous call, no relay call, nothing but two host calls that answer `nil`.
function M.tick()
  if M.role() == 'off' then return end
  if not state.configured then
    M.configure('boot')
  elseif refresh_due() then
    M.configure('refresh')
  end
  -- A worker that booted before its producer registered has no producer id yet; retry a couple of
  -- times a second until it does, rather than idling for the 30 s refresh.
  if M.work() and state.producer_id == '' and (host.now() - (state.producer_at or 0)) >= 2 then
    M.configure('producer-unknown')
  end
  if M.work() then pump() end
  -- A peer refused as `unknown_caller` is a worker that joined after this node last read the fabric.
  -- Refresh now instead of waiting for the 30 s cadence: the worker is already polling, and every
  -- refused call is a job it could have taken.
  local counters = call_admin({ action = 'counters' })
  local refused = counters and counters.ok and counters.ok.refused_unknown
  if refused and refused > (state.refused_unknown or 0) then
    state.refused_unknown = refused
    M.configure('unknown-caller')
  end
end

-- The operator view (`services` action `stt`): the node's own answer plus the role and the knobs
-- this file resolved, so "which workers are attached, how fast, and who decoded" is one table.
function M.view()
  local answer = call_admin({ action = 'status' })
  answer = answer or { error = 'stt_unavailable' }
  answer.role = M.role()
  answer.producer_selector = M.producer_selector()
  answer.knobs = {
    lease_ms = env_number('WASM_AGENT_STT_LEASE_MS', 60000),
    heartbeat_every_ms = env_number('WASM_AGENT_STT_HEARTBEAT_MS', 15000),
    grace_ms = env_number('WASM_AGENT_STT_GRACE_MS', 3000),
    fresh_ms = env_number('WASM_AGENT_STT_FRESH_MS', 300000),
  }
  answer.configured = state.configured
  answer.last_error = state.last_error or state.last_failure
  return answer
end

-- Submit one note (the operator/test entry; the component reaches the same queue through
-- `wa:kernel/speech`). `sent_at_ms` is what makes freshness mean "the conversation was live":
-- without it the window starts now, as the kernel call's does.
function M.submit(request)
  if type(host.stt_submit) ~= 'function' then return { error = 'stt_unavailable' } end
  local ok, raw = pcall(host.stt_submit, json.encode(request or {}))
  if not ok then return { error = 'stt_submit_failed' } end
  local decoded = pcall(json.decode, raw)
  return decoded and json.decode(raw) or { error = 'stt_answer_unreadable' }
end

-- The tick the node's housekeeping loop calls, guarded: a failing relay round must not take the
-- node thread down, and it must not log the same line every second either. The operator view shows
-- the last failure (`M.view().last_error`).
function M.safe_tick()
  local ok, problem = pcall(M.tick)
  if not ok then
    local word = tostring(problem)
    if state.last_failure ~= word then
      state.last_failure = word
      if type(host.log) == 'function' then host.log('[stt] tick failed: ' .. word) end
    end
  end
end

-- One job's state, ids and counts only (never its text): what an operator asks after "where did that
-- voice note go?".
function M.job(id)
  return call_admin({ action = 'job', job = tonumber(id) or 0 })
end

function M.sweep()
  return call_admin({ action = 'sweep' })
end

return M
