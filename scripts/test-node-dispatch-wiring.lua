-- The wiring guard: every capability the managed gate admits must actually dispatch.
--
-- Measured 2026-11-10 (change/remote-update): a capability branch was added to
-- `lua/core/server.lua`'s `node_capability` without the `return` in front of its handler call -
-- `elseif capability == "update" then dofile("lua/core/remote_update.lua").serve(args, caller)`.
-- The module's own tests passed, because they called `remote_update.serve` directly; the real peer
-- call was answered with nothing, and the capability was dead on the wire. Nothing looked at the
-- seam between the managed allow-list and the dispatch, so nothing failed.
--
-- This test looks at exactly that seam, as data:
--
--   1. it reads the managed allow-list out of `server.lua` (there is one copy: this test parses the
--      file the node loads, so a capability added to the gate is checked here the moment it lands);
--   2. for every name the list admits, the dispatch must serve it - either an explicit branch whose
--      body RETURNS (a branch body with no top-level `return` falls through and answers nothing), or
--      a tool the fallthrough dispatch really has (a name that is neither is answered
--      `unknown_tool`, which is not a capability);
--   3. it proves it can see that class of bug: the same audit runs against a copy of the source with
--      one `return` removed, and must name the branch it broke. A guard that cannot fail is not a
--      guard.
--
-- It is a source-level check on purpose. Calling every admitted capability for real is not an option:
-- `bash`, `write` and `update` have effects, and `chat` starts a model turn.
local json = dofile('lua/vendor/json.lua')
local tools = dofile('lua/core/tools.lua')

local checks = 0
local function ok(condition, label, detail)
  if not condition then error('dispatch-wiring: FAILED - ' .. label .. (detail and ('\n  ' .. tostring(detail)) or ''), 2) end
  checks = checks + 1
end

