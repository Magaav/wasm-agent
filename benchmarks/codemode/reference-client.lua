-- Harness-only injection, never a production backend or environment fallback.
-- The actual role/profile/workspace/schema/effect checks remain core/codemode.lua.
local json=dofile('lua/vendor/json.lua')
local M={}
function M.install(config)
 assert(config and type(config.url)=='string' and config.url:match('^http://127%.0%.0%.1:%d+/quickjs$'),'private reference endpoint required')
 assert(type(config.key)=='string' and config.key:match('^%x+$') and #config.key==64,'reference controller nonce required')
 host.quickjs=function(action,raw)
  assert(type(json.decode(raw))=='table','reference argument JSON required')
  -- Keep the exact raw object: the legacy Lua encoder maps a fieldless table to [].
  local wire='{"action":'..json.encode(action)..',"args":'..raw..'}'
  local reply=json.decode(host.http('POST',config.url,json.encode({['Content-Type']='application/json',Authorization='Bearer '..config.key}),wire))
  if reply.status~=200 or type(reply.body)~='string' then
   return json.encode({ok=false,error='codemode_reference_transport_failed',effect='unknown',replay_allowed=false})
  end
  local result=json.decode(reply.body)
  assert(type(result)=='table' and type(result.ok)=='boolean','reference response shape')
  return reply.body
 end
 return M
end
return M
