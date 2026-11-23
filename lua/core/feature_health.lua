-- Does every shipped feature still WORK on this node - and if not, since when.
--
-- THE FAILURE THIS FILE EXISTS FOR (Victor, 23/11, after finding WhatsApp transcription, the copilot
-- reply and the auto indexer all broken for days with nobody knowing): the release gate tests the TREE,
-- and the fleet read-back checks the COMMIT a node runs. Nothing exercises a user-facing feature ON the
-- node after the install, and nothing notices that a feature has not succeeded for days. So 'shipped' and
-- 'works' had no shared evidence anywhere.
--
-- The registry is ONE LIST in the tree (config/features/features.json: name, role, canary, where the
-- last real success is recorded, and how stale is too stale). This module is the only reader of it that
-- decides anything:
--
--   * WHERE THE LAST SUCCESS COMES FROM is named per feature and is one of two honest kinds:
--       - a HOOK: the real code path that performs the work calls M.record(name, true, ...) when it
--         succeeds and M.record(name, false, {stage=...}) when it fails. The registry row names the
--         file that holds the hook, and scripts/check-features-registry.mjs refuses a row whose file
--         does not exist.
--       - a COLLECTOR: the success is a durable artifact the node already keeps (the WhatsApp index's
--         newest transcript, the jobs ledger's last run, the install record) and M.collect reads it.
--     A collector that cannot read its artifact records NOTHING and says why - an unreadable index is
--     not a success, and reporting 'unknown' as 'fine' is the exact silence this file is against.
--   * WHY A SNAPSHOT AND NOT A LOG. A feature's latest success and its latest failure are the two facts
--     every reader needs, and the snapshot does not grow with every turn of a node that never prunes.
--     Recording a failure must not erase the success before it, or 'stopped 3 days ago' would be read
--     back as 'never worked'.
--   * STALENESS IS THE FEATURE'S OWN NUMBER, from the registry, never a global. Chat is stale in a day;
--     /undo in a week; the release check in a month. A feature that has never worked is NOT working
--     ('never' is its own verdict) and it is not stale either - it never started.
--
-- The verdicts are the same words everywhere (wa features, /status, wa health, the release step):
--   working  the last event succeeded and it is inside the feature's bound
--   stale    the last event succeeded but is older than the bound
--   failing  the last event failed (its stage and time are named) - nothing newer has succeeded
--   never    nothing has ever been recorded for it on this node
--   off-node the feature's component is not installed here, so this node cannot run it at all
-- A reader that treats off-node or never as working would rebuild the silence, so every renderer prints
-- them, and M.red (what the release step and the notice use) counts them: 'never' on a node that runs
-- the feature is a feature nobody has proven works.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local M = {}

M.SCHEMA = 1
M.REGISTRY_IN_TREE = 'config/features/features.json'
M.STORE = '/feature-health.json'
M.NOTICE = '/feature-health-notice.json'
-- A bound nothing may exceed: a feature past a year is a feature nobody uses, and a row with a bound
-- like that would silence it for good. The ceiling is a rule of this module, not a suggestion.
M.MAX_STALE_S = 365 * 86400

local function getenv(name)
  if type(host.getenv) ~= 'function' then return nil end
  local ok, value = pcall(host.getenv, name)
  if not ok or value == nil or value == '' then return nil end
  return tostring(value)
end

local function read_file(path)
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then return nil end
  return text
end

local function exists(path)
  local ok, value = pcall(host.canonical_path, path)
  return ok and type(value) == 'string' and value ~= ''
end

local function now_seconds(value)
  local now = tonumber(value)
  if not now then
    local ok, clock = pcall(host.now)
    now = ok and tonumber(clock) or nil
  end
  return now or os.time()
end

-- ISO-8601 UTC, whole seconds: the guest's os.date refuses a fractional epoch (event_ledger.lua).
function M.iso(at)
  local seconds = tonumber(at)
  if not seconds then return 'never' end
  return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(seconds))
end

