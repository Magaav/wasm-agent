-- tools.nodes() answers from what the node knows, in under a second, and says how old each answer is.
--
-- MEASURED, 23/11 on avell, three calls of the `nodes` tool in a row: 20.4 s, 20.4 s, 0.25 s
-- (harness_events, `tool end`, ms 20361-20461). The default list started one `wa nodes probe` child per
-- peer and WAITED OUT its 20 s deadline before answering - inside a turn, before the first model call -
-- and a child that ran out of that time was CANCELLED and its result published as `probe_timeout`, so the
-- next call started another one. Session daf51bb3 (22/11) paid for that: 83 s and nine model rounds, four
-- of them spent finding where WhatsApp runs.
--
-- WHAT THIS ROW PINS:
--   * the tool asks for a bounded wait (`wait_s`) and for the child to be LEFT RUNNING (`keep_running`),
--     not for a whole deadline;
--   * one peer that never answers is answered in under a second of real time (the stub awaits sleep for
--     real, so an unbounded budget is 20 s here, not a number in a log);
--   * the peer is marked `probe_pending` with no age - not `probe_timeout`, and no negative published;
--   * a second call inside the same window JOINS the child instead of starting another one.
--
-- Hermetic: the host layer is a stub over the real one (nodes.lua reads the global `host`), the roster is
-- handed in (`opts.peers`), no rendezvous is read, and the only state written is the scratch
-- WASM_AGENT_HOME this row refuses to run without.
local json = dofile('lua/vendor/json.lua')

local function refuse(why) print('REFUSED test-nodes-answers-now: ' .. why); os.exit(2) end
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-nodes-answers-now')
if why_home then refuse(why_home) end

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

local real_host = host
local waited_ms_total, starts, cancels = 0, 0, 0
local settled_at = nil
local clock = 1700000000

-- The stub is a LAYER: every field it does not name falls through to the real host, so loading the node's
-- own modules still has what it needs.
host = setmetatable({
  getenv = function(name)
    if name == 'WASM_AGENT_DB' then return '' end
    if name == 'WASM_AGENT_RENDEZVOUS' or name == 'WASM_AGENT_RELAY' then return '' end
    return real_host.getenv(name)
  end,
  now = function() return clock end,
  uuid = function() return 'answers-now-fixture' end,
  runtime_info = function() return json.encode({ binary_path = '/fixture/wa', process_id = 41, boot_id = 'boot-1' }) end,
  operation = function(action, args_json)
    local args = json.decode(args_json) or {}
    if action == 'start' then
      starts = starts + 1
      return json.encode({ operation_id = 'op-' .. starts, ok = true })
    elseif action == 'await' then
      local slice = tonumber(args.wait_ms) or 1000
      waited_ms_total = waited_ms_total + slice
      -- A REAL sleep of the budget the caller asked for: this is what makes the measurement a timing
      -- row instead of a claim about an argument.
      if type(real_host.sleep) == 'function' then pcall(real_host.sleep, slice) end
      return json.encode({ id = tostring(args.id or ''), settled = false, state = 'running' })
    elseif action == 'cancel' then
      cancels = cancels + 1
      return json.encode({ ok = true })
    end
    return json.encode({ error = 'unexpected_action_' .. tostring(action) })
  end,
}, { __index = real_host })

