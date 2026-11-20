-- Typed rows answer the SAME rows as the JSON text: parity on a seeded ledger, then on the path real
-- use takes.
--
--   WA_SCRIPT=scripts/test-sql-rows.lua wa --db <scratch>    (scripts/fast.sh runs it as a row)
--
-- The seam it guards: host.sql_query answers JSON text the caller decodes; host.sql_rows answers the
-- same rows as a Lua table (docs/HOST.md; docs/missions/reports/seam-audit.md, row 9), and
-- lua/core/memory.lua's query() takes the typed answer when the host has it. This test is what makes
-- that switch safe: every value, every Lua number type, every NULL, every key set and every error
-- message has to match, and the turn loop's own read has to actually take the typed path.
--
-- It writes rows, so it REFUSES to run without its own scratch home: the operator's ledger is never
-- a test fixture (docs/INSTRUCTIONS, the scratch-home rule).
local home = host.getenv('WASM_AGENT_HOME') or ''
assert(home ~= '', 'refuses to run without WASM_AGENT_HOME: this test writes rows and must not touch the operator ledger')
local function norm(value) return (tostring(value or ''):gsub('\\', '/'):gsub('/+$', '')):lower() end
local operator = norm((host.getenv('HOME') or host.getenv('USERPROFILE') or '') .. '/.wasm-agent')
assert(norm(home) ~= operator, 'refuses to run against the operator home (' .. operator .. ')')
assert(type(host.sql_rows) == 'function', 'this host has no host.sql_rows: nothing to compare, so nothing passes')

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()

local checks = 0
local function check(name, fn)
  local ok, err = pcall(fn)
  checks = checks + 1
  assert(ok, name .. ': ' .. tostring(err))
end

