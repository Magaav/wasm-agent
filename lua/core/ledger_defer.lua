-- A turn's transcript row, held for the ledger instead of waiting for it (22/11).
--
-- WHY. A run's first write is its user message (lua/core/agent.lua record_turn -> memory.append_turn),
-- and the model call comes after it. When another process holds the ledger's write lock (a deploy, a
-- serve restart, a land's herd of fresh binaries each applying the schema), that write used to spend the
-- connection's patience - 5 s a quantum, up to the 20 s retry budget - and the reader waited for a
-- number nobody would ever show them (measured on this node: 6.3, 15.4, 20.6 and 54.1 s turns).
--
-- WHAT IT DOES. A row that the ledger refuses is QUEUED here instead of being waited on. The turn goes
-- to its model call with the text it already has in memory, build_context appends the queued rows so the
-- request is the request it would have been, and the rows are written in order by the next write that
-- the ledger accepts - or at the end of the run, with the ordinary patience, because by then the answer
-- is on its way and waiting no longer costs the reader anything.
--
-- ORDER IS THE TRANSCRIPT. Rows are appended per session in the order they were created, and a flush
-- happens BEFORE any later row of the same session, so a reply can never overtake the message it
-- answers. `seq` is assigned at write time (memory.next_seq, inside the same transaction), which is
-- exactly the order they are written in.
--
-- WHAT IS LOST, AND SAID OUT LOUD: if the ledger stays locked past the end of the run, the row is still
-- queued when the process ends and the transcript keeps the gap. That is reported (a status line and a
-- log line naming the count) rather than swallowed - a turn the ledger could not record is a fact about
-- the ledger, not a turn that did not happen.
local M = {}

-- ONE QUEUE PER INTERPRETER, KEPT ON _G (change/start-instant, 22/11): dofile() re-runs a module, so a
-- queue in this file's chunk is a different queue for every caller - the agent would queue a row and the
-- next dofile would find nothing to write. The table is created once and shared, like
-- memory.lua's own transaction depth (__wa_tx_depth).
local function state()
  local queue = rawget(_G, "__wa_ledger_defer")
  if type(queue) ~= "table" then
    queue = { items = { }, count = 0 }
    rawset(_G, "__wa_ledger_defer", queue)
  end
  return queue
end

local function memory()
  return dofile('lua/core/memory.lua')
end

local function sqlite_busy()
  return dofile('lua/core/sqlite_busy.lua')
end

-- Keep the text of a row that the ledger would not take. Returns the new queue length for this session.
function M.append(session_id, turn)
  if type(turn) ~= 'table' or session_id == nil or session_id == '' then return 0 end
  local shared = state()
  shared.items[#shared.items + 1] = { session_id = session_id, turn = turn }
  shared.count = shared.count + 1
  return M.count(session_id)
end

function M.count(session_id)
  local shared = state()
  if session_id == nil then return shared.count end
  local n = 0
  for _, item in ipairs(shared.items) do if item.session_id == session_id then n = n + 1 end end
  return n
end

-- The rows this session is still owed, oldest first. build_context reads this so a request carries the
-- message the ledger has not taken yet.
function M.pending(session_id)
  local out = {}
  for _, item in ipairs(state().items) do
    if item.session_id == session_id then out[#out + 1] = item.turn end
  end
  return out
end

-- Write the queue, oldest first, stopping at the first row the ledger still refuses (nothing after it may
-- overtake it). Returns how many landed and, when it stopped, why.
function M.flush()
  local written, reason = 0, nil
  local shared = state()
  while #shared.items > 0 do
    local item = shared.items[1]
    local ok, problem = pcall(memory().append_turn, item.session_id, item.turn)
    if not ok then
      reason = tostring(problem)
      break
    end
    table.remove(shared.items, 1)
    shared.count = shared.count - 1
    written = written + 1
  end
  return written, reason
end

-- One attempt, no wait: used inside a start window, where waiting is the defect.
function M.offer(session_id, turn)
  if sqlite_busy().busy_now() then
    M.append(session_id, turn)
    return nil, 'the ledger is busy (already waited once this run)'
  end
  local ok, problem = pcall(memory().append_turn, session_id, turn)
  if ok then return problem end
  if not sqlite_busy().is_busy(problem) then error(problem, 0) end
  M.append(session_id, turn)
  return nil, tostring(problem)
end

function M.reset() local shared = state(); shared.items = {}; shared.count = 0 end

return M
