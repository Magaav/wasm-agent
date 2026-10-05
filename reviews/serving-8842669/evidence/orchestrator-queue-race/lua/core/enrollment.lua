-- Explicit, expiring customer consent. Registry discovery is not authority.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local M = {}
function M.managed() return host.getenv('WASM_AGENT_MANAGED') == '1' end
function M.path() return paths.config() .. '/enrollment.json' end
function M.profile(include_inactive)
  if not M.managed() then return nil, 'not_managed' end
  local raw = host.read_file(M.path())
  local ok, p = pcall(json.decode, raw or '')
  if not ok or type(p) ~= 'table' or p.schema ~= 1 or type(p.operators) ~= 'table'
      or type(p.service) ~= 'string' then return nil, 'invalid_enrollment' end
  if not include_inactive then
    if p.active ~= true then return nil, 'access_revoked' end
    if not tonumber(p.expires_at) or tonumber(p.expires_at) <= host.now() then return nil, 'access_expired' end
  end
  return p
end
function M.role()
  -- Revoking assistance must not take an already promoted owner's local agency away.
  local p = M.profile(true)
  return p and p.local_role == 'master' and 'master' or 'guest'
end
local function get(url, headers)
  local ok, raw = pcall(host.http, 'GET', url, json.encode(headers or {}), '')
  if not ok then return nil end
  local parsed, reply = pcall(json.decode, raw or '')
  if not parsed or type(reply) ~= 'table' or tonumber(reply.status) ~= 200 then return nil end
  local decoded, value = pcall(json.decode, reply.body or '')
  return decoded and type(value) == 'table' and value or nil
end
function M.caller(id, key)
  local p = M.profile()
  if not p then return nil end
  local pinned = false
  for _, operator in ipairs(p.operators) do
    if operator.node_id == id and operator.public_key == key then pinned = true end
  end
  if not pinned then return nil end
  -- Fresh service authority, not an indefinitely cached registration list.
  local service = get(p.service .. '/service')
  if not service or service.protocol ~= 1 or not service.enrollment_ready then return nil end
  for _, operator in ipairs(service.operators or {}) do
    if operator.node_id == id and operator.public_key == key then
      return { node_id = id, public_key = key, name = operator.name or id, role = 'master' }
    end
  end
  return nil
end
function M.author(caller)
  local p = M.profile()
  if not p or type(caller) ~= 'table' then return nil end
  for _, operator in ipairs(p.operators) do
    if operator.node_id == caller.node_id and operator.public_key == caller.public_key then
      return caller.node_id -- attribution is stable even if the display name changes
    end
  end
end
local function exec(sql, params)
  local result = json.decode(host.sql_exec(sql, json.encode(params or {})))
  if result and result.error then error(result.error) end
  return result
end
function M.seen_before(id)
  exec('CREATE TABLE IF NOT EXISTS access_requests (id TEXT PRIMARY KEY, at REAL)')
  exec('DELETE FROM access_requests WHERE at < ?', { host.now() - 300 })
  local result = exec('INSERT OR IGNORE INTO access_requests VALUES(?,?)', { host.sha256(id), host.now() })
  return result.changes == 0
end
function M.events()
  exec('CREATE TABLE IF NOT EXISTS access_events (id TEXT PRIMARY KEY, at REAL, caller TEXT, capability TEXT, state TEXT)')
  return { events = json.decode(host.sql_query('SELECT * FROM access_events ORDER BY at DESC LIMIT 100', '[]')) }
end
function M.audit(caller, capability, state)
  exec('CREATE TABLE IF NOT EXISTS access_events (id TEXT PRIMARY KEY, at REAL, caller TEXT, capability TEXT, state TEXT)')
  exec('INSERT INTO access_events VALUES(?,?,?,?,?)', { host.uuid(), host.now(), caller.node_id, capability, state })
end
function M.target(request)
  local identity = json.decode(host.node_identity())
  return request.to_node_id == identity.node_id
end
function M.set_role(role)
  if role ~= 'master' and role ~= 'guest' then return { error = 'invalid_role' } end
  local p, problem = M.profile()
  if not p then return { error = problem } end
  local identity = json.decode(host.node_identity())
  local ts = tostring(math.floor(host.now()))
  local signed = json.decode(host.sign('lookup|' .. identity.node_id .. '|' .. ts))
  local record = get(p.service .. '/lookup?node_id=' .. identity.node_id, {
    ['x-wa-node'] = identity.node_id, ['x-wa-pub'] = identity.public_key,
    ['x-wa-ts'] = ts, ['x-wa-sig'] = signed.signature,
  })
  if not record or record.public_key ~= identity.public_key or record.role ~= role then
    return { error = 'network_role_not_granted' }
  end
  p.local_role = role
  if not host.write_file(M.path(), json.encode(p)) then return { error = 'role_write_failed' } end
  return { ok = true, role = role, node_id = identity.node_id }
end
function M.status()
  local p, problem = M.profile()
  local registered, attached = false, false
  if p then
    local identity = json.decode(host.node_identity())
    local ts = tostring(math.floor(host.now()))
    local signed = json.decode(host.sign('lookup|' .. identity.node_id .. '|' .. ts))
    local record = get(p.service .. '/lookup?node_id=' .. identity.node_id, {
      ['x-wa-node']=identity.node_id, ['x-wa-pub']=identity.public_key,
      ['x-wa-ts']=ts, ['x-wa-sig']=signed.signature,
    })
    registered = record ~= nil and record.public_key == identity.public_key and record.online == true
    attached = registered and record.relay_attached == true
  end
  return { managed = M.managed(), active = p ~= nil, error = problem, registered = registered, attached = attached,
    role = M.role(), expires_at = p and p.expires_at or nil }
end
return M