-- ---- the two answers, compared value by value and type by type
local function compare(old, new, where)
  assert(type(new) == 'table', where .. ': the typed answer is not a table')
  assert(#old == #new, where .. ': row count ' .. #old .. ' vs ' .. #new)
  for index, row in ipairs(old) do
    local other = new[index]
    assert(type(other) == 'table', where .. ': row ' .. index .. ' is not a table')
    for key, value in pairs(row) do
      local got = other[key]
      assert(got ~= nil, where .. ': row ' .. index .. ' lost key ' .. tostring(key))
      assert(type(got) == type(value), where .. ': row ' .. index .. '.' .. key .. ' is a ' .. type(got) .. ', the JSON path gave a ' .. type(value))
      if type(value) == 'number' then
        -- An integer that arrives as a float compares equal but concatenates differently ("5" vs
        -- "5.0"), so the number TYPE is part of parity, not only the value.
        assert(math.type(got) == math.type(value), where .. ': row ' .. index .. '.' .. key .. ' is a ' .. tostring(math.type(got)) .. ', the JSON path gave a ' .. tostring(math.type(value)))
      end
      assert(got == value, where .. ': row ' .. index .. '.' .. key .. ' value ' .. tostring(got) .. ' vs ' .. tostring(value))
    end
    for key in pairs(other) do
      assert(row[key] ~= nil, where .. ': row ' .. index .. ' has key ' .. tostring(key) .. ' the JSON path does not')
    end
  end
end

-- Every SQLite type, plus the three values that have historically been easy to lose: a NULL, an
-- empty string and a zero.
check('the seeded types answer the same rows', function()
  assert(host.sql_exec('DROP TABLE IF EXISTS seam_types', '[]'))
  assert(host.sql_exec('CREATE TABLE seam_types(id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)', '[]'))
  local insert = json.encode({ 'x' })
  assert(host.sql_exec("INSERT INTO seam_types(i,r,t,b,n) VALUES(-7,1.5,'em-dash: \xe2\x80\x94 and check: \xe2\x9c\x93',X'DEADBEEF',NULL)", '[]'))
  assert(host.sql_exec("INSERT INTO seam_types(i,r,t,b,n) VALUES(42,-0.25,'',X'', 'not null')", '[]'))
  local sql = 'SELECT id, i, r, t, b, n FROM seam_types ORDER BY id'
  local typed = host.sql_rows(sql, '[]')
  local text = host.sql_query(sql, '[]')
  local decoded = json.decode(text)
  compare(decoded, typed, 'seeded types')
end)

-- A failure names the same reason on both paths, and the typed one says it as nil, error (a table
-- with an error key would be a row).
check('a failing statement answers the same reason', function()
  local bad = 'SELECT * FROM seam_table_that_does_not_exist'
  local parsed = json.decode(host.sql_query(bad, '[]'))
  assert(type(parsed) == 'table' and parsed.error, 'the JSON path answers an error object')
  local rows, failure = host.sql_rows(bad, '[]')
  assert(rows == nil, 'the typed path answers nil on failure, got ' .. type(rows))
  assert(failure == parsed.error, 'both paths name the same failure: ' .. tostring(failure) .. ' vs ' .. tostring(parsed.error))
end)

-- Parameters keep their types too: an integer parameter must bind as an integer.
check('parameters cross the same way', function()
  local sql = 'SELECT id, i FROM seam_types WHERE i = ? ORDER BY id'
  local params = json.encode({ -7 })
  local typed = host.sql_rows(sql, params)
  local decoded = json.decode(host.sql_query(sql, params))
  compare(decoded, typed, 'bound parameter')
  assert(#typed == 1 and typed[1].i == -7, 'the bound row came back')
end)

-- ---- the path real use takes: the turn loop's own read, through memory.query
local session = memory.start_session('local', 'chat',
  { id = 'sql-rows', user_id = 'master', node_id = 'test', title = 'sql rows' })
local filler = string.rep('a turn whose row holds tool calls and a trace, like a real one. ', 4)
for i = 1, 20 do
  local turn = { role = i % 2 == 0 and 'assistant' or 'user', content = filler .. tostring(i) }
  if i % 2 == 0 then
    turn.tool_calls = { { id = 'call_' .. i, type = 'function', name = 'bash',
      arguments = json.encode({ cmd = 'ls', timeout_s = 5 }) } }
    turn.trace = { steps = { { tool = 'bash', ok = true, ms = 3 } } }
  end
  memory.append_turn(session, turn)
end

check("the turn loop's window answers the same rows", function()
  local sql = 'SELECT * FROM (SELECT * FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT ?) ORDER BY seq ASC'
  local params = json.encode({ 'sql-rows', 50 })
  local typed = host.sql_rows(sql, params)
  local decoded = json.decode(host.sql_query(sql, params))
  assert(#decoded == 20, 'the window holds the 20 seeded turns, found ' .. #decoded)
  compare(decoded, typed, 'session window')
end)

check('memory.session_messages takes the typed path and still decodes its columns', function()
  -- The probe: with host.sql_query made an error, this read can only succeed through host.sql_rows.
  local real = host.sql_query
  host.sql_query = function() error('memory.query used the JSON path on a host that has host.sql_rows') end
  local ok, rows = pcall(memory.session_messages, 'sql-rows', { limit = 50 })
  host.sql_query = real
  assert(ok, 'memory.session_messages failed while the JSON path was disabled: ' .. tostring(rows))
  assert(#rows == 20, 'the typed read returned ' .. #rows .. ' rows')
  -- The function's own post-processing is untouched: these columns are still the tables it makes.
  local tool_row = rows[2]
  assert(type(tool_row.tool_calls) == 'table', 'tool_calls is still decoded into a table')
  assert(tool_row.tool_calls[1].name == 'bash', 'the tool call survived the typed read')
  assert(type(tool_row.trace) == 'table', 'trace is still decoded into a table')
  assert(tool_row.content:find('a turn whose row holds', 1, true), 'the content column arrived')
end)

print('sql rows ok (' .. checks .. ' checks, 0 skipped)')
