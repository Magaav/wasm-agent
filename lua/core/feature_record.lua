-- REAL TRAFFIC: a feature records its last success when a USER's request succeeds (features-real-traffic-hooks).
--
-- Until this landed, "last worked" was the last CANARY run: a synthetic loopback that proves the wiring, not
-- that anybody used the thing. A feature whose canary passes every night and which nobody has really used for
-- a week reads as green - which is the silence the parent mission exists against.
--
-- THE FOUR RULES A HOOK MUST KEEP, and why each is here rather than at the call site:
--   1. CHEAP AND DEBOUNCED. One timestamp write per feature per WA_FEATURE_RECORD_MIN_S (60 s) at most: a hook
--      in a code path that runs per message, per row, per block must not write a file every time. Inside the
--      debounce the call answers {ok=false, reason='debounced'} and writes nothing.
--   2. NEVER IN THE HOT LOOP, and never on the failure path: a call site records SUCCESS only, after the work
--      is done. A failure is the canary's and the notice's business, not a write per request.
--   3. NEVER THE CONTENT. `detail` is a stage name ("turn_finished"), never a message, a prompt, a path or an
--      address: the store is read by `wa health`, printed in logs and shipped in a release report.
--   4. IT CANNOT BREAK THE FEATURE. Every call is wrapped: a hook that raised would turn a working feature
--      into a failing one, so the answer is always a value, and a refusal is named in the return, never thrown.
local M = {}

M.DEFAULT_MIN_S = 60
-- The last write this PROCESS made, per feature. The debounce is per process on purpose: the store is the
-- truth across processes, and one stat per call would cost more than the write it saves.
local last_write = {}

local function min_interval()
  local set = tonumber(os.getenv('WA_FEATURE_RECORD_MIN_S') or '')
  if set and set >= 0 then return set end
  return M.DEFAULT_MIN_S
end

-- Record a REAL success for one feature. Returns true when written, false plus a reason when not.
function M.real(name, opts)
  opts = opts or {}
  name = tostring(name or '')
  if name == '' then return false, 'feature name missing' end
  local now = tonumber(opts.at) or os.time()
  local min = min_interval()
  local seen = last_write[name]
  if seen and (now - seen) < min and not opts.force then
    return false, string.format('debounced (%ds of %ds)', now - seen, min)
  end
  local ok_module, feature_health = pcall(dofile, 'lua/core/feature_health.lua')
  if not ok_module or type(feature_health) ~= 'table' then
    return false, 'feature_health unreadable: ' .. tostring(feature_health)
  end
  local slot, why = feature_health.record(name, true, { at = now, source = 'real', detail = opts.detail })
  if not slot then return false, tostring(why) end
  last_write[name] = now
  return true
end

-- Where a hook goes, in one line: `feature_record.real('chat', { detail = 'turn_finished' })`. Sites that can
-- be called from several places call M.real and ignore the answer.
function M.hook(name, detail)
  local ok, written = pcall(M.real, name, { detail = detail })
  return ok and written == true
end

function M.reset() last_write = {} end

return M
