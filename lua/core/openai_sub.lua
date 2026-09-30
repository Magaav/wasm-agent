-- Subscription transport through Pi's maintained adapter. Risk: this provider
-- requires Node and a compatible installed Pi; missing dependencies fail visibly.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local M = {}
-- The *picker* list: what this route offers a reader to choose. It is not this route's
-- catalogue - five ids the route serves are absent from it (gpt-5.5, gpt-5.6-luna,
-- gpt-5.6-sol, gpt-5.6-terra, gpt-5.3-codex-spark) and refusing from it is the defect
-- provider.lua documents. An id belongs here to be *offered*; it must also be in the
-- catalogue below, or selecting it fails at request time instead of at selection.
M.models = {'gpt-6-luna','gpt-6-sol','gpt-6.1-sol','gpt-6-astra'}
function M.auth_path()
  local directory = host.getenv('PI_CODING_AGENT_DIR') or (paths.home() .. '/.pi/agent')
  return directory .. '/auth.json'
end
-- The route's catalogue: pi's local model store, the file provider.lua's pi_store() decides
-- servability from and model_window.lua's from_pi_store() reads windows from. Same name,
-- same override, same default as those two, because one file has to answer for all three -
-- a second opinion about where the catalogue lives is how the picker-list version shipped.
function M.models_store_path()
  return host.getenv('WASM_AGENT_PI_MODELS_STORE')
    or (paths.home() .. '/.pi/agent/models-store.json')
end
-- The thinking levels a single id is published with. pi's store carries a per-model
-- `thinkingLevelMap` - level -> the value Pi puts in the Responses body's `reasoning.effort` -
-- and it is the only thing that can say what *this* id honours; a route-wide table can only say
-- what the route accepts. Read the entries this route is and nothing else: provider
-- `openai-codex` over `openai-codex-responses`, the same pair the bridge resolves the id
-- against. Read-only, and nil - not `{}` - when the store is absent, silent about the id, or
-- publishes no map for it: "the catalogue cannot answer" has to stay distinguishable from "this
-- id has no levels", or a node without a store would report a model with no reasoning instead
-- of a route that cannot describe it.
function M.thinking_level_map(model)
  local text = host.read_file(M.models_store_path())
  if not text then return nil end
  local ok, store = pcall(json.decode, text)
  if not ok or type(store) ~= 'table' then return nil end
  local profile = store['openai-codex']
  for _, entry in pairs(type(profile) == 'table' and profile.models or {}) do
    if type(entry) == 'table' and entry.id == model and entry.api == 'openai-codex-responses'
      and type(entry.thinkingLevelMap) == 'table' then
      return entry.thinkingLevelMap
    end
  end
  return nil
end
function M.configured()
  local raw = host.read_file(M.auth_path())
  local ok, auth = pcall(json.decode, raw or '')
  local credential = ok and type(auth)=='table' and auth['openai-codex']
  return type(credential)=='table' and credential.type=='oauth'
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
    local launch = operation('start', {program='node',args={script,input},
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
-- Long reasoning is work, not a stalled shell. Keep an explicit safety bound,
-- independent of the foreground shell default, and retain cancellation/deadlines.
function M.request_timeout()
  local raw=host.getenv('WASM_AGENT_SUBSCRIPTION_TIMEOUT') or host.getenv('WASM_AGENT_LLM_TIMEOUT')
  local seconds=raw and tonumber(raw) or 3600
  if not seconds or seconds~=math.floor(seconds) or seconds<1 or seconds>86400 then
    error('invalid_subscription_timeout: expected 1..86400 seconds')
  end
  return seconds
end
function M.complete(model, messages, tools, stream, opts, reasoning)
  local stem = paths.temp() .. '/wa-openai-sub-' .. host.uuid()
  local stream_id = host.uuid()
  local script, input = stem .. '.mjs', stem .. '.json'
  host.write_file(script, dofile('lua/core/openai_sub_bridge.lua'))
  host.write_file(input, json.encode({home=paths.home(), auth_path=M.auth_path(),
    models_store=M.models_store_path(),
    model=model, messages=messages, tools=tools, session_id=opts.session_id, stream_id=stream_id,
    reasoning=reasoning.selected=='provider' and 'medium' or reasoning.selected=='off' and 'none' or reasoning.selected,
    max_output=opts.max_output}))
  local id, offset, pending, result, failure = nil, 0, '', nil, nil
  local commentary_ids, commentary_pending_ids = {}, {}
  local ok, problem = pcall(function()
    local launch = operation('start', {program='node',args={script,input},
      timeout_seconds=M.request_timeout()})
    id=launch.operation_id
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
          if event.type=='result' then
            result=event.result
            if type(result.commentary) == 'table' then
              for index, item in ipairs(result.commentary) do
                local text = type(item) == 'table' and item.content or item
                result.commentary[index] = {content=text, id=commentary_ids[index],
                  pending_id=type(item) == 'table' and item.pending_id or commentary_pending_ids[index]}
              end
            end
            result.commentary_streamed = stream and #commentary_ids > 0 or false
          elseif event.type=='error' then failure=event.error
          elseif stream and (event.type=='delta' or event.type=='pending_delta' or event.type=='reasoning' or event.type=='decision' or event.type=='commentary') then
            if event.type == 'commentary' then
              event.message_id = host.uuid()
              commentary_ids[#commentary_ids + 1] = event.message_id
              commentary_pending_ids[#commentary_pending_ids + 1] = event.pending_id
            end
            host.stream(json.encode(event))
          end
        end
        if #content==0 then break end
      end
      if state.settled then
        if not state.ok then error(failure or ('subscription_bridge_'..tostring(state.error or state.state or 'failed')..': configured request bound '..M.request_timeout()..'s; cause is reported above; transcript preserved; no automatic effect replay')) end
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
  if not ok and id then
    operation('cancel', {id=id})
    operation('wait', {id=id,wait_ms=2000})
  end
  os.remove(script); os.remove(input)
  if not ok then error(problem) end
  return result
end
return M
