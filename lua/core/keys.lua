-- `/vault <name> <value>`: a key the agent can *use* in a command without ever *seeing* it.
--
-- One file per key, `~/.wasm-agent/keys/<name>.key`, mode 0600 (the host writes every `*.key`
-- private, see `secret_file` in rust/wa-host/src/host.rs). The agent is told the names and the path,
-- never a value, and uses one by reference - `curl -H "Authorization: Bearer $(cat ~/.wasm-agent/keys/github.key)"`
-- - so the value goes from the file into the child process and nowhere else.
--
-- Reading one back is not prevented (the agent's shell runs as the same user), it is made useless:
-- every value stored here is an exact-value secret for `redact.lua`, so a `cat`, an `env` dump or a
-- verbose curl that echoes it has the value replaced before the result is stored, shown, journalled
-- or sent to the provider. The shape rules there also mask any output of a call that names a `.key`.
--
-- The value itself never passes through anything that remembers: not the transcript (the CLI echoes
-- `/vault <name> ••••`), not the editor's history (terminal_editor.rs skips `/vault ` lines), not
-- steering (a slash line is never steered), not a model turn. The window posts it to `/vault/key`
-- from a password field; its composer refuses to send a `/vault` line as a message.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}

-- Short enough to type, safe as a file name and as a shell word: no path, no dot, no space.
M.NAME = "^[%a_][%w_%-]*$"
M.MAX_NAME = 64
M.MAX_VALUE = 16384

-- `WASM_AGENT_KEYS_DIR` moves the store (tests, a second node on one machine).
function M.dir()
  local override = host.getenv("WASM_AGENT_KEYS_DIR")
  if type(override) == "string" and override ~= "" then return (override:gsub("/+$", "")) end
  return paths.home() .. "/.wasm-agent/keys"
end

function M.path(name)
  return M.dir() .. "/" .. name .. ".key"
end

function M.valid_name(name)
  return type(name) == "string" and #name <= M.MAX_NAME and name:match(M.NAME) ~= nil
end

-- Store one key. Returns `{ok=true, name, path, replaced}` or `{error=code, note}`; never the value.
function M.set(name, value)
  if not M.valid_name(name) then
    return { error = "invalid_key_name",
      note = "a name is letters, digits, _ or -, starting with a letter or _, at most " .. M.MAX_NAME .. " characters" }
  end
  value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return { error = "key_value_required", note = "usage: /vault <name> <value>" } end
  if #value > M.MAX_VALUE then return { error = "key_value_too_long" } end
  if value:find("[\r\n]") then return { error = "key_value_multiline", note = "a key is one line" } end
  local path = M.path(name)
  local replaced = type(host.read_file(path)) == "string"
  if not host.write_file(path, value) then return { error = "key_write_failed", path = path } end
  return { ok = true, name = name, path = path, replaced = replaced }
end

-- The stored keys' names, sorted. Names only: this is what the prompt and the UI list.
function M.names()
  local names = {}
  local ok, listing = pcall(function() return json.decode(host.list_dir(M.dir())) end)
  if not ok or type(listing) ~= "table" or type(listing.entries) ~= "table" then return names end
  for _, entry in ipairs(listing.entries) do
    local name = entry.kind == "file" and type(entry.name) == "string" and entry.name:match("^(.+)%.key$")
    if name and M.valid_name(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- Every stored value, for the exact-value redactor. Never printed by anyone.
function M.values()
  local values = {}
  for _, name in ipairs(M.names()) do
    local value = host.read_file(M.path(name))
    if type(value) == "string" then
      value = value:gsub("^%s+", ""):gsub("%s+$", "")
      if #value >= 4 then values[#values + 1] = { name = "VAULT_KEY:" .. name, value = value } end
    end
  end
  return values
end

-- `/vault <name> <value>` as typed, split. The value is everything after the name (one line).
function M.parse(line)
  local rest = tostring(line or ""):match("^/vault%s*(.*)$")
  if not rest then return nil end
  local name, value = rest:match("^(%S+)%s+(.+)$")
  if not name then name = rest:match("^(%S+)%s*$") end
  return name, value
end

-- What the CLI echoes for a `/vault` line: the command and the name, never the value.
function M.masked(line)
  local name, value = M.parse(line)
  if not name then return line end
  return "/vault " .. name .. ((value and value ~= "") and " \226\128\162\226\128\162\226\128\162\226\128\162" or "")
end

-- The prompt's line about keys: the names and how to use one, or nil when there are none.
function M.prompt_line()
  local names = M.names()
  if #names == 0 then return nil end
  return "Stored keys (values are never shown to you; output containing one is redacted): "
    .. table.concat(names, ", ") .. ". Each is the file " .. M.dir() .. "/<name>.key; use it by reference inside "
    .. "the command, e.g. \"$(cat " .. M.dir() .. "/<name>.key)\", never print, echo or copy it."
end

return M
