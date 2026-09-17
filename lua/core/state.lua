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
  return (host.getenv("HOME") or ".") .. "/.wasm-agent"
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

-- Read from this node's directory, then the legacy flat file.
function M.read(name)
  for _, dir in ipairs({ M.dir(), base() }) do
    if host.read_file then
      local value = clean(host.read_file(dir .. "/" .. name))
      if value then return value end
    end
  end
  return nil
end

function M.write(name, value)
  if host.write_file then host.write_file(M.path(name), value) end
end

return M
