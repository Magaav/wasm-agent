-- Users and roles. A role decides which tools the agent may call.
--
--   master  full access: code, shell, files, client control, memory, plugins.
--   guest   on-demand memory only (remember/recall) plus spells.
--
-- `admin` is accepted as a legacy alias for `master`.
-- Stored at ~/.wasm-agent/users.json (created on first run).
local json = dofile("lua/vendor/json.lua")
local M = {}

-- Credentials are shared by every interpreter in this node, not stored in a Lua
-- module-local table. Otherwise a guest login on one worker becomes an unknown
-- token on another worker and used to fall back to the default master.
local schema_ready = false
local function sql(method, statement, params)
  if not host[method] then error("authentication_store_unavailable", 2) end
  local raw = host[method](statement, json.encode(params or {}))
  local result = type(raw) == "string" and json.decode(raw) or raw
  if type(result) ~= "table" or result.error then error("authentication_store_failed", 2) end
  return result
end
local function prepare()
  if schema_ready then return end
  sql("sql_exec", [[CREATE TABLE IF NOT EXISTS auth_sessions (
    token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, node_id TEXT NOT NULL,
    created_at REAL NOT NULL, expires_at REAL NOT NULL
  )]])
  schema_ready = true
end
local function identity()
  local raw = host.node_identity()
  local value = type(raw) == "string" and json.decode(raw) or raw
  if type(value) ~= "table" or type(value.node_id) ~= "string" or value.node_id == "" then
    error("authentication_identity_unavailable", 2)
  end
  return value.node_id
end

local function path()
  return dofile("lua/core/paths.lua").config() .. "/users.json"
end

local DEFAULT = {
  users = {
    { id = "master", name = "master", role = "master" },
    { id = "guest", name = "guest", role = "guest" },
  },
  default_user = "master",
}

function M.normalize(role)
  if role == "admin" then return "master" end
  return role or "guest"
end

function M.is_master(role)
  return M.normalize(role) == "master"
end

function M.load()
  -- Re-read role changes/revocations; a warm worker must not retain old authority.
  local text = host.read_file and host.read_file(path())
  if text ~= nil then
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.users) == "table" then
      return decoded
    end
    error("users_config_invalid", 2)
  end
  if host.write_file then host.write_file(path(), json.encode(DEFAULT)) end
  return DEFAULT
end

function M.list() return M.load().users end

function M.find(id)
  for _, user in ipairs(M.list()) do
    if user.id == id then return user end
  end
  -- `admin` maps onto the master account.
  if id == "admin" then
    for _, user in ipairs(M.list()) do
      if M.normalize(user.role) == "master" then return user end
    end
  end
  return nil
end

-- The user used when no session is presented (local-first default).
function M.default_user()
  return M.find(M.load().default_user) or M.list()[1]
end

function M.login(id)
  local user = M.find(id)
  if not user then return nil, "unknown_user" end
  prepare()
  local session = host.uuid() .. host.uuid()
  local now = host.now()
  local ttl = tonumber(host.getenv("WASM_AGENT_AUTH_TTL_SECONDS")) or 86400
  ttl = math.min(2592000, math.max(60, ttl))
  sql("sql_exec", "DELETE FROM auth_sessions WHERE expires_at<=?", {now})
  sql("sql_exec", "INSERT INTO auth_sessions(token_hash,user_id,node_id,created_at,expires_at) VALUES(?,?,?,?,?)",
    {host.sha256(session), user.id, identity(), now, now + ttl})
  return session, user
end

function M.logout(session)
  if type(session) ~= "string" or session == "" then return end
  prepare()
  sql("sql_exec", "DELETE FROM auth_sessions WHERE token_hash=? AND node_id=?", {host.sha256(session), identity()})
end

-- An empty credential preserves the trusted local account-switching surface. This
-- is NOT remote password authentication. A supplied but invalid/expired/revoked
-- credential must NEVER resolve as that default account.
function M.resolve(session)
  local user
  if session == nil or session == "" then
    user = M.default_user()
  else
    if type(session) ~= "string" or #session > 512 then return nil, "invalid_session" end
    prepare()
    local rows = sql("sql_query", "SELECT user_id FROM auth_sessions WHERE token_hash=? AND node_id=? AND expires_at>?",
      {host.sha256(session), identity(), host.now()})
    user = rows[1] and M.find(rows[1].user_id) or nil
    if not user then return nil, "invalid_session" end
  end
  if not user then return nil, "unknown_user" end
  return { id = user.id, name = user.name, role = M.normalize(user.role) }
end

function M.current(session)
  local user, problem = M.resolve(session)
  if not user then error(problem, 2) end
  return user
end

function M.public(user)
  if not user then return nil end
  return { id = user.id, name = user.name, role = M.normalize(user.role) }
end

return M
