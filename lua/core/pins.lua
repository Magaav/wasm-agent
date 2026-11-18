-- Pins: why a node may not move forward, recorded where the decision to move it is made.
--
-- THE MEASUREMENT THIS ANSWERS. On 18/11 three rollbacks happened by hand - mail and nextcloud back to their
-- glibc-2.30 binaries, the node on "work" back to a build the operator wanted - and none of them was
-- recorded anywhere. The next ordinary deploy had no way to know a node had been put somewhere on purpose,
-- so it did the default thing: it installed main over it. "Going back" was a shell command and a memory.
--
-- So going back is a RECORD with a shape the machine reads:
--
--   commit     what the node is held at (or unknown, for a binary that predates --build-info)
--   binary_sha256  which bytes, so a pin still names its object when no commit is known
--   reason     the sentence an operator would say out loud
--   by / at    who recorded it and when
--   until      an optional condition or date; a date that has passed is OVERDUE and is reported as such
--   await      an optional commit whose landing releases the pin: a target that contains it is not blocked
--
-- WHERE IT LIVES AND WHY THERE. The store is on the node that runs "wa update <node>", because that is the
-- party that decides to move a node - the same node that keeps the request audit records this module sits
-- beside. A pin gates that node's deploy requests (lua/core/remote_update.lua's request path and
-- lua/core/update.lua's local one) and is reported by the fleet view. What protects a node from going
-- backwards when nobody asked this coordinator is a different rule and it lives where the install happens:
-- the ancestry guard in scripts/deploy.sh, asked of the RUNNING binary. The two are complementary, and
-- neither of them is a substitute for the other.
--
-- THE FORMAT IS THE CONTRACT, because a shell script (scripts/lib/node-pins.sh) reads the same file for the
-- deploy-side check and for the seeded records. One record per block of key=value lines; a later record for
-- the same node supersedes an earlier one; "state=cleared" is the record that says a pin is over. That is
-- deliberately dull: a reader needs no parser beyond splitting on '='.
local paths = dofile('lua/core/paths.lua')
local nodes = dofile('lua/core/nodes.lua')

local M = {}

M.SCHEMA = 'wasm-agent-pins/1'
M.FILE = 'pins.txt'

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function slashes(path) return (tostring(path or ''):gsub('\\', '/')) end

-- The store: <config>/pins.txt, beside the node's other records.
function M.path() return slashes(paths.config()) .. '/' .. M.FILE end

local function read(path)
  local handle = io.open(path, 'r')
  if not handle then return nil end
  local text = handle:read('a')
  handle:close()
  return text
end

