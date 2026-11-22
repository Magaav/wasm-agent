-- Every file a run creates, edits or deletes is a card, drawn the way Claude Code draws one.
--
-- Victor, 22/11 20:30Z, with a Claude Code screenshot beside it: "everything once we create/edit/delete
-- a file must appear as claude code. we like to see everything. right now we only see like" a row
-- "write 24ms". The cause was not the renderer (lua/core/diff_view.lua already drew a card) but where
-- the event came from: the agent loop emitted it only for a call NAMED write or edit, and code mode is
-- the one execution path this node has, so the write happens INSIDE a script, the call is named run, and
-- no card was ever emitted for it.
--
-- What this row pins, through the real doors (tools.dispatch -> codemode -> the nested dispatcher):
--   1. a script that writes a new file and then edits it emits TWO change events, a Create and an
--      Update - the second one measured from what the first wrote, not from the run's starting point;
--   2. each one draws the card: Create(/path) / Update(/path), "Added N lines, removed M lines", the
--      numbered rows with "+" and "-";
--   3. a command that removes a file the run wrote gives a Delete card with its real lines;
--   4. the model-visible result of that run is the same bytes with a listener and without one - the
--      card is the reader's, never the model's;
--   5. a change made on ANOTHER node draws one honest row instead of nothing.
--
-- Hermetic: its own scratch home (it writes the change store), a path inside that home, no peer and no
-- fleet call.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

-- Code mode is a policy setting AND an asset: both are named here rather than assumed.
local env = host.getenv
host.getenv = function(key) if key == 'WASM_AGENT_CODEMODE' then return 'native' end return env(key) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local changeset = dofile('lua/core/changeset.lua')
local view_lib = dofile('lua/core/cli_view.lua')
local markdown = dofile('lua/core/markdown.lua')
local paths = dofile('lua/core/paths.lua')

