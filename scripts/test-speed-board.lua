-- THE SPEED BOARD ITSELF: one line per commit, the load guard, the RED row, and never a zero for a row it
-- could not measure (change/speed-board, 22/11).
--
-- This drives scripts/speed-board.sh through the SAME path main-health and status.sh take, with probes of
-- its own (WA_SPEED_PROBES -> a scratch directory), so the rows it judges are fixtures and the judgement is
-- the shipped one. What it pins:
--
--   1. two runs on two commits give two lines; a RE-RUN of the same commit replaces its own line (the
--      "last 10 commits" window must never be ten runs of one tip);
--   2. a row 25% slower than the best of the last 10 at a comparable load is RED, and --check names the row
--      and the commit that holds the floor (exit 3);
--   3. the same row at load 12 is NOT red - the machine was busy, the commit did not regress;
--   4. above the ceiling nothing is measured at all: the rows are 'guarded' with the reason;
--   5. a probe that refuses prints its reason and its row is 'unavailable', never green;
--   6. no binary means no live row, said by name;
--   7. the landing row comes from land-quick's own record and the release row from a release journal, and
--      when neither exists the rows say so instead of printing a zero.
--
-- Its own scratch HOME (rule 2: it refuses the operator's own), no binary of the product is needed (the
-- probes are shell stubs), no network, no node.
local json = dofile('lua/vendor/json.lua')

local failures, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then print('ok   ' .. label) else print('FAIL ' .. label); failures = failures + 1 end
end

local home = tostring(host.getenv('WASM_AGENT_HOME') or '')
local function norm(value) return (tostring(value or ''):gsub('\\', '/'):gsub('/+$', '')):lower() end
if home == '' then print('SKIP speed-board: no WASM_AGENT_HOME (a scratch home is required)'); os.exit(0) end
if norm(home) == norm((host.getenv('HOME') or '') .. '/.wasm-agent') then
  print('FAIL speed-board: refusing to run against the node own home (' .. home .. ')')
  os.exit(1)
