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
  -- A VIEW NEVER WAITS ON ANOTHER NODE (25/11). The chat already passes `cache_only` (chat.lua, operator
  -- 17/11: "/mcp should be instant"), and this makes it the default for every caller, including the one a
  -- test or a later surface adds: only `{ fresh = true }` (or an explicit `cache_only = false`) asks the
  -- fleet from the paint, and `/mcp refresh` is the verb a reader uses instead. The rows say how old the
  -- peer half is, so "cached" is visible rather than implied.
  if opts.cache_only == nil and opts.fresh ~= true then
    local copied = {}
    for key, value in pairs(opts) do copied[key] = value end
    copied.cache_only = true
    opts = copied
  end
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

  -- `/mcp refresh`: ask every online peer for its connectors NOW. The one path of this command that waits
  -- on another node, and only because the reader typed it - the list's own age line names this verb.
  if rest == 'refresh' then
    local answer = command.refresh_peers()
    emit('  ' .. command.refresh_text(answer))
    return answer
  end

  -- `/mcp <key> share <node> [replace]`: copy this node's connector to a peer, disabled there (operator 17/11).
  do
    local share_key, target, flag = rest:match('^(%S+)%s+share%s+(%S+)%s*(%S*)$')
    if share_key or rest:match('^%S+%s+share%s*$') then
      if not target then
        emit('  usage: /mcp <key> share <node> [replace]')
        return { ok = false, error = 'share_usage' }
      end
      local answer = dofile('lua/core/federation.lua').share(target, share_key, { replace = flag == 'replace' })
      if not answer.ok then
        emit('  ' .. tostring(share_key) .. ' not shared with ' .. tostring(target) .. ': ' .. refusal(answer)
          .. (answer.note and (' - ' .. tostring(answer.note)) or ''))
        return answer
      end
      emit(string.format('  %s shared with %s (%d file%s), %s', tostring(share_key), tostring(answer.peer),
        answer.files or 0, (answer.files == 1) and '' or 's', tostring(answer.note)))
      return answer
    end
  end

  -- Round 9: the FIRST two words, not the whole line. `^(%S+)%s*(%S*)$` is anchored at the end, so it
  -- failed on every line with a third word - which is `/mcp <key> on --native <path>` itself: key and verb
  -- came back nil and the command answered 'unknown_connector' instead of reading the voucher. Found by
  -- the CLI test of this round (scripts/test-mcp-vault-approval.lua, section 9); nothing else reaches the
  -- on/probe branches with four words.
  local key, verb = rest:match('^(%S+)%s+(%S+)')
  if not key then key, verb = rest:match('^(%S+)'), '' end
  verb = tostring(verb or '')
  -- `/mcp <key>`: the connector, as a balloon whose root is its page.
  if verb == '' then
    local detail = command.inspect(ctx, key, opts)
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
    -- Round 9: what follows the verb. The old anchored match refused every such line with a generic
    -- 'unknown_connector'; now that key and verb are the first two words, the REST has to be judged here -
    -- an unknown argument is refused by name rather than silently ignored (unknown is not yes).
    local tail = rest:match('^%S+%s+%S+%s*(.*)$') or ''
    -- `/mcp <key> on --native <program>`: the operator vouches for a native binary the digest cannot see
    -- inside, recorded with its sha256 in the approval (docs/VAULT.md). It must name a path: a bare word
    -- is resolved through PATH, which is the thing the approval exists not to trust.
    local native
    if enable then
      local explicit = rest:match('^%S+%s+%S+%s+%-%-native%s+(.+)$')
      if explicit then
        native = explicit:gsub('^%s+', ''):gsub('%s+$', '')
        local absolute = native:sub(1, 1) == '/' or native:match('^%a:/') ~= nil
        if native == '' then
          absolute = false
        end
        if not absolute then
          emit('  --native takes the ABSOLUTE path of a native binary this connector runs: a bare name is '
            .. 'resolved through PATH, which the approval does not trust')
          return { ok = false, error = 'mcp_vault_native_needs_absolute_path' }
        end
      elseif rest:match('%-%-native') then
        emit('  usage: /mcp <key> on --native <absolute path of the binary>')
        return { ok = false, error = 'mcp_vault_native_usage' }
      elseif tail ~= '' then
        emit('  usage: /mcp <key> on [--native <absolute path of the binary>]')
        return { ok = false, error = 'mcp_usage' }
      end
    elseif tail ~= '' then
      emit('  usage: /mcp <key> off')
      return { ok = false, error = 'mcp_usage' }
    end
    local answer = command.toggle(ctx, key, enable, { native = native })
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
    local detail = command.inspect(ctx, key, opts)
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

