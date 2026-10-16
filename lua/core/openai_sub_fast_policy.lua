-- Pure policy only; not wired into settings, credentials, transport or UI.
-- Contract/provenance: docs/OPENAI-SUB-FAST-STAGE1.md.
local M = {}
local documented = {
  ['gpt-6.1-sol']=true, ['gpt-6-astra']=true,
  ['gpt-6-sol']=true, ['gpt-6-luna']=true,
}

-- Existing catalogue convention: entry.id identifies the exact model. Never infer
-- entitlement from a model name. Optional service_tiers is upstream-shaped metadata.
function M.selection(provider, model, enabled, entry)
  if enabled == nil then enabled = false end
  if type(enabled) ~= 'boolean' then error('fast_mode_invalid_boolean', 0) end
  local result = {enabled=enabled, applicable=provider=='openai-sub',
    model_support='unknown', account_entitlement='unknown', selection='default'}
  if not result.applicable then
    result.reason = 'fast_mode_provider_not_applicable'
    return result -- retained preference must never leak to another provider
  end
  if documented[model] then result.model_support='documented' end
  if entry and entry.id ~= model then error('fast_mode_metadata_model_mismatch', 0) end
  if entry and type(entry.service_tiers)=='table' then
    result.model_support='unsupported'
    for _, tier in ipairs(entry.service_tiers) do
      if tier.id=='priority' or tier.id=='fast' then
        result.model_support='advertised'
        result.fast_wire_tier=tier.id
        break
      end
    end
  end
  if enabled then
    if result.model_support=='unknown' or result.model_support=='unsupported' then
      error('fast_mode_model_' .. result.model_support, 0)
    end
    -- Pinned Codex ServiceTier::Fast.request_value(), not Ultrafast.
    result.selection=result.fast_wire_tier or 'priority'
  end
  return result
end

-- Copy-on-write: no model/reasoning/tool/concurrency changes and no retry path.
-- Explicit Standard ('default') suppresses catalog defaults locally; pinned Codex
-- filters that sentinel out before HTTP serialization. Never emit 'auto'.
function M.request(body, selection)
  local copy = {}
  for key, value in pairs(body) do copy[key]=value end
  if selection.applicable then
    copy.service_tier = selection.enabled and selection.selection or nil
  end
  return copy
end

-- Pass the terminal response object, not a guessed tier from request/usage.
-- Raw usage remains entirely owned by the existing normalizer.
function M.observation(selection, response)
  local actual = type(response)=='table' and response.service_tier or nil
  if type(actual)~='string' or actual=='' then actual=nil end
  local requested = selection.applicable and selection.selection or nil
  local match
  if actual and requested then
    local function canonical(tier)
      return tier=='priority' and 'fast' or tier
    end
    match=canonical(actual)==canonical(requested)
  end
  return {requested=requested, actual=actual, actual_known=actual~=nil,
    matches_requested=match, account_entitlement='unknown'}
end

return M
