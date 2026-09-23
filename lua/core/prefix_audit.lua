-- Compare canonical, actually-sent components without retaining prompt text in telemetry.
-- Worker-local bounded baselines; a restart/eviction is unknown, not a stable-prefix claim.
local json=dofile('lua/vendor/json.lua')
local M={}
local baselines,order={},{}
function M.observe(session,kind,body,route)
  if not session or session=='' then return {schema_version=1,relation='unmeasured',reason='no_session'} end
  local key=session..'\0'..tostring(kind or 'model_call')
  if #(body.messages or {})>8192 then
    baselines[key]=nil
    for i=#order,1,-1 do if order[i]==key then table.remove(order,i) end end
    return {schema_version=1,relation='unmeasured',reason='message_budget'}
  end
  local hashes={}
  for i,message in ipairs(body.messages or {}) do hashes[i]=host.sha256(json.encode(message)) end
  local settings={}
  for name,value in pairs(body) do if name~='messages' and name~='tools' then settings[name]=value end end
  local current={messages=hashes,tools=host.sha256(json.encode(body.tools or {})),
    settings=host.sha256(json.encode(settings)),routing=host.sha256(json.encode(route or {}))}
  local prior=baselines[key]
  if not prior then
    while #order>=16 do baselines[table.remove(order,1)]=nil end
    order[#order+1]=key
  end
  baselines[key]=current
  if not prior then return {schema_version=1,relation='unmeasured',reason='baseline_missing',messages=#hashes} end
  local common=0
  for i=1,math.min(#prior.messages,#hashes) do if prior.messages[i]~=hashes[i] then break end;common=i end
  local relation=common==#prior.messages and (#hashes==common and 'identical' or 'append_only')
    or (common==#hashes and 'shortened' or 'rewritten')
  return {schema_version=1,relation=relation,shared_messages=common,messages=#hashes,previous_messages=#prior.messages,
    first_changed_message=common<math.min(#prior.messages,#hashes) and common+1 or nil,
    tools_changed=prior.tools~=current.tools,settings_changed=prior.settings~=current.settings,routing_changed=prior.routing~=current.routing,
    -- Only these can invalidate a cached prefix. `settings_changed` covers every body field
    -- that is not the messages or the tools, and `max_tokens` shrinks as the context grows -
    -- so it is true on most rounds and says nothing about the cache. Measured over 48h:
    -- settings_changed on 142 of 852 prepared requests while the provider reported a cache
    -- hit on 98.7% of them, and the message prefix was append-only in 851 of 852. Reading
    -- the settings flag as a cache miss sends the reader after a `max_tokens` that is
    -- deliberately bounded by the remaining window.
    prefix_changed=relation=='rewritten' or relation=='shortened' or prior.tools~=current.tools,
    note='Prepared canonical request components, not provider acceptance, tokenization, retention or guaranteed cache reuse. settings_changed is not a cache miss: check prefix_changed.'}
end
return M
