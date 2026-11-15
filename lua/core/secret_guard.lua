-- The agent's own tools never reach credentials (15/11: with the mail connector refusing, a model listed
-- ~/.wasm-agent/secrets and logged into Gmail over IMAP with the password from that folder). The agent and
-- the connectors run as the same OS user, so file modes cannot separate them; this is the tool-level wall:
-- read/write/edit/ls/grep refuse a path under a secret root, and bash/shell refuse a command naming one.
-- It does not stop deliberate obfuscation inside a shell (the vault-delivered secrets plan closes that);
-- it stops the plain routes. Internal harness code (the mail wrapper, deploys) does not pass through here.
local M = {}

M.ROOTS = { '.wasm-agent/secrets', '.wasm-agent/keys', '.wasm-agent/node.key',
  '.config/wasm-agent-sandbox', 'wasm-agent-sandbox/vault' }

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
