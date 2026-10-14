-- A provider measurement belongs to one exact request prefix, not to a byte count.
-- Keep only scoped hashes/counts in local derived metadata; never drop replayed reasoning.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local M={}
local function integer(n)
  return type(n)=='number' and n>=0 and n<9007199254740991 and n%1==0
end
local function key(bot)
  return 'context-usage.v1:'..host.sha256(json.encode({bot.session_id,bot.user,bot.role}))
end
local function prefix(messages,count)
  local rows={};for i=1,count do rows[i]=messages[i] end
  return host.sha256(json.encode(rows))
end
local function valid(anchor)
  return type(anchor)=='table' and anchor.version==1 and integer(anchor.prompt)
    and integer(anchor.messages) and anchor.messages>0 and type(anchor.model)=='string'
    and type(anchor.scope)=='string' and type(anchor.route)=='string'
    and type(anchor.prefix)=='string' and #anchor.prefix==64
    and type(anchor.tools)=='string' and #anchor.tools==64
end
local function load(bot)
  if not bot._context_anchor_loaded then
    bot._context_anchor_loaded=true
    local ok,raw=pcall(memory.meta_get,key(bot))
    if not ok then return nil,'measurement_store_unreadable' end
    if raw then
      local decoded,anchor=pcall(json.decode,raw)
      if not decoded or not valid(anchor) then return nil,'measurement_invalid' end
      bot._context_anchor=anchor
    end
  end
  return bot._context_anchor
end
function M.route(provider)
  local active=provider.active() or {}
  return host.sha256(json.encode({active.id or '',active.base_url or '',
    active.id=='openai-sub' and (host.getenv('WASM_AGENT_SUBSCRIPTION_TRANSPORT') or 'native') or ''}))
end
function M.estimate(bot,messages,tools,route)
  local anchor,reason=load(bot)
  if not anchor then return nil,reason or 'measurement_missing' end
  if anchor.scope~=key(bot) then return nil,'measurement_scope_changed' end
  if anchor.route~=(route or '') then return nil,'measurement_provider_changed' end
  if anchor.model~=bot.model then return nil,'measurement_model_changed' end
  if anchor.tools~=host.sha256(json.encode(tools or {})) then return nil,'measurement_tools_changed' end
  if #messages<anchor.messages or prefix(messages,anchor.messages)~=anchor.prefix then
    return nil,'measurement_prefix_changed'
  end
  local tokens=anchor.prompt
  for i=anchor.messages+1,#messages do tokens=tokens+telemetry.estimate_messages({messages[i]}) end
  return tokens,'provider-plus-tail-estimate'
end
function M.remember(bot,messages,tools,usage,route)
  if type(usage)~='table' or usage.known~=true or usage.issue or not integer(usage.prompt)
      or not integer(usage.output) or usage.prompt+usage.output>=9007199254740991
      or #messages==0 then return false,'measurement_unavailable' end
  local anchor={version=1,scope=key(bot),route=route or '',model=bot.model,prompt=usage.prompt,messages=#messages,
    prefix=prefix(messages,#messages),tools=host.sha256(json.encode(tools or {}))}
  bot._context_anchor_loaded,bot._context_anchor=true,anchor
  local ok,problem=pcall(memory.meta_set,key(bot),json.encode(anchor))
  if not ok then
    if host.log then host.log('context_usage: measurement persistence failed: '..tostring(problem)) end
    return false,'measurement_persistence_failed'
  end
  return true
end
function M.reset(bot)
  bot._context_anchor_loaded,bot._context_anchor=nil,nil
  -- Historical derived measurement remains; changed summary/prefix cannot match it.
end
return M
