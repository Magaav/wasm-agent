-- `/mcp` in `wa chat`: the list, one connector in full, or one connector turned on or off.
--
-- The data belongs to `lua/core/mcp_command.lua` - the same object the window renders - so this file only
-- parses the line and prints. Grammar: `/mcp`, `/mcp <key>`, `/mcp <key> on|off`, where `<key>` is the
-- first column of the list (`whatsapp`, `openclaw:whatsapp_native`).
local M = {}

-- Why a change was refused, in the words of the rule that refused it. The registry's error codes are
-- precise but terse; a reader at a prompt needs the next action, not only the code.
local function refusal(answer)
  local error = tostring(answer.error or 'not_changed')
  local hints = {
    mcp_store_revision_changed = 'the registry moved to revision ' .. tostring(answer.revision)
      .. ' since this list was read; run /mcp again and repeat the change',
    mcp_probe_required = 'a connector is only enabled after a probe passed: run the mcp tool with '
      .. 'action=probe, id=' .. tostring(answer.connector or '?') .. ' (the window has the same button)',
    forbidden = 'read-only: turning a connector on or off needs a master',
    unknown_connector = 'no connector has that key; /mcp lists them',
    connector_registry_not_reported = 'that peer reported its tools, not its registry: nothing to toggle here',
    unknown_peer = 'that peer is not in the federation catalog (it is offline or was never bound)',
    federation_requires_master = 'the peer refused: only a master may change another node\'s connectors',
    remote_unreachable = 'the peer did not answer; nothing is known about whether it changed, so inspect '
      .. 'before repeating the change',
  }
  local hint = hints[error]
  if not hint and error:match('^mcp_approved_tool_missing:') then
    hint = 'the connector no longer lists a tool this node approved; re-probe it, then approve the tool list again'
  end
  return hint and (error .. ' - ' .. hint) or error
end

function M.run(argument, opts)
  opts = opts or {}
  local emit = opts.print or print
  local command = dofile('lua/core/mcp_command.lua')
  local ctx = opts.ctx or { role = 'master' }
  local rest = tostring(argument or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if rest == '' then
    local view = command.list(ctx)
    if view.ok == false then
      emit('  MCP registry unreadable: ' .. tostring(view.registry_error or view.error))
      return view
    end
    emit(command.text(view))
    return view
  end
  local key, verb = rest:match('^(%S+)%s*(%S*)$')
  if verb == '' then
    local detail = command.inspect(ctx, key)
    if not detail.ok then
      emit('  ' .. refusal({ error = detail.error }))
      if detail.keys then emit('  keys: ' .. table.concat(detail.keys, ', ')) end
      return detail
    end
    emit(command.detail_text(detail.connector))
    return detail
  end
  if verb ~= 'on' and verb ~= 'off' and verb ~= 'enable' and verb ~= 'disable' then
    emit('  usage: /mcp [<key>] [on|off]')
    return { ok = false, error = 'usage' }
  end
  local enable = verb == 'on' or verb == 'enable'
  local answer = command.toggle(ctx, key, enable, {})
  if not answer.ok then
    emit('  ' .. tostring(answer.connector or key) .. ' not changed: ' .. refusal(answer))
    return answer
  end
  local state = answer.connector_state
  emit(string.format('  %s: %s%s', tostring(answer.connector), state and state.state or (enable and 'enabled' or 'disabled'),
    answer.revision and (' (revision ' .. tostring(answer.revision) .. ')') or ''))
  if state and state.tool_count then
    emit(string.format('  %d tool%s callable from this connector now.', state.tool_count,
      state.tool_count == 1 and '' or 's'))
  end
  emit('  new sessions see this at once; sessions already running are told on their next turn '
    .. '(the existing [session update] note, because the callable tool list is part of the frozen prefix).')
  return answer
end

return M
