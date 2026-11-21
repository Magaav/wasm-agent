-- The one rule every Lua row that gives a node a home must obey, in ONE place: the home it hands over is
-- a SCRATCH home, never the operator's (item 3 of the node-ops round).
--
-- MEASURED 19/11: the four rows below compared WASM_AGENT_HOME against $HOME/... and got the SIDE wrong.
-- WASM_AGENT_HOME is the USER home (rust/wa-host-support/src/paths.rs:12) - the node's state hangs off it
-- as <home>/.wasm-agent - so a row given WASM_AGENT_HOME=$HOME wrote straight into the operator's real
-- ~/.wasm-agent while its guard passed. The shell tests were fixed (scripts/lib/scratch-home.sh); these
-- rows kept the old comparison, which is the same defect in a second language.
--
-- The rule is the shell guard's, refusal for refusal:
--   refuse an empty home;
--   refuse the real $HOME (its store would BE ~/.wasm-agent);
--   refuse the real $HOME/.wasm-agent and anything inside it (the operator's own store);
--   refuse anything that CONTAINS the real $HOME/.wasm-agent (a home above the store is the same store);
--   accept everything else, and say so by returning nil.
--
--   local scratch = dofile('scripts/lib/scratch-home.lua')
--   local why = scratch.guard('test-x.lua')
--   if why then print('REFUSED ' .. why); os.exit(2) end
local M = {}

local function norm(value) return (tostring(value or ''):gsub('\\', '/'):gsub('/+$', '')):lower() end

-- The operator's own home, resolved the way the shell guard resolves it: $HOME, or USERPROFILE on Windows.
function M.real_home()
  local home = host.getenv('HOME') or host.getenv('USERPROFILE') or ''
  return norm(home)
end

-- <label> [, <home>] -> nil when the home is a scratch home, or the refusal text (prefixed with the
-- label). The second argument exists so a TEST can drive every case in one process: the rule is about a
-- PATH, and a rule that can only be exercised by relaunching a node with a different environment is a rule
-- nobody tests. With no second argument, the running node's own WASM_AGENT_HOME is judged.
function M.guard(label, explicit)
  local who = tostring(label or 'this test')
  local raw = (explicit ~= nil) and tostring(explicit) or (host.getenv('WASM_AGENT_HOME') or '')
  if raw == '' then
    return who .. ': WASM_AGENT_HOME is not set, so this test cannot prove it is not the real node home'
  end
  local home = norm(raw)
  -- THE HOME THIS NODE HAD BEFORE WASM_AGENT_HOME REPLACED IT (rust/wa-host/src/main.rs sets HOME
  -- from WASM_AGENT_HOME at startup, so inside a node HOME == WASM_AGENT_HOME BY CONSTRUCTION and the
  -- comparison below could never fail - the 19/11 defect in this rule). The launcher records the
  -- original as WA_HOME_BEFORE_OVERRIDE when the two differ, and that is the home this guard judges.
  local real_home = norm(host.getenv('WA_HOME_BEFORE_OVERRIDE') or '')
  if real_home == '' then real_home = M.real_home() end
  if real_home == '' then
    -- An unknown operator home is not a licence: the shell guard refuses here too.
    return who .. ': the operator home (HOME/USERPROFILE) is not set, so the scratch home ' .. raw
      .. ' cannot be proven distinct from it'
  end
  local real_store = real_home .. '/.wasm-agent'
  if home == real_home then
    return who .. ': WASM_AGENT_HOME is the real ' .. real_home .. '; its store would BE ' .. real_store
      .. ' - a row given the user home writes the operator node'
  end
  if home == real_store then
    return who .. ': WASM_AGENT_HOME is the real store ' .. real_store .. '; a row must never act on it'
  end
  if home:sub(1, #real_store + 1) == real_store .. '/' then
    return who .. ': WASM_AGENT_HOME (' .. raw .. ') is inside the operator store ' .. real_store
  end
  -- The other direction: a home ABOVE the store holds it, so its own .wasm-agent is the same directory.
  if real_store:sub(1, #home + 1) == home .. '/' then
    return who .. ': WASM_AGENT_HOME (' .. raw .. ') contains the operator store ' .. real_store
      .. '; a home above the store is the same store'
  end
  if home:sub(1, 1) ~= '/' and not home:match('^%a:/') then
    -- A relative home resolves against whatever cwd the node happened to have, so it cannot be proven
    -- to be outside the store. The shell guard refuses it by name for the same reason.
    return who .. ': WASM_AGENT_HOME (' .. raw .. ') is not an absolute path, so where it points depends on the caller cwd'
  end
  return nil
end

return M
