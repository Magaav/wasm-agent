-- `/mcp` in `wa chat`: one balloon over every connector this node can use.
--
-- The data belongs to `lua/core/mcp_command.lua` (the same object the window renders, and the same pages
-- the client draws mid-run), so this file only drives the balloon: the list, a connector, its tools, and
-- the four verbs that change something - `probe` (reconnect), `on`, `off`, `login`.
--
-- What this replaces: a printed table plus `/mcp <key> on|off` typed by hand. The commands are unchanged
-- (`/mcp whatsapp`, `/mcp whatsapp off` still work, and are what the balloon's own options queue), but
-- nothing here prints a wall of text any more: `balloon` renders the pages, and a pipe gets the same
-- pages rendered as text by the same renderer.
local M = {}

local balloon = dofile('lua/core/balloon.lua')

-- Why a change was refused, in the words of the rule that refused it. The registry's error codes are
-- precise but terse; a reader at a prompt needs the next action, not only the code.
local function refusal(answer)
  local error = tostring(answer.error or 'not_changed')
  local hints = {
    mcp_store_revision_changed = 'the registry moved to revision ' .. tostring(answer.revision)
      .. ' since this list was read; run /mcp again and repeat the change',
    mcp_server_enabled_disable_first = 'turn the connector off first, then remove it',
    mcp_probe_required = 'a connector is only enabled after a probe passed: choose Reconnect first '
      .. '(the window has the same button)',
    forbidden = 'read-only: turning a connector on or off needs a master',
    unknown_connector = 'no connector has that key; /mcp lists them',
    connector_probe_remote = 'a connector is probed on the node that runs it, not from here',
    connector_registry_not_reported = 'that peer reported its tools, not its registry: nothing to toggle here',
    unknown_peer = 'that peer is not in the federation catalog (it is offline or was never bound)',
    federation_requires_master = 'the peer refused: only a master may change another node\'s connectors',
    remote_unreachable = 'the peer did not answer; nothing is known about whether it changed, so inspect '
      .. 'before repeating the change',
  }
  local hint = hints[error]
  if not hint and error:match('^mcp_approved_tool_missing:') then
    hint = 'the connector no longer lists a tool this node approved; reconnect it, then approve the tool list again'
  end
  return hint and (error .. ' - ' .. hint) or error
end

-- The balloon over the whole inventory: the list, a connector, its tools.
--
-- `io` is `lua/core/balloon.lua`'s writer for this chat (`io.show`, `io.say`, `io.publish`). Without one
-- (a test, a caller that only wants the pages) the pages are returned and nothing is drawn.
function M.views(ctx, opts)
  opts = opts or {}
  local command = dofile('lua/core/mcp_command.lua')
  local view = command.list(ctx, opts)
  if view.ok == false then return nil, view end
  return command.views(view, opts)
end

-- One connector's own page as a starting point: `/mcp <key>` opens there instead of at the list.
local function page_of(set, key)
  for index, page in ipairs(set.views) do
    if index > 1 and page.title and (page.title == key or page.title:sub(1, #key + 3) == key .. ' \u{b7}') then
      return index
    end
  end
  return nil
end

function M.run(argument, opts)
  opts = opts or {}
  local io = opts.io
  local command = dofile('lua/core/mcp_command.lua')
  local ctx = opts.ctx or { role = 'master' }
  local emit = opts.print or (io and io.say) or print
  local rest = tostring(argument or ''):gsub('^%s+', ''):gsub('%s+$', '')

  -- `/mcp`: the balloon. Fresh between runs (`opts.cached` unset), from the cache mid-run, and published
  -- for the client either way so a run in flight already has one.
  if rest == '' then
    local set, problem = M.views(ctx, opts)
    if not set then
      emit('  MCP registry unreadable: ' .. tostring(problem.registry_error or problem.error))
      return problem
    end
    if io and io.publish then io.publish('/mcp', set.views, set.captured_at) end
    if io then
      local answer = balloon.drive(io, set.views, { start = opts.start or 1 })
      -- An option that queues a line (`/mcp <key> off`): the balloon returned it, and the line is run by
      -- the caller's own loop - or, mid-run, by the REPL once the turn is over. Say which, once.
      if answer and answer.action == 'run' then
        emit(string.format('  %s: queued - it runs after this turn', tostring(answer.line)))
      end
    end
    return set
  end

  local key, verb = rest:match('^(%S+)%s*(%S*)$')
  verb = tostring(verb or '')
  -- `/mcp <key>`: the connector, as a balloon whose root is its page.
  if verb == '' then
    local detail = command.inspect(ctx, key)
    if not detail.ok then
      emit('  ' .. refusal({ error = detail.error }))
      if detail.keys then emit('  keys: ' .. table.concat(detail.keys, ', ')) end
      return detail
    end
    if io then
      local set = M.views(ctx, opts)
      local start = set and page_of(set, detail.connector.key) or nil
      if set and start then
        if io.publish then io.publish('/mcp', set.views, set.captured_at) end
        local answer = balloon.drive(io, set.views, { start = start })
        if answer and answer.action == 'run' then
          emit(string.format('  %s: queued - it runs after this turn', tostring(answer.line)))
        end
        return detail
      end
      -- No page for it (a connector that left the registry between the two reads): say what it is.
      emit(command.detail_text(detail.connector))
    else
      emit(command.detail_text(detail.connector))
    end
    return detail
  end

  if verb == 'on' or verb == 'off' or verb == 'enable' or verb == 'disable' then
    local enable = verb == 'on' or verb == 'enable'
    local answer = command.toggle(ctx, key, enable, {})
    if not answer.ok then
      emit('  ' .. tostring(answer.connector or key) .. ' not changed: ' .. refusal(answer))
      return answer
    end
    local state = answer.connector_state
    emit(string.format('  %s: %s%s', tostring(answer.connector),
      state and (command.state_label(state)) or (enable and 'connected' or 'disabled'),
      state and (' \u{b7} ' .. tostring(state.tool_count) .. ' tools callable now') or ''))
    emit('  new sessions see this at once; sessions already running are told on their next turn '
      .. '(the existing [session update] note, because the callable tool list is part of the frozen prefix).')
    return answer
  end

  -- "Reconnect": probe the connector again and cache the tool list it reports. The registry's own verb.
  if verb == 'probe' or verb == 'reconnect' then
    local answer = command.probe(ctx, key, {})
    if not answer.ok then
      emit('  ' .. tostring(answer.connector or key) .. ': ' .. refusal(answer)
        .. (answer.note and (' - ' .. tostring(answer.note)) or ''))
      return answer
    end
    local state = answer.connector_state
    emit(string.format('  %s reconnected \u{b7} %s \u{b7} %s callable now', tostring(answer.connector),
      state and command.state_label(state) or 'connected', tostring(answer.tools or 0)))
    return answer
  end

  -- Sign in: store the connector's credential as a vault key and probe again. Offered only where the
  -- definition names the key (`secret_env`); a connector with no such key says so rather than pretending.
  if verb == 'login' or verb == 'signin' then
    local detail = command.inspect(ctx, key)
    if not detail.ok then
      emit('  ' .. refusal({ error = detail.error }))
      return detail
    end
    local entry = detail.connector
    local names = entry.secret_env or {}
    if #names == 0 then
      emit(string.format('  %s names no vault key in its definition: there is nothing to sign in with here.',
        tostring(entry.key)))
      return { ok = false, error = 'connector_has_no_vault_key', connector = entry.key }
    end
    local name = tostring(names[1])
    local page = balloon.page({
      title = 'Sign in to ' .. tostring(entry.key),
      lines = {
        'The credential is stored as the vault key ' .. name .. ' (0600).',
        'The connector reads it at the next probe; this terminal never keeps it.',
      },
      input = 'secret', placeholder = 'paste the credential',
    })
    local value = nil
    if io and io.ask then
      value = io.ask(page)
    else
      emit(balloon.text({ page }))
    end
    if not value or value == '' then
      emit('  nothing stored: Esc leaves the connector as it was')
      return { ok = false, error = 'cancelled', connector = entry.key }
    end
    local stored = dofile('lua/core/keys.lua').set(name, value)
    value = nil
    if not stored.ok then
      emit('  vault: ' .. tostring(stored.error) .. (stored.note and (' - ' .. tostring(stored.note)) or ''))
      return { ok = false, error = stored.error, connector = entry.key }
    end
    emit('  stored ' .. name .. ' in ' .. tostring(stored.path) .. ' (0600)')
    local answer = command.probe(ctx, entry.key, {})
    emit(answer.ok and ('  ' .. tostring(entry.key) .. ' reconnected with the new credential - choose Turn on when it passed')
      or ('  probed again: ' .. refusal(answer)))
    return answer
  end

  emit('  usage: /mcp [<key>] [on|off|probe|login]')
  return { ok = false, error = 'usage' }
end

return M
