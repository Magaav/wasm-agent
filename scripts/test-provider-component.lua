-- THE LUA SIDE OF THE PROVIDER COMPONENT (claude-inside-wa, slice 2): the door /login and /model will use.
--
-- The component itself is rust/components/provider (it builds: scripts/build-components.sh provider). This row
-- holds the CALLER's contract, which is the half that must be right on a node where the component is NOT
-- installed - which is every node today.
--
-- WHAT IT ASSERTS:
--   1. no capability -> every call answers nil plus "component_capability_missing" (a named fallback, never an
--      empty list that would read as "you are signed in to nothing");
--   2. a capability that refuses -> the component's own words come back, not a second vocabulary invented here;
--   3. a capability that answers nonsense -> "component_no_answer"/"component_answer_malformed", named.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-provider-component.lua wa
--   -> prints "provider component ok (N checks)"
--
-- Costs under a second: no component, no network.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local provider_component = dofile("lua/core/provider_component.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)), 2)
  end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find '" .. tostring(needle) .. "' in: " .. tostring(text), 2)
  end
end

-- 1. NO COMPONENT: the shape a node has today.
local real = host.provider
host.provider = nil
eq(provider_component.available(), false, "a node with no provider capability says so")
local accounts, why = provider_component.list_accounts()
eq(accounts, nil, "no capability answers no accounts")
eq(why, 'component_capability_missing', "and names the reason")
local _, models_why = provider_component.list_models('x')
eq(models_why, 'component_capability_missing', "list_models falls back the same way")

-- 2. A COMPONENT THAT REFUSES: its words, not ours.
host.provider = function() return '{"ok":false,"error":"no provider module is installed behind this component yet (list-accounts)"}' end
local refused, refused_why = provider_component.list_accounts()
eq(refused, nil, "a refusal is not a list")
contains(refused_why, 'no provider module is installed', "the component's own sentence comes back")
contains(refused_why, 'list-accounts', "with the step it named")

-- 3. A COMPONENT THAT ANSWERS: the fields pass through.
host.provider = function(request)
  local asked = dofile('lua/vendor/json.lua').decode(request)
  if asked.op == 'list-accounts' then
    return '{"ok":true,"accounts":[{"id":"anthropic","label":"Anthropic (Claude subscription)","kind":"subscription","default":true}]}'
  end
  if asked.op == 'list-models' then
    return '{"ok":true,"models":[{"id":"claude-sonnet-4-5","label":"Claude Sonnet 4.5","context":200000}]}'
  end
  return '{"ok":false,"unsupported":"' .. tostring(asked.op) .. '"}'
end
local list = provider_component.list_accounts()
eq(type(list), 'table', "a component that answers gives a table")
eq(#list, 1, "one account")
eq(list[1].label, 'Anthropic (Claude subscription)', "with the label /login shows")
local models = provider_component.list_models('anthropic')
eq(#models, 1, "one model")
eq(models[1].id, 'claude-sonnet-4-5', "with the id the CALL takes")

-- 4. NONSENSE IS NAMED, not guessed at.
host.provider = function() return 'not json' end
local _, nonsense = provider_component.list_accounts()
eq(nonsense, 'component_no_answer', "an unreadable answer is named")
host.provider = function() return '{"ok":true}' end
local _, malformed = provider_component.list_accounts()
eq(malformed, 'component_answer_malformed', "a well-formed answer with no list is named too")

host.provider = real
print('provider component ok (' .. checks .. ' checks)')
