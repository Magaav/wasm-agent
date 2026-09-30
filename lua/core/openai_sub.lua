-- The ChatGPT-subscription route. Two transports meet here, and the default is still Pi's adapter:
--
--   * `pi` (default) - Pi's maintained adapter, through Node. Requires an installed Pi, and its
--     dependencies fail visibly. This is what the route does today.
--   * `native` - wasm-agent's own wire (`lua/core/subscription_wire.lua`): our endpoint, our
--     headers, our SSE client over `host.http_sse`, with no Node and no Pi in the runtime at all.
--     `WASM_AGENT_SUBSCRIPTION_TRANSPORT=native` selects it.
--
-- Both answer the same event contract, the same result shape and the same cancellation, deadline and
-- truncation rules, so the route can be cut over - and rolled back - with one environment variable
-- while both are verified. The catalogue and the credential are shared, not duplicated: the ids and
-- thinking levels come from `lua/core/openai_sub_catalogue.lua`, and the credential from
-- `lua/core/subscription_auth.lua` (owned by the credential lane; this file only calls `token()`).
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local catalogue = dofile('lua/core/openai_sub_catalogue.lua')
local wire = dofile('lua/core/subscription_wire.lua')
local M = {}
-- The *picker* list: what this route offers a reader to choose. It is not this route's
-- catalogue - five ids the route serves are absent from it (gpt-5.5, gpt-5.6-luna,
-- gpt-5.6-sol, gpt-5.6-terra, gpt-5.3-codex-spark) and refusing from it is the defect
-- provider.lua documents. An id belongs here to be *offered*; it must also be in the
-- catalogue below, or selecting it fails at request time instead of at selection.
M.models = {'gpt-6-luna','gpt-6-sol','gpt-6.1-sol','gpt-6-astra'}
-- This route's catalogue (`lua/core/openai_sub_catalogue.lua`), so a caller that needs more than one
-- field - windows as well as levels - asks the same source this file reads. Checked in and owned by
-- us: no request-time read of a third-party package's store.
function M.catalogue()
  return catalogue
end
-- The wire this route uses when `native` is selected, for the same reason: a diagnostic that has to
-- answer for the credential before the credential lane's file exists replaces
-- `credential_provider` on *this* instance, not on a second copy of the module.
function M.wire()
  return wire
end
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
-- The thinking levels a single id is published with, from the catalogue this repo owns. Per id and
-- not route-wide, because only the id can say what *it* honours. nil - not `{}` - when the
-- catalogue cannot answer, i.e. it does not publish the id: "the catalogue cannot answer" has to
-- stay distinguishable from "this id has no levels", or a reader would be shown a model with no
-- reasoning instead of a route that cannot describe it.
--
-- This used to read pi's local store at request time (`~/.pi/agent/models-store.json`), which made
-- the route's own catalogue a fact about a third-party package's disk. It now reads
-- `lua/core/openai_sub_catalogue.lua`, whose entries were imported from that store once - see that
-- file for the import and for the nil-vs-empty rule's full statement.
function M.thinking_level_map(model)
  return catalogue.thinking_level_map(model)
end

-- Which transport this route uses. `pi` - Pi's adapter through Node - is the default and stays the
-- default; `native` is wasm-agent's own wire. Anything else is refused rather than guessed: a typo
-- that silently kept using Pi would look like a working cutover.
function M.transport()
  local value = (host.getenv('WASM_AGENT_SUBSCRIPTION_TRANSPORT') or ''):lower()
  if value == '' or value == 'pi' then return 'pi' end
  if value == 'native' or value == 'wire' then return 'native' end
  error('invalid_subscription_transport: expected pi or native, got ' .. value)
end
function M.configured()
  if M.transport() == 'native' then
    -- The credential is the seam's question, not Pi's disk. Measured, and the reason this branch
    -- exists: with Pi's `auth.json` unreachable - which is exactly what a machine without Pi looks
    -- like - this function returned false while the route's own credential was present and usable,
    -- so `wa status` said the route was unconfigured and the agent refused the turn at its own
    -- `provider.configured()` gate. A route with no Pi on disk must not answer a credential question
    -- by reading a third-party package's file.
    --
    -- Cost, stated: asking the seam is a real `token()` call, so a hard-expired token makes this
    -- answer mint one. That is not a side effect invented here - it is the same call, with the same
    -- refresh rule, that the request this route is about to make would have performed.
    local ok, credential = pcall(function() return wire.credential_provider() end)
    return ok and type(credential) == 'table' and type(credential.access) == 'string'
      and credential.access ~= ''
  end
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
  if M.transport() == 'native' then return wire.limits() end
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
  if M.transport() == 'native' then
    -- Same arguments, same result. The wire owns its own deadline check but reads the same
    -- WASM_AGENT_SUBSCRIPTION_TIMEOUT bound, so the budget does not change with the transport.
    return wire.complete(model, messages, tools, stream, opts, reasoning)
  end
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