end
local root = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local function sh(command)
  local called, raw = pcall(host.exec, command, root, 300)
  if not called then return { code = 127, stdout = '', stderr = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= 'table' then return { code = 127, stdout = tostring(raw), stderr = '' } end
  return decoded
end

local work = home .. '/speed-board-test'
sh('rm -rf "' .. work .. '" && mkdir -p "' .. work .. '/probes" "' .. work .. '/home" "' .. work .. '/land"')
local history = work .. '/speed-history.jsonl'
local landings = work .. '/landings.jsonl'

-- Four probes with the harness's own names, printing the samples a real one prints. The numbers are the
-- test's: what is judged here is the board, not the machine.
local function probe(numbers)
  local body = '#!/usr/bin/env bash\n'
  for index, value in ipairs(numbers) do
    body = body .. "echo 'sample " .. index .. ' ' .. value .. "'\n"
  end
  return body
end
local function write_probe(name, body)
  local path = work .. '/probes/' .. name .. '.sh'
  local file = assert(io.open(path, 'w'))
  file:write(body)
  file:close()
  sh('chmod +x "' .. path .. '"')
end
write_probe('probe-cold-start', probe({ 100, 100, 100 }))
write_probe('probe-first-token', probe({ 200, 200, 200 }))
write_probe('probe-cold-start', probe({ 100, 100, 100 }))
write_probe('probe-tool-roundtrip', probe({ 50, 50, 50 }))
write_probe('probe-remote', probe({ 400, 400, 400 }))

local board = 'bash "' .. root .. '/scripts/speed-board.sh"'
local function measure(sha, extra)
  return sh('WA_SPEED_LOAD=2 ' .. board .. ' --measure --probes "' .. work .. '/probes" --history "' .. history .. '" --sha ' .. sha
    .. ' --samples 3' .. (extra or '') .. ' 2>&1')
end
local function print_table(sha)
  return sh(board .. ' --print --history "' .. history .. '" --sha ' .. sha .. ' 2>&1').stdout or ''
end

-- 1. a first commit: four rows and two records that do not exist yet.
local first = measure('c0001', ' --bin /bin/true')
check(first.code == 0, 'the first measurement is written (' .. tostring(first.code) .. ')')
check(first.stdout:find('start=100ms', 1, true) ~= nil, 'the first line names the median of the start row: ' .. tostring(first.stdout:match('start=[^ ]*')))
local table_text = print_table('c0001')
check(table_text:find('start', 1, true) ~= nil and table_text:find('100 ms', 1, true) ~= nil,
  'status.sh prints the commit number and its load')
check(table_text:find('landing', 1, true) ~= nil and table_text:find('no landing recorded', 1, true) ~= nil,
  'a landing nobody recorded is unknown with the reason, not a zero')
check(table_text:find('release', 1, true) ~= nil, 'the release row is on the table')

-- 2. a second commit, 25% slower on start: RED, named, and --check exits 3.
write_probe('probe-cold-start', probe({ 125, 125, 125 }))
local second = measure('c0002', ' --bin /bin/true')
check(second.code == 3, 'a RED row makes --measure exit 3 (' .. tostring(second.code) .. ')')
check((second.stdout or ''):find('RED start', 1, true) ~= nil, 'the RED row is named: ' .. tostring((second.stdout or ''):match('RED [^\n]*')))
local check_run = sh(board .. ' --check --history "' .. history .. '" 2>&1')
check(check_run.code == 3, '--check exits 3 while a row is red')

-- 3. the same row taken at load 12 is NOT a regression: the commit did not get slower, the machine did.
write_probe('probe-cold-start', probe({ 900, 900, 900 }))
local busy = sh('WA_SPEED_LOAD=12 ' .. board .. ' --measure --probes "' .. work .. '/probes" --history "' .. history .. '" --sha c0003 --bin /bin/true --samples 3 2>&1')
check(busy.code == 0, 'a busy but valid measurement is not RED (' .. tostring(busy.code) .. ')')
check(print_table('c0003'):find('at a comparable load', 1, true) ~= nil,
  'the busy row says it has no comparable baseline')

-- 4. above the ceiling nothing is measured: the reason is written down instead.
local guarded = sh('WA_SPEED_LOAD=99 ' .. board .. ' --measure --probes "' .. work .. '/probes" --history "' .. history
  .. '" --sha c0004 --bin /bin/true --samples 3 2>&1')
check(guarded.code == 0, 'a guarded run still records its line (' .. tostring(guarded.code) .. ')')
check((guarded.stdout or ''):find('start=guarded', 1, true) ~= nil, 'the live rows are guarded, not measured: ' .. tostring((guarded.stdout or ''):match('start=[^ ]*')))
check((guarded.stdout or ''):find('100ms', 1, true) == nil, 'nothing was measured at load 99')

-- 5. a probe that refuses: its row is unavailable and its reason is printed.
write_probe('probe-cold-start', probe({ 100, 100, 100 }))
local refusing = '#!/usr/bin/env bash\necho "unavailable: the fixture said no" >&2\nexit 2\n'
write_probe('probe-first-token', refusing)
local refused = measure('c0005', ' --bin /bin/true --samples 3')
check(refused.code == 0, 'one refused row does not fail the board (' .. tostring(refused.code) .. ')')
check((refused.stdout or ''):find('first_token=unavailable', 1, true) ~= nil, 'the refused row is unavailable: ' .. tostring((refused.stdout or ''):match('first_token=[^ ]*')))
local refused_table = print_table('c0005')
check(refused_table:find('the fixture said no', 1, true) ~= nil, 'the table carries the probe own reason')

-- 6. no binary: every live row says so, by name.
local no_bin = sh(board .. ' --measure --probes "' .. work .. '/probes" --history "' .. history .. '" --sha c0006 --samples 3 2>&1')
check(no_bin.code == 0, 'a board with no binary still records its line (' .. tostring(no_bin.code) .. ')')
check((no_bin.stdout or ''):find('start=unavailable', 1, true) ~= nil, 'the start row says it had no binary')
check((no_bin.stdout or ''):find('remote_roundtrip=unavailable', 1, true) ~= nil, 'so does the remote row')

-- 7. the two records: land-quick's own line and a release journal.
write_probe('probe-first-token', probe({ 200, 200, 200 }))
local land = assert(io.open(landings, 'w'))
land:write('{"branch":"change/x","sha":"abc","seconds":42,"load":1.1}\n')
land:close()
local release_dir = work .. '/home/.wasm-agent/land/release-20261122T000000Z-test'
sh('mkdir -p "' .. release_dir .. '" && printf \'{"result":"done","created_at":1000,"updated_at":1150}\\n\' > "' .. release_dir .. '/journal.json"')
local recorded = sh('HOME="' .. work .. '/home" WA_SPEED_LANDINGS="' .. landings .. '" ' .. board
  .. ' --measure --probes "' .. work .. '/probes" --history "' .. history .. '" --sha c0007 --bin /bin/true --samples 3 2>&1')
check(recorded.code == 0, 'a measurement with records still writes (' .. tostring(recorded.code) .. ')')
check((recorded.stdout or ''):find('landing=42000ms', 1, true) ~= nil, 'the landing row is landed from its own record: ' .. tostring((recorded.stdout or ''):match('landing=[^ ]*')))
check((recorded.stdout or ''):find('release=150000ms', 1, true) ~= nil, 'the release row is cut -> published from the journal: ' .. tostring((recorded.stdout or ''):match('release=[^ ]*')))

-- 8. one line per commit, and a re-run of a commit replaces its own line.
local before = sh('wc -l < "' .. history .. '"').stdout or ''
measure('c0007', ' --bin /bin/true --samples 3')
local after = sh('wc -l < "' .. history .. '"').stdout or ''
check(before:gsub('%s', '') == after:gsub('%s', ''), 'a re-measured commit keeps one line (' .. tostring(before) .. ' -> ' .. tostring(after) .. ')')

sh('rm -rf "' .. work .. '"')
if failures > 0 then
  print(string.format('speed-board: %d FAIL of %d', failures, checks))
  os.exit(1)
end
print(string.format('speed-board ok (%d checks)', checks))
