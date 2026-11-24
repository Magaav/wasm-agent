-- ACCEPT FAST, RUN DETACHED, POLL BY ID.
--
-- Mission fleet-update-survives-a-slow-relay, STEP 0 of the pull design
-- (_queue/updates-never-touch-a-running-turn.md). One request, two lifetimes, and this is the seam
-- between them - it is deliberately not about deploys: a kind, an idempotency key and a command are
-- all it knows, so the pull design and a long check on a peer can call the same three functions.
--
-- The collision it exists for, measured on `work` 24/11 (timings in
-- docs/missions/reports/fleet-update-survives-a-slow-relay.md): a caller on the other side of a relay
-- has a deadline (42 s: rust/wa-rendezvous SEND_WAIT 45 s less ANSWER_MARGIN_MS 3 s), and the work a
-- node is asked for can take minutes (there: 101 s of pre-update backup). Held in ONE call the two
-- collide: the relay answers a named timeout, and the caller is told the node "refused" a request the
-- node had not even reached.
--
--   accepted.begin{root, id, kind, detail, program, args, ...}
--       Claims the id, writes the record, STARTS the work as the node's OWN managed operation
--       (`host.operation`, the one long-job path this node has) and returns at once - in milliseconds,
--       never after the work. A second call with the same id starts NOTHING and answers what the first
--       one is doing: the retry a caller with a deadline will make cannot run an update twice.
--
--   accepted.status{root, id, probe}
--       accepted / running / done / failed, from durable evidence only: the record the node wrote, the
--       operation the host says it is running, and the caller's own probe (a deploy's installed.txt, a
--       job's outcome file). A question this cannot answer is `unknown` - never `done`, and never a
--       guess (the fleet's rule: unknown is not yes).
--
--   accepted.finish{root, id, state, detail}
--       The detached process' own terminal write. It is the only writer of `done`/`failed`.
--
-- THE CLAIM IS ATOMIC, and that is the whole of the idempotency: `mkdir` either creates the claim
-- directory or it does not, so two callers cannot both believe they are first - not two threads, not
-- two relayed calls a second apart. A claim that cannot be made is a REFUSAL ("accept_claim_unavailable"),
-- never an assumed success: an accept that might run twice is worse than one that did not run.
--
-- WHAT THIS DOES NOT DO: it does not make a slow caller fast. The caller still has one deadline; what
-- it gets now is the truth - "accepted, read it back by id" - instead of a refusal, and the node goes
-- on working after the caller has gone.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local M = {}

-- The name this module's operations are owned by (host.operation's `owner`: a caller may only read
-- back and cancel its own). One constant, so a second call site cannot start a row nobody owns.
M.OWNER = 'accepted'

-- The phases, and the only ones: a request is accepted, then running, then done or failed. `unknown`
-- is not a phase - it is what `status` answers when it cannot tell, and it is never written down.
M.STATES = { accepted = true, running = true, done = true, failed = true }
M.TERMINAL = { done = true, failed = true }

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function slashes(path) return (tostring(path or ''):gsub('\\', '/')) end

local function quote(value) return "'" .. tostring(value or ''):gsub("'", "'\\''") .. "'" end

local function decode(text)
  if type(text) ~= 'string' or text == '' then return nil end
  local ok, value = pcall(json.decode, text)
  return (ok and type(value) == 'table') and value or nil
end

local function read(path)
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' or text == '' then return nil end
  return decode(text)
end

local function write(path, value)
  local ok, wrote = pcall(host.write_file, path, json.encode(value))
  return ok and wrote == true
end

local function shell(command)
  local ok, raw = pcall(host.exec, command, '')
  if not ok then return nil end
  return decode(raw)
end

-- An id becomes a file name and a shell word, so it is allow-listed rather than escaped: letters,
-- digits, dash, underscore and dot, and nothing that could leave the records directory or end a quote.
function M.valid_id(id)
  local value = tostring(id or '')
  return #value >= 6 and #value <= 120 and value:match('^[%w%-_%.]+$') ~= nil and not value:find('%.%.', 1, true)
