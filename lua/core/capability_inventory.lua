-- The node's own capability inventory, as data.
--
-- The list itself lives in one place: the live registry in `rust/wa-host/src/capabilities.rs`
-- that the interpreter is booted from. This module is only a door: the CLI (`wa capabilities`)
-- and the codemode sandbox (`capabilities()` / `describe(name)`) both read it here, and `/health`
-- publishes the same names and the sha256 of the same bytes. There is no second copy to drift,
-- and `docs/HOST.md` is checked against that registry by a test rather than by eye.
local json = dofile('lua/vendor/json.lua')
local M = {}

local cached_raw, cached_list

-- The registry's own JSON text: `[{name, description, effect}, ...]`, stably ordered by name.
-- Kept as text, not re-encoded, so the digest `wa capabilities` prints is byte-for-byte the one
-- `/health` publishes. Nil when this host predates the inventory (an older node, or a shim).
function M.raw()
  if cached_raw then return cached_raw end
  if type(host.capability_inventory) ~= 'function' then return nil end
  local raw = host.capability_inventory()
  if type(raw) ~= 'string' or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  cached_raw, cached_list = raw, decoded
  return cached_raw
end

-- The same inventory as a Lua array, in the registry's order.
function M.list()
  if M.raw() then return cached_list end
  return nil
end

-- One entry by exact name, or nil.
function M.describe(name)
  local list = M.list()
  if not list or type(name) ~= 'string' then return nil end
  for _, entry in ipairs(list) do
    if entry.name == name then return entry end
  end
  return nil
end

-- The two codemode globals, `capabilities()` and `describe(name)`, as one function so the
-- sandbox and the test that checks it exercise the same code. Returns `value, success`.
-- `params` is the JSON-decoded argument array the guest sent: `describe("exec")` arrives as
-- `{"exec"}`. Read-only in both branches: it admits no call and changes no ceiling.
function M.global(name, params)
  if name == 'capabilities' then
    local raw = M.raw()
    if not raw then return { error = 'capability_inventory_unavailable' }, false end
    return json.decode(raw), true
  end
  if name == 'describe' then
    local entry = M.describe(type(params) == 'table' and params[1] or params)
    if not entry then return { error = 'unknown_capability' }, false end
    return entry, true
  end
  return nil, nil
end

-- What `--json` prints and what the sandbox returns: the registry text unchanged.
function M.json()
  return M.raw()
end

-- The human form: one line per capability, then the digest of the list so two nodes can be
-- compared without diffing prose.
function M.text()
  local list = M.list()
  if not list then return 'capability_inventory_unavailable' end
  local lines = { string.format('%-20s %-15s %s', 'capability', 'effect', 'description') }
  for _, entry in ipairs(list) do
    lines[#lines + 1] = string.format('%-20s %-15s %s', entry.name, entry.effect, entry.description)
  end
  lines[#lines + 1] = string.format('(%d capabilities; sha256 %s)', #list, host.sha256(M.raw()))
  return table.concat(lines, '\n')
end

return M
