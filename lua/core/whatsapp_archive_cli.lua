-- `wa whatsapp archive ...`: the operator's door to the index archives (docs/WHATSAPP-ARCHIVE.md).
--
-- WHY THIS EXISTS. The live index keeps its window and deletes what leaves it, so an operator needs a
-- command that answers "what has been archived, where is it, what is loaded here, what leaves this
-- node next" without a model turn and without a session. The work is the host's
-- (`host.whatsapp_archive`, `rust/wa-capabilities/src/whatsapp_archive.rs`); this file is the dispatch
-- and the printing, exactly as `lua/core/services_cli.lua` is for `wa services`.
--
-- The verbs are the operator's:
--
--   list                      every archive, its month, counts, size, digest, expiry, and whether the
--                             month is loaded back here
--   cut [YYYY-MM]             cut the oldest month that left the window (or exactly that month, which
--                             must have left it) into its archive file
--   restore <YYYY-MM>         load one archived month back into the index, read-only and marked
--   unload <YYYY-MM>          take a loaded month back out (the archive file stays where it is)
--   push <YYYY-MM> [--to X]   send it to another disk (a path) or another node (a name), verify its
--                             sha256 on arrival and remove the local copy
--   expire                    delete the archives past their 360 days, unloading them first
--
-- Nothing here prints a message: a month, counts, bytes, a digest and a path. `--json` prints the
-- host's own answer instead of the one-line form.
local json = dofile('lua/vendor/json.lua')

local M = {}

local VERBS = {
  list = 'every archive this node holds, and which months are loaded back',
  cut = 'cut the oldest month that left the window (or exactly the month named) into its archive',
  restore = 'load one archived month back into the index, read-only and marked as restored',
  unload = 'take a loaded month back out of the index; the archive file stays',
  push = 'send one archive to another disk or node, verify its sha256 there, drop the local copy',
  expire = 'delete the archives past their 360 days, after unloading them',
}

local function usage(stream)
  stream = stream or 'out'
  local function say(line) if stream == 'err' then io.stderr:write(line .. '\n') else print(line) end end
  say('wa whatsapp archive <verb> [YYYY-MM] [--to <node|dir>] [--keep-local] [--json]')
  for _, verb in ipairs({ 'list', 'cut', 'restore', 'unload', 'push', 'expire' }) do
    say(string.format('  %-8s %s', verb, VERBS[verb]))
  end
  say('')
  say('  A month is UTC (`YYYY-MM`). Restore, unload and push need one; cut takes the oldest that the')
  say('  window has released. A push target that is a path goes to that directory, a single word is a')
  say('  node on the mesh (default `nextcloud`, or WA_WHATSAPP_ARCHIVE_PUSH).')
end

local function ask(request)
  if type(host.whatsapp_archive) ~= 'function' then return nil, 'whatsapp_archive_unavailable' end
  local ok, raw = pcall(host.whatsapp_archive, json.encode(request))
  if not ok then return nil, tostring(raw) end
  local answer = json.decode(tostring(raw or ''))
  if type(answer) ~= 'table' then return nil, 'whatsapp_archive_answer_unreadable' end
  if answer.ok ~= true then return nil, tostring(answer.error or 'whatsapp_archive_failed'), answer end
  return answer
end

local function bytes(n)
  n = tonumber(n) or 0
  if n >= 1024 * 1024 then return string.format('%.1f MiB', n / (1024 * 1024)) end
  if n >= 1024 then return string.format('%.1f KiB', n / 1024) end
  return string.format('%d B', n)
end

-- `YYYY-MM-DD` of an epoch-ms instant, UTC: what an expiry date means in an archive's own calendar.
local function day(ms)
  local days = math.floor((tonumber(ms) or 0) / 86400000)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return string.format('%04d-%02d-%02d', y, m, d)
end

