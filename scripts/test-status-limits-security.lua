-- THE LIMITS DOOR'S SECURITY (Fable, 26/11): a URL comes from the HOST, never from a caller.
--
-- What this pins, with the real host functions and no provider of ours:
--   1. a caller-given URL is REFUSED by name, and the host it named hears nothing (the wrapper counts
--      connections on that listener and this row fails if it saw one);
--   2. a provider that redirects (302) to another origin is a FAILURE: no hop is followed, so no
--      credential can leave for it (the wrapper's second listener must see zero connections too);
--   3. the provider key appears in no answer this row can see.
--
-- The wrapper (scripts/test-status-limits-security.mjs) owns the listeners, the scratch HOME and the
-- grep of everything the run wrote; this file is the interpreter's half.
local json = dofile('lua/vendor/json.lua')
local checks, failed, first_fail = 0, 0, nil
local function check(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    if first_fail == nil then first_fail = label end
    print('FAIL ' .. label)
  end
end

local attacker = os.getenv('WA_SEC_ATTACKER') or ''
local provider = os.getenv('WA_SEC_PROVIDER') or ''

-- 1. a caller-given URL is refused by name -------------------------------------
local ok, answer = pcall(host.limits_start, 'opencode-go', 'http://' .. attacker .. '/v1')
local decoded = {}
if ok and type(answer) == 'string' then decoded = json.decode(answer) or {} end
check(decoded.state == 'failed', 'a caller-given URL is refused: ' .. tostring(answer))
check(tostring(decoded.error or ''):find('limits_url_refused', 1, true) ~= nil,
  'and the refusal is named: ' .. tostring(decoded.error))
check(tostring(decoded.error or ''):find(attacker, 1, true) == nil,
  'and it does not repeat the URL back: ' .. tostring(decoded.error))

-- 2. an unknown provider is refused too, with no read attempted -----------------
local ok2, answer2 = pcall(host.limits_start, 'evil-provider')
local decoded2 = {}
if ok2 and type(answer2) == 'string' then decoded2 = json.decode(answer2) or {} end
check(decoded2.state == 'failed' and tostring(decoded2.error or ''):find('unknown provider', 1, true) ~= nil,
  'an unknown provider is refused by name: ' .. tostring(answer2))

-- 3. a provider that redirects is a failure, never a hop -----------------------
-- The host resolves the URL itself, so this read goes to WASM_AGENT_LLM_BASE_URL (the wrapper's
-- provider stub, which answers 302 to the second listener).
local ok3, answer3 = pcall(host.limits_start, 'opencode-go')
check(ok3 and type(answer3) == 'string', 'the door answers at once: ' .. tostring(answer3))
local settled = nil
--- A bounded poll with a tiny spin between: a localhost answer arrives in milliseconds, and a busy
-- loop keeps this row from forking (a SIGCHLD would interrupt the read thread's socket call).
for _ = 1, 400 do
  local ok4, text = pcall(host.limits_poll, 'opencode-go')
  if ok4 and type(text) == 'string' then
    local state = json.decode(text) or {}
    if state.state ~= 'loading' and state.state ~= 'none' then settled = state break end
  end
  local spin = os.clock() + 0.005
  while os.clock() < spin do end
end
check(settled ~= nil and settled.state == 'failed', 'the redirecting read fails: ' .. json.encode(settled or {}))
check(settled ~= nil and tostring(settled.error or ''):find('redirect', 1, true) ~= nil,
  'and says a redirect is not followed: ' .. tostring(settled and settled.error))

-- 4. what this row can see carries no key -------------------------------------
local key = os.getenv('WASM_AGENT_LLM_API_KEY') or ''
check(key ~= '', 'the row has a key to look for (the wrapper sets one)')
for _, value in ipairs({answer or '', answer2 or '', json.encode(settled or {})}) do
  check(tostring(value):find(key, 1, true) == nil, 'no answer carries the key')
end

if failed > 0 then
  error(string.format('status limits security: %d of %d checks failed, first: %s', failed, checks, tostring(first_fail)), 0)
end
print('status limits security ok (' .. checks .. ' checks)')
