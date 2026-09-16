-- Users and roles. A role decides which tools the agent may call.
--
--   admin  full access: code, shell, files, client control, memory, plugins.
--   guest  on-demand memory only (remember/recall) plus future "spells".
--
-- Stored at ~/.wasm-agent/users.json (created on first run).
local json = dofile("lua/vendor/json.lua")
local M = {}

local sessions = {}
local cache = nil

local function path()
  return (os.getenv("HOME") or ".") .. "/.wasm-agent/users.json"
end

local DEFAULT = {
  users = {
    { id = "admin", name = "admin", role = "admin" },
    { id = "guest", name = "guest", role = "guest" },
  },
  default_user = "admin",
}

function M.load()
  if cache then return cache end
  local text = host.read_file and host.read_file(path())
  if text and text ~= "" then
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.users) == "table" then
      cache = decoded
      return cache
    end
  end
  cache = DEFAULT
  if host.write_file then host.write_file(path(), json.encode(DEFAULT)) end
  return cache
end

function M.list() return M.load().users end

function M.find(id)
  for _, user in ipairs(M.list()) do
    if user.id == id then return user end
  end
  return nil
end

-- The user used when no session is presented (local-first default).
function M.default_user()
  return M.find(M.load().default_user) or M.list()[1]
end

function M.login(id)
  local user = M.find(id)
  if not user then return nil end
  local session = host.uuid()
  sessions[session] = user.id
  return session, user
end

function M.logout(session)
  sessions[session] = nil
end

function M.current(session)
  local id = session and sessions[session] or nil
  if id then
    local user = M.find(id)
    if user then return user end
  end
  return M.default_user()
end

function M.public(user)
  if not user then return nil end
  return { id = user.id, name = user.name, role = user.role }
end

return M