local checks, failed = 0, 0
local function check(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then
    print('FAIL ' .. label .. ': missing ' .. string.format('%q', needle) .. ' in:\n' .. tostring(text))
    failed = failed + 1
  end
end
local function visible(text) return (tostring(text):gsub('\27%[[%d;]*m', '')) end

-- The sandbox itself: a node without its code-mode assets cannot run a script, and a row that cannot
-- run what it measures is a refusal here, never a pass.
local ready = false
if type(host.quickjs) == 'function' then
  local ok, raw = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = json.decode(raw); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no script ran and nothing here was measured')

local data = tostring(paths.data())
local work = data .. '/script-writes'
local target = work .. '/demo.txt'
os.execute('mkdir -p ' .. string.format('%q', work))
os.remove(target)

local sid = memory.start_session('', 'script writes show a diff', { user_id = 'master' })
-- The ctx the agent builds for a run (lua/core/agent.lua, dispatch_ctx): the run's change record, the
-- display opt-in, and the listener the view is behind. The session is a parameter because one reader's
-- fact (a file it was already served) must not decide what a second run answers.
local function context(events, session)
  return { session_id = session or sid, user_id = 'master', changes = changeset.new(),
    watch_changes = true,
    emit = events and function(event) events[#events + 1] = event end or nil }
end
local function dispatch(ctx, code)
  return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx)
end
local function quoted(text) return json.encode(tostring(text)) end

-- ---- 1. create, then edit, then delete, all inside ONE script --------------------------------
local STRIDES = 'const w = await tools.write({path: ' .. quoted(target) .. ', content: "one\\ntwo\\nthree\\n"});\n'
  .. 'const e = await tools.edit({path: ' .. quoted(target) .. ', old_string: "two", new_string: "TWO"});\n'
  .. 'const b = await tools.bash({command: "rm -f " + ' .. quoted(target) .. '});\n'
  .. 'return {wrote: w.ok, edited: e.applied === true, removed: b.ok === true};'
local events = {}
local result = dispatch(context(events), STRIDES)
check(type(result) == 'table' and result.ok == true,
  'the script ran: ' .. tostring(type(result) == 'table' and (result.error or result.value) or result))
local changes = {}
for _, event in ipairs(events) do if event.type == 'change' then changes[#changes + 1] = event end end
check(#changes == 3, 'three file changes are shown for the run (got ' .. #changes .. ')')
local paths_seen = {}
for index, event in ipairs(changes) do paths_seen[index] = tostring(event.path) end
check(paths_seen[1] == target and paths_seen[2] == target and paths_seen[3] == target,
  'every card names the file the script changed (' .. table.concat(paths_seen, ', ') .. ')')
check(changes[1] and changes[1].created == true, 'the first change is a CREATE')
check(changes[2] and changes[2].created ~= true, 'the second change is an UPDATE of what the first wrote')
check(changes[3] and changes[3].deleted == true, 'the removal is a DELETE')

-- ---- 2. the cards themselves ----------------------------------------------------------------
local function card(event)
  return table.concat(view_lib.diff_block({ path = event.path, before = event.before,
    after = event.after, deleted = event.deleted }, 80, false) or {}, '\n')
end
local created_card = changes[1] and card(changes[1]) or ''
has(created_card, 'Create(' .. target .. ')', 'the created file is named Create(path), as Claude Code names it')
has(created_card, 'Added 3 lines, removed 0 lines', 'the card counts what the create added')
has(visible(created_card), string.format('\226\148\130 %2s %2d + ', '', 1),
  'the created lines are numbered + rows')
local edited_card = changes[2] and card(changes[2]) or ''
has(edited_card, 'Update(' .. target .. ')', 'the edit is named Update(path)')
has(edited_card, 'Added 1 lines, removed 1 lines', 'the update counts its own one-line change')
has(visible(edited_card), string.format('\226\148\130 %2d %2s - ', 2, ''),
  'the replaced line is a - row carrying the number it had')
has(visible(edited_card), string.format('\226\148\130 %2s %2d + ', '', 2),
  'and the line that replaced it is a + row with its new number')
local deleted_card = changes[3] and card(changes[3]) or ''
has(deleted_card, 'Delete(' .. target .. ')', 'the removal is named Delete(path)')
has(deleted_card, 'Added 0 lines, removed 3 lines', 'and it counts the lines that went with it')
has(visible(deleted_card), string.format('\226\148\130 %2d %2s - ', 1, ''),
  'the removed lines are - rows with the numbers they had')

-- ---- 3. the model's bytes --------------------------------------------------------------------
-- The same script, run twice: once with a listener behind the view and once with none. The card is
-- the reader's, so the two results are the same bytes. The clock is frozen for both runs, because a
-- millisecond is the one thing a tool result legitimately carries that two runs need not agree on.
local real_now = host.now
host.now = function() return 1700000000 end
local bytes_script = 'const w = await tools.write({path: ' .. quoted(work .. '/bytes.txt')
  .. ', content: "alpha\\nbeta\\n"});\n'
  .. 'const r = await tools.read({path: ' .. quoted(work .. '/bytes.txt') .. '});\n'
  .. 'return {wrote: w.ok, text: r.content};'
-- Two sessions, not one: the read tool's answer carries what THIS session was already served, so the
-- second read in one session is a shorter answer than the first - a fact about the session, not about
-- the card, and mixing the two would make this check fail for the wrong reason.
local session_watched = memory.start_session('', 'bytes with a listener', { user_id = 'master' })
local session_silent = memory.start_session('', 'bytes without one', { user_id = 'master' })
local watched_events = {}
local watched = dispatch(context(watched_events, session_watched), bytes_script)
local silent = dispatch(context(nil, session_silent), bytes_script)
host.now = real_now
local watched_bytes, silent_bytes = json.encode(watched), json.encode(silent)
local at = nil
if watched_bytes ~= silent_bytes then
  for index = 1, math.min(#watched_bytes, #silent_bytes) do
    if watched_bytes:sub(index, index) ~= silent_bytes:sub(index, index) then at = index break end
  end
  at = at or (math.min(#watched_bytes, #silent_bytes) + 1)
end
local from = math.max(1, (at or 1) - 120)
check(watched_bytes == silent_bytes,
  'the model-visible result is byte-identical with a listener and without one; differs at '
  .. tostring(at) .. ':\n' .. watched_bytes:sub(from, (at or 1) + 120)
  .. '\nvs\n' .. silent_bytes:sub(from, (at or 1) + 120))
local watched_changes = 0
for _, event in ipairs(watched_events) do if event.type == 'change' then watched_changes = watched_changes + 1 end end
check(watched_changes == 1, 'and the listener did receive its card (got ' .. watched_changes .. ')')
check(not json.encode(silent):find('Create(', 1, true),
  'no line of a card reaches the result the model reads')

-- ---- 3b. the ORDER a reader sees: the run's queue, drained after the call's own result row ----
-- lua/core/agent.lua hands every call a queue and drains it after that call's tool_result, because a
-- card that arrived while a code-mode block was still open would have been written inside it and then
-- overwritten when the block settled. The seam is at the dispatcher, so it is pinned there: with a
-- queue on the ctx, a change is QUEUED and not emitted; the drain is what the reader sees.
local in_call, queue_ctx = {}, { session_id = sid, user_id = 'master', changes = changeset.new(),
  watch_changes = true, emit = function(event) in_call[#in_call + 1] = event end, change_queue = {} }
local wrote = tools.dispatch(memory, 'write', { path = work .. '/queued.txt', content = 'q\n' },
  'master', queue_ctx)
check(type(wrote) == 'table' and wrote.ok == true, 'a direct write ran through the same door')
check(#in_call == 0, 'nothing was drawn while the call was still open (got ' .. #in_call .. ')')
check(#queue_ctx.change_queue == 1, 'the change waits in the run queue (got ' .. #queue_ctx.change_queue .. ')')
local queued_event = queue_ctx.change_queue[1] or {}
check(queued_event.type == 'change' and queued_event.path == work .. '/queued.txt' and queued_event.created == true,
  'and it is the Create for the file just written')

-- ---- 4. a change made on another node --------------------------------------------------------
-- The peer's answer carries no text this node could draw, so the view draws one honest row. Read
-- through the chat.lua filter, which is what a `wa chat` reader's view is handed.
local chat = dofile('lua/core/chat.lua')
local buffer = {}
local view = view_lib.new({ out = function(text) buffer[#buffer + 1] = text end, live = false,
  now = function() return 0 end, limit = 80 })
view:event({ type = 'remote_change', capability = 'write', node = 'peer-one',
  path = '/srv/app/notes.md', ok = true })
local drawn = table.concat(buffer)
has(drawn, 'wrote /srv/app/notes.md on peer-one', 'a write on another node is one honest row, never nothing')
buffer = {}
view_lib.new({ out = function(text) buffer[#buffer + 1] = text end, live = false,
  now = function() return 0 end, limit = 80 })
  :event({ type = 'remote_change', capability = 'edit', node = 'peer-one', path = '/srv/app/notes.md',
    ok = false, error = 'not_peer_operator' })
local failed_row = table.concat(buffer)
has(failed_row, 'could not write /srv/app/notes.md on peer-one: not_peer_operator',
  'and a refused one says so instead of claiming a write')
check(chat ~= nil, 'chat.lua loads (its event filter is what a terminal run hands the view)')

-- ---- 5. through the AGENT LOOP, which is what a `wa chat` turn runs ------------------------
-- The dispatcher's card is not the product until the loop carries it: this is the path where the
-- event used to be emitted (only for a call NAMED write or edit) and where a SECOND emitter would
-- draw every direct write twice. Both facts are pinned here, in order: the call's result row first,
-- then its card, and exactly one card.
--
-- The model is a fixture, never the network: the vault is refused by name (scripts/lib/test-provider.lua)
-- and host.http raises, so a row that reached a provider would fail here instead of spending a call.
local original_dofile = dofile
local fixture = dofile('scripts/lib/test-provider.lua')
fixture.refuse_vault('script writes show a diff')
local fixture_env = host.getenv
host.getenv = fixture.getenv({ WASM_AGENT_LLM_API_KEY = 'test-only',
  WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash' })
local real_http, real_stream = host.http, host.http_stream
host.http = function() error('network forbidden') end
host.http_stream = host.http
-- The provider the AGENT will call is the one patched below: agent.lua loads its own copy, so the
-- module is handed back by name instead of being read a second time (the same seam
-- scripts/test-codemode-model-boundary.lua uses).
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agent = original_dofile('lua/core/agent.lua')
local loop_sid = memory.start_session('', 'script writes through the loop', { user_id = 'master' })
memory.set_session_workspace(loop_sid, { required = true, state = 'allocated', worktree = work })
local loop_target = work .. '/loop.txt'
local loop_events, rounds = {}, 0
local real_complete = provider.complete_with
provider.complete_with = function(_, _messages)
  rounds = rounds + 1
  if rounds == 1 then
    return { content = '', finish_reason = 'tool_calls',
      tool_calls = { { id = 'loop-write', type = 'function',
        ['function'] = { name = 'write',
          arguments = json.encode({ path = loop_target, content = 'a\nb\n' }) } } } }
  end
  return { content = 'LOOP-DONE', finish_reason = 'stop', tool_calls = {} }
end
local bot = agent.new(loop_sid, function(event) loop_events[#loop_events + 1] = event end,
  'master', 'master', '')
local answer = bot:run('write the fixture file')
provider.complete_with = real_complete
dofile = original_dofile
host.http, host.http_stream = real_http, real_stream
host.getenv = fixture_env
check(answer == 'LOOP-DONE', 'the loop finished its two mock rounds (got ' .. tostring(answer) .. ')')
local result_at, change_at, change_count = nil, nil, 0
for index, event in ipairs(loop_events) do
  if event.type == 'tool_result' and event.name == 'write' then result_at = index end
  if event.type == 'change' and event.path == loop_target then
    change_at = index; change_count = change_count + 1
  end
end
check(result_at ~= nil, 'the loop emitted the write call own result row')
check(change_count == 1, 'exactly one card for that call, never two (got ' .. change_count .. ')')
check(result_at ~= nil and change_at ~= nil and result_at < change_at,
  'and the card is drained AFTER the result row (' .. tostring(result_at) .. ' < ' .. tostring(change_at) .. ')')
local loop_card = ''
for _, event in ipairs(loop_events) do
  if event.type == 'change' and event.path == loop_target then loop_card = card(event) end
end
has(loop_card, 'Create(' .. loop_target .. ')', 'the loop card names the file the model wrote')
local tool_message = nil
for _, message in ipairs(memory.session_messages(loop_sid, { limit = 100 })) do
  if message.role == 'tool' and message.tool_call_id == 'loop-write' then tool_message = message end
end
check(tool_message ~= nil, 'the tool message the model reads is stored')
check(tool_message and not tostring(tool_message.content):find('Create(', 1, true),
  'and it carries no line of the card')
os.remove(loop_target)
os.remove(target)
os.remove(work .. '/bytes.txt')
os.remove(work .. '/queued.txt')
if failed > 0 then print('FAILED ' .. failed); os.exit(1) end
print('script writes show a diff ok (' .. checks .. ' checks)')
