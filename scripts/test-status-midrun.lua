-- `/status` DURING A RUN: THE LIMITS IT ALREADY HAS, WITH THEIR AGE - AND THE COST THE PROVIDER NAMED.
--
-- Victor, 23/11 11:05Z, mid-run: "Usage in 342.6k · out 6.7k · cache 92% · cost unknown", then
-- "limits unavailable: read on the next /status between runs" (lua/core/status.lua:228, 273 on the
-- base). Two refusals to say a number the process already had:
--
--   * the panel's limits read is kept (`M._limits`) so a snapshot built while the model is answering
--     never waits on the network - and it then dropped WHEN the reading was taken, so a bar on the
--     screen could only be shown as if it were this second's allowance, or not at all;
--   * `cost` is priced from this node's rate snapshot, which opencode-go publishes none of, so every
--     call was "unpriced" and the row said "cost unknown" - while the provider's own usage block
--     carries `opencode.list_cost` (0.00102713 on a real call), the list price of THAT call.
--
-- What this pins, with no network (host.http is a stub that answers the provider's /usage):
--   1. a reading taken now draws the bars and NO age row;
--   2. the same reading, 250 s later and asked for mid-run (`cached`), draws the bars AND "as of 4 min
--      ago", and asks the network NOTHING;
--   3. a process that never read the limits says so by name and invents no age;
--   4. the summed `list_cost` of the session's calls is the Usage row's cost, named as the provider's
--      list cost; one call without one makes the row say unknown again (a sum with a hole is not a
--      cost);
--   5. the adapter carries the provider's field to the record, and the flat spelling too.
--
-- Hermetic: its own scratch home (it writes the ledger), no provider, no peer, no fleet.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local checks, failed, first_fail = 0, 0, nil
local function check(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    if first_fail == nil then first_fail = label end
    print('FAIL ' .. label)
  end
end
local function visible(text) return (tostring(text):gsub('\27%[[%d;]*m', '')) end
local function rows_text(rows) return visible(table.concat(rows, '\n')) end
local function has(text, needle, label) check(tostring(text):find(needle, 1, true) ~= nil,
  label .. ' (missing ' .. string.format('%q', needle) .. ')') end

-- ---- the environment: a configured provider whose /usage is this test's own answer -----------
local env_get = host.getenv
local ANSWERS = {
  WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_BASE_URL = 'http://limits.test.invalid',
  WASM_AGENT_LLM_API_KEY = 'test-only',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash',
  -- This shell is vaulted; the test's provider is the one it names, not the vault's route.
  WASM_AGENT_VAULT_URL = nil,
  WASM_AGENT_OPENCODE_GO_VAULT_URL = nil,
}
host.getenv = function(key)
  if key == 'WASM_AGENT_VAULT_URL' or key == 'WASM_AGENT_OPENCODE_GO_VAULT_URL' then return nil end
  if ANSWERS[key] then return ANSWERS[key] end
  return env_get(key)
end
local http_calls = 0
local RESET = os.time() + 3600
host.http = function(_, url)
  http_calls = http_calls + 1
  if tostring(url):find('/usage', 1, true) then
    return json.encode({ status = 200, body = json.encode({ usage = { rolling = { percent = 37,
      resetsAt = os.date('!%Y-%m-%dT%H:%M:%SZ', RESET) } } }) })
  end
  return json.encode({ status = 404, body = '{}' })
end
-- A clock this test owns: `status` asks host.now for when a reading was taken.
local clock = 1795000000
local now_real = host.now
host.now = function() return clock end

local memory = dofile('lua/core/memory.lua')
memory.setup()
local status = dofile('lua/core/status.lua')
local telemetry = dofile('lua/core/telemetry.lua')

-- ---- 1. the words an age is said in -----------------------------------------------------------
check(status.age_text(5) == 'just now', 'a reading taken seconds ago is "just now"')
check(status.age_text(250) == 'as of 4 min ago', '250 s is "as of 4 min ago": ' .. status.age_text(250))
check(status.age_text(7200) == 'as of 2 h ago', 'two hours is "as of 2 h ago": ' .. status.age_text(7200))
check(status.age_text(200000) == 'as of 2 d ago', 'two days is "as of 2 d ago": ' .. status.age_text(200000))

-- ---- 2. THE DOOR: a /status that never waits, mid-run or not -------------------------------
-- The limits read is the host's now (`host.limits_start`/`limits_poll`): this test stubs the door,
-- which is exactly the seam the panel sees, and proves the three things Victor asked for - a spinner
-- first, the bars when they land, one named line when they do not.
local door = { state = 'none' }
local starts, polls = 0, 0
host.limits_poll = function(_id)
  polls = polls + 1
  if door.state == 'failed' then
    return json.encode({ state = 'failed', error = door.error })
  end
  -- The real door keeps the last reading while a refresh is in flight: so does this one.
  local answer = { state = door.state }
  if door.usage then answer.usage = door.usage end
  if door.age_s then answer.age_s = door.age_s end
  return json.encode(answer)
end
host.limits_start = function(_id, url)
  starts = starts + 1
  door.started_with = url
  door.state = 'loading'
  return json.encode({ state = 'loading' })
end

-- 2a. FIRST EVER, mid-run: the panel draws what it has (session/model) and says the limits are on
-- their way - and the read was started by the panel itself, off the turn.
local sid = memory.start_session('', 'status mid-run', { user_id = 'master' })
status._limits = {}
door = { state = 'none' }
starts, polls = 0, 0
local first = rows_text(status.session_lines(sid, { cached = true }))
has(first, 'loading limits', 'the first open says the limits are loading: ' .. first)
check(starts == 1, 'and the panel started exactly one read: ' .. starts)
check(door.started_with == 'http://limits.test.invalid',
  'naming the provider URL it would have called: ' .. tostring(door.started_with))
check(first:find('read on the next /status', 1, true) == nil,
  'never again the old refusal to read')

-- 2b. the answer lands: the bars, and no age (it was taken just now).
door.state = 'ready'
door.usage = { rolling = { percent = 37, resetsAt = os.date('!%Y-%m-%dT%H:%M:%SZ', RESET) } }
door.age_s = 0
local fresh = rows_text(status.session_lines(sid, { cached = true }))
has(fresh, '37%', 'the bars are drawn as soon as the door has them')
check(fresh:find('as of ', 1, true) == nil,
  'a reading taken now is not drawn with an age: ' .. string.format('%q', fresh))
check(fresh:find('loading limits', 1, true) == nil, 'and the spinner text is gone')

-- 3. four minutes later, mid-run: the bars, their age, and a refresh started because they are old.
local before_starts = starts
door.age_s = 250
local cached = rows_text(status.session_lines(sid, { cached = true }))
has(cached, '37%', 'a mid-run snapshot still draws the reading it has')
has(cached, 'as of 4 min ago', 'and says how old it is')
check(starts == before_starts + 1, 'a reading past the window starts one refresh: ' .. (starts - before_starts))
check(door.state == 'loading', 'and the rows below keep the old bars while it loads')

-- 4. the provider that does not answer: ONE line naming why, never a blank.
status._limits = {}
door = { state = 'none' }
starts = 0
local _ = rows_text(status.session_lines(sid, {}))
door.state = 'failed'
door.error = "the provider didn't answer (timeout 8 s)"
local failed_rows = rows_text(status.session_lines(sid, {}))
has(failed_rows, "limits: the provider didn't answer (timeout 8 s)",
  'a failure draws one line naming why')
check(failed_rows:find('loading limits', 1, true) == nil, 'and stops claiming to be loading')

-- ---- 5. the provider's own list cost, summed --------------------------------------------------
-- Two model calls whose usage blocks carry opencode.list_cost, written the way a real run writes
-- them: telemetry.event start/end pairs, payloads normalized by the same function the agent uses.
local function call_record(run, usage, at)
  local normalized = telemetry.normalize(usage, nil)
  telemetry.event(sid, run, run .. '-span', 'model_call', 'start', { model = 'deepseek-v4.1-flash' }, at)
  telemetry.event(sid, run, run .. '-span', 'model_call', 'end',
    { model = 'deepseek-v4.1-flash', ok = true, ms = 10, normalized = normalized, usage = usage }, at + 1)
  return normalized
end
local one = call_record('run-one', { prompt_tokens = 1000, completion_tokens = 100,
  opencode = { list_cost = 0.00102713 } }, clock + 10)
check(one.list_cost_known == true and math.abs((one.list_cost or 0) - 0.00102713) < 1e-12,
  'a usage block with opencode.list_cost is read as a price: ' .. json.encode(one))
local flat = telemetry.normalize({ prompt_tokens = 10, completion_tokens = 2, list_cost = 0.5 }, nil)
check(flat.list_cost_known == true and flat.list_cost == 0.5,
  'the flat spelling of the same field is read too: ' .. json.encode(flat))
call_record('run-two', { prompt_tokens = 1000, completion_tokens = 100, opencode = { list_cost = 0.00102713 } },
  clock + 20)
local observed = telemetry.snapshot(sid)
check(observed.available == true and observed.total.calls == 2,
  'the ledger holds both calls: ' .. json.encode({ available = observed.available,
    calls = observed.total and observed.total.calls }))
check(observed.total.list_cost_known == true,
  'the summed list cost is known when every call named one: ' .. json.encode(observed.total))
check(math.abs((observed.total.list_cost or 0) - 0.00205426) < 1e-12,
  'and it is the sum: ' .. tostring(observed.total.list_cost))
local priced = rows_text(status.session_lines(sid, { cached = true }))
has(priced, 'Cost     list $0.0021', 'the Cost row shows the provider list cost, named')
check(priced:find('unknown', 1, true) == nil,
  'and no longer says unknown anywhere: ' .. string.format('%q', priced))

-- One call without a price makes the sum a hole, and a hole is unknown, not the other calls' sum.
call_record('run-three', { prompt_tokens = 10, completion_tokens = 2 }, clock + 30)
local holed = telemetry.snapshot(sid)
check(holed.total.list_cost_known == false,
  'one unpriced call makes the total unknown again: ' .. json.encode(holed.total))
local holed_rows = rows_text(status.session_lines(sid, { cached = true }))
has(holed_rows, 'Cost     unknown', 'and the row says unknown rather than a partial sum')

-- ---- 6. the adapter carries the provider's field to the record --------------------------------
local adapter = dofile('lua/core/adapters/openai_completions.lua')
local carried = adapter.usage_of({ prompt_tokens = 10, completion_tokens = 2,
  opencode = { list_cost = 0.25 } })
check(carried.list_cost == 0.25, 'the adapter passes the provider own price through: '
  .. json.encode(carried))
check(adapter.usage_of({ prompt_tokens = 10, completion_tokens = 2 }).list_cost == nil,
  'and a provider that names none leaves it nil, never zero')

host.now = now_real
host.getenv = env_get
if failed > 0 then
  error(string.format('status mid-run: %d of %d checks failed, first: %s', failed, checks,
    tostring(first_fail)), 0)
end
print('status mid-run ok (' .. checks .. ' checks)')