-- A human span: 'just now', '12m', '3h', '2d'. Rounded down, so '1m' is never an exaggeration.
function M.age(seconds)
  local value = tonumber(seconds) or 0
  if value < 60 then return 'just now' end
  if value < 3600 then return string.format('%dm', math.floor(value / 60)) end
  if value < 86400 then return string.format('%dh', math.floor(value / 3600)) end
  return string.format('%dd', math.floor(value / 86400))
end

function M.span(seconds)
  local value = tonumber(seconds) or 0
  if value % 86400 == 0 then return string.format('%dd', value / 86400) end
  if value % 3600 == 0 then return string.format('%dh', value / 3600) end
  if value % 60 == 0 then return string.format('%dm', value / 60) end
  return string.format('%ds', value)
end

-- ------------------------------------------------------------------ where the two files are

-- The registry: an explicit file when a caller names one (WA_FEATURES_FILE, which is how a test drives
-- a fixture), else the copy an install puts in this node's state root, else the tree - the last one only
-- ever resolves when the process runs from a checkout, and M.load says which of them it read, so a node
-- can never be silent about answering from a file nobody deployed.
-- WHERE AN INSTALL PUTS THE LIST, named on its own so a reader (and a test) can write that copy without
-- going through M.registry_path - which answers the TREE until the copy exists, and a caller that wrote
-- "the registry" through it would edit the checkout instead of the node.
function M.installed_registry_path() return paths.config() .. '/features.json' end

function M.registry_path()
  local named = getenv('WA_FEATURES_FILE')
  if named then return named, 'override' end
  local installed = M.installed_registry_path()
  if read_file(installed) then return installed, 'installed' end
  return M.REGISTRY_IN_TREE, 'tree'
end

function M.store_path() return paths.config() .. M.STORE end
function M.notice_path() return paths.config() .. M.NOTICE end

-- ------------------------------------------------------------------ the registry

local function registry_error(where, why) return nil, where .. ': ' .. why end

-- Parse and VALIDATE. A row that is missing a field, or whose bound is not a positive number of
-- seconds, is a refusal that names the row - a feature silently dropped from the list would be exactly
-- the silence this file exists to end, so a broken row fails the whole read instead of being skipped.
function M.parse_registry(text, where)
  local ok, document = pcall(json.decode, text or '')
  if not ok or type(document) ~= 'table' then return registry_error(where, 'the document does not parse as JSON') end
  if tonumber(document.schema) ~= M.SCHEMA then return registry_error(where, 'schema is not ' .. M.SCHEMA) end
  if type(document.features) ~= 'table' then return registry_error(where, 'there is no features array') end
  local rows, seen = {}, {}
  for index, row in ipairs(document.features) do
    if type(row) ~= 'table' then return registry_error(where, 'row ' .. index .. ' is not a table') end
    local name = type(row.name) == 'string' and row.name or nil
    if not name or name == '' then return registry_error(where, 'row ' .. index .. ' has no name') end
    if seen[name] then return registry_error(where, 'the feature ' .. name .. ' is listed twice') end
    seen[name] = true
    for _, field in ipairs({ 'role', 'canary', 'last_success' }) do
      if type(row[field]) ~= 'string' or row[field] == '' then
        return registry_error(where, 'the feature ' .. name .. ' has no ' .. field)
      end
    end
    local bound = tonumber(row.stale_after_s)
    if not bound or bound <= 0 then return registry_error(where, 'the feature ' .. name .. ' has no positive stale_after_s') end
    if bound > M.MAX_STALE_S then
      return registry_error(where, string.format('the feature %s has a stale_after_s of %d, past the %d ceiling', name, bound, M.MAX_STALE_S))
    end
    rows[#rows + 1] = {
      name = name, role = row.role, canary = row.canary, last_success = row.last_success,
      stale_after_s = bound, why = type(row.why) == 'string' and row.why or nil,
    }
  end
  if #rows == 0 then return registry_error(where, 'the features array is empty') end
  return { schema = M.SCHEMA, features = rows, source = where }
end

