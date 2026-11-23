-- Posting on the wa-whatsapp COMPONENT: the operator's switch (docs/WHATSAPP-TRANSCRIPTION.md).
--
-- WHY THIS EXISTS. The gate that decides whether a transcript is delivered is the component's own
-- configuration - `post_transcripts` + `post_allow` (+ `alerts`, `language`), read by
-- `rust/components/wa-whatsapp/src/posting.rs:42-43` - and no tool in this tree could write it: the
-- definition stored on the serving node has no `config` block, so the component starts with posting off
-- and answers `posting off (allow [])` while it transcribes correctly (measured 23/11, openclaw: two
-- notes decoded at 12:04Z, zero `kind=posted` lines in 2896 retained log lines). The one operator door
-- that existed for exactly this switch, `wa_whatsapp_posting`, POSTed to the Go connector's
-- `/operator/posting` - the connector retired in `67c78621` (Phase 4, 11/11). A switch with no target.
--
-- So this module is the switch, and it talks to the component:
--   * read: the definition this node stores (`lua/core/services.lua`, the registry) plus the health line
--     the component prints at start and every `health_every_seconds` (`src/health.rs`);
--   * write: the SAME services path an operator would take by hand - `disable` -> `put` with the new
--     config -> `enable` - because `put` refuses to change a definition that is enabled, and a change
--     this module made by some other route could not be rolled back by `wa services`;
--   * answer: what the COMPONENT says, not what was asked for. The health line is the evidence
--     (`posting=on|off posted=<n>`); when it cannot be read the answer refuses by name - unknown is not
--     yes - and says `written=true`, because the definition WAS changed.
--
-- WHO MAY CHANGE IT: the same authority as every other operator endpoint - a master on this node
-- (`wa_whatsapp_posting` gates on `require_master`, and this module refuses anything that is not master
-- again, plus a child agent). The allow list is NEVER logged, NEVER echoed in a refusal and NEVER
-- written into this repository: a refusal says which POSITION was refused, not what it held.
--
-- The allow list's accepted forms are the component's own gate (`posting.rs` `allowed`): `own` (the
-- account's own chat), `*` (every chat: the cutover setting), or one exact chat JID
-- (`<digits>@s.whatsapp.net`, `<digits>@lid`, `<id>@g.us`). Anything else is refused by name instead of
-- being stored and silently never matching.
local json = dofile('lua/vendor/json.lua')
local services = dofile('lua/core/services.lua')

local M = {}

M.SERVICE = 'wa-whatsapp'
-- The log window read for the health line. The component prints one every `health_every_seconds`
-- (default 300 s), so a 64 KiB tail holds several unless the log is noisy in between.
M.LOG_BYTES = 64 * 1024
M.ALLOW_MAX = 64
M.ALLOW_ENTRY_MAX = 64
-- The language codes the pipeline accepts: `rust/components/wa-whatsapp/src/guest.rs:720` refuses
-- anything else as `language_must_be_en_pt_auto`.
M.LANGUAGES = { en = true, pt = true, auto = true }
-- The variables the REMOVED connector's door read. They are named so an operator can be told to delete
-- them; their values are never read, never used and never printed - the removed transport is gone.
M.LEGACY_ENV = { 'WA_WHATSAPP_POSTING_URL', 'WA_WHATSAPP_ACCOUNT', 'WA_WHATSAPP_GENERATION',
  'WA_WHATSAPP_READ_TOKEN_FILE', 'WA_WHATSAPP_APPROVAL_TOKEN_FILE' }
-- Request fields only the connector's API ever carried. A caller built for that door is refused BY NAME
-- here rather than being obeyed against the component with half its intent dropped.
M.LEGACY_FIELDS = { 'account', 'generation', 'posting_url', 'target_url' }

local function fail(error, extra)
  local answer = extra or {}
  answer.ok = false
  answer.error = error
  return answer
end

-- The same authority as the operator endpoints: master, never a child agent. `services.lua` refuses a
-- guest and a child agent again for every write this module makes, so this is the read half of it.
local function master_ctx(ctx)
  ctx = ctx or {}
  if ctx.subagent then return false end
  local users = dofile('lua/core/users.lua')
  if type(users.is_master) ~= 'function' then return false end
  return users.is_master(ctx.role)
end

-- The connector's environment, as NAMES. A node still carrying these has stale configuration nobody
-- should keep: the URL points at a service that does not exist, and nothing here calls it.
local function legacy_env()
  local names = {}
  for _, name in ipairs(M.LEGACY_ENV) do
    local ok, value = pcall(function() return host.getenv(name) end)
    if ok and type(value) == 'string' and value ~= '' then names[#names + 1] = name end
  end
  if #names == 0 then return nil end
  return { variables = names,
    note = 'these variables configured the Go connector that was removed on 11/11; nothing reads them'
      .. ' and nothing calls that URL any more - delete them from this node\'s environment' }
end

-- ---- the allow list -------------------------------------------------------------------------------
-- An allow-list of accepted FORMS (never a block-list): exactly what the component's own gate matches.
-- `own` and `*` are the two words `posting.rs` knows; the rest are exact JIDs.
local function allow_entry_ok(entry)
  if type(entry) ~= 'string' then return false end
  if entry == 'own' or entry == '*' then return true end
  if entry == '' or #entry > M.ALLOW_ENTRY_MAX then return false end
  if entry:match('^%d+@s%.whatsapp%.net$') then return true end
  if entry:match('^%d+@lid$') then return true end
  if entry:match('^[%d%-]+@g%.us$') then return true end
  return false
end

--- Validate a requested allow list. (nil, normalized list) when it is usable, else a refusal.
--- The refusal names the POSITION and the accepted forms, never the entry that failed.
function M.validate_allow(list)
  if type(list) ~= 'table' then return fail('posting_allow_required', {
    note = 'post_allow is a list of chat scopes: "own", "*", or one exact chat JID'
      .. ' (<digits>@s.whatsapp.net, <digits>@lid, <id>@g.us)' }) end
  if #list == 0 then return fail('posting_allow_required', {
    note = 'an empty allow list posts nowhere; turn posting off with enabled=false instead of leaving a'
      .. ' list that matches nothing' }) end
  if #list > M.ALLOW_MAX then return fail('posting_allow_too_many', { limit = M.ALLOW_MAX }) end
  local seen, normalized = {}, {}
  for index, entry in ipairs(list) do
    if not allow_entry_ok(entry) then
      return fail('posting_allow_invalid', { index = index,
        note = 'one allow-list entry is not an accepted form. Accepted: "own", "*", or one exact chat'
          .. ' JID (<digits>@s.whatsapp.net, <digits>@lid, <id>@g.us). The refused entry is not repeated'
          .. ' here on purpose: the allow list is never echoed back' })
    end
    if not seen[entry] then seen[entry] = true; normalized[#normalized + 1] = entry end
  end
  return nil, normalized
end

-- ---- the "every chat" scope -----------------------------------------------------------------------
--- How many chats `"*"` covers, from the component's own index: a COUNT, never a list of ids.
--- (`lua/core/whatsapp.lua` answers it from a `contacts` call with no query, which the component counts
--- over its index.) Unknown stays unknown: the answer names it instead of inventing a number.
function M.all_chats()
  local loaded, whatsapp = pcall(dofile, 'lua/core/whatsapp.lua')
  if not loaded or type(whatsapp) ~= 'table' or type(whatsapp.holds_account) ~= 'function' then
    return { chats = nil, covers = 'every chat, groups included', unverified = 'whatsapp_index_count_unreadable',
      note = 'the account is not served by a component on this node, so its index cannot be counted here' }
  end
  if not whatsapp.holds_account() then
    return { chats = nil, covers = 'every chat, groups included', unverified = 'whatsapp_posting_account_elsewhere',
      note = 'this node does not hold the WhatsApp account, so the index that would count the chats is elsewhere' }
  end
  local answer = whatsapp.invoke(whatsapp.by_verb.contacts, { limit = 1 })
  local index = type(answer) == 'table' and answer.index or nil
  local chats = type(index) == 'table' and tonumber(index.chats) or nil
  if not chats then
    return { chats = nil, covers = 'every chat, groups included', unverified = 'whatsapp_index_count_unreadable',
      note = 'the component did not answer how many chats its index holds, so what "*" covers is unknown here' }
  end
  return { chats = chats, covers = 'every chat, groups included', source = 'index' }
end

-- ---- the stored definition ------------------------------------------------------------------------
local function store_row(name)
  local inventory = services.inventory()
  for _, row in ipairs(inventory.services or {}) do
    if row.name == name then return row, inventory end
  end
  return nil, inventory
end

-- The four keys this verb owns, as the component reads them (`PostConfig::from_json`). Every other key
-- in the definition's config is left exactly as it was: this verb is not the owner of `stream_edits`,
-- `held_chats`, `pair_phone`, `health_every_seconds` or the index settings.
local function owned(cfg)
  cfg = type(cfg) == 'table' and cfg or {}
  local allow = {}
  if type(cfg.post_allow) == 'table' then
    for _, entry in ipairs(cfg.post_allow) do
      if type(entry) == 'string' then allow[#allow + 1] = entry end
    end
  end
  return { enabled = cfg.post_transcripts == true, allow = allow, alerts = cfg.alerts == true,
    language = type(cfg.language) == 'string' and cfg.language or 'pt' }
end

local function copy_map(value)
  local out = {}
  if type(value) == 'table' then for key, item in pairs(value) do out[key] = item end end
  return out
end

-- Is `a` the same owned configuration as `b`? Field by field, never by an encoded string: a definition
-- that already says what was asked for must not be rewritten (and must not restart the component).
local function same_owned(a, b)
  if a.enabled ~= b.enabled or a.alerts ~= b.alerts or a.language ~= b.language then return false end
  if #a.allow ~= #b.allow then return false end
  for index = 1, #a.allow do if a.allow[index] ~= b.allow[index] then return false end end
  return true
end

-- ---- what the component says ----------------------------------------------------------------------
--- Parse the health line out of a component log. Returns (health) or (nil, refusal).
---
--- Freshness is not assumed: every run prints `clock: ...` as its first line, so only the tail AFTER the
--- last one is read. A health line inherited from a previous instance would answer for a configuration
--- that is no longer in place, which is exactly the mistake this verb exists to end.
function M.parse_health(log)
  if type(log) ~= 'string' or log == '' then return nil, 'whatsapp_posting_health_unreadable' end
  local start
  for index in log:gmatch('()clock: ') do start = index end
  if not start then return nil, 'whatsapp_posting_health_unreadable' end
  local run = log:sub(start)
  local health
  for line in run:gmatch('[^\n]+') do
    if line:find('health: v=1 ', 1, true) then
      local posting = line:match('posting=(%a+)')
      if posting then
        health = {
          posting = posting,
          posted = tonumber(line:match('posted=(%d+)') or '') or 0,
          last_post = line:match('last_post=(%S+)'),
          transcripts = tonumber(line:match('ok=(%d+)') or '') or 0,
          failed = tonumber(line:match('failed=(%d+)') or '') or 0,
          reason = line:match('reason=(%S+)'),
        }
      end
    end
  end
  -- The mode the running instance STARTED with, which is the config it read: the gate for whether the
  -- health line describes the definition this node stores now.
  local language, configured
  for line in run:gmatch('[^\n]+') do
    if line:find('transcription: language ', 1, true) then
      configured = line:match('posting (%a+) %(allow') or configured
      language = line:match('transcription: language (%S+),') or language
    end
  end
  if not health then return nil, 'whatsapp_posting_health_unreadable' end
  health.configured = configured
  health.language = language
  return health
end

--- The health line the component reports now, or (nil, refusal).
function M.health()
  if type(host.service) ~= 'function' then return nil, 'whatsapp_posting_component_unavailable' end
  local ok, raw = pcall(host.service, json.encode({ action = 'logs', name = M.SERVICE, bytes = M.LOG_BYTES }))
  if not ok or type(raw) ~= 'string' then return nil, 'whatsapp_posting_health_unreadable' end
  local decoded, answer = pcall(json.decode, raw)
  if not decoded or type(answer) ~= 'table' or answer.ok ~= true then
    return nil, 'whatsapp_posting_health_unreadable'
  end
  return M.parse_health(answer.log)
end

-- ---- the two verbs --------------------------------------------------------------------------------
--- What is stored, what the host says the component is doing, and what the component itself reports.
function M.status(ctx)
  if not master_ctx(ctx) then return fail('forbidden') end
  local row = store_row(M.SERVICE)
  if not row then
    return fail('whatsapp_posting_component_missing', {
      note = 'this node stores no `' .. M.SERVICE .. '` service component, so it has no posting gate to'
        .. ' read; `wa services list` names what it does run' })
  end
  local cfg = owned(row.definition.config)
  local live = type(row.live) == 'table' and row.live or {}
  local answer = {
    ok = true,
    name = M.SERVICE,
    enabled = cfg.enabled,
    allow = cfg.allow,
    allow_count = #cfg.allow,
    alerts = cfg.alerts,
    language = cfg.language,
    connection = tostring(live.state or 'not_running'),
    live = row.enabled == true and tostring(live.state or '') ~= 'stopped',
    stored = true,
  }
  if live.sha256 then answer.sha256 = tostring(live.sha256) end
  -- The one scope that is not a name: say what it covers, as a count from the index.
  for _, entry in ipairs(cfg.allow) do
    if entry == '*' then answer.all_chats = M.all_chats(); break end
  end
  local legacy = legacy_env()
  if legacy then answer.connector_removed = legacy end
  if row.enabled then
    local health, problem = M.health()
    if health then
      answer.posting = health.posting
      answer.posted = health.posted
      answer.last_post = health.last_post
      answer.health = health
      answer.verified = health.configured == nil or health.configured == (cfg.enabled and 'on' or 'off')
      if not answer.verified then
        answer.note = 'the component is running an older configuration than the one this node stores;'
          .. ' its next start reads the stored definition'
      end
    else
      answer.posting = 'unknown'
      answer.unverified = problem
    end
  else
    answer.posting = 'unknown'
    answer.live = false
    answer.unverified = 'whatsapp_posting_component_not_running'
    answer.note = 'the component is stored disabled, so nothing is running to report its posting mode;'
      .. ' `wa services enable ' .. M.SERVICE .. '` starts it'
  end
  return answer
end

--- Change the switch. Writes through the services path, restarts safely, and answers with the state the
--- component reports - or refuses by name and says whether the definition was changed.
function M.set(args, ctx)
  if not master_ctx(ctx) then return fail('forbidden') end
  args = type(args) == 'table' and args or {}
  if args.enabled ~= nil and type(args.enabled) ~= 'boolean' then
    -- The code the old door answered, kept: a caller that sent "true" must not be read as on.
    return fail('posting_enabled_boolean_required')
  end
  local allow
  if args.allow ~= nil then
    local refusal, normalized = M.validate_allow(args.allow)
    if refusal then return refusal end
    allow = normalized
  end
  local language
  if args.language ~= nil then
    language = type(args.language) == 'string' and args.language:lower() or ''
    if not M.LANGUAGES[language] then
      return fail('posting_language_invalid', { accepted = { 'en', 'pt', 'auto' },
        note = 'the component transcribes in one of these three and refuses anything else' })
    end
  end
  if args.alerts ~= nil and type(args.alerts) ~= 'boolean' then return fail('posting_alerts_boolean_required') end
  if args.all_chats ~= nil and type(args.all_chats) ~= 'boolean' then return fail('posting_all_chats_boolean_required') end
  if args.enabled == nil and allow == nil and args.alerts == nil and language == nil then
    return fail('posting_change_required', {
      note = 'name at least one of enabled (boolean), allow (list), alerts (boolean), language (en|pt|auto)' })
  end
  local row = store_row(M.SERVICE)
  if not row then
    return fail('whatsapp_posting_component_missing', {
      note = 'this node stores no `' .. M.SERVICE .. '` service component, so there is no definition to'
        .. ' change; `wa services list` names what it does run' })
  end
  local definition = copy_map(row.definition)
  local config = copy_map(definition.config)
  local before = owned(config)
  local wanted = copy_map(before)
  if args.enabled ~= nil then config.post_transcripts = args.enabled; wanted.enabled = args.enabled end
  if allow ~= nil then config.post_allow = allow; wanted.allow = allow end
  if args.alerts ~= nil then config.alerts = args.alerts; wanted.alerts = args.alerts end
  if language ~= nil then config.language = language; wanted.language = language end
  local was_enabled = row.enabled == true
  -- "*" is every chat, groups included, and it is the setting that made this mission necessary. Naming it
  -- on this request takes a second word, so a list cannot be widened by a typo or a copy-paste: "own" and
  -- an exact JID need no flag.
  local wildcard = false
  for _, entry in ipairs(wanted.allow) do if entry == '*' then wildcard = true end end
  if wildcard and args.allow ~= nil and args.all_chats ~= true then
    return fail('posting_all_chats_unconfirmed', { covers = 'every chat, groups included',
      note = '"*" posts to EVERY chat, groups included. Name it twice: `wa whatsapp posting allow \'*\''
        .. ' --all-chats` (or {"action":"set","allow":["*"],"all_chats":true} on the operator endpoint).'
        .. ' "own" and exact chat JIDs need no flag' })
  end
  if wanted.enabled and #wanted.allow == 0 then
    -- `post_transcripts: true` with an empty list is the shadow mode that made this mission necessary:
    -- the gate says on and nothing is ever delivered. A switch that posts nowhere is a refusal by name.
    return fail('posting_allow_required', { note = 'posting cannot be turned on with an empty allow list:'
      .. ' an empty list posts nowhere. Name the chats it may reach - "own" for the account\'s own chat,'
      .. ' "*" for every chat, or exact JIDs - or turn posting off with enabled=false' })
  end
  if same_owned(before, wanted) then
    -- Already exactly this: no write, no restart, and the answer is the live state.
    local answer = M.status(ctx)
    answer.unchanged = true
    return answer
  end
  definition.config = config

  -- The write: `disable` -> `put` -> `enable`, the supported path (an enabled definition cannot be
  -- replaced, and the boot decision is the operator's, so it is put back exactly as it was).
  local function control(request)
    request.expected_revision = services.inventory().revision
    return services.control(request, { role = 'master', user_id = ctx.user_id, session_id = ctx.session_id })
  end
  local previous = row.definition
  if was_enabled then
    local stopped = control({ action = 'disable', name = M.SERVICE })
    if not stopped.ok then
      return fail('whatsapp_posting_write_refused', { stage = 'disable', detail = stopped.error,
        written = false, note = 'nothing was changed: the component could not be stopped through the'
          .. ' services registry, so its definition was left exactly as it was' })
    end
  end
  local written = control({ action = 'put', name = M.SERVICE, definition = definition })
  if not written.ok then
    local restored
    if was_enabled then restored = control({ action = 'enable', name = M.SERVICE }).ok == true end
    return fail('whatsapp_posting_write_refused', { stage = 'put', detail = written.error,
      written = false, restored = restored,
      note = 'the new definition was refused and the old one is still stored'
        .. (restored and '; the component is running again on it' or '; the component is NOT running') })
  end
  if was_enabled then
    local started = control({ action = 'enable', name = M.SERVICE })
    if not started.ok then
      -- A definition written but not runnable is worse than either state: put the old one back.
      control({ action = 'disable', name = M.SERVICE })
      local back = control({ action = 'put', name = M.SERVICE, definition = previous })
      local back_started = back.ok and control({ action = 'enable', name = M.SERVICE })
      local restored = (back.ok and back_started and back_started.ok) == true
      return fail('whatsapp_posting_start_refused', { stage = 'enable', detail = started.error,
        written = false, restored = restored,
        note = 'the component refused to start on the new definition, so the previous definition was put'
          .. ' back' .. (restored and ' and started' or ' but could not be started - the component is NOT running') })
    end
  end

  -- Read the stored definition back: the write is only done when the store says so.
  local after_row = store_row(M.SERVICE)
  local after = after_row and owned(after_row.definition.config)
  if not after or not same_owned(after, wanted) then
    return fail('whatsapp_posting_store_unverified', { written = true,
      note = 'the services registry answered ok but the stored definition does not read back as asked;'
        .. ' check `wa services status ' .. M.SERVICE .. '` before trusting this switch' })
  end
  local answer = M.status(ctx)
  answer.ok = true
  answer.error = nil
  answer.written = true
  answer.restarted = was_enabled == true
  answer.before = before
  if was_enabled and (answer.posting == nil or answer.posting == 'unknown') then
    -- Unknown is not yes: the definition is stored and the component was restarted, but nothing said
    -- whether it is posting, and this verb will not report a switch it could not observe.
    return fail('whatsapp_posting_unverified', { written = true, unverified = answer.unverified,
      enabled = wanted.enabled, allow_count = #wanted.allow, alerts = wanted.alerts,
      language = wanted.language, connection = answer.connection,
      note = 'the definition was written and the component was restarted, but its health line could'
        .. ' not be read, so the effective mode is unknown; read `wa services logs ' .. M.SERVICE .. '`' })
  end
  if answer.posting and answer.posting ~= 'unknown' then
    -- The component is the authority on whether it is posting; the health line it printed after this
    -- restart is the evidence. A mode it did not reach is a refusal, not a success.
    local expected = wanted.enabled and 'on' or 'off'
    if answer.posting ~= expected then
      return fail('whatsapp_posting_not_effective', { written = true, posting = answer.posting,
        expected = expected, allow_count = #wanted.allow, alerts = wanted.alerts,
        language = wanted.language, connection = answer.connection,
        note = 'the definition was written and the component restarted, but the health line it printed'
          .. ' does not carry the mode that was asked for' })
    end
  end
  return answer
end

--- The one entry point both doors use (the operator endpoint in `lua/core/server.lua` and
--- `wa whatsapp posting`): the gate, the removed connector's refusal, and the two verbs.
function M.answer(args, ctx)
  args = type(args) == 'table' and args or {}
  if not master_ctx(ctx) then return fail('forbidden') end
  for _, field in ipairs(M.LEGACY_FIELDS) do
    if args[field] ~= nil then
      return fail('whatsapp_posting_connector_removed', {
        note = 'this request carries `' .. field .. '`, a field of the Go connector API removed on 11/11.'
          .. ' This switch talks to the `' .. M.SERVICE .. '` component: send {action="status"} to read it'
          .. ' or {action="set", enabled=..., allow=..., alerts=..., language=...} to change it' })
    end
  end
  local action = tostring(args.action or 'status')
  if action == 'status' then return M.status(ctx) end
  if action == 'set' then return M.set(args, ctx) end
  return fail('invalid_posting_action')
end

return M
