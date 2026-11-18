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
--   * `<data>/mcp/requests` (19/11) holds the request and seed files a launch is spawned from: the child
--     reads `server.program`/`args`/`cwd` out of them, so a background loop rewriting one between the
--     console's write and the child's read chose the program that got the vault value. The kernel now
--     hashes the file it approved and the child verifies those bytes before it spawns, and the directory
--     is refused here as well - belt and braces, because the kernel/child check is the one that matters.
--
-- These are refused for READS as well as writes, like every other root here: one list, one rule, and a
-- refusal that is the same whichever tool asked.
M.ROOTS = { '.wasm-agent/secrets', '.wasm-agent/keys', '.wasm-agent/node.key',
  '.config/wasm-agent-sandbox', 'wasm-agent-sandbox/vault',
  '.wasm-agent/memory.db', '.wasm-agent/scripts', '.local/bin/scripts', 'wasm-agent-sandbox/scripts',
  '.wasm-agent/mcp/'..'requests',
  -- 20/11 (round 6): the interpreter the installer provisions (<data>/node/bin/node). It is the process a
  -- vault connector's values are put in, so a file the agent can rewrite is a file that can read them; the
  -- approval hashes it (docs/VAULT.md), and this is the tool-level half - a binary the agent cannot reach
  -- is also a binary it cannot replace with something it wrote.
  '.wasm-agent/node' }

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
      add(data .. '/mcp/'..'requests')
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

-- The same refusal, for the reason that root is a root. "Credentials are reachable only through their
-- connectors" is the truth about a key file and the wrong fact about memory.db or a script directory: a
-- model told that after asking to read a script learns nothing about why the call was refused, and the
-- next session asks again. One note per KIND of root, chosen by the root that matched.
M.NOTES = {
  store = "this is the node's own store: it holds the MCP registry, every connector's approval and the "
    .. 'session ledger, so an agent tool neither reads nor writes it (wa show / wa vault are the surfaces)',
  code = 'this directory holds the code an approved connector runs: an agent tool neither reads nor '
    .. 'writes it, so the bytes that were approved are the bytes that run',
  request = "these are the kernel's own per-launch request and seed files: a launch is spawned from the "
    .. 'bytes the kernel read and approved, so an agent tool neither reads nor writes them',
  runtime = 'this is the interpreter the node runs its connectors on: the process a vault value is put in, '
    .. 'so an agent tool neither reads nor writes it',
}
local function note_for(root)
  local value = tostring(root or ''):lower()
  if value:find('memory%.db') then return M.NOTES.store end
  if value:find('mcp/'..'requests', 1, true) then return M.NOTES.request end
  if value:find('scripts', 1, true) then return M.NOTES.code end
  if value:find('.wasm-agent/node', 1, true) then return M.NOTES.runtime end
  return M.NOTE
end

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
  return { ok = false, error = 'secret_path_denied', status = 403, effect = 'none', root = root, tool = name, note = note_for(root) }
end

return M