-- named is for a caller with a registry of its own - a test driving a fixture, a release step reading the
-- list it is about to ship. Absent, the node's own file is resolved as above.
function M.load(named)
  local path, kind = M.registry_path()
  if named then path, kind = named, 'named' end
  local text = read_file(path)
  if not text then return nil, 'the feature registry is not readable: ' .. path end
  local registry, why = M.parse_registry(text, path)
  if not registry then return nil, why end
  registry.path, registry.kind = path, kind
  return registry
end

-- One row by name, or nil plus the reason. The registry is re-read on each call on purpose: a node that
-- just deployed a new list must not answer from the one it started with.
function M.row(name)
  local registry, why = M.load()
  if not registry then return nil, why end
  for _, row in ipairs(registry.features) do
    if row.name == tostring(name) then return row end
  end
  return nil, 'the feature ' .. tostring(name) .. ' is not in the registry'
end

function M.rows()
  local registry, why = M.load()
  if not registry then return nil, why end
  return registry.features, registry
end

-- Can this node run the feature at all? A role that is not 'any' names the component the feature lives
-- in, and a node without that component is not running the feature - which is a fact about this node,
-- not a verdict about the feature, so it is reported as off-node with the component named.
function M.applies(row)
  if not row then return false, 'no row' end
  if row.role == 'any' then return true end
  local component = tostring(row.role):match('^component:(.+)$')
  if not component then return false, 'the role ' .. tostring(row.role) .. ' is not one this module understands' end
  local dir = paths.config() .. '/components/'
  if not exists(dir .. component .. '.json') then return false, component .. ' is not installed on this node' end
  if not exists(dir .. component .. '.wasm') then return false, component .. ' has a definition but no component binary on this node' end
  return true
end

-- ------------------------------------------------------------------ the snapshot

function M.snapshot()
  local text = read_file(M.store_path())
  if not text then return { schema = M.SCHEMA, features = {} }, 'empty' end
  local ok, document = pcall(json.decode, text)
  if not ok or type(document) ~= 'table' then return { schema = M.SCHEMA, features = {} }, 'unreadable' end
  if type(document.features) ~= 'table' then document.features = {} end
  document.schema = M.SCHEMA
  return document, 'read'
end

local function save(snapshot)
  snapshot.schema = M.SCHEMA
  local wrote, err = pcall(host.write_file, M.store_path(), json.encode(snapshot) .. '\n')
  if not wrote or not err then return nil, 'the feature-health snapshot could not be written: ' .. M.store_path() end
  return snapshot
end