end

-- Where the records live. `opts.root` is the seam a test (or another product) points at its own
-- directory; the default is this node's config directory, beside the other durable records.
function M.root(custom)
  local explicit = trim(custom)
  if explicit ~= '' then return slashes(explicit) end
  return slashes(paths.config()) .. '/accepted'
end

function M.record_path(root, id)
  if not M.valid_id(id) then return nil end
  return M.root(root) .. '/' .. tostring(id) .. '.json'
end

function M.record(root, id)
  local path = M.record_path(root, id)
  if not path then return nil end
  return read(path)
end

local function save(root, id, fields)
  local path = M.record_path(root, id)
  if not path then return nil end
  local record = read(path) or { schema = 1, id = tostring(id), state = 'accepted' }
  for key, value in pairs(fields or {}) do record[key] = value end
  record.updated_at = math.floor(host.now())
  if not write(path, record) then return nil end
  return record
end

-- One line a human acts on. It names the phase, the kind and the id, and it never says a request is
-- finished when the phase says it is not.
function M.summary(record, extra)
  if type(record) ~= 'table' then return 'no accept record' end
  local state = tostring(record.state or 'unknown')
  local parts = { string.format('%s %s', tostring(record.kind or 'request'), state) }
  if record.id then parts[#parts + 1] = 'id ' .. tostring(record.id) end
  local detail = tostring((extra and extra.detail) or record.detail or '')
  if detail ~= '' then parts[#parts + 1] = detail end
  local operation = tostring((extra and extra.operation) or (record.operation and record.operation.id or ''))
  if operation ~= '' then parts[#parts + 1] = 'operation ' .. operation end
  return table.concat(parts, '; ')
end

-- ---- the claim ----------------------------------------------------------------------------------
--
-- A directory, because `mkdir` is the one create that is atomic across processes here: it answers 0
-- to the caller that created it and non-zero to every other one, with no window in between. The claim
-- lives beside the record, so "claimed but nothing written" is visible as a missing record rather than
-- as an accepted request.
function M.claim(root, id)
  local dir = M.root(root)
  if not M.valid_id(id) then return nil, { error = 'accept_id_invalid', observed = tostring(id) } end
  local path = dir .. '/' .. tostring(id) .. '.claim'
  local result = shell('mkdir -p ' .. quote(dir) .. ' && mkdir ' .. quote(path) .. ' 2>/dev/null')
  if not result or result.code == nil then
    -- A claim nobody could make is not a claim that was made. Say so and start nothing: two updates
    -- of one node is the failure this function exists to make impossible.
    return nil, { error = 'accept_claim_unavailable',
      observed = 'mkdir answered ' .. json.encode(result or {}),
      next = 'check that ' .. dir .. ' is writable by this node, then ask again; nothing was started' }
  end
  return (result.code or 1) == 0, nil
end

-- ---- starting the work --------------------------------------------------------------------------

-- The node's own managed operation, by its real name (rust/wa-capabilities/src/operations.rs): the
-- signature receipt, an id this node can read back and cancel, and a child that outlives the call
-- that started it. Absent in a host that has no operation manager: then there is NO detached path,
-- and this says so rather than pretending (the caller decides between inline and refusing).
function M.start_operation(opts)
  if type(host.operation) ~= 'function' then
    return { ok = false, error = 'operation_host_unavailable',
      observed = 'this host exposes no host.operation, so no work can be started detached' }
  end
  local program = trim(opts and opts.program)
  if program == '' then return { ok = false, error = 'program_required' } end
  local argv = {}
  for _, value in ipairs((opts and opts.args) or {}) do argv[#argv + 1] = tostring(value) end
  local request = { program = program, args = argv, kind = trim(opts.kind) ~= '' and trim(opts.kind) or 'command',
    timeout_seconds = tonumber(opts.timeout_seconds) or 1800, owner = trim(opts.owner) ~= '' and trim(opts.owner) or M.OWNER }
  if trim(opts.cwd) ~= '' then request.cwd = trim(opts.cwd) end
  local ok, receipt = pcall(host.operation, 'start', json.encode(request))
  local answer = ok and type(receipt) == 'string' and decode(receipt) or (ok and type(receipt) == 'table' and receipt or nil)
  local id = answer and answer.operation_id
  if not id then
    return { ok = false, error = 'operation_start_refused',
      observed = ok and json.encode(answer or {}) or tostring(receipt) }
  end
  return { ok = true, id = tostring(id), state = tostring(answer.state or 'accepted') }
end

-- What the host says about one of this module's operations: running, settled-and-how, or unreadable.
-- `settled == nil` means "cannot tell" and is returned as such - never as done.
function M.operation_state(operation, owner)
  local id = tostring((type(operation) == 'table' and operation.id) or operation or '')
  if id == '' then return nil end
  if type(host.operation) ~= 'function' then return nil end
  local ok, raw = pcall(host.operation, 'status', json.encode({ id = id, owner = trim(owner) ~= '' and trim(owner) or M.OWNER }))
  local answer = ok and type(raw) == 'string' and decode(raw) or (ok and type(raw) == 'table' and raw or nil)
  if type(answer) ~= 'table' or answer.error then return nil end
  return answer
end

-- ---- the three calls a caller makes ---------------------------------------------------------------

-- Accept one id-keyed request and start its work detached. Returns in milliseconds: the record is on
-- disk and the operation is started, and NOTHING here waits for the work.
--
--   opts.root      the records directory (a test's own; this node's config by default)
--   opts.id        the idempotency key - a retry with the same id starts nothing
--   opts.kind      what this is, for the record and the summary ("remote-update", "pull", ...)
--   opts.detail    a table the caller wants kept with the record (commit, node, requester, ...)
--   opts.program   the child to run detached (args = opts.args, cwd = opts.cwd)
--   opts.owner     the host.operation owner (default M.OWNER)
-- STEP 1, for a caller whose own refusals must stay synchronous: claim the id and write the record,
-- and start NOTHING yet. The cheap, decisive checks run between this and M.detach (a deploy's dirty
-- tree, a peer's missing watcher), so a refusal still answers the caller directly - and the record
-- already names the id, so a caller whose deadline expired reads the same refusal back by id instead
-- of being told nothing happened.
function M.accept(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  if not M.valid_id(id) then return { ok = false, error = 'accept_id_invalid', observed = tostring(opts.id) } end
  local root = M.root(opts.root)
  local first, problem = M.claim(root, id)
  if first == nil then return { ok = false, error = problem.error, observed = problem.observed, next = problem.next } end
  if not first then
    -- Already claimed: answer what that one is doing. NOT a refusal, and not a second run.
    local existing = M.record(root, id) or { id = id, state = 'accepted', kind = opts.kind }
    return { ok = true, already = true, id = id, state = tostring(existing.state or 'accepted'),
      accepted_at = existing.accepted_at, operation = existing.operation,
      detail = existing.detail, root = root, summary = M.summary(existing) }
  end
  local record = {
    schema = 1, id = id, kind = trim(opts.kind) ~= '' and trim(opts.kind) or 'request',
    state = 'accepted', accepted_at = math.floor(host.now()),
    detail = type(opts.detail) == 'table' and opts.detail or {},
    owner = trim(opts.owner) ~= '' and trim(opts.owner) or M.OWNER,
    detached = false,
  }
  if not save(root, id, record) then
    return { ok = false, error = 'accept_record_not_written', id = id,
      observed = 'the id was claimed and its record could not be written to ' .. root,
      next = 'check that ' .. root .. ' is writable by this node; nothing was started' }
  end
  return { ok = true, id = id, state = record.state, detached = false, claimed = true,
    accepted_at = record.accepted_at, detail = record.detail, root = root, summary = M.summary(record) }
end

-- STEP 2: start the work detached for an id that M.accept already claimed. It returns at once - the
-- operation is the node's own managed one, so the caller's process is not holding it.
function M.detach(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  if not M.valid_id(id) then return { ok = false, error = 'accept_id_invalid' } end
  local root = M.root(opts.root)
  local started = M.start_operation(opts)
  local record = {
    schema = 1, id = id, kind = trim(opts.kind) ~= '' and trim(opts.kind) or 'request',
    state = started.ok and 'running' or 'accepted',
    accepted_at = math.floor(host.now()),
    detail = type(opts.detail) == 'table' and opts.detail or {},
    owner = trim(opts.owner) ~= '' and trim(opts.owner) or M.OWNER,
    detached = started.ok == true,
    operation = started.ok and { id = started.id, state = started.state } or nil,
    start_problem = (not started.ok) and { error = started.error, observed = started.observed } or nil,
  }
  if not save(root, id, record) then
    -- The work is started and the record is not: that is exactly the case a caller must not read as
    -- "did not run". It is named, and the operation id travels with it so the node can still be asked.
    return { ok = false, error = 'accept_record_not_written', id = id, operation = record.operation,
      observed = 'the work was started detached and its record could not be written to ' .. root,
      next = 'read the operation back on that node: operation ' .. tostring(record.operation and record.operation.id or 'unknown') }
  end
  return { ok = true, id = id, state = record.state, detached = record.detached,
    accepted_at = record.accepted_at, operation = record.operation, detail = record.detail,
    root = root, summary = M.summary(record) }
end

-- ONE ID, ONE RUN OF ITS WORK (review item b). `mkdir` either creates the claim or it does not, so a
-- retry, a second operator, or the same verb twice can never run the tail for one id: the caller that
-- loses is answered with the id's own phase and starts nothing. The claim lives beside the record and is
-- removed by M.finish, which is the only terminal write.
--
-- A claim left behind by a process that DIED is not cleared here on purpose: whether that run got
-- anywhere is not knowable from the claim, and re-running a deploy that may have queued one is the
-- double update this module exists to prevent. M.status reports the phase, and a record whose work
-- settled without a terminal write says exactly that.
function M.claim_running(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  if not M.valid_id(id) then return { ok = false, error = 'accept_id_invalid' } end
  local root = M.root(opts.root)
  local path = root .. '/' .. tostring(id) .. '.running'
  local result = shell('mkdir -p ' .. quote(root) .. ' && mkdir ' .. quote(path) .. ' 2>/dev/null')
  if not result or result.code == nil then
    return { ok = false, error = 'accept_claim_unavailable',
      observed = 'mkdir answered ' .. json.encode(result or {}) }
  end
  if (result.code or 1) ~= 0 then
    local record = M.record(root, id) or {}
    return { ok = false, claimed = false, state = tostring(record.state or 'unknown'),
      detail = 'this id has already been claimed for its one run on this node, so nothing was started' }
  end
  return { ok = true, claimed = true }
end

function M.release_running(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  if not M.valid_id(id) then return false end
  local result = shell('rmdir ' .. quote(M.root(opts.root) .. '/' .. tostring(id) .. '.running') .. ' 2>/dev/null')
  return result ~= nil and (result.code or 1) == 0
end

-- The detached process' own terminal write, and the only writer of done/failed.
function M.finish(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  local state = trim(opts.state)
  if not M.valid_id(id) then return { ok = false, error = 'accept_id_invalid' } end
  if not M.STATES[state] then return { ok = false, error = 'accept_state_unknown', observed = state,
    allowed = { 'accepted', 'running', 'done', 'failed' } } end
  local record = save(M.root(opts.root), id, { state = state, detail = tostring(opts.detail or ''),
    finished_at = math.floor(host.now()), result = type(opts.result) == 'table' and opts.result or nil })
  if not record then return { ok = false, error = 'accept_record_not_written' } end
  if M.TERMINAL[state] then M.release_running({ root = opts.root, id = id }) end
  return { ok = true, id = id, state = record.state, detail = record.detail }
end

-- What one id is doing, from durable evidence only. `probe` is the caller's own reader of ITS outcome
-- files (a deploy's installed.txt, a job's done/): it may answer done or failed and is never used to
-- downgrade a record that already settled.
function M.status(opts)
  opts = type(opts) == 'table' and opts or {}
  local id = trim(opts.id)
  if not M.valid_id(id) then return { state = 'unknown', error = 'accept_id_invalid', id = tostring(opts.id) } end
  local root = M.root(opts.root)
  local record = M.record(root, id)
  local answer = { id = id, root = root, record = record ~= nil }
  if record then
    answer.state = tostring(record.state or 'accepted')
    answer.detail = record.detail
    answer.accepted_at = record.accepted_at
    answer.operation = record.operation
    answer.detached = record.detached == true
    answer.start_problem = record.start_problem
  else
    -- Claimed and not written, or never asked for: two different facts, and the claim directory says
    -- which. Nothing here is read as accepted.
    local claimed = shell('[ -d ' .. quote(root .. '/' .. id .. '.claim') .. ' ] && echo yes')
    answer.state = 'unknown'
    answer.error = (claimed and tostring(claimed.stdout or ''):find('yes', 1, true)) and 'accept_record_missing' or 'unknown_request'
    answer.detail = answer.error == 'accept_record_missing'
      and 'this id was claimed on that node and no record was written: whether anything ran is unknown'
      or 'no accept record on that node names this id'
    return answer
  end
  if not M.TERMINAL[answer.state] then
    -- The caller's own outcome files first: they are what "installed" or "failed" MEANS for its kind.
    if type(opts.probe) == 'function' then
      local ok, probed = pcall(opts.probe, record)
      if ok and type(probed) == 'table' and (probed.state == 'done' or probed.state == 'failed') then
        answer.state, answer.detail = probed.state, probed.detail
        answer.evidence = probed.evidence
        answer.probed = true
        return answer
      elseif ok and type(probed) == 'table' and probed.state then
        answer.probe_state = tostring(probed.state)
      end
    end
    local snapshot = record.operation and M.operation_state(record.operation, record.owner) or nil
    answer.operation_state = snapshot and tostring(snapshot.state or '') or nil
    if snapshot then
      answer.settled = snapshot.settled == true
      if snapshot.settled == true then
        local code = tonumber(snapshot.code)
        if code == nil then
          -- Settled with no exit code the host can name: the phase is unknown, and it says so.
          answer.detail = 'the detached work settled and the host named no exit code'
        elseif code ~= 0 then
          answer.state = 'failed'
          answer.detail = 'the detached work exited ' .. tostring(code) .. (snapshot.error and (' (' .. tostring(snapshot.error) .. ')') or '')
        else
          -- Exited 0 without a terminal write: the work stopped without saying what it did. Not done.
          answer.detail = 'the detached work exited 0 and wrote no terminal phase'
        end
      else
        answer.state = 'running'
      end
    end
  end
  answer.summary = M.summary(record, answer)
  return answer
end

-- Both steps in one call, for a caller with nothing to say between them.
function M.begin(opts)
  local accepted = M.accept(opts)
  if not accepted.ok or accepted.already then return accepted end
  local detached = M.detach(opts)
  detached.claimed = true
  if detached.ok ~= true then
    -- The id stays claimed. A retry must not start the work twice, and the caller is told which call
    -- failed rather than being invited to try again blindly.
    return detached
  end
  return detached
end

return M
