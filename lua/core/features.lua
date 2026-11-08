-- The node's feature switches, asked through one door (docs/FEATURES.md).
--
-- Every gate that can choose between a component and the native path asks HERE - `lua/core/selfloop`,
-- `codemode`, `hooks` and `memory` - so "is this feature on, which path is live, and why" has one
-- answer per node. The answer is the host's: `host.features` is bound to `rust/wa-features`, the crate
-- that resolves env override > policy.json `features` > default (ON since 08/11) and checks that the
-- component is installed with a verified pin. This module adds no rule of its own and caches nothing: a
-- `policy.json` edit reaches a running node, and a feature that is on with no component behind it
-- reports `component_missing` instead of quietly running the native path. One line per feature in the
-- policy file turns it off live: `"memory": false`.
--
-- WHY IT IS ASKED PER CALL AND NOT ONCE AT LOAD. The switch used to be a module-load constant read from
-- `WA_*_COMPONENT`: turning a feature on meant a restart, and turning one off meant a restart that
-- could not be done from inside the turn. The resolver reads its file live (one stat a second), so a
-- gate asks each time it routes, and `scripts/test-features-gate.lua` proves a gate reacts to a change
-- without reloading the module.
--
-- FALLBACK, and it is named, not silent: a host whose binary has no `host.features` (a stub, a probe
-- script, a plain interpreter) answers from the env flag alone, which is exactly the pre-features
-- behaviour of these gates. A real node always has the capability: the Lua tree is pinned to the
-- binary's capability digest at boot, so a tree that asks for `host.features` cannot run on a binary
-- that does not have it.
local json = dofile('lua/vendor/json.lua')
local M = {}

-- The env flag each feature's resolver honours, for the no-capability fallback. Kept in step with
-- `FEATURES` in `rust/wa-features/src/lib.rs`; `scripts/test-features-gate.lua` checks the two agree
-- for the four gates that live here.
M.env = {
  selfloop = 'WA_SELFLOOP_COMPONENT',
  codemode = 'WA_CODEMODE_COMPONENT',
  hooks = 'WA_HOOKS_COMPONENT',
  memory = 'WA_MEMORY_COMPONENT',
  gateway = 'WA_MODEL_GATEWAY_COMPONENT',
  mesh_component = 'WA_MESH_COMPONENT',
  agent_core = 'WA_AGENT_CORE_COMPONENT',
  telemetry_sink = 'WA_TELEMETRY_SINK_COMPONENT',
}

local function decode(raw)
  if type(raw) == 'table' then return raw end
  if type(raw) ~= 'string' or raw == '' then return nil end
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == 'table' then return value end
  return nil
end

-- The resolver's whole answer for one feature: `{feature, enabled, source, installed, active, reason}`,
-- or nil plus the reason there is no answer.
function M.resolve(feature)
  if type(host.features) == 'function' then
    local ok, raw = pcall(host.features, json.encode({ feature = feature }))
    if not ok then return nil, 'features_capability_failed' end
    local answer = decode(raw)
    if type(answer) ~= 'table' then return nil, 'features_no_answer' end
    if answer.ok == false then return nil, tostring(answer.error or 'features_refused') end
    local entry = answer.feature or answer
    if type(entry) ~= 'table' then return nil, 'features_no_answer' end
    return entry
  end
  -- No capability: the env flag, read the way this gate read it before the resolver existed. It is
  -- deliberately the *conservative* half of the rule: a stub host has no component directory to check a
  -- pin against, so it may claim the component only when the flag names it. A real node always has the
  -- capability (the Lua tree is pinned to the binary's digest at boot), so the default-on rule is the
  -- resolver's, never this fallback's guess.
  local name = M.env[feature]
  if not name then return nil, 'unknown_feature:' .. tostring(feature) end
  local ok, value = pcall(host.getenv, name)
  local on = ok and tostring(value or '') == '1'
  return {
    feature = feature,
    enabled = on,
    source = 'env',
    installed = nil,
    active = on and 'component' or 'native',
    reason = on and 'active_component' or 'feature_off',
    fallback = 'features_capability_missing',
  }
end

-- What a gate asks: `active` is true when the component must answer this feature's calls. The reason
-- is `seam_disabled` when the feature is simply off - the native path IS the off state, so there is
-- nothing to report - and the resolver's own reason (`component_missing`, `component_pin_mismatch`, …)
-- when the node asked for the component and cannot have it. A gate reports THAT one, once per
-- operation: a feature that silently fell back is the bug this whole module exists to prevent.
function M.seam(feature)
  local entry, reason = M.resolve(feature)
  if not entry then return false, tostring(reason or 'features_unavailable') end
  if entry.active == 'component' then return true, tostring(entry.reason or 'active_component') end
  if entry.enabled ~= true then return false, 'seam_disabled' end
  return false, tostring(entry.reason or 'component_unavailable')
end

-- The whole node's table, as data (`wa features` prints it, the CLI and a skill read it).
function M.status()
  if type(host.features) ~= 'function' then return nil, 'features_capability_missing' end
  local ok, raw = pcall(host.features)
  if not ok then return nil, 'features_capability_failed' end
  local answer = decode(raw)
  if type(answer) ~= 'table' then return nil, 'features_no_answer' end
  return answer
end

-- One line per feature, for a caller that wants a readable answer without the JSON.
function M.text()
  local answer, reason = M.status()
  if not answer then return 'features unavailable: ' .. tostring(reason) end
  local lines = { 'feature           component        installed  enabled  source   active     reason' }
  for _, entry in ipairs(answer.features or {}) do
    lines[#lines + 1] = string.format('%-17s %-16s %-10s %-8s %-8s %-10s %s',
      tostring(entry.feature), tostring(entry.component),
      entry.installed and tostring(entry.installed):sub(1, 10) or '-',
      entry.enabled and 'yes' or 'no',
      tostring(entry.source), tostring(entry.active), tostring(entry.reason))
  end
  lines[#lines + 1] = 'policy: ' .. tostring(answer.policy)
  if answer.policy_error then lines[#lines + 1] = 'policy error: ' .. tostring(answer.policy_error) end
  -- The mesh's own switch (docs/MESH.md): on by default when a roster verifies against the pinned key,
  -- the legacy path otherwise. `mesh_component` above says which *code* decides; this says whether the
  -- mesh is in use at all, so the table never leaves that to a guess.
  if type(answer.mesh) == 'table' then
    lines[#lines + 1] = 'mesh: ' .. (answer.mesh.enabled and 'on' or 'off') ..
      ' (' .. tostring(answer.mesh.source or 'unknown') .. ')'
    if answer.mesh.problem then lines[#lines + 1] = 'mesh error: ' .. tostring(answer.mesh.problem) end
  end
  return table.concat(lines, '\n')
end

return M