local source = host.read_file('lua/core/server.lua')
ok(type(source) == 'string' and #source > 1000, 'server.lua is readable from the tree under test')

-- The names the managed gate admits, in the order the file lists them.
local function allowlist(text)
  local start = text:find('local MANAGED_CAPABILITIES = {', 1, true)
  if not start then return nil end
  local finish = text:find('}\n', start, true)
  if not finish then return nil end
  local names = {}
  for name in text:sub(start, finish):gmatch('([%a_][%w_]*)%s*=%s*true') do names[#names + 1] = name end
  table.sort(names)
  return names, start, finish
end

-- The region of `node_capability` that holds the branches, ending at the fallthrough.
local function dispatchRegion(text)
  local start = text:find('local function node_capability(capability, args, caller)', 1, true)
  if not start then return nil end
  local fallthrough = text:find('return toolslib.dispatch(memory, capability, args', start + 1, true)
  if not fallthrough then return nil end
  return text:sub(start, fallthrough), start, fallthrough
end

-- One audit: the violations of the wiring rule in `text`.
local function audit(text, toolNames)
  local names = allowlist(text)
  if not names then return {'no managed allow-list (local MANAGED_CAPABILITIES = { ... }) in server.lua'} end
  local region = dispatchRegion(text)
  if not region then return {'no node_capability dispatch region, or no `return toolslib.dispatch(...)` fallthrough'} end
  local violations = {}
  for _, name in ipairs(names) do
    local marker = 'capability == "' .. name .. '"'
    local at = region:find(marker, 1, true)
    if not at then
      -- No branch: the fallthrough dispatch must really have this tool. A name that is neither a
      -- branch nor a tool is answered `unknown_tool` on every peer call.
      if not toolNames[name] then
        violations[#violations + 1] = string.format('%s: no dispatch branch and no such tool (the fallthrough would answer unknown_tool)', name)
      end
    else
      -- The branch body runs from its `then` to the next branch or to the fallthrough.
      local body_start = region:find('\n', at, true) or #region
      local next_branch = region:find('capability == "', body_start, true)
      local body = region:sub(body_start, (next_branch or #region) - 1)
      -- A top-level `return` is one at the body's own indentation. Inside an `if` it is deeper, and
      -- a branch that only returns on one path is exactly the bug this looks for.
      local returned = false
      for line in body:gmatch('[^\n]+') do
        if line:match('^    return[%s]') or line == '    return' then returned = true; break end
      end
      if not returned then
        violations[#violations + 1] = string.format('%s: the dispatch branch has no top-level `return`, so the call falls through and answers nothing', name)
      end
    end
  end
  return violations, names
end

-- The tools the fallthrough really has, from the catalogue itself (not from a list in this file), plus
-- the one shape a catalogue cannot show: a HIDDEN tool of a surface - callable, dispatched by the same
-- library, and in no catalogue because a model is never offered it (`mcp_whatsapp_send_status` is the
-- resume form of `mcp_whatsapp_send`, `lua/core/whatsapp.lua`). Without this the rule would call a
-- reachable tool unreachable, which is the opposite of what it exists to catch.
local toolNames = {}
for _, entry in ipairs(tools.catalog('master')) do
  local name = type(entry) == 'table' and entry['function'] and entry['function'].name
  if type(name) == 'string' then toolNames[name] = true end
end
local whatsapp_lib = dofile('lua/core/whatsapp.lua')
for _, tool in ipairs(whatsapp_lib.TOOLS) do
  if tool.hidden then toolNames[tool.name] = true end
end
ok(next(toolNames) ~= nil, 'the tool catalogue is readable, so "no branch" can be checked against it')

local violations, names = audit(source, toolNames)
ok(names ~= nil, 'the managed allow-list is in server.lua')
-- A list this short would make the loop below pass by doing nothing.
ok(#names >= 15, 'the managed allow-list names the capabilities a peer may invoke', #names .. ' name(s): ' .. table.concat(names or {}, ', '))
ok(#violations == 0,
  'every capability the managed gate admits dispatches: a branch that RETURNS, or a real tool',
  table.concat(violations, '\n  '))

-- No reverse check ("every branch is admitted"). It is not true of this node by design: an unbound
-- node runs `node_capability` without the managed list at all (`wa_node_call`'s last line), and a
-- roster-attested call is admitted by its verb even when the legacy list does not name it. A branch
-- for `batch`, `access`, `chat` or `subagent` is reached those ways, so demanding that every branch be
-- in the managed list would be a rule this node does not follow - and a guard that encodes a false
-- rule is worse than none. What must hold is the direction above: a name the gate ADMITS must
-- dispatch.

-- The control: the same audit, on a copy of the source with one branch's `return` removed, must name
-- that branch. This is the 2026-11-10 defect, reproduced and caught.
local victim = nil
for _, name in ipairs(names) do
  if source:find('capability == "' .. name .. '"', 1, true) then victim = name; break end
end
ok(victim ~= nil, 'at least one admitted capability has an explicit branch to mutate')
local victim_at = source:find('capability == "' .. victim .. '"', 1, true)
local body_start = source:find('\n', victim_at, true) or #source
local next_branch = source:find('capability == "', body_start, true)
local victim_body = source:sub(body_start, (next_branch or #source) - 1)
local muted_body, replaced = victim_body:gsub('\n    return ', '\n    ', 1)
ok(replaced == 1, 'the control could remove the `return` of the ' .. victim .. ' branch')
local mutated = source:sub(1, body_start - 1) .. muted_body .. source:sub(next_branch or #source)
local broken = audit(mutated, toolNames)
local named = false
for _, violation in ipairs(broken) do
  if violation:find(victim, 1, true) and violation:find('return', 1, true) then named = true end
end
ok(named, 'the guard catches a branch whose `return` was removed (the 2026-11-10 update defect)',
  table.concat(broken, '\n  '))
-- And it stays quiet about the rest: the mutation must add exactly one violation.
ok(#broken == #violations + 1, 'and only that branch is reported', table.concat(broken, '\n  '))

-- A missing branch for a name the gate admits is caught too: drop the `update` branch entirely.
local without_branch = source:gsub('\n  elseif capability == "update" then', '\n  elseif capability == "update_gone" then', 1)
local caught = false
for _, violation in ipairs(audit(without_branch, toolNames)) do
  if violation:find('', 1, true) and violation:find('update:', 1, true) and violation:find('no dispatch branch', 1, true) then caught = true end
end
ok(caught, 'the guard catches an admitted capability with no dispatch branch (answered unknown_tool)',
  table.concat(audit(without_branch, toolNames), '\n  '))

print(string.format('dispatch-wiring: %d checks passed (%d admitted capabilities)', checks, #names))
