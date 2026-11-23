-- ONE notice when a feature stops, and not a stream of them.
--
-- The brief's rule (Victor, 23/11): a feature past its staleness bound "raises one notice to Victor's own
-- channel and the orchestrator's log - once, with the stage and the time, not a stream". This is that
-- once, and the whole of it:
--
--   * WHAT COUNTS is lua/core/feature_health.lua's red list - failing, stale, or never proven on a node
--     that runs the feature. The notice does not re-decide any verdict; it speaks what the report says.
--   * ONCE means once per INCIDENT, not once per run. The incident is identified by the set of red
--     features and their verdicts: a second call while that set is unchanged sends nothing, and a set that
--     changes (something else stops, or one comes back) speaks again - because that is new information.
--   * A NOTICE THAT FAILED TO SEND IS NOT RECORDED AS SENT. If the channel refuses, nothing is written and
--     the next call tries again: marking a failed send as done is how a silence gets a receipt.
--   * THE LOG IS ALWAYS WRITTEN, and the channel is best-effort with its own named outcome, so an operator
--     reading the node's log always sees the stop even when the message never left.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local feature_health = dofile('lua/core/feature_health.lua')

local M = {}

M.STATE = '/feature-health-notice.json'

function M.state_path() return paths.config() .. M.STATE end

local function read_state()
  local ok, text = pcall(host.read_file, M.state_path())
  if not ok or type(text) ~= 'string' then return {} end
  local parsed, document = pcall(json.decode, text)
  if not parsed or type(document) ~= 'table' then return {} end
  return document
end

local function write_state(document)
  local ok, err = pcall(host.write_file, M.state_path(), json.encode(document) .. '\n')
  if not ok or not err then return nil, 'the notice state could not be written: ' .. M.state_path() end
  return document
end

-- The sentence a person reads: every stopped feature, its verdict, the time, and - for a failure - the
-- stage it broke in. Short, and never more than one line per feature.
function M.text(red)
  local parts = {}
  for _, item in ipairs(red or {}) do
    parts[#parts + 1] = string.format('%s %s (%s)', item.name, item.verdict, tostring(item.detail))
  end
  return string.format('wa: %d feature(s) stopped: %s', #parts, table.concat(parts, '; '))
end

-- The node's log, then the operator's own channel when this node has one. Nothing here invents a reach it
-- does not have: a node without the WhatsApp component says so instead of dropping the message quietly.
function M.default_sender(text)
  local logged, log_error = pcall(host.log, 'feature-health: ' .. text)
  local channel = 'log'
  local problem
  if type(host.whatsapp_send) == 'function' then
    local declared = pcall(function() return dofile('lua/core/whatsapp.lua').declared_owner() end)
    local owner = select(2, declared)
    if type(owner) == 'string' and owner ~= '' then
      local sent, answer = pcall(host.whatsapp_send, json.encode({ chat = owner, text = text }))
      if sent and not (type(answer) == 'table' and answer.error) then channel = 'whatsapp'
      else problem = tostring(type(answer) == 'table' and answer.error or answer) end
    else
      problem = 'no owner chat is declared on this node'
    end
  else
    problem = 'this binary has no whatsapp_send capability'
  end
  if not logged then return false, 'the node log refused the notice: ' .. tostring(log_error) end
  if problem then
    pcall(host.log, 'feature-health: operator channel not used - ' .. problem)
  end
  return true, channel
end

-- One notice per incident. `opts.sender` is the test's: a function(text) -> ok, detail.
function M.notice(now, opts)
  opts = opts or {}
  local red, why = feature_health.red(now)
  if not red then return { sent = false, reason = 'unreadable', detail = why } end
  local state = read_state()
  if #red == 0 then
    -- Back to green: the fingerprint is cleared, so the NEXT incident speaks. Nothing is sent.
    if state.fingerprint and state.fingerprint ~= '' then write_state({ fingerprint = '', cleared_at = tonumber(now) or 0 }) end
    return { sent = false, reason = 'all_working' }
  end
  local names = {}
  for _, item in ipairs(red) do names[#names + 1] = item.name .. '=' .. item.verdict end
  table.sort(names)
  local fingerprint = table.concat(names, ',')
  if state.fingerprint == fingerprint then
    return { sent = false, reason = 'already_noticed', fingerprint = fingerprint, at = state.at }
  end
  local text = M.text(red)
  local sender = opts.sender or M.default_sender
  local sent, detail = sender(text, red)
  if not sent then
    -- NOT recorded: a failed send must not silence the next attempt.
    return { sent = false, reason = 'sender_failed', detail = tostring(detail), text = text }
  end
  write_state({ fingerprint = fingerprint, at = tonumber(now) or 0, channel = tostring(detail or ''), text = text })
  return { sent = true, fingerprint = fingerprint, channel = tostring(detail or ''), text = text }
end

return M