-- ---------------------------------------------------------------- `wa mcp list`
--
-- The brief's seventh line: "wa mcp list prints the same groups and columns as plain text." So this is not a
-- second table: it is the SAME builder the balloon uses (`mcp_command.list` -> `mcp_command.views`), printed.
-- A reader who compares the window with a pipe must not find two layouts, and a column added to one must
-- appear in the other without anyone remembering to do it.
--
-- `--all` is the pipe's Enter: a pipe cannot open a row, so the folded pages (the connectors on other nodes,
-- the retired entries) and every connector's own page are printed after the list. Without it the words are
-- the window's, exactly.
function M.run_cli(argv, opts)
  opts = opts or {}
  argv = argv or {}
  local emit = opts.print or print
  local verb = tostring(argv[1] or '')
  local function usage()
    emit('usage: wa mcp list [--all] [--refresh] [--width <columns>]   the MCP connectors this node can use')
    emit('  --all      also print the rows the list folds away (other nodes, retired) and each connector')
    emit('  --refresh  ask the other nodes for their connectors now, then print (the list itself never waits)')
    emit('  --width    the column count to lay the rows out for (80 by default)')
  end
  -- A question runs nothing: `wa mcp --help` is the usage and exit 0, like every read-only verb
  -- (lua/core/cli_help.lua lists only the verbs that ACT, and this one cannot).
  if verb == '--help' or verb == '-h' then
    usage()
    return { ok = true, usage = true }
  end
  if verb ~= 'list' then
    usage()
    return { ok = false, error = 'usage', exit = 2 }
  end
  local all, width, refresh, index = false, nil, false, 2
  while index <= #argv do
    local word = tostring(argv[index])
    if word == '--all' then all = true; index = index + 1
    elseif word == '--refresh' then refresh = true; index = index + 1
    elseif word == '--width' then
      width = tonumber(argv[index + 1])
      if not width or width < 20 then
        emit('--width takes the column count, 20 or more')
        return { ok = false, error = 'mcp_usage_width', exit = 2 }
      end
      index = index + 2
    else
      -- An argument nothing recognises is refused by name: a verb that silently ignores half a line is how
      -- an operator ends up believing a flag applied (unknown is not yes).
      emit('wa mcp list does not take ' .. word)
      return { ok = false, error = 'mcp_usage', argument = word, exit = 2 }
    end
  end
  local command = dofile('lua/core/mcp_command.lua')
  -- The operator's own terminal, so the operator's own view: the same context `wa services` uses.
  local ctx = opts.ctx or { role = 'master', user_id = 'cli' }
  -- THE LIST NEVER ASKS ANOTHER NODE (25/11). "wa mcp list" took 3.4-6.4 s on the laptop and 3.5 s here,
  -- and the two waits were a REMOTE one in each half: `federation.catalog()` re-read every online peer's
  -- catalogue when its ten-minute cache was old (up to `federation.BUDGET` = 15 s), and the WhatsApp row
  -- asked the account node for its chat count on every run (2.3 s measured here). Neither number is worth a
  -- blocked prompt: the rows come from the caches and the list PRINTS HOW OLD the peer half is, with the
  -- verb that re-reads it. `--refresh` is that verb, and it is the only thing here that waits.
  local list_options = { cache_only = true, counts = false }
  for key, value in pairs(opts.list_options or {}) do list_options[key] = value end
  if refresh then
    -- An explicit verb may wait: the reader asked for this node's peers to be asked. The chat count comes
    -- with it, because the same reader is asking for the whole picture (`wa mcp list --all` prints it) -
    -- and for that this read must NOT be cache-only: `whatsapp.service_row` forces `counts = false` under
    -- `cache_only` (its own line, 17/11), so passing `counts = true` beneath it reads as nothing.
    -- `cache_only = false` is safe here: the catalogue was just written, so `federation.catalog` answers
    -- from it without asking anyone again (a failed refresh leaves `.tried` behind, which holds RETRY = 60 s).
    emit('  ' .. command.refresh_text(command.refresh_peers()))
    list_options.cache_only = false
    list_options.counts = true
  end
  local view = command.list(ctx, list_options)
  if view.ok == false then
    emit('  MCP registry unreadable: ' .. tostring(view.registry_error or view.error))
    return { ok = false, error = view.registry_error or view.error, exit = 1 }
  end
  local set = command.views(view, { refresh_verb = 'wa mcp list --refresh', max_pages = opts.max_pages,
    list_only = not all })
  -- `keys = false`: a pipe has no keys, so the panel's key hint row ("Enter opens a connector - Esc closes")
  -- is not printed here. The page keeps it for the chat, which does have a keyboard.
  emit(balloon.text(all and set.views or { set.views[1] }, width or balloon.WIDTH, { keys = false }))
  return { ok = true, view = view }
end

return M
