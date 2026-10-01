-- Executed in separate real processes by test-selection-state.cjs.
local json=dofile('lua/vendor/json.lua')
local provider=dofile('lua/core/provider.lua')
local phase=assert(host.getenv('WA_SELECTION_PHASE'))
local root=assert(host.getenv('WA_SELECTION_FIXTURE'))
local function revision() return provider.selection_revision() end
if phase=='init' then
  assert(provider.set_provider('opencode-go'))
  assert(provider.set_model('fixture-model'))
  print(json.encode({revision=revision(),provider=provider.settings().provider}))
elseif phase=='hold' then
  provider.pin()
  local selected=provider.settings()
  local rev=revision()
  assert(host.write_file(root..'/pinned',tostring(rev)))
  local started=host.monotonic_ms()
  while not host.read_file(root..'/release') do
    assert(host.monotonic_ms()-started<10000,'pin fixture timed out')
    host.sleep(10)
  end
  assert(provider.settings().provider==selected.provider,'in-flight provider changed')
  assert(provider.settings().model==selected.model,'in-flight model changed')
  assert(revision()==rev,'in-flight revision changed')
  provider.unpin()
  assert(provider.settings().provider=='openai-sub','independent interpreter missed switch')
  print('pin held; next run sees new provider')
elseif phase=='switch' then
  local old=revision()
  assert(provider.set_provider('openai-sub',old))
  assert(provider.set_model('gpt-6.1-sol',revision()))
  assert(provider.set_reasoning('low',revision()))
  assert(provider.reasoning().selected=='low')
  local ok,err=provider.set_model('gpt-6-astra',old)
  assert(not ok and err=='settings_conflict','stale revision was applied')
  print(json.encode({revision=revision(),provider=provider.settings().provider,model=provider.settings().model}))
elseif phase=='cas' then
  local expected=tonumber(assert(host.getenv('WA_SELECTION_REVISION')))
  local ok,err=provider.set_model(assert(host.getenv('WA_SELECTION_MODEL')),expected)
  print(json.encode({ok=ok,error=err or '',revision=revision()}))
elseif phase=='read' then
  print(provider.with_selection(function()
    return json.encode({revision=revision(),provider=provider.settings().provider,model=provider.settings().model,reasoning=provider.reasoning().selected})
  end))
else error('unknown phase') end
