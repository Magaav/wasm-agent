-- The speech queue's node role (docs/QUEUE.md "Phase 2", docs/WHATSAPP-TRANSCRIPTION.md
-- "Remote workers"): a producing node enqueues `stt.requests` and falls back to its own warm
-- recognizer, and a node whose role is `stt_worker` long-polls that queue over the signed relay.
--
-- This file owns only the *node's* decisions, and even those are few: which role the environment or
-- the node's own persisted setting asks for, which node is the producer, and the pump that lets the
-- worker thread make a signed call (the signature is Lua's - `nodes.lua` holds the key; the freshness
-- rule, the lease cadence, the segment stream and the settle are `rust/wa-stt-remote`'s
-- `RemoteWorker`/`Decoder`, so they are the same code the two-node simulation proves).
--
-- Configuration, highest precedence first:
--
--   WASM_AGENT_STT_ROLE         producer (default) | worker | stt_worker | both | off
--   the node setting `stt.role`  the same words, in the ledger's `meta` table   <- `wa stt role`
--   ~/.wasm-agent/node.stt      the same words, first line (legacy file, still read)
--
--   WASM_AGENT_STT_PRODUCER     the producer's node name or id, on a worker node
--   the node setting `stt.producer`   the same, written by `wa stt role ... --producer <node>`
--   ~/.wasm-agent/node.stt      second line (legacy)
--
--   WASM_AGENT_STT_LEASE_MS     default 60000, the lease every worker takes and extends
--   WASM_AGENT_STT_HEARTBEAT_MS default 15000, how often a streaming worker extends it
--   WASM_AGENT_STT_GRACE_MS     default 3000, how long the local worker holds back for a remote
--   WASM_AGENT_STT_FRESH_MS     default 300000, the freshness window (`WA_WHATSAPP_FRESH_SECONDS`)
--   WASM_AGENT_STT_LATENCY_TTL_MS default 600000, how long a decode measurement is evidence
--
-- The environment keeps winning on purpose: it is the operator's emergency and test override, and a
-- file it can be overridden by would be a setting nobody can force. The persisted setting is the one
-- a *running* node can change: `tick` (once a second) notices it and re-configures the node, so the
-- role moves without a restart. A change never interrupts a job: switching to `off`/`producer` stops
-- *polling* and the call already in flight is answered and settled, so the producer is never left
-- holding a lease that this node walked away from (that is the duplicate decode).
--
-- Nothing here logs audio or text: the pump forwards envelopes, and the answers it forwards are the
-- library's fixed refusals (`{"refused":"lease_lost"}`), never a payload.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local nodes = dofile('lua/core/nodes.lua')
local M = {}

local PUMP_MAX = 8          -- relay calls per tick, so one pump cannot hold the node thread for long
local CONFIGURE_EVERY = 30  -- seconds between peer-list refreshes (Admission needs the current ids)

local state = { configured = false, at = 0, wanted = nil, pumping = false, worked = false,
  last_error = nil, last_failure = nil }

local function env_number(name, fallback)
  local raw = tonumber(host.getenv(name))
  if not raw or raw <= 0 then return fallback end
  return math.floor(raw)
end

-- ---- the role, and where it came from ------------------------------------------------------------

-- The persisted setting: the node's own `meta` row, so a role change is one primary-key read on the
-- next housekeeping tick and survives a restart. Read at most once a second (the tick cadence) and
-- invalidated on write: several callers ask for the role inside one tick, and none of them should be
-- a second database round trip. An unreadable store answers `nil`, never a word: a database this
-- node cannot read must not be able to say "off".
local SETTING_TTL = 1
local cache = { at = nil, role = nil, producer = nil }

