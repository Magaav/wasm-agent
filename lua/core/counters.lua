-- The three numbers that decide the next mission (21/11; docs/CODEMODE.md, "The three counters").
--
-- Telemetry, not policy: each is one increment on a path that already runs, stored in one
-- `memory.meta` document so /stats can read it without a schema change, and nothing here changes a
-- decision the node makes.
--
--   wake_only_round     a model step whose only input was a settled handle. Counted where a handle
--                       wake runs its turn (lua/core/selfloop.lua), which is exactly that step.
--   script_cut_at_cap   a script that got a `pending` answer - its work outlived the wait it was
--                       given - or hit its deadline with lines still to run. This build measures the
--                       first half at the script's own end (one increment per script, never per
--                       call); the deadline half is NOT counted yet and is named here rather than
--                       silently folded in.
--   handle_mishandled   a script that used a pending answer as a result (the harness's
--                       pending-value TypeError) or that ended on the wait-never-settles bound
--                       because it polled one handle instead of ending its step.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- One document, one version: a later mission that redefines a counter writes a new key instead of
-- reinterpreting this one.
M.KEY = "codemode.counters.v1"
M.NAMES = { "wake_only_round", "script_cut_at_cap", "handle_mishandled" }

local memory
local function store()
  if not memory then memory = dofile("lua/core/memory.lua"); memory.setup() end
  return memory
end

-- The three counts, always three numbers: a counter nothing has bumped is 0, not absent.
function M.read()
  local raw = store().meta_get(M.KEY)
  local decoded
  if type(raw) == "string" and raw ~= "" then
    local ok, value = pcall(json.decode, raw)
    if ok then decoded = value end
  end
  local out = {}
  for _, name in ipairs(M.NAMES) do
    out[name] = type(decoded) == "table" and tonumber(decoded[name]) or 0
  end
  return out
end

-- One increment. An unknown name is refused by returning nil rather than creating a key nobody reads.
function M.bump(name, by)
  local known = false
  for _, candidate in ipairs(M.NAMES) do if candidate == name then known = true end end
  if not known then return nil end
  local counts = M.read()
  counts[name] = (counts[name] or 0) + (tonumber(by) or 1)
  store().meta_set(M.KEY, json.encode(counts))
  return counts[name]
end

return M
