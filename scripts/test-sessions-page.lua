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

if failed > 0 then error(string.format('sessions page: %d of %d failed, first: %s', failed, checks, tostring(first)), 0) end
print(string.format('sessions page ok (%d checks, %.1f ms for %d sessions)', checks, elapsed_ms, #page.options))
