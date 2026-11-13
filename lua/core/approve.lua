-- Operator approval of outgoing WhatsApp drafts: `/approve` in `wa chat`, `wa approve` on the CLI.
--
-- The gate itself is NOT here. It is in the node that holds the account, at the one place a send
-- arrives from anywhere in the fleet: `whatsapp_send::send` asks `whatsapp_approve::gate` before it
-- queues anything (`rust/wa-capabilities/src/whatsapp_approve.rs`, docs/APPROVE.md). A node that was
-- never configured cannot bypass it, and a run of the model does not need to be told about it: with
-- the switch on, `mcp_whatsapp_send` answers `pending` with a draft handle instead of a job id, and
-- the message waits.
--
-- What this file is, then, is the operator's side:
--
--   * the switch, `/approve on|off|status`, and the per-chat rules (`only`/`except`), all asked of
--     the ACCOUNT node through the same routed call every other WhatsApp question uses - the policy
--     that matters is the one where the send lands;
--   * the queue of drafts, read the same way, so a reader on any node sees what is waiting;
--   * the decision, `send` (as is), `edit` (the operator's text becomes the message) or `reject` (a
--     note), each one routed to the outbox that will settle the caller's pending handle;
--   * the balloon the operator decides in (`lua/core/balloon.lua`): the draft, its chat by name and
--     JID, its text, and Enter / [e] / [r];
--   * the evaluation record (`wa eval report`): what the operator did with each draft, per chat, so
--     "should we let it talk on its own" is a number and not an impression.
--
-- A draft is never sent by this file. It is sent by the decision, on the account node, through the
-- ordinary enqueue - the same policy check and the same queue as a send that never needed approval.
local json = dofile('lua/vendor/json.lua')

local M = {}

-- The one overlay (`lua/core/balloon.lua`): every page this file draws is a balloon page, and a pipe
-- gets the same pages as text from the same renderer. Read once at load, like every other command
-- module (`lua/core/mcp_cli.lua` has the same line): under live reload (`docs/HOTRELOAD.md`) this file
-- is compiled into a fresh environment whose `dofile` is routed, so a reloaded `/approve` draws with
-- the reload tree's balloon, and this module keeps no state of its own that a swap would drop.
local balloon = dofile('lua/core/balloon.lua')

-- The one routed door. `whatsapp.route` names the node that holds the account (nil = this one), and
-- `whatsapp.forward` is the ordinary remote call with the answer kept as it is. A test injects
-- `ctx.remote_call`, exactly as the send tests do.
local function ask(args, ctx)
  local whatsapp = dofile('lua/core/whatsapp.lua')
  ctx = ctx or {}
  local owner = whatsapp.route(ctx)
  if owner == nil then return whatsapp.call('mcp_whatsapp_approve', args, ctx) end
  return whatsapp.forward(owner, 'mcp_whatsapp_approve', args, ctx.remote_call)
end
M.ask = ask

-- ---------------------------------------------------------------- the switch

--- This node's... no: the ACCOUNT node's policy. `ok` false carries the reason.
function M.policy(ctx)
  return ask({ action = 'policy' }, ctx)
end

--- Change the policy. `opts` is `{on = bool, mode = "all"|"only"|"except", chats = {...}}`; a field
--- left out is left as it is, which is what `/approve except <chat>` needs (it adds a chat without
--- turning the switch on by itself... unless it says `on`).
function M.set(ctx, opts)
  opts = opts or {}
  return ask({ action = 'policy_set', on = opts.on, mode = opts.mode, chats = opts.chats }, ctx)
end

-- ---------------------------------------------------------------- the drafts

--- Every draft the account node holds, oldest first, plus how many are still undecided.
function M.list(ctx)
  local answer = ask({ action = 'list' }, ctx)
  if type(answer) ~= 'table' then return { ok = false, error = 'whatsapp_approve_unreadable' } end
  answer.drafts = answer.drafts or {}
  return answer
end

--- One draft, with the outbox job folded in (a settled send carries its message id).
function M.status(ctx, handle)
  return ask({ action = 'status', draft = handle }, ctx)
end

