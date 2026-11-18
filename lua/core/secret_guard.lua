-- The agent's own tools never reach credentials (15/11: with the mail connector refusing, a model listed
-- ~/.wasm-agent/secrets and logged into Gmail over IMAP with the password from that folder). The agent and
-- the connectors run as the same OS user, so file modes cannot separate them; this is the tool-level wall:
-- read/write/edit/ls/grep refuse a path under a secret root, and bash/shell refuse a command naming one.
-- It does not stop deliberate obfuscation inside a shell (the vault-delivered secrets plan closes that);
-- it stops the plain routes. Internal harness code (the mail wrapper, deploys) does not pass through here.
local M = {}

-- The paths the agent's own tools never touch. Two more kinds were added on 18/11, because each was a
-- write that decided what a connector IS rather than what it does:
--
--   * `memory.db` (and its `-wal`/`-shm`) is the node's own store, and the MCP registry lives in it: a
--     `sqlite3 ~/.wasm-agent/memory.db "update meta set value=..."` set a connector's approval by hand,
--     which nothing else could see. Refusing the file is the tool-level half of that hole; the digest a
--     launch is checked against (docs/VAULT.md) is the other.
--   * the connector SCRIPT directories (`<data>/scripts`, `~/.local/bin/scripts`, and whatever
--     `WA_MCP_SCRIPT_DIR`/`WA_INSTALL_DIR` name) hold the code an approved connector runs: overwriting
--     one script replaced the program behind an approval.
--
-- These are refused for READS as well as writes, like every other root here: one list, one rule, and a
-- refusal that is the same whichever tool asked.
M.ROOTS = { '.wasm-agent/secrets', '.wasm-agent/keys', '.wasm-agent/node.key',
  '.config/wasm-agent-sandbox', 'wasm-agent-sandbox/vault',
  '.wasm-agent/memory.db', '.wasm-agent/scripts', '.local/bin/scripts', 'wasm-agent-sandbox/scripts' }

-- The same rule for the directories this node RESOLVES rather than assumes: the data directory the host
-- reports and the script directory the MCP runtime is actually launched from. A fixed list cannot know
-- them - `WA_MCP_SCRIPT_DIR`, a custom `WA_DATA`, a per-install layout - and a root that is not in the
-- list is the one an agent would use.
local function configured()
  local list = {}
  local function add(path)
    if type(path) ~= 'string' or path == '' then return end
    list[#list + 1] = (tostring(path):gsub('\\', '/'):lower():gsub('/+', '/'):gsub('/$', ''))
  end
  local function getenv(name)
    local ok, value = pcall(host.getenv, name)
    return ok and type(value) == 'string' and value or ''
  end
  local ok, paths = pcall(dofile, 'lua/core/paths.lua')
  if ok and type(paths) == 'table' then
    local okdata, data = pcall(paths.data)
    if okdata and type(data) == 'string' then
      add(data .. '/memory.db')
      add(data .. '/scripts')
    end
  end
  add(getenv('WA_MCP_SCRIPT_DIR'))
  local install = getenv('WA_INSTALL_DIR')
  if install ~= '' then add(install .. '/scripts') end
  local root = getenv('WASM_AGENT_LUA_ROOT')
  if root ~= '' then add(root .. '/scripts') end
  return list
end
M.CONFIGURED = configured()

local FILE_TOOLS = { read = true, write = true, edit = true, ls = true, grep = true }
local SHELL_TOOLS = { bash = true, shell = true }

local function home()
  local ok, value = pcall(host.getenv, 'HOME')
  if ok and type(value) == 'string' and value ~= '' then return value end
  local ok2, profile = pcall(host.getenv, 'USERPROFILE')
  return ok2 and profile or ''
end

local function normal(text)
  text = tostring(text or ''):gsub('\\', '/')
  if text:sub(1, 1) == '~' then text = home() .. text:sub(2) end
  text = text:gsub('%$HOME', home()):gsub('%${HOME}', home())
  text = text:gsub('/%./', '/'):gsub('/+', '/')
  return text:lower()
end

local function hit(text)
  local value = normal(text)
  for _, root in ipairs(M.ROOTS) do
    if value:find(root, 1, true) then return root end
  end
  for _, root in ipairs(M.CONFIGURED) do
    if root ~= '' and value:find(root, 1, true) then return root end
  end
  return nil
end

M.NOTE = 'credentials are reachable only through their connectors (mcp_google_*, mcp_whatsapp_*, email tools); an agent tool never reads them'

-- nil when allowed; the refusal when a call reaches a secret root.
function M.check(name, args)
  args = type(args) == 'table' and args or {}
  local root
  if FILE_TOOLS[name] then
    root = hit(args.path)
    if not root and type(args.paths) == 'table' then
      for _, p in ipairs(args.paths) do root = root or hit(p) end
    end
  elseif SHELL_TOOLS[name] then
    root = hit(args.command) or hit(args.cwd)
  end
  if not root then return nil end
  return { ok = false, error = 'secret_path_denied', status = 403, effect = 'none', root = root, tool = name, note = M.NOTE }
end

return M