local function text_list(answer)
  local rows = answer.archives or {}
  print(string.format('archives in %s (keeping %s days, then 360 days after the month)',
    tostring(answer.dir or ''), tostring(answer.keep_days or '')))
  if #rows == 0 then
    print('  none yet')
  else
    print(string.format('  %-8s %-9s %-8s %-6s %-10s %-11s %s', 'month', 'messages', 'chats', 'size', 'expires', 'state', 'sha256'))
    for _, row in ipairs(rows) do
      local state = row.restored and 'restored' or 'archived'
      if row.missing then state = 'restored (file pushed away)' end
      print(string.format('  %-8s %-9s %-8s %-6s %-10s %-11s %s', tostring(row.month), tostring(row.messages or 0),
        tostring(row.chats or 0), bytes(row.bytes), day(row.expire_ms), state, tostring(row.sha256 or ''):sub(1, 12)))
    end
  end
  if answer.due then
    print(string.format('due: %s has left the %s-day window and can be cut', tostring(answer.due), tostring(answer.keep_days or '')))
  else
    print('due: nothing - every month still in the index is inside the window')
  end
  local restored = answer.restored or {}
  if #restored > 0 then print('loaded here: ' .. table.concat(restored, ', ')) end
  return 0
end

-- argv is everything after `wa whatsapp`: `archive <verb> ...`.
function M.run(argv)
  local rest = argv or {}
  if rest[1] ~= 'archive' then
    if rest[1] == nil or rest[1] == '-h' or rest[1] == '--help' or rest[1] == 'help' then
      usage(rest[1] and 'out' or 'err')
      return rest[1] and 0 or 2
    end
    io.stderr:write(string.format("whatsapp: unknown command `%s` (the only one is `archive`)\n", tostring(rest[1])))
    usage('err')
    return 2
  end
  local verb = rest[2]
  local as_json = false
  local keep_local = false
  local to
  local positional = {}
  local index = 3
  while index <= #rest do
    local arg = rest[index]
    if arg == '--json' then as_json = true
    elseif arg == '--keep-local' then keep_local = true
    elseif arg == '--to' then index = index + 1; to = rest[index]
    elseif arg == '-h' or arg == '--help' then usage('out'); return 0
    else positional[#positional + 1] = arg end
    index = index + 1
  end
  if verb == nil or verb == '-h' or verb == '--help' then usage(verb and 'out' or 'err'); return verb and 0 or 2 end
  if VERBS[verb] == nil then
    io.stderr:write(string.format("whatsapp: unknown archive verb `%s`\n", tostring(verb)))
    usage('err')
    return 2
  end

  local request = { action = verb, month = positional[1], to = to, keep_local = keep_local }
  if verb == 'push' then
    if keep_local then request.keep_local = true end
  end
  local answer, problem = ask(request)
  if not answer then
    io.stderr:write(string.format('whatsapp archive: %s\n', tostring(problem)))
    return 1
  end
  if as_json then print(json.encode(answer)); return 0 end

  if verb == 'list' then return text_list(answer) end
  if verb == 'cut' then
    if answer.nothing_due then
      print(string.format('cut: nothing due - every month still in the index is inside the %s-day window', tostring(answer.keep_days)))
      return 0
    end
    if not answer.written then
      print(string.format('cut: %s held nothing to archive', tostring(answer.month)))
      return 0
    end
    print(string.format('cut %s: %s messages in %s chats, %s entries, %s', tostring(answer.month),
      tostring(answer.messages), tostring(answer.chats), tostring(answer.entries), bytes(answer.bytes)))
    print(string.format('  %s', tostring(answer.path)))
    print(string.format('  sha256 %s', tostring(answer.sha256)))
    return 0
  end
  if verb == 'restore' then
    print(string.format('restored %s: %s messages (%s), read-only and marked%s', tostring(answer.month),
      tostring(answer.messages), tostring(answer.entries) .. ' entries', answer.again and ' - it was already loaded' or ''))
    return 0
  end
  if verb == 'unload' then
    print(string.format('unloaded %s: %s entries removed from the index (the archive file stays)', tostring(answer.month), tostring(answer.entries)))
    return 0
  end
  if verb == 'push' then
    print(string.format('pushed %s to %s over %s: %s, verified %s%s', tostring(answer.month), tostring(answer.to),
      tostring(answer.transport), bytes(answer.bytes), tostring(answer.verified):sub(1, 12),
      answer.removed_local and ', local copy removed' or ', local copy kept'))
    return 0
  end
  if verb == 'expire' then
    local expired = answer.expired or {}
    if #expired == 0 then print('expire: nothing is past 360 days') else print('expired: ' .. table.concat(expired, ', ')) end
    return 0
  end
  print(json.encode(answer))
  return 0
end

return M
