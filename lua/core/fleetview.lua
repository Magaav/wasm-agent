-- fleetview: one read-only call that answers every node of the fabric at once (docs/FLEET-OPS.md).
--
-- The tool answers: per node, whether it is online and when it was last seen, its version and source
-- commit, its health, its disk, the components it runs and the features they carry, the operations and
-- jobs currently running, and recent incidents from telemetry and the lessons store. Nothing here
-- changes anything: this file has no write path, no `host.exec`, no restart and no deploy. A caller
-- cannot ask it to act.
--
-- Two rules shape the shape of the answer:
--
-- * **Unknown is named, never faked.** Every field a node could not answer is listed in that node's
--   `missing` array and left absent. A zero disk, a `last_seen` of now for a peer nobody heard from,
--   or a `health: "ok"` for a node whose health was never read would all be misleading results - the
--   exact failure mode the operating habits warn about (`lua/core/habits.lua`).
-- * **No message text, ever.** An incident carries an id, a source, a time, a kind and a lesson's own
--   rule/symptom sentence. Channel and transcript text is not a fleet fact and never enters here.
--
-- `M.assemble(observations)` is pure: it takes what a collector saw and builds the view. The tests use
-- it to build a three-node local fabric without a network; `M.collect()` is the live collector.
local json = dofile('lua/vendor/json.lua')

local M = {}

M.VERSION = 1
M.SCHEMA = 'fleetview.v1'
M.READ_ONLY = true
-- Bounds: one call must stay readable. These trim lists, and a trimmed list says `truncated`.
M.MAX_NODES = 64
M.MAX_COMPONENTS = 40
M.MAX_OPERATIONS = 25
M.MAX_INCIDENTS = 5
M.DISK_DEGRADED_PERCENT = 90

-- The fields every node record answers (or names as missing). The test asserts this exact list, so a
-- field cannot be dropped from the answer by accident.
M.FIELDS = {
  'online', 'last_seen_ms', 'role', 'version', 'commit', 'health', 'disk',
  'components', 'features', 'operations', 'jobs', 'incidents',
}

local function trim(text, limit)
  local value = tostring(text or '')
  if #value <= limit then return value end
  return value:sub(1, limit) .. '…'
end

local function number_or_nil(value)
  local number = tonumber(value)
  if number == nil or number ~= number then return nil end
  return number
end

local function list_of(value)
  return type(value) == 'table' and value or nil
end