local nodes = dofile('lua/core/nodes.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()

-- ---- 1. what the tool asks for ------------------------------------------------------------------
-- The tool is the caller the brief is about, so the options it passes are checked directly: a bounded
-- wait, and a child left running. `live_capabilities = false` would be the opposite mistake (it asks
-- nobody and reports nothing), so it must not be there either.
local seen_opts = nil
local real_list = nodes.list
nodes.list = function(opts) seen_opts = opts; return {} end
-- The redirect is installed BEFORE the tool layer loads, because `tools.lua` holds its own
-- `dofile('lua/core/nodes.lua')` from load time: a stub installed after it would be a second table
-- nobody calls (measured in this row's first run: `seen_opts` was nil).
local dofile_real = dofile
dofile = function(path) if path == 'lua/core/nodes.lua' then return nodes end return dofile_real(path) end
local tools = dofile('lua/core/tools.lua')
tools.dispatch(memory, 'nodes', {}, 'master', { user_id = 'master', role = 'master' })
dofile = dofile_real
nodes.list = real_list
ok(type(seen_opts) == 'table', 'the nodes tool asks the list for a roster: ' .. json.encode(seen_opts))
ok(tonumber(seen_opts.wait_s) ~= nil and tonumber(seen_opts.wait_s) <= 1,
  'it waits at most a second for the probes, not a deadline: ' .. tostring(seen_opts.wait_s))
ok(seen_opts.keep_running == true,
  'and it leaves a probe that has not answered RUNNING (a cancelled child answers nobody): '
    .. tostring(seen_opts.keep_running))
ok(seen_opts.live_capabilities ~= false,
  'it still asks: a list that asks nobody is not an answer either')

-- ---- 2. one peer that never answers, answered in under a second --------------------------------
-- The roster holds the ONE peer: `M.list` prepends this node itself and asks one child per entry whose
-- node_id is not this node's, so a "self" row here would be a second child (measured: two 0.9 s waits
-- for a roster of two, which is how this row first read 1.9 s).
local roster = {
  { node_id = 'peer-1', name = 'openclaw', online = true },
}
-- `probe = true` is the allow-list `nodes.lua` keeps for a SCRIPT RUN (a row that tests probing is the
-- only kind that opts in; every other row would be a live fleet call). It is the same fan-out the tool
-- drives in a real turn, which is what this row measures.
-- The real clock, not `os.time`: a budget of 0.9 s measured to whole seconds is a coin toss on which
-- second boundary it crossed. `host.now()` is the host's own (fractional) clock, so this is the real time
-- the call took, and an unbounded wait would be ~20 s here.
-- The budget is the tool's OWN (`seen_opts.wait_s`), not a number written twice: this measures what a
-- turn actually pays.
local budget = tonumber(seen_opts.wait_s)
local started = real_host.now()
local rows = nodes.list({ peers = roster, wait_s = budget, keep_running = true, probe = true })
local elapsed = real_host.now() - started
local function peer_row(list)
  for _, row in ipairs(list) do if row.node_id == 'peer-1' then return row end end
end
local peer = peer_row(rows)
ok(peer ~= nil and peer.local_node == false, 'the peer is in the list: ' .. json.encode(rows))
ok(elapsed <= 1, 'the call answered in at most a second of real time (measured ' .. string.format('%.3f', elapsed) .. ' s)')
ok(waited_ms_total <= 1000,
  'and asked the host for at most a second of waiting, not a deadline: ' .. waited_ms_total .. ' ms')
ok(starts == 1, 'one probe child was started for the one peer: ' .. starts)
ok(cancels == 0, 'and nothing was cancelled (with no CPU stolen from a child that would have answered): '
  .. cancels)
ok(peer.capabilities == nil and peer.capabilities_reason == 'probe_pending',
  'the peer says it has not answered YET, which is not a timeout: ' .. json.encode(peer))
ok(peer.capabilities_age_s == nil,
  'and carries no age, because there is no answer to be old: ' .. tostring(peer.capabilities_age_s))

-- ---- 3. the next call joins the child instead of forking another --------------------------------
local before = starts
local again = peer_row(nodes.list({ peers = roster, wait_s = 0.2, keep_running = true, probe = true }))
ok(starts == before, 'a second call inside the window starts no second child: ' .. starts)
ok(again and (again.capabilities_reason == 'probe_pending' or again.capabilities ~= nil),
  'and answers what it has: ' .. json.encode(again))
ok(cancels == 0, 'still nothing cancelled: ' .. cancels)

-- A child that DOES answer is reported with its answer and an age - and an answer already on disk is
-- how the next call gets one without waiting for the deadline at all.
ok(type(nodes.known_capabilities()) == 'table', 'the known-capabilities reader answers a table, never nil')

host = real_host
print('nodes answers now ok (' .. checks .. ' checks)')