-- Parse the file into records. A malformed line is kept as-is under "unparsed" rather than dropped: a
-- record this reader does not understand is a fact about the writer, not permission to ignore it.
function M.parse(text)
  local records, current = {}, nil
  for line in (tostring(text or '') .. '\n'):gmatch('([^\n]*)\n') do
    line = (line:gsub('\r$', ''))
    if line == '' then
      if current and current.id then records[#records + 1] = current end
      current = nil
    else
      local key, value = line:match('^([%w_]+)=(.*)$')
      if key then
        if key == 'id' and current and current.id then records[#records + 1] = current; current = nil end
        current = current or {}
        current[key == 'until' and 'until_' or key] = value
      else
        current = current or {}
        current.unparsed = (current.unparsed and (current.unparsed .. ' | ') or '') .. line
      end
    end
  end
  if current and (current.id or next(current)) then records[#records + 1] = current end
  return records
end

function M.records()
  return M.parse(read(M.path()) or '')
end

-- The pin in force for a node: the LAST record written for it, when that record says active. History is
-- kept, so "when was this node pinned, by whom, and why" is answerable after the fact.
function M.active(node)
  local wanted = trim(node)
  if wanted == '' then return nil end
  local latest = nil
  for _, record in ipairs(M.records()) do
    if trim(record.node) == wanted and trim(record.state) ~= '' then latest = record end
  end
  if latest and trim(latest.state) == 'active' then return latest end
  return nil
end

-- Every record for a node, oldest first: the history behind the current state.
function M.history(node)
  local wanted, out = trim(node), {}
  for _, record in ipairs(M.records()) do
    if wanted == '' or trim(record.node) == wanted then out[#out + 1] = record end
  end
  return out
end

local function stamp()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function caller_name()
  local ok, name = pcall(nodes.node_name)
  if ok and type(name) == 'string' and name ~= '' then return name end
  return trim(host.getenv and host.getenv('HOSTNAME') or '') ~= '' and trim(host.getenv('HOSTNAME')) or 'unknown'
end

local function field_block(record)
  local order = { 'id', 'node', 'kind', 'state', 'commit', 'binary_sha256', 'reason', 'by', 'at', 'until_', 'await', 'supersedes' }
  local lines = { 'schema=' .. M.SCHEMA }
  for _, key in ipairs(order) do
    if record[key] ~= nil and record[key] ~= '' then
      -- "until" on disk, until_ in code: Lua reserves the word, and a record a human reads should still say
      -- the word a human says.
      local name = key == 'until_' and 'until' or key
      lines[#lines + 1] = name .. '=' .. (tostring(record[key]):gsub('[\r\n]+', ' '))
    end
  end
  return table.concat(lines, '\n')
end

-- Append a record. Never rewrites what is already there: the store is an append-only ledger, so a pin that
-- was cleared and re-applied can be read back in order.
function M.write(record)
  local existing = read(M.path()) or ''
  if existing ~= '' and not existing:match('\n$') then existing = existing .. '\n' end
  local text = existing .. (existing ~= '' and '\n' or '') .. field_block(record) .. '\n'
  local path = M.path()
  local ok, wrote = pcall(host.write_file, path, text)
  if not ok or wrote ~= true then return nil, { error = 'pin_not_written', observed = 'could not write ' .. path } end
  return record
end

local function new_id(node, at)
  local seed = tostring(node) .. tostring(at) .. tostring(os.time()) .. tostring(math.random(1, 1000000))
  local hash = 0
  for index = 1, #seed do hash = (hash * 31 + seed:byte(index)) % 2147483647 end
  return string.format('%08x', hash)
end

-- Record a pin. This is the ONE writer; "wa update <node> --rollback|--to" and the operator's own
-- "--pin" both come through here, so a pin always names its node, its reason, who asked and when.
function M.set(fields)
  fields = type(fields) == 'table' and fields or {}
  local node = trim(fields.node)
  if node == '' then return nil, { error = 'pin_node_required', observed = 'a pin without a node pins nothing' } end
  local reason = trim(fields.reason)
  if reason == '' then
    return nil, { error = 'pin_reason_required', observed = 'a pin without a reason is a memory, not a record: say why the node is held' }
  end
  local at = stamp()
  local previous = M.active(node)
  local record = {
    id = new_id(node, at), node = node, state = 'active',
    kind = trim(fields.kind) ~= '' and trim(fields.kind) or 'pin',
    commit = trim(fields.commit) ~= '' and trim(fields.commit) or 'unknown',
    binary_sha256 = trim(fields.binary_sha256),
    reason = reason, by = trim(fields.by) ~= '' and trim(fields.by) or caller_name(), at = at,
    until_ = trim(fields.until_), await = trim(fields.await),
    supersedes = previous and previous.id or '',
  }
  local written, problem = M.write(record)
  if not written then return nil, problem end
  record.summary = M.summary_line(record)
  return record
end

-- Clear a pin: a record that says the node may move again, with the reason it may. A clear with no reason
-- is allowed (the operator's own command), and it is still a record.
function M.clear(node, opts)
  opts = type(opts) == 'table' and opts or {}
  node = trim(node)
  local current = M.active(node)
  if not current then return nil, { error = 'node_not_pinned', observed = tostring(node) .. ' carries no active pin; nothing was cleared' } end
  local at = stamp()
  local record = {
    id = new_id(node, at), node = node, kind = 'unpin', state = 'cleared',
    commit = current.commit, reason = trim(opts.reason) ~= '' and trim(opts.reason) or 'unpinned',
    by = trim(opts.by) ~= '' and trim(opts.by) or caller_name(), at = at, supersedes = current.id,
  }
  local written, problem = M.write(record)
  if not written then return nil, problem end
  return record
end

-- Is a date-shaped "until" behind us? A condition that is not a date ("release-glibc lands") cannot be
-- decided here, and pretending otherwise would hide the pin that a human has to release.
function M.overdue(record, now)
  local until_ = trim(type(record) == 'table' and record.until_ or '')
  local year, month, day = until_:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  if not year then return false, 'condition' end
  local deadline = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 23, min = 59, sec = 59 })
  if not deadline then return false, 'condition' end
  return (now or os.time()) > deadline, 'date'
end

-- Does a target release this pin? Two ways, and both are the operator's own statement: the target is the
-- pinned commit itself, or the pin named the commit whose landing it awaits and the target contains it.
-- Containment is asked of git in the node's runtime tree; with no tree the answer is "cannot tell", which
-- is reported as unknown and never as released.
function M.released(record, target_commit, tree)
  if type(record) ~= 'table' then return nil end
  local target = trim(target_commit)
  local pinned = trim(record.commit)
  if target ~= '' and (pinned == target) then return { released = true, why = 'the target is the pinned commit' } end
  local await = trim(record.await)
  if await == '' then return { released = false, why = 'the pin names no awaited commit' } end
  if target ~= '' and await == target then return { released = true, why = 'the target is the awaited commit' } end
  if trim(tree) == '' then return nil end
  local quoted = await:gsub("'", "'\\''")
  local command = "git -C '" .. slashes(tree):gsub("'", "'\\''") .. "' merge-base --is-ancestor '" .. quoted .. "' '" .. target:gsub("'", "'\\''") .. "' 2>/dev/null"
  local handle = io.popen(command)
  if not handle then return nil end
  -- io.popen's close() is where a child's exit status arrives in Lua 5.4: true/nil, "exit", code. Closing
  -- twice would answer the first call's status and lose this one, so it is closed exactly once.
  local ok_close, _, exit_code = handle:close()
  if ok_close == nil then return nil end
  if exit_code == 0 then return { released = true, why = 'the target contains the awaited commit ' .. await:sub(1, 12) } end
  return { released = false, why = 'the target does not contain the awaited commit ' .. await:sub(1, 12) }
end

function M.summary_line(record)
  if type(record) ~= 'table' then return '' end
  local parts = { tostring(record.node or '?') .. ' pinned to ' .. tostring(record.commit or 'unknown'):sub(1, 12) }
  if trim(record.binary_sha256) ~= '' then parts[#parts + 1] = 'bytes ' .. tostring(record.binary_sha256):sub(1, 12) end
  parts[#parts + 1] = 'since ' .. tostring(record.at or '?')
  parts[#parts + 1] = 'by ' .. tostring(record.by or '?')
  if trim(record.reason) ~= '' then parts[#parts + 1] = 'reason: ' .. trim(record.reason) end
  if trim(record.until_) ~= '' then
    local late = M.overdue(record)
    parts[#parts + 1] = 'until ' .. trim(record.until_) .. (late and ' (OVERDUE)' or '')
  end
  if trim(record.await) ~= '' then parts[#parts + 1] = 'awaits ' .. trim(record.await):sub(1, 12) end
  return table.concat(parts, ', ')
end

-- Every active pin, for the fleet report and for "wa update --status": one line per node, with the overdue
-- ones named as overdue instead of being left for a reader to compare dates.
function M.list()
  local out, seen = {}, {}
  for _, record in ipairs(M.records()) do
    local node = trim(record.node)
    if node ~= '' then seen[node] = record end
  end
  for node, record in pairs(seen) do
    local state = trim(record.state)
    if state == 'active' then
      local late, kind = M.overdue(record)
      out[#out + 1] = { node = node, commit = record.commit, binary_sha256 = record.binary_sha256,
        reason = record.reason, by = record.by, at = record.at, until_ = record.until_, await = record.await,
        overdue = late, until_kind = kind, id = record.id, summary = M.summary_line(record) }
    end
  end
  table.sort(out, function(a, b) return tostring(a.node) < tostring(b.node) end)
  return out
end

function M.overdue_list()
  local out = {}
  for _, pin in ipairs(M.list()) do
    if pin.overdue then out[#out + 1] = pin end
  end
  return out
end

return M