-- One event, for the feature named. ok is the success; a failure carries the STAGE it broke at (the
-- brief's 'answers pass/fail with the stage that failed') and never erases the success before it.
-- Answers the entry, or nil plus a named reason - a recorder that cannot write must not look like it did.
function M.record(name, ok, opts)
  opts = opts or {}
  local row, why = M.row(name)
  if not row then return nil, why end
  local snapshot = M.snapshot()
  local slot = snapshot.features[tostring(name)] or {}
  local at = now_seconds(opts.at)
  if ok then
    slot.last_ok_at = at
    slot.last_ok_source = tostring(opts.source or 'record')
    slot.last_ok_detail = opts.detail and tostring(opts.detail) or nil
  else
    slot.last_fail_at = at
    slot.last_fail_stage = tostring(opts.stage or 'unknown_stage')
    slot.last_fail_detail = opts.detail and tostring(opts.detail) or nil
  end
  snapshot.features[tostring(name)] = slot
  local saved, err = save(snapshot)
  if not saved then return nil, err end
  return slot
end

local function entry_of(snapshot, name) return (snapshot.features or {})[name] end

-- The verdict for one row and its entry, in the five words the header names.
function M.verdict(row, entry, now)
  now = now_seconds(now)
  if not entry or (not entry.last_ok_at and not entry.last_fail_at) then
    return 'never', 'nothing has been recorded for it on this node'
  end
  local failed = entry.last_fail_at and (not entry.last_ok_at or tonumber(entry.last_fail_at) >= tonumber(entry.last_ok_at))
  if failed then
    return 'failing', string.format('last failed at %s (stage %s)%s', M.iso(entry.last_fail_at), tostring(entry.last_fail_stage or 'unknown'),
      entry.last_ok_at and ('; last worked ' .. M.iso(entry.last_ok_at)) or '; it has never worked')
  end
  local age = now - (tonumber(entry.last_ok_at) or now)
  if age < 0 then age = 0 end
  if age > row.stale_after_s then
    return 'stale', string.format('last worked %s ago (%s), past its bound of %s', M.age(age), M.iso(entry.last_ok_at), M.span(row.stale_after_s))
  end
  -- 'just now' is already an adverb: 'last worked just now ago' is the kind of sentence a reader trips on.
  local when = M.age(age)
  return 'working', when == 'just now' and 'last worked just now' or string.format('last worked %s ago', when)
end

-- Every feature, its row, its entry and its verdict, in registry order. 'applies' decides between a
-- verdict and off-node; nothing here hides a feature, so a reader sees the whole list on any node.
function M.report(now)
  now = now_seconds(now)
  local rows, why = M.rows()
  if not rows then return nil, why end
  local snapshot = M.snapshot()
  local out = {}
  for _, row in ipairs(rows) do
    local entry = entry_of(snapshot, row.name)
    local applies, not_applicable = M.applies(row)
    local verdict, detail = M.verdict(row, entry, now)
    if not applies then verdict, detail = 'off-node', not_applicable end
    out[#out + 1] = {
      name = row.name, role = row.role, canary = row.canary, stale_after_s = row.stale_after_s,
      applies = applies, verdict = verdict, detail = detail,
      last_ok_at = entry and tonumber(entry.last_ok_at) or nil,
      last_ok_source = entry and entry.last_ok_source or nil,
      last_fail_at = entry and tonumber(entry.last_fail_at) or nil,
      last_fail_stage = entry and entry.last_fail_stage or nil,
    }
  end
  return out
end

-- What has stopped, and the reason in one line each: what the release step refuses on and what the
-- notice speaks about. 'never' counts only where the node runs the feature; off-node never counts.
function M.red(now)
  local rows, why = M.report(now)
  if not rows then return nil, why end
  local out = {}
  for _, item in ipairs(rows) do
    if item.verdict == 'failing' or item.verdict == 'stale' or item.verdict == 'never' then out[#out + 1] = item end
  end
  return out
end

-- The /status and wa features rows: a summary line and one line per feature. Every feature appears,
-- with the time it last worked - which is Victor's own test of this feature ('wa health lists every
-- feature with last worked: <time>').
function M.lines(now)
  local rows, why = M.report(now)
  if not rows then return { 'features: unreadable (' .. tostring(why) .. ')' } end
  local counts = { working = 0, stale = 0, failing = 0, never = 0, ['off-node'] = 0 }
  local width = 0
  for _, item in ipairs(rows) do counts[item.verdict] = (counts[item.verdict] or 0) + 1; width = math.max(width, #item.name) end
  local summary = string.format('features: %d listed  %d working  %d stale  %d failing  %d never  %d off-node',
    #rows, counts.working, counts.stale, counts.failing, counts.never, counts['off-node'])
  local out = { summary }
  for _, item in ipairs(rows) do
    -- WHAT KIND OF SUCCESS IT WAS, in the same line as when it happened. Until real-traffic hooks land, most
    -- rows are proven by their CANARY, and a synthetic pass read as real use is exactly the false comfort
    -- this mission is against (Fable, 23/11). A canary-sourced time is therefore labelled; a hook's is not.
    local last = item.last_ok_at and M.iso(item.last_ok_at) or 'never'
    local kind = item.last_ok_source == 'canary' and '  [canary]' or ''
    out[#out + 1] = string.format('  %-' .. width .. 's  %-9s  last worked: %s%s  (%s)',
      item.name, item.verdict, last, kind, item.detail)
  end
  return out
end

return M
