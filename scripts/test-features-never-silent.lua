-- A FEATURE THAT CANNOT WORK SAYS SO, IN WORDS (features-never-break-silently, item 5: "a test per
-- feature that removes its dependency and asserts a visible message").
--
-- The mission's promise is that no feature goes quiet. This row takes the classes whose dependency can be
-- removed in a scratch home - no peer, no component, no credential - removes it, and holds the ANSWER: not
-- the bare code, a sentence naming the cause and what to do about it.
--
-- WHY IT IS NEEDED. The mission report (docs/missions/reports/features-never-break-silently.md, section 8)
-- names this as NOT DONE: the canaries answer in named stages, but nothing asserted that the CALL a user makes
-- answers a message. A feature that was switched off, or whose component is missing, could answer "{}" and
-- every test would still pass.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-features-never-silent.lua wa
--   -> prints "features-never-silent ok (N checks)"
--
-- Costs about 1 s: no child process, no network, no peer (a peer call here would be an external effect).
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- It writes state (a mail search and a contacts read each queue a job in this home), so it takes the same
-- guard as every other row that does: a home outside the suite's scratch root is refused by name.
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local refusal = dofile("lua/core/refusal.lua")
local feature_health = dofile("lua/core/feature_health.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find '" .. tostring(needle) .. "' in: " .. tostring(text), 2)
  end
end

-- 1. THE GRAPH, SWITCHED OFF (its default on a fresh node): a call answers a named refusal WITH a next step.
--    This is the real capability, not a stub: what a user's graph_query gets when nobody switched graph on.
local ok, answer = pcall(host.graph_query, 'MATCH (n) RETURN n LIMIT 1')
check(ok, "graph_query answers instead of raising: " .. tostring(answer))
-- The capability answers a JSON STRING (measured on this node), so decode before reading the fields: a
-- reader that assumed a table would find no 'next' and conclude the message was silent.
local decoded = answer
if type(decoded) == 'string' then
  local ok_json, parsed = pcall(dofile('lua/vendor/json.lua').decode, decoded)
  if ok_json and type(parsed) == 'table' then decoded = parsed end
end
local text = type(decoded) == 'table' and tostring(decoded.error or decoded.message or '') or tostring(decoded)
local next_step = type(decoded) == 'table' and tostring(decoded.next or '') or ''
check(text:find('graph_dormant', 1, true) ~= nil,
  "a graph call on a node with graph off names graph_dormant, got: " .. text)
check(#next_step > 20, "it carries a sentence to act on, got: " .. next_step)
contains(next_step, 'OFF by default', "the sentence says the feature is off, not broken")
contains(next_step, 'policy.json', "and names where to switch it on")

-- 2. MAIL, WITH NO CONNECTOR (the dependency removed: this scratch home has no account, no connector).
--    A search answers a NOTE that says the connector is not answering and names what to use instead - the
--    user is told which thing is broken and where to go, not left with an empty result that reads like
--    "no mail matches". Measured on this node with no connector: state=running plus that note.
local mail_ok, mail_answer = pcall(host.email_search, '{"q":"canary","limit":1}')
check(mail_ok, "email_search answers instead of raising: " .. tostring(mail_answer))
local mail_text = tostring(mail_answer)
local mail_decoded = mail_answer
if type(mail_answer) == 'string' then
  local ok_json, parsed = pcall(dofile('lua/vendor/json.lua').decode, mail_answer)
  if ok_json and type(parsed) == 'table' then mail_decoded = parsed end
end
local mail_note = type(mail_decoded) == 'table'
  and tostring(mail_decoded.note or mail_decoded.detail or mail_decoded.error or '') or ''
check(#mail_note > 20, "a mail search with no connector says something, got: " .. mail_text:sub(1, 200))
contains(mail_note, 'connector', "the note names the connector as the thing that is not answering")
contains(mail_note, 'mcp_google_imap', "and names what to use instead")

-- 3. WHATSAPP, WITH NO COMPONENT (the dependency removed: this scratch home runs no wa-whatsapp). A contacts
--    read answers a NAMED error plus a detail that says the component has not answered, and says it is worth
--    retrying - so a user's "who is this" does not look like "no such contact". Measured on this node with no
--    component: error=whatsapp_contacts_slow, state=queued, retry=true.
local wa_ok, wa_answer = pcall(host.whatsapp_contacts, '{"q":"canary","limit":1}')
check(wa_ok, "whatsapp_contacts answers instead of raising: " .. tostring(wa_answer))
local wa = wa_answer
if type(wa) == 'string' then
  local ok_json, parsed = pcall(dofile('lua/vendor/json.lua').decode, wa)
  if ok_json and type(parsed) == 'table' then wa = parsed end
end
check(type(wa) == 'table', "the answer is a document, got: " .. tostring(wa_answer):sub(1, 160))
local wa_error = tostring(wa.error or '')
local wa_detail = tostring(wa.note or wa.detail or '')
check(wa_error ~= '', "the failure carries a code, not an empty answer")
check(wa_error:find('slow', 1, true) ~= nil or wa_error:find('component', 1, true) ~= nil,
  "the code names a slow/missing component, got: " .. wa_error)
contains(wa_detail, 'wa-whatsapp component', "the detail names the component that has not answered")
check(wa.retry == true, "it says the same call can be retried rather than that the data does not exist")

-- 2. EVERY FEATURE'S REFUSAL HAS WORDS. The vocabulary every tool refusal crosses (lua/core/refusal.lua) must
--    render a sentence and a fix for the codes a feature emits - the shape fallback covers a code nobody has
--    taught it, so a code from tomorrow is still not silence.
local registry, why = feature_health.load()
check(type(registry) == 'table', "the registry is readable: " .. tostring(why))
check(#registry.features > 0, "the registry lists features")
local empty_placeholder = string.rep('`', 2)
for _, row in ipairs(registry.features) do
  local code = tostring(row.name):gsub('%-', '_') .. '_unavailable'
  local built = refusal.build(code, {}, { origin = 'scripts/test-features-never-silent.lua', tool = row.name })
  check(type(built) == 'table', row.name .. ": a refusal is built for " .. code)
  check(type(built.message) == 'string' and #built.message > 20,
    row.name .. ": the message is a sentence, not the code (" .. tostring(built.message) .. ")")
  check(type(built.fix) == 'string' and #built.fix > 10,
    row.name .. ": the fix says what to do (" .. tostring(built.fix) .. ")")
  check(built.message ~= code, row.name .. ": the message is not the bare code")
  -- A template that lost a value reads as the placeholder twice - the exact silence this row is against.
  check(not built.message:find(empty_placeholder, 1, true), row.name .. ": no empty placeholder in the message")
  check(not built.fix:find(empty_placeholder, 1, true), row.name .. ": no empty placeholder in the fix")
end

print('features-never-silent ok (' .. checks .. ' checks)')
