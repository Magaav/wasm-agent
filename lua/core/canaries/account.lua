-- CANARY ACCOUNT GATE (25/11): is there an account of this kind ON THIS NODE, or is the canary asking a
-- question this machine cannot answer?
--
-- MEASURED (v0.1.2 cut, 25/11): on the laptop that cuts, `mail`, `whatsapp-receive`, `whatsapp-index` and
-- `whatsapp-transcription` all answered FAIL `index_empty` / `no_voice_notes` - the index answers and holds
-- nothing, because no account of that kind is configured here at all. A FAIL says the FEATURE is broken; this
-- machine simply has no mailbox and no linked device, so the honest answer is a third state: not proven.
--
-- WHAT IS READ, and it is the component's own file, not the index: `<config>/components/<component>.json`, the
-- definition the component itself runs from (feature_health.applies reads the same path for "is it installed").
-- A definition that carries nothing beyond the manifest skeleton (name, kind, target, description,
-- capabilities, limits) is a component with NO account configured; one that carries any other key has been
-- configured on this node. An account that IS configured and whose index is empty stays a FAIL: that is the
-- feature being broken, which is exactly what a canary is for.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

-- The manifest keys every component definition has, configured or not.
local SKELETON = { name = true, kind = true, target = true, description = true, capabilities = true, limits = true }

local M = {}

-- <component> [, <config root>] -> true | false, reason
-- The second argument exists so a row can drive every case in one process (the rule is about a FILE, and a rule
-- only exercised by restarting a node with another home is a rule nobody tests).
function M.present(component, config_root)
  local root = config_root or paths.config()
  local path = root .. '/components/' .. tostring(component) .. '.json'
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then
    return false, 'no account of this kind is configured on this node: ' .. path .. ' does not exist'
  end
  local parsed, document = pcall(json.decode, text)
  if not parsed or type(document) ~= 'table' then
    return false, 'no account of this kind can be read on this node: ' .. path .. ' does not parse'
  end
  for key in pairs(document) do
    if not SKELETON[tostring(key)] then
      return true
    end
  end
  return false, 'no account of this kind is configured on this node: ' .. path .. ' holds only the component definition'
end

return M
