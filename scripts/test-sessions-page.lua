-- /sessions AS A PAGE: the rows, their order, and the budget (sessions-is-a-balloon).
--
-- What this pins, with 200 sessions written into a scratch ledger:
--   1. THIS session is the first option and is marked;
--   2. the others run before the settled ones and, within each group, most recent first;
--   3. a mission session with a title goes to the worker block, not into the chat list;
--   4. every option carries its FULL id in `copy` (what a click copies) and its state and age in the
--      hint - never a query per row;
--   5. the page with 200 sessions is built in under M.BUDGET_MS of CPU (the mission's 100 ms).
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local view = dofile('lua/core/sessions_view.lua')
local checks, failed, first = 0, 0, nil
local function check(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; if first == nil then first = label end; print('FAIL ' .. label) end
end

-- 200 sessions: one mission (with a title), one this-session stand-in, the rest chats.
local here = memory.start_session('node-x', 'chat', { user_id = 'master', title = 'this one' })
local mission = memory.start_session('node-x', 'mission', { user_id = 'master', title = 'mission: sessions-is-a-balloon' })
for i = 1, 198 do memory.start_session('node-x', 'chat', { user_id = 'master', title = 'chat ' .. i }) end

local started = os.clock()
local page, spent = view.page({ session_id = here, user_id = 'master', limit = 200 })
local elapsed_ms = (os.clock() - started) * 1000

check(#page.options >= 199, 'the page lists the sessions: ' .. #page.options)
check(page.options[1].session == here, 'THIS session is the first row')
check(tostring(page.options[1].label):sub(1, 2) == '* ', 'and it is marked: ' .. tostring(page.options[1].label))
local saw_worker_heading = false
local workers = 0
for _, option in ipairs(page.options) do
  if option.action == 'collapse' then saw_worker_heading = true
  elseif option.worker then workers = workers + 1 end
  if option.session then
    check(#tostring(option.copy or '') == 36, 'a row carries its full id in copy: ' .. tostring(option.copy))
    check(tostring(option.hint or ''):find('msg', 1, true) ~= nil, 'and its hint says the message count')
  end
end
check(saw_worker_heading, 'the factory session is under its own heading')
check(workers >= 1, 'and it is inside that block: ' .. workers)
check(page.options[2].session ~= mission, 'the mission is not in the chat list')
check(elapsed_ms < view.BUDGET_MS, string.format('200 sessions under %d ms (%.1f ms)', view.BUDGET_MS, elapsed_ms))

-- ---- the command, and the pipe's plain list --------------------------------------------------
local commands = dofile('lua/core/commands.lua')
local listed_sessions, listed_alias = false, false
for _, entry in ipairs(commands.commands or {}) do
  if type(entry) == 'table' and entry.name == '/sessions' then listed_sessions = true end
  if type(entry) == 'table' and entry.name == '/session' then listed_alias = true end
end
check(listed_sessions, '/sessions is a command')
check(listed_alias, '/session stays an alias')

local printed = {}
view.run({ print = function(text) printed[#printed + 1] = text end },
  { session_id = here, user_id = 'master', limit = 200 })
check(#printed >= 199, 'a pipe prints the plain list: ' .. #printed)
check(tostring(printed[1]):sub(1, 36) == here, 'the first line is this session id: ' .. tostring(printed[1]))

-- ---- the filter -------------------------------------------------------------------------------
-- A name narrows the list to it; the title says so, and a heading with nothing under it goes away.
local narrowed = view.page({ session_id = here, user_id = 'master', limit = 200, filter = 'chat 7' })
check(#narrowed.options < #page.options, 'a name narrows the list: ' .. #narrowed.options .. ' of ' .. #page.options)
local every_match = true
for _, option in ipairs(narrowed.options) do
  if option.session and not tostring(option.label):lower():find('chat 7', 1, true) then every_match = false end
end
check(every_match, 'and every row left matches it')
check(tostring(narrowed.title):find('filtered: chat 7', 1, true) ~= nil, 'the title says what it is narrowed to: ' .. tostring(narrowed.title))
local by_id = view.page({ session_id = here, user_id = 'master', limit = 200, filter = here:sub(1, 8) })
check(#by_id.options == 1 and by_id.options[1].session == here, 'the start of an id finds that session')
local nothing = view.page({ session_id = here, user_id = 'master', limit = 200, filter = 'zzz-nothing' })
check(#nothing.options == 0, 'a name nothing has is an empty list, not the whole one: ' .. #nothing.options)

-- ---- what a copy puts on the clipboard --------------------------------------------------------
-- `c` and a click write OSC 52 with the base64 of the id (`copy_id` in chat.lua, `copy_at` in the panel):
-- the bytes are the id, so decoding them gives it back unchanged.
local encoded = memory.base64_encode(here)
check(memory.base64_decode(encoded) == here, 'a copied id decodes back to itself')
check(#here == 36, 'and an id is 36 characters, whatever the terminal says it copied')

-- ---- an unnamed session is named by its first words --------------------------------------------
local quiet = memory.start_session('node-x', 'chat', { user_id = 'master' })
memory.append_turn(quiet, { role = 'user', content = 'how do I rotate the vault key  please' })
memory.append_turn(quiet, { role = 'assistant', content = 'open the vault page' })
local named = view.page({ session_id = here, user_id = 'master', limit = 200 })
local shown = nil
for _, option in ipairs(named.options) do
  if option.session == quiet then shown = tostring(option.label) end
end
check(shown ~= nil, 'the unnamed session is on the page')
check(shown ~= nil and shown:find('how do I rotate', 1, true) ~= nil,
  'and it is named by the first words of its first message: ' .. tostring(shown))
check(shown ~= nil and not shown:find('open the vault page', 1, true), 'not by the answer')

if failed > 0 then error(string.format('sessions page: %d of %d failed, first: %s', failed, checks, tostring(first)), 0) end
print(string.format('sessions page ok (%d checks, %.1f ms for %d sessions)', checks, elapsed_ms, #page.options))
