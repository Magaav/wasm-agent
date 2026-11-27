-- THE CLI ATTACHES TO A TURN THE NODE RUNS (mission turn-survives-a-provider-stall, item 3 / C2).
--
-- Measured 24/11 (report section 3): a wake turn runs on the node, no window is connected to it, and 2 s
-- later the CLI's catch_up draws the finished turn as history - the "added to this session elsewhere"
-- line plus a replay, where tool-carrying text becomes the Commentary topic. The turn's FACTS are however
-- written the moment they happen (telemetry.lua:272) and telemetry.events is a cursor reader, so the CLI
-- can attach by cursor and draw the two things a reader otherwise cannot see while the turn runs: the
-- provider pause (with its wait and attempt) and the next model call.
--
-- What is pinned here:
--   * a pause fact becomes ONE status line in the live words, with its seconds and attempt;
--   * a model call's start becomes one status line, and nothing is drawn for facts that are not progress;
--   * the cursor advances over what it drew and does NOT redraw it on the next poll (no duplicate lines);
--   * a ledger that cannot be read draws NOTHING and leaves the cursor alone - unknown is not "no news".
--
-- Hermetic: a real ledger in the scratch home, a view stub that records what it is told. No model, no network.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local telemetry = dofile('lua/core/telemetry.lua')
local turn_tail = dofile('lua/core/turn_tail.lua')

local failed, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then return end
  failed = failed + 1
  print('FAIL ' .. label)
end

local session = memory.start_session('', 'turn-tail', { user_id = 'master', node_id = '', title = 'turn-tail' })

-- A view stub: exactly the two methods the tail touches.
local drawn = {}
local view = { event = function(_, event) drawn[#drawn + 1] = event end }

-- ---- a pause and a model call, as the node writes them ----------------------------------
telemetry.event(session, 'run-1', '', 'provider_retry', 'attempt',
  { wait_ms = 2000, attempt = 1, limit = 2, reason = 'provider_stalled' })
telemetry.event(session, 'run-1', '', 'model_call', 'start', { model = 'm' })
telemetry.event(session, 'run-1', '', 'step', 'end', { outcome = 'answered' })

local state = turn_tail.poll(view, session, nil)
check(#drawn == 2, 'a pause and a model start are drawn, and the step end is not a status (' .. #drawn .. ')')
check(drawn[1] and drawn[1].type == 'status', 'the pause arrives as a status line')
check(tostring(drawn[1] and drawn[1].text):find('paused 2s', 1, true) ~= nil,
  'in the live words: ' .. tostring(drawn[1] and drawn[1].text))
check(tostring(drawn[1] and drawn[1].text):find('(1/2)', 1, true) ~= nil,
  'with the attempt and its bound: ' .. tostring(drawn[1] and drawn[1].text))
check(drawn[2] and tostring(drawn[2].text) == 'model', 'the model call says model')
check(state.cursor > 0, 'the cursor moved over what it drew')

-- ---- the same facts are not drawn twice -------------------------------------------------
local again = {}
local view2 = { event = function(_, event) again[#again + 1] = event end }
turn_tail.poll(view2, session, state)
check(#again == 0, 'a second poll over the same facts draws nothing new (' .. #again .. ')')

-- ---- new facts after the cursor ARE drawn -----------------------------------------------
telemetry.event(session, 'run-1', '', 'provider_retry', 'attempt',
  { wait_ms = 4000, attempt = 2, limit = 2, reason = 'provider_stalled' })
local third = {}
local view3 = { event = function(_, event) third[#third + 1] = event end }
turn_tail.poll(view3, session, state)
check(#third == 1 and tostring(third[1].text):find('paused 4s', 1, true) ~= nil,
  'the next pause is drawn once: ' .. tostring(third[1] and third[1].text))

-- ---- an unreadable ledger draws nothing and does not move the cursor --------------------
local before = state.cursor
local blocked = turn_tail.poll({ event = function() error('must not be called') end }, '', state)
check(blocked ~= nil, 'the poll answers even when there is nothing to read')
check(blocked.cursor == before, 'and leaves the cursor where it was (' .. tostring(blocked.cursor) .. ')')

print(string.format('ok turn-tail: %d checks, %d failed', checks, failed))
if failed > 0 then error('turn-tail failed') end

