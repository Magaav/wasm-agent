-- Per-node state.
--
-- State belongs to a *node*, not to a machine: two nodes on one box (a host and
-- a test peer, or a future multi-tenant install) must not share their provider
-- selection or their spells. Everything is keyed by node_id under
-- ~/.wasm-agent/nodes/<node_id>/, with the legacy flat files as a read
-- fallback so existing selections survive the move.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function base()
  return dofile("lua/core/paths.lua").config()
end

local function node_id()
  local ok, raw = pcall(host.node_identity)
  if not ok or not raw then return nil end
  local identity = json.decode(raw)
  return identity and identity.node_id or nil
end

function M.dir()
  local id = node_id()
  if id then return base() .. "/nodes/" .. id end
  return base()
end

function M.path(name)
  return M.dir() .. "/" .. name
end

local function clean(text)
  if not text or text == "" then return nil end
  local value = text:gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return nil end
  return value
end

local function legacy_read(name)
  for _, dir in ipairs({ M.dir(), base() }) do
    if host.read_file then
      local value = clean(host.read_file(dir .. "/" .. name))
      if value then return value end
    end
  end
  return nil
end

local function selection_key(name)
  return name == 'provider' or name:match('^model%.') or name:match('^reasoning%.')
end

local function sql(verb, statement, params)
  local result = host[verb](statement, json.encode(params or {}))
  if type(result) == 'string' then result = json.decode(result) end
  if type(result) ~= 'table' or result.error then error('selection_store: ' .. tostring(result and result.error)) end
  return result
end

local frozen, writing, ready
local function setup()
  if ready then return end
  sql('sql_exec', 'CREATE TABLE IF NOT EXISTS node_selection(node TEXT PRIMARY KEY,revision INTEGER NOT NULL,selections TEXT NOT NULL)')
  ready = true
end
function M.snapshot()
  -- Capability-free fixtures retain the old file contract. A present but broken
  -- database is an error, never a silent fallback to another settings authority.
  if not host.sql_query then return {revision=0, values={}} end
  setup()
  local rows = sql('sql_query', 'SELECT revision,selections FROM node_selection WHERE node=?', {M.dir()})
  local row = rows[1]
  return {revision=row and row.revision or 0, values=row and json.decode(row.selections) or {}}
end

function M.with_snapshot(fn)
  if frozen then return fn() end
  frozen = M.snapshot()
  local ok, result = pcall(fn)
  frozen = nil
  if not ok then error(result) end
  return result
end

function M.revision() return (frozen or M.snapshot()).revision end

function M.read(name)
  if selection_key(name) and host.sql_query then
    local snapshot = frozen or M.snapshot()
    if snapshot.values[name] ~= nil then return clean(snapshot.values[name]) end
  end
  return legacy_read(name)
end

-- Validation and the write share SQLite's writer lock across all interpreters.
-- Optional CAS prevents an old window's model choice applying to a new provider.
function M.mutate(fn, expected_revision)
  if not host.sql_query then return fn() end
  setup()
  sql('sql_exec', 'BEGIN IMMEDIATE')
  local old = frozen
  local ok, result = pcall(function()
    frozen = M.snapshot()
    if expected_revision ~= nil and tonumber(expected_revision) ~= tonumber(frozen.revision) then
      return {ok=false, error='settings_conflict'}
    end
    writing = true
    return fn()
  end)
  writing = nil
  frozen = old
  if not ok then pcall(sql, 'sql_exec', 'ROLLBACK'); error(result) end
  sql('sql_exec', 'COMMIT')
  return result
end

function M.write(name, value)
  if selection_key(name) and host.sql_query then
    if not writing then return M.mutate(function() M.write(name, value); return true end) end
    frozen.values[name] = value or ''
    frozen.revision = tonumber(frozen.revision) + 1
    sql('sql_exec', 'INSERT INTO node_selection(node,revision,selections) VALUES(?,?,?) ON CONFLICT(node) DO UPDATE SET revision=excluded.revision,selections=excluded.selections',
      {M.dir(), frozen.revision, json.encode(frozen.values)})
    return true
  end
  if host.write_file then return host.write_file(M.path(name), value) end
end

return M