--- The decision. `decision` is send, edit, reject or cancel; `text` is the final text for an edit and
--- `note` the operator's words for a rejection.
function M.decide(ctx, handle, decision, text, note)
  local answer = ask({ action = 'decide', draft = handle, decision = decision, text = text, note = note }, ctx)
  -- Every settled decision is recorded HERE, whoever asked: the balloon's key, a `/approve` line, the
  -- CLI, and a script that decides a draft of its own. A refusal, and a draft that is still waiting,
  -- record nothing - there is no decision to evaluate.
  if type(answer) == 'table' and answer.ok ~= false and type(answer.draft) == 'table'
    and answer.draft.state ~= 'pending' then
    answer.record = M.record(answer.draft, {
      outcome = answer.draft.outcome or answer.draft.state,
      final_text = answer.draft.final,
      decided_at = answer.draft.decided_at,
    })
  end
  return answer
end

--- The drafts still waiting, oldest first. A `pending` draft is the only one an operator decides.
function M.waiting(ctx)
  local answer = M.list(ctx)
  local rows = {}
  for _, draft in ipairs(answer.drafts or {}) do
    if draft.state == 'pending' then rows[#rows + 1] = draft end
  end
  return rows, answer
end

-- ---------------------------------------------------------------- chats: an exact JID, or a name

--- An exact JID, in the four shapes the outbox can send to (`wa-whatsapp-outbox::Chat::parse`,
--- restated because a rule that lives in one language leaves the other guessing).
local function exact_jid(text)
  if type(text) ~= 'string' then return false end
  text = text:gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' or #text > 129 or text:find('[%s%c]') then return false end
  local user, server = text:match('^(.-)@([%w%.]+)$')
  if not user or not server or user:find(':') then return false end
  local function digits(value) return value ~= '' and value:match('^%d+$') ~= nil end
  if server == 's.whatsapp.net' or server == 'c.us' or server == 'lid' then return digits(user) end
  if server ~= 'g.us' then return false end
  local creator, epoch = user:match('^(%d+)%-(%d+)$')
  return digits(user) or (creator ~= nil and epoch ~= nil)
end
M.exact_jid = exact_jid

--- Turn one token into the exact JID the policy has to name: an exact JID stays itself, and a name
--- is resolved through the same ranking the read tool uses. An ambiguous name is never picked - the
--- refusal carries the candidates, because gating the wrong Laura is the mistake this must not make.
---
--- Returns `jid` or `nil, refusal`.
function M.resolve(token, ctx)
  token = tostring(token or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if token == '' then return nil, { ok = false, error = 'whatsapp_approve_chat_required' } end
  if exact_jid(token) then return (token:gsub('@c%.us$', '@s.whatsapp.net')) end
  local whatsapp = dofile('lua/core/whatsapp.lua')
  local answer = whatsapp.call('mcp_whatsapp_contacts', { q = token, limit = 5 }, ctx or {})
  if type(answer) ~= 'table' then return nil, { ok = false, error = 'whatsapp_approve_lookup_failed' } end
  if answer.error then
    return nil, { ok = false, error = tostring(answer.error), note = 'the name could not be resolved to a chat',
      served_by = answer.served_by, owner = answer.owner }
  end
  if answer.ambiguous == true or answer.chat == nil then
    local names = {}
    for _, candidate in ipairs(answer.candidates or {}) do
      names[#names + 1] = string.format('%s (%s)', tostring(candidate.name or candidate.chat), tostring(candidate.chat))
    end
    return nil, { ok = false, error = 'whatsapp_approve_chat_ambiguous', candidates = answer.candidates or {},
      note = #names > 0
        and ('"' .. token .. '" names more than one chat; name one of: ' .. table.concat(names, ', '))
        or ('no WhatsApp chat this index knows is called "' .. token .. '"') }
  end
  return answer.chat
end

-- ---------------------------------------------------------------- the evaluation record

--- Where the decisions are kept: the harness evaluator's own state directory, which is the node's
--- and gitignored, and is the one place a draft's text is kept after the message is gone.
function M.record_dir()
  local ok, evaluator = pcall(dofile, 'lua/core/harness_evaluator.lua')
  local base = ok and type(evaluator) == 'table' and evaluator.state_dir and evaluator.state_dir() or nil
  if not base then
    local paths = dofile('lua/core/paths.lua')
    base = paths.config() .. '/evaluator'
  end
  return base .. '/approve'
end

function M.records_path() return M.record_dir() .. '/decisions.jsonl' end

--- The distance between the draft and what was sent, as characters inserted, removed or replaced.
--- A big number is the operator rewriting; zero is the operator agreeing. It is computed here, on the
--- draft and the final text, and never guessed from a length.
function M.edit_distance(before, after)
  before, after = tostring(before or ''), tostring(after or '')
  local function chars(text)
    local out = {}
    for _, code in utf8.codes(text) do out[#out + 1] = utf8.char(code) end
    return out
  end
  local ok, a, b = pcall(chars, before), nil, nil
  if not ok then return math.abs(#before - #after) end
  a = chars(before); b = chars(after)
  -- Levenshtein, with the rows one-based and the row's 0-index stored at [1]: `previous[j]` is the
  -- distance for the first j-1 characters of `after`, which is what makes the j = 1 case read the
  -- empty prefix instead of nil.
  local previous = {}
  for j = 0, #b do previous[j + 1] = j end
  for i = 1, #a do
    local current = { [1] = i }
    for j = 1, #b do
      local cost = a[i] == b[j] and 0 or 1
      current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
    end
    previous = current
  end
  return previous[#b + 1] or 0
end

--- One line per decision. `chat_hash` is the digest of the exact JID, so the report can say "this
--- chat is edited 40% of the time" without the record holding who the chat is; the draft and the
--- final text are kept because that is the whole point of an evaluation record.
function M.record(draft, decision)
  draft, decision = draft or {}, decision or {}
  local chat = tostring(draft.chat or '')
  local handle = tostring(draft.handle or '')
  local text = tostring(draft.text or '')
  local outcome = tostring(decision.outcome or draft.outcome or '')
  local final = decision.final_text or draft.final or text
  local edited = outcome == 'edited'
  local decided_at = tonumber(decision.decided_at) or tonumber(host.now and host.now() or 0) or 0
  local prepared = tonumber(draft.created_at) or decided_at
  local row = {
    at = decided_at,
    draft_handle = handle,
    chat_hash = type(host.sha256) == 'function' and host.sha256(chat) or '',
    outcome = outcome,
    -- The distance is measured only where the operator changed something: a rejection is a decision,
    -- not an edit, and counting its whole body as "edited" would make the median meaningless.
    edit_distance = edited and M.edit_distance(text, tostring(final)) or 0,
    decided_after_ms = math.max(0, math.floor((decided_at - prepared) * 1000)),
    draft = text,
    final = tostring(final),
  }
  local dir = M.record_dir()
  local path = M.records_path()
  if type(host.write_file) ~= 'function' then return row end
  local existing = host.read_file(path) or ''
  -- A single append keeps the file one line per decision; the directory is created by writing the
  -- empty prefix first when it does not exist yet.
  host.write_file(dir .. '/.keep', '')
  host.write_file(path, existing .. json.encode(row) .. '\n')
  return row
end

--- `wa eval report`'s approval section: per chat, what the operator did, and how far they moved the
--- text when they did. Percentages over the decisions recorded, and a median edit distance that says
--- nothing when nothing was edited (instead of printing 0 as if the edits were tiny).
function M.report(opts)
  opts = opts or {}
  local text = type(host.read_file) == 'function' and (host.read_file(M.records_path()) or '') or ''
  local rows, by_chat, total = {}, {}, 0
  for line in text:gmatch('[^\n]+') do
    local ok, record = pcall(json.decode, line)
    if ok and type(record) == 'table' then
      total = total + 1
      local key = tostring(record.chat_hash or '')
      local row = by_chat[key]
      if not row then
        row = { chat_hash = key, unchanged = 0, edited = 0, rejected = 0, cancelled = 0, failed = 0, distances = {}, total = 0 }
        by_chat[key] = row
        rows[#rows + 1] = row
      end
      row.total = row.total + 1
      local outcome = tostring(record.outcome or '')
      if row[outcome] ~= nil then row[outcome] = row[outcome] + 1 end
      if outcome == 'edited' then row.distances[#row.distances + 1] = tonumber(record.edit_distance) or 0 end
    end
  end
  local function median(list)
    if #list == 0 then return nil end
    table.sort(list)
    local middle = math.floor((#list + 1) / 2)
    if #list % 2 == 1 then return list[middle] end
    return math.floor((list[middle] + list[middle + 1]) / 2)
  end
  local lines = {}
  if total == 0 then
    lines[#lines + 1] = 'no approval decisions recorded yet (they are written when an operator decides a draft, ' .. M.records_path() .. ')'
    return { ok = true, total = 0, rows = rows, lines = lines }
  end
  lines[#lines + 1] = string.format('%d decision%s, %d chat%s (chat named by its digest)', total, total == 1 and '' or 's',
    #rows, #rows == 1 and '' or 's')
  table.sort(rows, function(a, b) return a.total > b.total end)
  for _, row in ipairs(rows) do
    local function percent(n) return string.format('%d%%', math.floor((n / math.max(1, row.total)) * 100 + 0.5)) end
    local moved = median(row.distances)
    lines[#lines + 1] = string.format('%s  %d drafts: %s unchanged, %s edited, %s rejected%s%s',
      row.chat_hash ~= '' and row.chat_hash:sub(1, 12) or '(no chat)', row.total,
      percent(row.unchanged), percent(row.edited), percent(row.rejected),
      row.cancelled > 0 and (', ' .. row.cancelled .. ' cancelled') or '',
      moved ~= nil and string.format(', median edit %d chars', moved) or ', median edit - (nothing edited)')
  end
  return { ok = true, total = total, rows = rows, lines = lines }
end

-- ---------------------------------------------------------------- one line of the command

--- The usage the balloon, the help row and the refusal share, so the three cannot promise different
--- things.
M.USAGE = 'usage: /approve [on|off|status|list|review|only <chat>,...|except <chat>,...|send|edit|reject|cancel <handle>]'
M.CLI_USAGE = 'usage: wa approve [on|off|status|list|only <chat>,...|except <chat>,...|send|edit|reject|cancel <handle>]'

local function words(text)
  local out = {}
  for word in tostring(text or ''):gmatch('%S+') do out[#out + 1] = word end
  return out
end

--- Split a comma-separated list of chats into exact JIDs, resolving names. Returns the list, or nil
--- and the refusal of the first token that could not be resolved.
local function chat_list(text, ctx)
  local list = {}
  for token in tostring(text or ''):gmatch('[^,%s]+') do
    local jid, refusal = M.resolve(token, ctx)
    if not jid then return nil, refusal end
    local seen = false
    for _, existing in ipairs(list) do if existing == jid then seen = true end end
    if not seen then list[#list + 1] = jid end
  end
  if #list == 0 then return nil, { ok = false, error = 'whatsapp_approve_chat_required' } end
  return list
end
M.chat_list = chat_list

--- What a `/approve ...` line means, with no side effect: a table with `action` and its arguments, or
--- nil and the usage line. The one parser both surfaces use.
function M.parse(rest)
  local parts = words(rest)
  local action = (parts[1] or ''):lower()
  if action == '' or action == 'status' then return { action = 'status' } end
  if action == 'on' or action == 'off' then
    return { action = action, mode = (parts[2] or ''):lower(), chats = table.concat(parts, ' ', 3) }
  end
  if action == 'only' or action == 'except' then
    return { action = 'rules', mode = action, chats = table.concat(parts, ' ', 2) }
  end
  if action == 'any' or action == 'all' then return { action = 'rules', mode = 'all' } end
  if action == 'list' or action == 'review' then return { action = action } end
  if action == 'send' or action == 'edit' or action == 'reject' or action == 'cancel' or action == 'show' then
    local handle = parts[2] or ''
    if handle == '' then return { action = action, handle = nil } end
    -- No words after the handle is NO words, not an empty sentence: `nil` is what makes the balloon
    -- ask for an edit or a note, and `""` would mean "the operator wrote nothing".
    local rest = table.concat(parts, ' ', 3)
    return { action = action, handle = handle, text = rest ~= '' and rest or nil }
  end
  return nil
end

-- ---------------------------------------------------------------- the balloon

--- The first link in a draft, for the preview line: a send through the outbox is text, and a link in
--- it is the one thing that changes what the reader on the other side sees.
function M.link(text)
  return tostring(text or ''):match('https?://[%w%-_%.~:/?#%[%]@!$&\'()*+,;=]+')
end

--- How long a draft has been waiting, in words a reader can use.
function M.age(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then return string.format('%ds', seconds) end
  if seconds < 3600 then return string.format('%dm', math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format('%dh%02dm', math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
  return string.format('%dd', math.floor(seconds / 86400))
end

--- One draft as the page the operator decides in. Enter sends it as it is, [e] edits it, [r] rejects
--- it with a note - the three keys are named in the page (`keys`), so no other balloon grows them.
function M.page(draft, index, count, now)
  now = tonumber(now) or tonumber(host.now and host.now() or 0) or 0
  local handle = tostring(draft.handle or '')
  local chat = tostring(draft.chat or '')
  local wait = M.age(math.max(0, now - (tonumber(draft.created_at) or now)))
  local link = M.link(draft.text)
  local lines = {
    'to      ' .. (draft.chat_name and (draft.chat_name .. '  ') or '') .. chat,
    'text    ' .. tostring(draft.text or ''):gsub('\r', ''),
    'media   none: this send carries text only',
  }
  if link then lines[#lines + 1] = 'link    ' .. link end
  if draft.reply_to then lines[#lines + 1] = 'reply   ' .. tostring(draft.reply_to) end
  lines[#lines + 1] = 'waiting ' .. wait .. (draft.asked_by and ('  (asked by ' .. tostring(draft.asked_by) .. ')') or '')
  return {
    title = string.format('Approve \u{b7} draft %d/%d', index, count),
    lines = lines,
    options = {
      { label = 'Send as is', hint = 'Enter', run = '/approve send ' .. handle },
      { label = 'Edit the text', hint = 'e', run = '/approve edit ' .. handle },
      { label = 'Reject with a note', hint = 'r', run = '/approve reject ' .. handle },
    },
    keys = { e = 2, r = 3 },
    hint = 'Enter sends \u{b7} e edits \u{b7} r rejects \u{b7} Esc leaves it unsent',
  }
end

--- The page that collects an edit. The draft is IN the field (`value`), so this is an edit and not a
--- retype; an `input = "line"` field keeps the spaces a message is made of.
function M.edit_page(draft)
  return {
    title = 'Edit \u{b7} ' .. tostring(draft.chat or ''),
    lines = { 'the text below replaces the draft exactly - one line, Enter saves, Esc leaves it unsent' },
    input = 'line',
    value = tostring(draft.text or ''),
    hint = 'Enter saves the edit \u{b7} Esc leaves the draft undecided',
  }
end

--- The page that collects a rejection's note.
function M.reject_page(draft)
  return {
    title = 'Reject \u{b7} ' .. tostring(draft.chat or ''),
    lines = { 'why it was not sent: the note is kept with the decision and handed back to the agent' },
    input = 'line',
    placeholder = 'a word for the agent (Enter alone rejects without one)',
    hint = 'Enter rejects \u{b7} Esc leaves the draft undecided',
  }
end

--- Publish the draft for a reader whose run is in flight (`host.local_view`). The options carry
--- `run` lines, so the client queues the decision and the interpreter runs it at the next turn - the
--- stream is never interrupted for a balloon. Returns false when this binary has no channel.
function M.publish(pages)
  local balloon = dofile('lua/core/balloon.lua')
  if not balloon.publishing() then return false, 'unavailable' end
  local handle = pages and pages[1] and tostring(pages[1].title or '') or ''
  return balloon.publish('/approve', pages, host.now())
end

-- ---------------------------------------------------------------- the decision, once

--- Decide one draft and say what happened. Every caller - a balloon key, a `/approve send`, a
--- `wa approve reject` - goes through here, so the answer's words exist in one place.
function M.act(io, ctx, action, handle, text)
  local say = (io and io.say) or print
  action = tostring(action or '')
  handle = tostring(handle or '')
  if handle == '' then
    say('  usage: /approve ' .. (action ~= '' and (action .. ' <handle>') or 'send <handle>'))
    return nil
  end
  if action == 'show' then
    local answer = M.status(ctx, handle)
    local draft = type(answer) == 'table' and (answer.draft or answer) or {}
    if type(draft) ~= 'table' or draft.handle == nil then
      say('  ' .. tostring(answer and answer.error or 'whatsapp_approve_unknown_draft'))
      return nil
    end
    say(string.format('  %s  %s  %s', tostring(draft.state), tostring(draft.chat), tostring(draft.text or ''):gsub('\n', ' ')))
    return draft
  end
  -- An edit and a rejection collect their words first: the balloon asks, the CLI takes them from the
  -- line (`/approve reject <handle> too familiar`).
  local words_text = text
  if action == 'edit' and (words_text == nil or words_text == '') then
    local draft = M.status(ctx, handle)
    draft = type(draft) == 'table' and (draft.draft or draft) or nil
    if not draft or draft.handle == nil then
      say('  ' .. tostring(draft and draft.error or 'whatsapp_approve_unknown_draft'))
      return nil
    end
    words_text = io and io.ask and io.ask(M.edit_page(draft))
    if words_text == nil then
      say('  edit cancelled: the draft is still waiting')
      return nil
    end
  elseif action == 'reject' and words_text == nil and io and io.ask then
    local draft = M.status(ctx, handle)
    draft = type(draft) == 'table' and (draft.draft or draft) or nil
    if not draft or draft.handle == nil then
      say('  ' .. tostring(draft and draft.error or 'whatsapp_approve_unknown_draft'))
      return nil
    end
    local note = io.ask(M.reject_page(draft))
    if note == nil then
      say('  rejection cancelled: the draft is still waiting')
      return nil
    end
    words_text = note ~= '' and note or nil
  end
  local decision = action == 'reject' and 'reject' or action
  local answer = M.decide(ctx, handle, decision, action == 'edit' and words_text or nil, action == 'reject' and words_text or nil)
  if type(answer) ~= 'table' then
    say('  the account node did not answer: the draft is still waiting')
    return nil
  end
  if answer.ok == false then
    local detail = answer.detail and (': ' .. tostring(answer.detail)) or ''
    say('  ' .. tostring(answer.error or 'whatsapp_approve_failed') .. detail)
    if answer.draft then say('  the draft is ' .. tostring(answer.draft.state or '?')) end
    return answer.draft
  end
  local draft = answer.draft or {}
  -- `M.decide` already wrote the evaluation record (it is the one place a decision happens), so there
  -- is nothing to add here: this line is the operator's acknowledgement.
  say('  ' .. M.decision_line(draft))
  return draft
end

--- Draw a stack of pages: the balloon when the writer has a screen, and the same pages as text when it
--- does not (the CLI's `wa approve`, a pipe, a script). One call site for every page this file shows,
--- so a surface cannot grow a page the other cannot render.
local function show(io, pages)
  if type(io.show) == 'function' then return io.show(pages) end
  local say = io.say or print
  say(balloon.text(pages, balloon.width()))
  return { action = 'printed' }
end

--- What one settled draft says to the operator, in one line.
function M.decision_line(draft)
  local state = tostring(draft.state or '')
  if state == 'sent' then
    if draft.outcome == 'edited' then
      return 'sent, edited: ' .. tostring(draft.final or ''):gsub('\n', ' ')
    end
    return 'sent as it was written' .. (draft.message_id and (' (' .. tostring(draft.message_id) .. ')') or '')
  end
  if state == 'rejected' then
    return 'rejected' .. (draft.note and (': ' .. tostring(draft.note)) or '')
  end
  if state == 'cancelled' then return 'cancelled: nothing was sent' end
  if state == 'failed' then return 'failed: ' .. tostring(draft.note or 'the send was refused') end
  return state
end

-- ---------------------------------------------------------------- the review walk

--- Walk the drafts that are waiting, one balloon page per draft, till none are left or the operator
--- leaves. Each page's keys queue a `/approve ...` line (the interpreter runs it - the client only
--- queues), so this works the same between turns and mid-run.
function M.review(io, ctx)
  local balloon = dofile('lua/core/balloon.lua')
  local asked = 0
  while true do
    local rows, listed = M.waiting(ctx)
    if listed and listed.ok == false then
      io.say('  ' .. tostring(listed.error or 'whatsapp_approve_unreadable'))
      return
    end
    if #rows == 0 then
      io.say(asked == 0 and '  no drafts are waiting: every send went out as written' or '  no drafts left waiting')
      return
    end
    -- Publish the same page for a reader whose run is in flight; the blocking balloon below is what
    -- this turn uses when it has the screen.
    local pages = {}
    for index, draft in ipairs(rows) do pages[index] = M.page(draft, index, #rows) end
    M.publish(pages)
    local result = show(io, pages)
    if type(result) ~= 'table' or result.action ~= 'run' or not result.line then
      local left = #rows
      io.say(string.format('  %d draft%s still waiting - /approve list shows them, /approve review decides them',
        left, left == 1 and '' or 's'))
      return
    end
    local rest = tostring(result.line):gsub('^/approve%s*', '')
    asked = asked + 1
    M.run('/approve ' .. rest, io, ctx)
  end
end

-- ---------------------------------------------------------------- the one door

--- Run one `/approve ...` line. `io` is a balloon writer (`balloon.for_view`) between turns, a
--- print-only stand-in on the CLI, and anything with `say`/`show`/`ask` in a test.
function M.run(line, io, ctx)
  io = io or { say = print }
  local rest = tostring(line or ''):gsub('^%s*/?approve%s*', '')
  local parsed = M.parse(rest)
  if not parsed then
    io.say('  ' .. M.USAGE)
    return { ok = false, error = 'whatsapp_approve_usage' }
  end

  if parsed.action == 'status' then
    local policy = M.policy(ctx)
    if type(policy) ~= 'table' or policy.ok == false then
      io.say('  ' .. tostring(policy and policy.error or 'whatsapp_approve_unreadable'))
      return policy
    end
    local _, listed = M.waiting(ctx)
    local waiting = type(listed) == 'table' and tonumber(listed.waiting) or 0
    local lines = {
      'approval is ' .. (policy.on and 'ON' or 'OFF') .. (policy.served_by and (' (the account node ' .. tostring(policy.served_by) .. ')') or ''),
      'gates     ' .. M.rule_line(policy),
      'waiting   ' .. tostring(waiting) .. ' draft' .. (tonumber(waiting) == 1 and '' or 's'),
    }
    show(io, balloon.paged('Approve', lines, { per = 12, nowrap = true }))
    return { ok = true, policy = policy, waiting = waiting }
  end

  if parsed.action == 'list' then
    local answer = M.list(ctx)
    if type(answer) ~= 'table' or answer.ok == false then
      io.say('  ' .. tostring(answer and answer.error or 'whatsapp_approve_unreadable'))
      return answer
    end
    local lines = {}
    for _, draft in ipairs(answer.drafts or {}) do
      lines[#lines + 1] = string.format('%s  %-9s %s  %s', tostring(draft.handle), tostring(draft.state),
        tostring(draft.chat or ''), tostring(draft.text or ''):gsub('\n', ' '))
    end
    if #lines == 0 then lines[1] = 'no drafts: nothing is waiting for a decision' end
    show(io, balloon.paged('Drafts', lines, { per = 12, nowrap = true }))
    return answer
  end

  if parsed.action == 'review' then return M.review(io, ctx) end

  if parsed.action == 'rules' then
    if parsed.mode == 'all' then
      local answer = M.set(ctx, { mode = 'all', chats = {} })
      if answer and answer.ok ~= false then
        io.say('  every chat is gated: ' .. M.rule_line(answer))
      else
        io.say('  ' .. tostring(answer and answer.error or 'whatsapp_approve_failed'))
      end
      return answer
    end
    local chats, refusal = chat_list(parsed.chats, ctx)
    if not chats then
      io.say('  ' .. M.refusal_line(refusal))
      return refusal
    end
    local answer = M.set(ctx, { on = true, mode = parsed.mode, chats = chats })
    if answer and answer.ok ~= false then
      io.say('  approval is ON: ' .. M.rule_line(answer))
    else
      io.say('  ' .. tostring(answer and answer.error or 'whatsapp_approve_failed'))
    end
    return answer
  end

  if parsed.action == 'on' or parsed.action == 'off' then
    local on = parsed.action == 'on'
    -- `/approve on` with no qualifier means every chat waits for the operator. A per-chat rule left
    -- over from an earlier decision is not silently kept: "on" is what a reader reads it as, and
    -- `/approve on only <chat>` is how the narrower rule is asked for.
    local mode, chats = on and 'all' or nil, on and {} or nil
    if on and (parsed.mode == 'only' or parsed.mode == 'except') then
      local list, refusal = chat_list(parsed.chats, ctx)
      if not list then
        io.say('  ' .. M.refusal_line(refusal))
        return refusal
      end
      mode, chats = parsed.mode, list
    elseif on and parsed.chats ~= '' then
      io.say('  ' .. M.USAGE)
      return { ok = false, error = 'whatsapp_approve_usage' }
    end
    local answer = M.set(ctx, { on = on, mode = mode, chats = chats })
    if type(answer) ~= 'table' or answer.ok == false then
      io.say('  ' .. tostring(answer and answer.error or 'whatsapp_approve_failed'))
      return answer
    end
    if on then
      io.say('  approval is ON: ' .. M.rule_line(answer))
      io.say('  every send now waits as a draft for you: /approve list, /approve review')
    else
      io.say('  approval is OFF: sends go out as written, as before')
    end
    return answer
  end

  -- send / edit / reject / cancel / show
  return M.act(io, ctx, parsed.action, parsed.handle, parsed.text)
end

--- The reload self-check (`docs/HOTRELOAD.md`): `reload.lua` calls this when a new copy of this file is
--- loaded, and refuses the swap if it does not pass. It RUNS the code - a page built from a fixture
--- draft, the three keys, the distance - because "it parsed" is not "the balloon renders". It touches
--- no host capability and no file: a self-check that could fail because a node is busy would refuse a
--- good module.
function M.selfcheck()
  local draft = { handle = 'd-probe', chat = '5511999999999@lid', text = 'bom dia', created_at = 0 }
  local page = M.page(draft, 1, 1, 1)
  assert(type(page.title) == 'string' and #page.title > 0, 'page title')
  assert(#page.lines >= 3 and page.lines[2]:find('bom dia', 1, true) ~= nil, 'the draft is on the page')
  assert(page.options[1].run == '/approve send d-probe', 'Enter sends as it is')
  assert(page.options[2].run == '/approve edit d-probe' and page.keys.e == 2, '[e] edits')
  assert(page.options[3].run == '/approve reject d-probe' and page.keys.r == 3, '[r] rejects')
  assert(M.edit_page(draft).value == 'bom dia' and M.edit_page(draft).input == 'line', 'the edit field')
  assert(M.reject_page(draft).input == 'line', 'the note field')
  assert(M.edit_distance('abc', 'abd') == 1 and M.edit_distance('abc', 'abc') == 0, 'the distance')
  assert(M.link('veja https://exemplo.com/a?b=1 agora') == 'https://exemplo.com/a?b=1', 'the link')
  assert(M.parse('reject d-probe muito formal').note == nil and M.parse('reject d-probe').text == nil, 'the parser')
  assert(M.parse('on only 5511999999999@lid').mode == 'only', 'the switch')
  assert(M.rule_line({ on = true, mode = 'only', chats = { '1@lid' } }):find('only these chats', 1, true) ~= nil, 'the rule line')
  return true
end

--- One sentence for a policy: what is gated and what is not.
function M.rule_line(policy)
  policy = policy or {}
  local on, mode = policy.on == true, tostring(policy.mode or 'all')
  local chats = policy.chats or {}
  local listed = #chats > 0 and table.concat(chats, ', ') or ''
  if not on then return 'off: every send goes out as written' end
  if mode == 'only' then return 'only these chats wait for you: ' .. (listed ~= '' and listed or '(none listed, so no chat is gated)') end
  if mode == 'except' then return 'every chat waits for you except: ' .. (listed ~= '' and listed or '(none listed, so every chat waits)') end
  return 'every chat waits for you'
end

--- One sentence for a refusal: the word, then the sentence a person can act on.
function M.refusal_line(refusal)
  if type(refusal) ~= 'table' then return tostring(refusal) end
  if refusal.note then return tostring(refusal.error or 'refused') .. ': ' .. tostring(refusal.note) end
  return tostring(refusal.error or 'refused')
end

return M
