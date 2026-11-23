-- `wa whatsapp posting ...`: the operator's door to the component's posting switch.
--
-- WHY THIS EXISTS. The switch has a decision logic of its own (`lua/core/whatsapp_posting.lua`): the
-- allow-list gate, the write through the services registry, the safe restart, and the health line the
-- component answers with. This file is the dispatch and the printing, exactly as
-- `lua/core/services_cli.lua` is for `wa services` - so the operator at the machine, the operator
-- endpoint (`POST /whatsapp/posting`) and any future peer door cannot disagree about what a verb means.
--
-- The verbs:
--   status                 what is stored, whether the component is running, and what it reports
--                          (its health line: posting=on|off, posted=<n>)
--   on | off               turn posting on or off on the component
--   allow <entry,...>      the chats posting may reach: own, *, or exact chat JIDs
--   alerts on|off          the own-chat alert for a note that could not be transcribed
--   language en|pt|auto    the language the pipeline transcribes in
--
-- Nothing here prints a message, a chat id or a transcript; `--json` prints the module's own answer.
-- A refusal is printed to stderr with a non-zero exit, because "it refused" must never read as "it is
-- on".
local json = dofile('lua/vendor/json.lua')
local posting = dofile('lua/core/whatsapp_posting.lua')

local M = {}

local VERBS = {
  status = 'what is stored, whether the component runs, and what its health line reports',
  on = 'post the transcript of every allowed chat',
  off = 'post nothing (transcription keeps working)',
  allow = 'the chats posting may reach: own, exact chat JIDs, or * with --all-chats (every chat, groups included)',
  alerts = 'the own-chat alert when a note could not be transcribed: on|off',
  language = 'the language the pipeline transcribes in: en|pt|auto',
}

local function usage(stream)
  stream = stream or 'out'
  local function say(line) if stream == 'err' then io.stderr:write(line .. '\n') else print(line) end end
  say('wa whatsapp posting <verb> [--all-chats] [--json]')
  for _, verb in ipairs({ 'status', 'on', 'off', 'allow', 'alerts', 'language' }) do
    say(string.format('  %-9s %s', verb, VERBS[verb]))
  end
  say('')
  say('  The switch is the `' .. posting.SERVICE .. '` service component\'s own configuration. A change is')
  say('  written through the services registry (disable -> put -> enable), so `wa services` and this verb')
  say('  cannot disagree about the definition, and the answer is the health line the component prints.')
  say('  "*" is every chat, groups included: it takes the second word --all-chats, and the answer says')
  say('  how many chats it covers (a count from the component index, never the ids). "own" needs no flag.')
  say('  Master only: the allow list is never printed back in a refusal and never logged.')
end

local function fail(code, message)
  io.stderr:write(string.format('whatsapp posting: %s\n', message))
  return code
end

--- The state, printed. `--json` prints the module's answer instead of this shape.
local function text_state(answer)
  print(string.format('posting   %s', answer.enabled and 'on' or 'off'))
  if type(answer.allow) == 'table' and #answer.allow > 0 then
    print(string.format('allow     %s', table.concat(answer.allow, ', ')))
  else
    print('allow     (none: nothing may be posted)')
  end
  print(string.format('alerts    %s', answer.alerts and 'on' or 'off'))
  print(string.format('language  %s', tostring(answer.language)))
  if type(answer.all_chats) == 'table' then
    local cover = answer.all_chats
    if tonumber(cover.chats) then
      print(string.format('covers    %s (%d %s in the index)', tostring(cover.covers or 'every chat, groups included'),
        tonumber(cover.chats), tonumber(cover.chats) == 1 and 'chat' or 'chats'))
    else
      print(string.format('covers    %s (the index\'s chat count is unknown: %s)',
        tostring(cover.covers or 'every chat, groups included'), tostring(cover.unverified or 'unavailable')))
    end
  end
  print(string.format('component %s', tostring(answer.connection or 'unknown')))
  if answer.health then
    print(string.format('health    posting=%s posted=%s last_post=%s', tostring(answer.health.posting),
      tostring(answer.health.posted), tostring(answer.health.last_post)))
  elseif answer.unverified then
    print(string.format('health    unavailable (%s)', tostring(answer.unverified)))
  end
  if answer.connector_removed then
    print(string.format('stale     %s', table.concat(answer.connector_removed.variables or {}, ', ')))
  end
  if answer.written then
    print(string.format('written   yes%s', answer.restarted and ' (component restarted)' or ''))
  end
  if answer.unchanged then print('written   no (already this)') end
  if answer.note then print('note      ' .. tostring(answer.note)) end
  return 0
end

--- One verb, its answer printed. A refusal exits non-zero and names itself.
local function apply(args, want_json)
  local answer = posting.answer(args, { role = 'master', user_id = 'cli' })
  if type(answer) ~= 'table' then return fail(1, 'the module answered nothing') end
  if want_json then print(json.encode(answer)) end
  if answer.ok == false or answer.error then
    -- The refusal's own sentence travels with the code: a refusal a reader cannot act on (which flag,
    -- which form) is half a refusal. Nothing in these sentences is an allow-list entry.
    if type(answer.note) == 'string' and answer.note ~= '' then io.stderr:write('whatsapp posting: ' .. answer.note .. '\n') end
    return fail(1, string.format('%s: %s', tostring(args.action or 'status'), tostring(answer.error)))
  end
  return want_json and 0 or text_state(answer)
end

--- `wa whatsapp posting ...`: dispatch and print. Returns the process exit code.
function M.run(argv)
  argv = type(argv) == 'table' and argv or {}
  local verb = tostring(argv[1] or '')
  local want_json, all_chats, rest = false, false, {}
  for index = 2, #argv do
    if argv[index] == '--json' then want_json = true
    elseif argv[index] == '--all-chats' then all_chats = true
    else rest[#rest + 1] = argv[index] end
  end
  if verb == '' or verb == 'status' then return apply({ action = 'status' }, want_json) end
  if verb == 'help' or verb == '--help' or verb == '-h' then usage('out'); return 0 end
  if VERBS[verb] == nil then
    io.stderr:write(string.format('whatsapp posting: unknown verb %q\n', verb))
    usage('err')
    return 2
  end
  if verb == 'on' or verb == 'off' then
    if rest[1] ~= nil then return fail(2, verb .. ' takes no argument') end
    return apply({ action = 'set', enabled = verb == 'on' }, want_json)
  end
  if verb == 'allow' then
    local text = tostring(rest[1] or '')
    if text == '' then return fail(2, 'allow needs the chats it may reach: own, *, or exact JIDs') end
    local list = {}
    for entry in text:gmatch('[^,]+') do
      local trimmed = entry:gsub('^%s+', ''):gsub('%s+$', '')
      if trimmed ~= '' then list[#list + 1] = trimmed end
    end
    return apply({ action = 'set', allow = list, all_chats = all_chats }, want_json)
  end
  if verb == 'alerts' then
    local value = tostring(rest[1] or '')
    if value ~= 'on' and value ~= 'off' then return fail(2, 'alerts needs on or off') end
    return apply({ action = 'set', alerts = value == 'on' }, want_json)
  end
  local value = tostring(rest[1] or '')
  if value == '' then return fail(2, 'language needs one of en, pt, auto') end
  return apply({ action = 'set', language = value }, want_json)
end

return M
