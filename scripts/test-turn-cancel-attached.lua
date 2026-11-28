-- ESC ON AN ATTACHED TURN (mission turn-survives-a-provider-stall, item 3 / C2b's last step).
--
-- The console's Esc row already says it interrupts the run (keymap.rs), but `host.run_cancelled` is
-- process-local (host.rs:593), so for a turn ANOTHER process owns the key did nothing. This row pins the
-- three facts that compose it with the door: poll records the run id the facts name; a pending interrupt
-- with a run id asks the node to stop THAT run; and the interrupt is consumed once, so one key never stops
-- two things and never also lands in the draft. A tail with no run id (a local turn) leaves the key alone.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local turn_tail = dofile('lua/core/turn_tail.lua')
local json = dofile('lua/vendor/json.lua')

local failed, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then return end
  failed = failed + 1
  print('FAIL ' .. label)
end

-- ---- poll records the run the facts name ------------------------------------------------
-- Real facts, written to this run's own ledger: stubbing the reader was the scaffolding that made the first
-- draft of this row lie (turn_tail re-reads telemetry itself), and a fact in the ledger is what the tail
-- actually reads.
local telemetry = dofile('lua/core/telemetry.lua')
local session = 'tc-attached-' .. tostring(host.now())
telemetry.event(session, 42, '', 'provider_retry', 'stall', { run_id = 42, attempt = 1 })
telemetry.event(session, 42, '', 'model_call', 'start', { run_id = 42 })
local drawn = {}
local view = { event = function(_, e) drawn[#drawn + 1] = e.text end,
  line = function(_, text) drawn[#drawn + 1] = text end, live = true }
local state = turn_tail.poll(view, session, { cursor = 0 })
check(state.run_id == 42, 'poll records the run id the facts name: ' .. tostring(state.run_id))
check((state.cursor or 0) >= 2, 'and advances its cursor: ' .. tostring(state.cursor))

-- ---- no run id: the key is left alone (a local turn's Esc) ------------------------------
local function fake_input(at)
  local made = 0
  return { interrupt = function() made = made + 1; if made > 1 then return nil end; return 0x1b, at end },
    function() return made end
end
local calls = {}
local native_http = host.http
host.http = function(method, url, headers, body)
  calls[#calls + 1] = { url = url, body = body }
  return json.encode({ ok = true, cancel_requested = true })
end

local input, _ = fake_input(1000)
check(turn_tail.cancel_on_interrupt(view, session, { cursor = 3 }, input) == false,
  'no run id: nothing is cancelled')
check(#calls == 0, 'and no request is made')

-- ---- a pending interrupt on an attached turn: the node is asked to stop THAT run ---------
input = fake_input(2000)
drawn = {}
check(turn_tail.cancel_on_interrupt(view, session, state, input) == true, 'the key asks the node to stop')
check(#calls == 1, 'one request')
check(calls[1] and calls[1].url == 'http://127.0.0.1:8799/runs', 'to the documented node route: ' .. tostring(calls[1] and calls[1].url))
local sent = calls[1] and json.decode(calls[1].body) or {}
check(tonumber(sent.run_id) == 42, 'naming the run the tail drew: ' .. tostring(sent.run_id))
check(sent.action == 'cancel', 'as a cancel')
check(drawn[1] == '  asked the node to stop this turn', 'and the reader is told in one line: ' .. tostring(drawn[1]))

-- one key, one stop: the same interrupt is not consumed twice
local again = turn_tail.cancel_on_interrupt(view, session, state, input)
check(again == false and #calls == 1, 'the same key does not stop a second thing: ' .. tostring(#calls))

-- ---- a node that did not answer is said so by name --------------------------------------
host.http = function() error('connection refused') end
local down_state = { cursor = 9, run_id = 7 }
input = fake_input(3000)
drawn = {}
check(turn_tail.cancel_on_interrupt(view, session, down_state, input) == true, 'it still reports the attempt')
check(#drawn == 1 and drawn[1]:find('did not answer the stop request', 1, true) ~= nil,
  'and names the failure: ' .. tostring(drawn[1]))

host.http = native_http
print(string.format('ok turn-cancel-attached: %d checks, %d failed', checks, failed))
if failed > 0 then error('turn-cancel-attached failed') end