local function meta_get(key)
  if type(host.sql_query) ~= 'function' then return nil end
  local ok, raw = pcall(host.sql_query, 'SELECT value FROM meta WHERE key=?', json.encode({ key }))
  if not ok or type(raw) ~= 'string' then return nil end
  local decoded, rows = pcall(json.decode, raw)
  if not decoded or type(rows) ~= 'table' or type(rows[1]) ~= 'table' then return nil end
  local value = rows[1].value
  if type(value) ~= 'string' then return nil end
  return value
end

local function meta_set(key, value)
  if type(host.sql_exec) ~= 'function' then return false, 'stt_setting_store_unavailable' end
  local ok, raw = pcall(host.sql_exec,
    'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    json.encode({ key, value }))
  if not ok then return false, 'stt_setting_store_write_failed' end
  local decoded, answer = pcall(json.decode, tostring(raw or ''))
  if not decoded or type(answer) ~= 'table' or answer.error then return false, 'stt_setting_store_write_unverified' end
  return true
end

local function settings()
  local now = host.now()
  if cache.at and (now - cache.at) < SETTING_TTL then return cache end
  cache = { at = now, role = meta_get('stt.role'), producer = meta_get('stt.producer') }
  return cache
end

-- `producer`, `worker`/`stt_worker`, `both`, `off` - and nothing else. An unreadable word is not a
-- role: it is skipped, and the last resort is `producer`, because a typo must never silently stop a
-- node from transcribing (the same rule `nodes.role` keeps).
local function canonical(word)
  local raw = tostring(word or ''):lower():gsub('%s+', '')
  if raw == '' then return nil end
  if raw == 'off' or raw == 'none' or raw == 'disabled' then return 'off' end
  if raw == 'worker' or raw == 'stt_worker' or raw == 'sttworker' then return 'worker' end
  if raw == 'both' then return 'both' end
  if raw == 'producer' or raw == 'stt_producer' or raw == 'sttproducer' then return 'producer' end
  return nil
end

-- The legacy file, read whole: the role is its first line, the producer selector its second.
local function node_stt()
  local text = host.read_file(paths.config() .. '/node.stt')
  if type(text) ~= 'string' then return nil, nil end
  local role = text:match('^[^\r\n]*') or ''
  -- One capture, so one value: `local _, producer = match(...)` used to read the capture into `_` and
  -- leave `producer` nil, which is why a second line in `node.stt` never named a producer at all.
  local producer = text:match('^[^\r\n]*[\r\n]+([^\r\n]*)')
  producer = tostring(producer or ''):gsub('^%s+', ''):gsub('%s+$', '')
  return role, producer
end

-- The role this node plays, and which layer named it (`env`, `setting`, `file`, `default`).
local function resolve()
  local from_env = canonical(host.getenv('WASM_AGENT_STT_ROLE'))
  if from_env then return from_env, 'env' end
  local from_setting = canonical(settings().role)
  if from_setting then return from_setting, 'setting' end
  local from_file = canonical((node_stt()))
  if from_file then return from_file, 'file' end
  return 'producer', 'default'
end

function M.role() return (resolve()) end
function M.source() local _, source = resolve(); return source end

function M.produce() local role = resolve(); return role == 'producer' or role == 'both' end
function M.work() local role = resolve(); return role == 'worker' or role == 'both' end

-- The producer's selector: the environment, else the setting, else the file's second line, else
-- nothing (a worker with no producer named is idle and says so, rather than guessing a peer).
function M.producer_selector()
  local named = host.getenv('WASM_AGENT_STT_PRODUCER')
  if type(named) == 'string' and named ~= '' then return named end
  local stored = settings().producer
  if type(stored) == 'string' and stored ~= '' then return stored end
  local _, from_file = node_stt()
  if type(from_file) == 'string' and from_file ~= '' then return from_file end
  return ''
end

-- Where the selector came from, for `wa stt status` (the role has `M.source`).
local function selector_source()
  local named = host.getenv('WASM_AGENT_STT_PRODUCER')
  if type(named) == 'string' and named ~= '' then return 'env' end
  local stored = settings().producer
  if type(stored) == 'string' and stored ~= '' then return 'setting' end
  local _, from_file = node_stt()
  if type(from_file) == 'string' and from_file ~= '' then return 'file' end
  return 'none'
end

-- Change the node's role while it runs (`wa stt role`, or the `services` tool's `stt` action from
-- another node). The write is the setting; the apply is the same `configure` the boot path uses, so
-- there is one way to start or stop the threads and this command cannot invent a second one.
--
-- A refused write leaves the role it had: the producer is written first, so a failure can never leave
-- a new role pointing at a producer that was not stored. `producer` is only touched when the caller
-- names one ("role only" must not silently forget the producer a worker was pointed at).
function M.set_role(request)
  request = request or {}
  local role = canonical(request.role)
  if not role then
    return { ok = false, error = 'invalid_stt_role', allowed = { 'producer', 'worker', 'both', 'off' } }
  end
  local producer = request.producer
  if producer ~= nil then
    producer = tostring(producer):gsub('^%s+', ''):gsub('%s+$', '')
    if #producer > 200 or producer:find('[^%w%-%._:@]') then
      return { ok = false, error = 'invalid_stt_producer' }
    end
    local saved, why = meta_set('stt.producer', producer)
    if not saved then return { ok = false, error = why } end
  end
  local written, problem = meta_set('stt.role', role)
  if not written then return { ok = false, error = problem } end
  cache = { at = nil, role = nil, producer = nil }
  -- Applied here or on the node's next tick: a one-shot `wa stt role` process must *persist* the
  -- change and not start a speech worker of its own (a CLI that configured itself would poll the
  -- live node's queue for the few milliseconds it lives, and a job taken there dies with it). The
  -- serving node configures on its next tick, which is at most a second later.
  local answer
  if request.apply ~= false then answer = M.configure('set-role') end
  local effective, source = resolve()
  local target = M.producer_selector()
  -- The audit trail is the node's `access_events` table (`wa access log`), the same one enrollment
  -- writes: who changed it, to what, and what the node is actually doing. No text, no audio, ever.
  local audited = pcall(function()
    dofile('lua/core/enrollment.lua').audit({ node_id = tostring(request.by or 'operator') },
      'stt.set_role', role .. (target ~= '' and ('@' .. target) or '') .. ' effective=' .. effective .. '/' .. source)
  end)
  if type(host.log) == 'function' then
    host.log('[stt] setting role=' .. role .. (target ~= '' and ('@' .. target) or '') .. ' effective=' ..
      effective .. '/' .. source .. ' by=' .. tostring(request.by or 'operator'))
  end
  return {
    ok = true, setting = role, producer = producer, role = effective, source = source,
    producer_selector = target, producer_source = selector_source(), audited = audited,
    applied = answer and (answer.ok and 'ok' or answer.error) or
      (request.apply == false and 'next-tick' or 'stt_no_answer'),
    -- A stored role the environment overrides is stored and not in effect: said out loud, because a
    -- command that answered `ok` without this would be claiming a role change that did not happen.
    overridden_by = (source ~= 'setting' and role ~= effective) and source or nil,
  }
end

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
  -- What this node has been told to do, so `tick` can notice the setting moving under it. Recorded
  -- whatever the host answers: a configure that failed is retried on the 30 s refresh, not hammered
  -- every second by a node whose role it cannot change.
  state.wanted = M.role() .. '|' .. M.producer_selector()
  state.signature = signature
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
      ' from=' .. M.source() ..
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
--
-- The one thing this tick must not do is wait 30 s to notice the node's own setting: a role that was
-- changed with `wa stt role` while the node runs is applied here, on the next tick. So the signature
-- is the role and the selector, not the peer list.
function M.tick()
  local role = M.role()
  local want = role .. '|' .. M.producer_selector()
  if not state.configured or want ~= state.wanted then
    M.configure(state.configured and 'setting-changed' or 'boot')
  elseif refresh_due() then
    M.configure('refresh')
  end
  if M.work() then state.worked = true end
  -- The pump is deliberately *not* gated on the role. A switch to `producer`/`off` stops new work
  -- (the node's worker thread sees `work=false` and stops polling) but a job it had already taken may
  -- still be decoding; its settle must be signed and delivered or the lease lapses and the producer
  -- decodes the same note again. A node that never worked pays nothing: the tunnel is empty and
  -- `pump` returns on the first host call. Bounded by `PUMP_MAX` per tick either way.
  if state.worked then pump() end
  if not M.work() then
    -- Not a worker: no peer to admit, so no `counters` to read. Nothing else in this tick belongs to
    -- a node that is only producing (or is off).
    if role == 'off' then return end
  else
    -- A worker that booted before its producer registered has no producer id yet; retry a couple of
    -- times a second until it does, rather than idling for the 30 s refresh.
    if state.producer_id == '' and (host.now() - (state.producer_at or 0)) >= 2 then
      M.configure('producer-unknown')
    end
  end
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
  answer.role_source = M.source()
  answer.producer_selector = M.producer_selector()
  answer.producer_source = selector_source()
  -- The stored setting, even when it is not what the node is doing: "I set worker, why is it still
  -- producing?" is answered by `role_source = env`, not by hiding the setting. `""` is "not stored".
  local stored = settings()
  answer.setting = { role = stored.role or '', producer = stored.producer or '' }
  answer.knobs = {
    lease_ms = env_number('WASM_AGENT_STT_LEASE_MS', 60000),
    heartbeat_every_ms = env_number('WASM_AGENT_STT_HEARTBEAT_MS', 15000),
    grace_ms = env_number('WASM_AGENT_STT_GRACE_MS', 3000),
    fresh_ms = env_number('WASM_AGENT_STT_FRESH_MS', 300000),
  }
  answer.configured = state.configured
  -- A different process (`wa stt status`, a one-shot script) has its own, unconfigured speech runtime:
  -- the queue counters and the workers attached to it are real and shared, but `producer`/`worker`
  -- there are the *default* config of a runtime that never read this node's setting. Overwritten with
  -- what this node will actually do, and labelled, so the two do not contradict each other.
  if type(answer.ok) == 'table' and not state.configured then
    answer.ok.producer = M.produce()
    answer.ok.worker = M.work()
    answer.ok.enabled = answer.ok.producer or answer.ok.worker
    answer.ok.runtime = 'not-configured-in-this-process'
  end
  answer.last_error = state.last_error or state.last_failure
  return answer
end

-- `wa stt status`: the same table, and nothing new. Kept as a name of its own because that is what
-- the operator types, and because a status that grew a second implementation would be a second truth.
function M.status() return M.view() end

-- `wa stt role <producer|worker|both|off> [--producer <node>]`, and `wa stt status`. The module owns
-- the words and the persistence; this owns turning argv into the one request `set_role` takes, so
-- the CLI has no rule of its own to drift from.
function M.cli(argv)
  argv = argv or {}
  local function usage()
    return { 'wa stt status', 'wa stt role <producer|worker|both|off> [--producer <node>]' }
  end
  local sub = tostring(argv[1] or 'status')
  if sub == 'status' then return M.status() end
  if sub ~= 'role' then return { ok = false, error = 'usage', usage = usage() } end
  local request = { role = argv[2], by = 'cli', apply = false }
  local index = 3
  while argv[index] do
    if argv[index] == '--producer' then
      if argv[index + 1] == nil then return { ok = false, error = 'usage', usage = usage() } end
      request.producer = argv[index + 1]
      index = index + 2
    elseif argv[index] == '--clear-producer' then
      request.producer = ''
      index = index + 1
    else
      return { ok = false, error = 'usage', usage = usage() }
    end
  end
  return M.set_role(request)
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