local function sorted_unique(names)
  local seen, out = {}, {}
  for _, name in ipairs(names or {}) do
    local text = tostring(name or '')
    if text ~= '' and not seen[text] then
      seen[text] = true
      out[#out + 1] = text
    end
  end
  table.sort(out)
  return out
end

-- A component row as the view reports it: what it is called, whether it is enabled, what state it is
-- in, and the features (tools/verbs) it carries. A component the registry knows but the runtime does
-- not have running reports `state: "not_running"` - which is a fact, not an outage.
local function component_row(entry)
  if type(entry) ~= 'table' then return nil end
  local live = type(entry.live) == 'table' and entry.live or {}
  local definition = type(entry.definition) == 'table' and entry.definition or {}
  local features = definition.features or live.features or entry.features
  return {
    name = tostring(entry.name or definition.name or ''),
    enabled = entry.enabled == true,
    state = tostring(live.state or entry.state or 'unknown'),
    features = sorted_unique(list_of(features)),
  }
end

local function operation_row(entry)
  if type(entry) ~= 'table' then return nil end
  local id = entry.id or entry.operation_id
  if id == nil then return nil end
  return {
    id = tostring(id),
    state = tostring(entry.state or 'unknown'),
    kind = entry.kind and tostring(entry.kind) or nil,
    started_at = number_or_nil(entry.started_at or entry.started_ms),
    owner = entry.owner and trim(entry.owner, 120) or nil,
  }
end

-- Health is a judgement with its reasons attached, so a reader can disagree with it. `unknown` is the
-- only honest answer when nothing was read.
local function health_of(observation)
  local reported = type(observation.health) == 'table' and observation.health or nil
  local reasons = {}
  for _, reason in ipairs((reported and list_of(reported.reasons)) or {}) do
    reasons[#reasons + 1] = trim(reason, 200)
  end
  local disk = observation.resources and observation.resources.disk or nil
  local used = disk and number_or_nil(disk.used_percent) or nil
  if used and used >= M.DISK_DEGRADED_PERCENT then
    reasons[#reasons + 1] = 'disk used ' .. string.format('%.1f', used) .. '%'
  end
  if reported and reported.state then
    local state = tostring(reported.state)
    if #reasons > 0 and state == 'ok' then state = 'degraded' end
    return { state = state, source = trim(reported.source or 'reported', 60), reasons = #reasons > 0 and reasons or nil }
  end
  if #reasons > 0 then return { state = 'unknown', source = 'local_resources', reasons = reasons } end
  return nil
end

local function disk_of(observation)
  local disk = observation.resources and observation.resources.disk or nil
  if type(disk) ~= 'table' then return nil end
  local available = number_or_nil(disk.available_bytes)
  local total = number_or_nil(disk.total_bytes)
  local used = number_or_nil(disk.used_percent)
  if available == nil and total == nil and used == nil then return nil end
  return { available_bytes = available, total_bytes = total, used_percent = used }
end

-- One incident row. `summary` is a lesson's own sentence or a telemetry class name - never a message
-- body, a prompt or a credential.
local function incident_row(entry, fallback_source)
  if type(entry) ~= 'table' then return nil end
  local summary = entry.rule or entry.symptom or entry.summary or entry.kind
  if summary == nil then return nil end
  return {
    id = tostring(entry.id or ''),
    source = tostring(entry.source or fallback_source or 'unknown'),
    at = number_or_nil(entry.at),
    kind = entry.kind and tostring(entry.kind) or nil,
    summary = trim(summary, 400),
  }
end

-- The view of one node. Every field that is absent is named in `missing`.
function M.node(observation, opts)
  opts = opts or {}
  observation = type(observation) == 'table' and observation or {}
  local missing = {}
  local row = {
    name = tostring(observation.name or observation.node_id or 'unnamed'),
    node_id = tostring(observation.node_id or observation.id or 'unknown'),
    role = tostring(observation.role or 'unknown'),
    local_node = observation.local_node == true,
  }
  local function present(field, value)
    if value == nil then
      missing[#missing + 1] = field
      return nil
    end
    return value
  end

  local online = nil
  if type(observation.online) == 'boolean' then online = observation.online end
  row.online = present('online', online)
  local last_seen = number_or_nil(observation.last_seen_ms or observation.last_seen)
  -- A rendezvous reports last_seen in seconds; a local node reports its own clock in milliseconds.
  if last_seen and last_seen < 100000000000 then last_seen = last_seen * 1000 end
  if last_seen then
    row.last_seen_ms = last_seen
    local now = number_or_nil(opts.now_ms) or number_or_nil(observation.now_ms)
    if now then row.last_seen_age_s = math.max(0, math.floor((now - last_seen) / 1000)) end
  else
    missing[#missing + 1] = 'last_seen_ms'
  end
  row.version = present('version', observation.version and tostring(observation.version) or nil)
  row.commit = present('commit', observation.commit and tostring(observation.commit) or nil)

  local health = health_of(observation)
  if not health then
    missing[#missing + 1] = 'health'
  end
  row.health = health
  if not row.health and observation.health_reason then
    row.health = { state = 'unknown', source = 'collector', reasons = { trim(observation.health_reason, 200) } }
  end

  local disk = disk_of(observation)
  row.disk = present('disk', disk)

  local components, features = {}, {}
  for _, entry in ipairs(list_of(observation.components) or {}) do
    local component = component_row(entry)
    if component then
      components[#components + 1] = component
      for _, feature in ipairs(component.features) do features[#features + 1] = feature end
    end
  end
  for _, feature in ipairs(list_of(observation.features) or {}) do features[#features + 1] = tostring(feature) end
  if type(observation.components) ~= 'table' then
    missing[#missing + 1] = 'components'
  else
    row.components = components
    if #components > M.MAX_COMPONENTS then
      row.components = {}
      for index = 1, M.MAX_COMPONENTS do row.components[index] = components[index] end
      row.components_truncated = #components
    end
  end
  row.features = sorted_unique(features)
  if #row.features == 0 and type(observation.capabilities) == 'table' then
    row.features = sorted_unique(observation.capabilities)
  end

  local operations = {}
  for _, entry in ipairs(list_of(observation.operations) or {}) do
    local operation = operation_row(entry)
    if operation then operations[#operations + 1] = operation end
  end
  if type(observation.operations) ~= 'table' then
    missing[#missing + 1] = 'operations'
  else
    row.operations = operations
    if #operations > M.MAX_OPERATIONS then
      row.operations = {}
      for index = 1, M.MAX_OPERATIONS do row.operations[index] = operations[index] end
      row.operations_truncated = #operations
    end
  end

  local jobs = {}
  for _, entry in ipairs(list_of(observation.jobs) or {}) do
    local job = operation_row(entry)
    if job then jobs[#jobs + 1] = job end
  end
  row.jobs = present('jobs', type(observation.jobs) == 'table' and jobs or nil)

  local incidents = {}
  for _, entry in ipairs(list_of(observation.incidents) or {}) do
    local incident = incident_row(entry, 'telemetry')
    if incident then incidents[#incidents + 1] = incident end
  end
  table.sort(incidents, function(a, b) return (a.at or 0) > (b.at or 0) end)
  if #incidents > M.MAX_INCIDENTS then
    row.incidents_truncated = #incidents
    local kept = {}
    for index = 1, M.MAX_INCIDENTS do kept[index] = incidents[index] end
    incidents = kept
  end
  row.incidents = incidents

  if #missing > 0 then row.missing = missing end
  return row
end

-- Does a lesson name this node? Its tags are the node's name or id, or its symptom/rule text
-- mentions the name. A lesson that names no node belongs to the whole fleet.
local function rows_mentions(lesson, row)
  local names = { tostring(row.name):lower(), tostring(row.node_id):lower() }
  for _, tag in ipairs(list_of(lesson.tags) or {}) do
    for _, name in ipairs(names) do
      if name ~= '' and tostring(tag):lower() == name then return true end
    end
  end
  for _, name in ipairs(names) do
    if name ~= '' and #name > 3 then
      local text = tostring(lesson.symptom or ''):lower() .. ' ' .. tostring(lesson.rule or ''):lower()
      if text:find(name, 1, true) then return true end
    end
  end
  return false
end

-- The whole view: the local node first (it is the one doing the looking), then peers by name, so two
-- runs over the same fabric answer in the same order.
function M.assemble(observations, opts)
  opts = opts or {}
  local rows = {}
  for _, observation in ipairs(list_of(observations) or {}) do
    rows[#rows + 1] = M.node(observation, opts)
  end
  -- The lessons store is fleet-wide knowledge, not a per-node telemetry row: a lesson that names a
  -- node is reported on that node, a lesson that names none is reported everywhere.
  local lessons = list_of(opts.lessons) or {}
  for _, lesson in ipairs(lessons) do
    local named = nil
    for _, row in ipairs(rows) do
      if rows_mentions(lesson, row) then
        named = named or {}
        named[row.node_id] = true
      end
    end
    for _, row in ipairs(rows) do
      if named == nil or named[row.node_id] then
        local merged, seen = {}, {}
        for _, incident in ipairs(row.incidents or {}) do
          seen[incident.id] = true
          merged[#merged + 1] = incident
        end
        local incident = incident_row({ id = lesson.id, source = 'lesson', at = lesson.at,
          kind = 'lesson', summary = lesson.rule }, 'lesson')
        if incident and not seen[incident.id] then merged[#merged + 1] = incident end
        table.sort(merged, function(a, b) return (a.at or 0) > (b.at or 0) end)
        while #merged > M.MAX_INCIDENTS do table.remove(merged) end
        row.incidents = merged
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.local_node ~= b.local_node then return a.local_node end
    if a.name ~= b.name then return a.name < b.name end
    return a.node_id < b.node_id
  end)
  local nodes = {}
  for index_row, row in ipairs(rows) do
    if index_row > M.MAX_NODES then
      break
    end
    nodes[#nodes + 1] = row
  end
  local missing_total = 0
  for _, row in ipairs(nodes) do missing_total = missing_total + #(row.missing or {}) end
  return {
    schema = M.SCHEMA,
    generated_at = number_or_nil(opts.now_ms) or math.floor((host.now() or 0) * 1000),
    read_only = true,
    count = #nodes,
    nodes = nodes,
    missing_total = missing_total,
    note = 'Unknown fields are listed in each node\'s `missing` and left absent: an empty value here is '
      .. 'never a zero. Read-only: this call changes nothing.',
  }
end

-- ---- the live collector -------------------------------------------------------------------------

local function decode(value)
  if type(value) ~= 'string' then return nil end
  local ok, decoded = pcall(json.decode, value)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

local function try(fn, ...)
  local ok, value = pcall(fn, ...)
  if not ok then return nil, tostring(value) end
  return value, nil
end

-- What this node can say about itself: identity and build, resources (disk included), components,
-- operations and jobs. Each source is independent, and one that fails is a named reason on the field,
-- not a failed view.
function M.local_observation(opts)
  opts = opts or {}
  local observation = { local_node = true, online = true }
  local runtime = host.runtime_info and decode((try(host.runtime_info)) or nil) or nil
  if runtime then
    observation.version = runtime.version
    observation.commit = runtime.build_source_commit ~= '' and runtime.build_source_commit or nil
    observation.health = { state = 'ok', source = 'runtime_info' }
  else
    observation.health_reason = 'runtime_info_unavailable'
  end
  local resources = host.system_resources and decode((try(host.system_resources)) or nil) or nil
  if resources then
    observation.resources = resources
  else
    observation.health_reason = observation.health_reason or 'system_resources_unavailable'
  end
  local ok, services = pcall(function()
    return dofile('lua/core/services.lua').inventory()
  end)
  if ok and type(services) == 'table' and not services.error then
    observation.components = services.services or {}
  end
  if type(host.operation) == 'function' then
    local operations = decode((try(host.operation, 'status', '{}')) or nil)
    if type(operations) == 'table' then
      observation.operations = operations.operations or operations.list or (operations[1] and operations) or {}
    end
  end
  if type(host.jobs) == 'function' then
    local jobs = decode((try(host.jobs, 'list', '{}')) or nil)
    if type(jobs) == 'table' then
      observation.jobs = jobs.jobs or jobs.list or (jobs[1] and jobs) or {}
    end
  end
  return observation
end

-- A peer as the rendezvous registry knows it. The registry carries identity, reachability and the last
-- advisory sample - not health, components or running work, and it must not pretend to: those stay
-- `missing` until a peer read is added (docs/FLEET-OPS.md), which is why they are listed by name.
function M.peer_observation(node)
  local observation = {
    name = node.name, node_id = node.node_id or node.id, role = node.role,
    local_node = false, online = node.online == true, last_seen_ms = node.last_seen,
    resources = node.resources, capabilities = node.capabilities,
  }
  observation.health_reason = node.online == true and 'peer_read_not_performed' or 'peer_offline_no_sample'
  return observation
end

-- Recent incidents from this node's telemetry: unsettled operations and resource claims are the two
-- facts a fleet view can state without reading anyone's transcript.
function M.telemetry_incidents(opts)
  opts = opts or {}
  local out = {}
  if type(host.operation) == 'function' then
    local operations = decode((try(host.operation, 'status', '{}')) or nil) or {}
    for _, entry in ipairs(type(operations) == 'table' and (operations.operations or operations.list or {}) or {}) do
      local state = tostring(type(entry) == 'table' and entry.state or '')
      if state == 'failed' or state == 'unknown' or state == 'cancelled' then
        out[#out + 1] = { id = tostring(entry.id or ''), source = 'telemetry', at = tonumber(entry.finished_at or entry.started_at),
          kind = 'operation_' .. state, summary = 'operation ' .. tostring(entry.id or '?') .. ' settled as ' .. state }
      end
    end
  end
  local ok, resources = pcall(function() return dofile('lua/core/resources.lua').inspect() end)
  if ok and type(resources) == 'table' then
    for _, claim in ipairs(resources.claims or {}) do
      if tostring(claim.state or '') == 'uncertain' or tostring(claim.state or '') == 'unknown' then
        out[#out + 1] = { id = tostring(claim.key or claim.id or ''), source = 'telemetry',
          at = tonumber(claim.at or claim.updated_at), kind = 'resource_unknown',
          summary = 'resource claim ' .. tostring(claim.key or claim.id or '?') .. ' is unresolved' }
      end
    end
  end
  return out
end

-- Collect the whole fabric and answer the view, ready for the tool.
function M.view(opts)
  opts = opts or {}
  local observations = {}
  local local_observation = M.local_observation(opts)
  observations[#observations + 1] = local_observation
  local ok, list = pcall(function() return dofile('lua/core/nodes.lua').list() end)
  if ok and type(list) == 'table' then
    for _, node in ipairs(list) do
      if node.local_node ~= true then observations[#observations + 1] = M.peer_observation(node) end
    end
  end
  local incidents = M.telemetry_incidents(opts)
  for _, observation in ipairs(observations) do
    if observation.local_node == true then observation.incidents = incidents end
  end
  local view = M.assemble(observations, { now_ms = opts.now_ms, lessons = opts.lessons })
  -- `local` is a keyword: the key is quoted so the table can say what it means.
  view.sources = { nodes = 'registry', ['local'] = 'runtime_info', incidents = 'telemetry+lessons' }
  return view
end

return M
