-- Subscription transport through Pi's maintained adapter. Risk: this provider
-- requires Node and a compatible installed Pi; missing dependencies fail visibly.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local M = {}
M.models = {'gpt-6-luna','gpt-6-sol','gpt-6-astra'}
function M.auth_path()
  local directory = host.getenv('PI_CODING_AGENT_DIR') or (paths.home() .. '/.pi/agent')
  return directory .. '/auth.json'
end
function M.configured()
  local raw = host.read_file(M.auth_path())
  local ok, auth = pcall(json.decode, raw or '')
  local credential = ok and type(auth)=='table' and auth['openai-codex']
  return type(credential)=='table' and credential.type=='oauth'
end
local function quote(value)
  if dofile('lua/core/platform.lua').os()=='windows' and
      dofile('lua/core/platform.lua').shell():find('cmd',1,true) then
    if tostring(value):find('["%%\r\n]') then error('unsafe_subscription_command_path') end
    return '"' .. tostring(value) .. '"'
  end
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function operation(action, args)
  local value = json.decode(host.operation(action, json.encode(args)))
  if value.error and not value.operation_id then error(value.error) end
  return value
end
function M.limits()
  local stem = paths.temp() .. '/wa-openai-sub-limits-' .. host.uuid()
  local script, input = stem .. '.mjs', stem .. '.json'
  host.write_file(script, dofile('lua/core/openai_sub_bridge.lua'))
  host.write_file(input, json.encode({action='limits', home=paths.home(), auth_path=M.auth_path()}))
  local id
  local ok, result = pcall(function()
    local launch = operation('start', {command='node ' .. quote(script) .. ' ' .. quote(input),
      timeout_seconds=tonumber(host.getenv('WASM_AGENT_LIMITS_TIMEOUT')) or 20})
    id = launch.operation_id
    local offset, pending, limits, failure = 0, '', nil, nil
    while true do
      if host.beat then host.beat() end
      local state = operation('wait', {id=id, wait_ms=100})
      while true do
        local page = operation('read', {id=id, stream='stdout', offset=offset, limit=65536})
        local content = page.content or ''
        offset = page.next_offset or (offset + #content)
        pending = pending .. content
        while pending:find('\n',1,true) do
          local ending = pending:find('\n',1,true)
          local event = json.decode(pending:sub(1,ending-1))
          pending = pending:sub(ending+1)
          if event.type=='limits' then limits=event.limits
          elseif event.type=='error' then failure=event.error end
        end
        if #content==0 then break end
      end
      if state.settled then
        if not state.ok then error(failure or state.error or 'subscription_limits_failed') end
        break
      end
    end
    if failure then error(failure) end
    if not limits or pending~='' then error('subscription_limits_incomplete') end
    return limits
  end)
  if id then
    if not ok then pcall(operation, 'cancel', {id=id}) end
    pcall(operation, 'wait', {id=id, wait_ms=2000})
  end
  os.remove(script); os.remove(input)
  if not ok then error(result) end
  return result
end
function M.complete(model, messages, tools, stream, opts, reasoning)
  local stem = paths.temp() .. '/wa-openai-sub-' .. host.uuid()
  local script, input = stem .. '.mjs', stem .. '.json'
  host.write_file(script, dofile('lua/core/openai_sub_bridge.lua'))
  host.write_file(input, json.encode({home=paths.home(), auth_path=M.auth_path(),
    model=model, messages=messages, tools=tools, session_id=opts.session_id,
    reasoning=reasoning.selected=='provider' and 'medium' or reasoning.selected=='off' and 'none' or reasoning.selected,
    max_output=opts.max_output}))
  local launch = operation('start', {command='node ' .. quote(script) .. ' ' .. quote(input),
    timeout_seconds=tonumber(host.getenv('WASM_AGENT_LLM_TIMEOUT')) or 300,
    })
  local id, offset, pending, result, failure = launch.operation_id, 0, '', nil, nil
  local ok, problem = pcall(function()
    while true do
      if host.beat then host.beat() end
      local state = operation('wait', {id=id, wait_ms=100})
      while true do
        local page = operation('read', {id=id, stream='stdout', offset=offset, limit=65536})
        local content = page.content or ''
        offset = page.next_offset or (offset + #content)
        pending = pending .. content
        while pending:find('\n',1,true) do
          local ending = pending:find('\n',1,true)
          local event = json.decode(pending:sub(1,ending-1))
          pending = pending:sub(ending+1)
          if event.type=='result' then result=event.result
          elseif event.type=='error' then failure=event.error
          elseif stream and (event.type=='delta' or event.type=='reasoning') then host.stream(json.encode(event)) end
        end
        if #content==0 then break end
      end
      if state.settled then
        if not state.ok then error(failure or state.error or 'subscription_bridge_failed') end
        break
      end
      if host.run_cancelled then
        local cancelled=json.decode(host.run_cancelled())
        if cancelled.cancelled then error('run_cancelled') end
      end
    end
    if failure then error(failure) end
    if not result or pending~='' then error('subscription_bridge_incomplete') end
  end)
  if not ok then
    operation('cancel', {id=id})
    operation('wait', {id=id,wait_ms=2000})
  end
  os.remove(script); os.remove(input)
  if not ok then error(problem) end
  return result
end
return M
