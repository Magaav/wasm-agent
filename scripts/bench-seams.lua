-- What each internal seam costs, measured in one process: p50/p99 per call, the bytes that cross,
-- and how much of the call is JSON (Lua's encoder/decoder here, serde's in the json-cost example).
--
--   WA_SEAM_ITERATIONS=200 WA_SEAM_PAYLOAD_DIR=/tmp/x wa --db scratch.db   (see scripts/bench-seams.sh)
--
-- One row per seam, printed as TSV:
--   seam <name> n p50_us p99_us max_us bytes_in bytes_out lua_json_us status
--
-- Timed with os.clock (CPU seconds, sub-microsecond resolution), because host.monotonic_ms is a
-- whole millisecond and every call here is far below it. CPU time is also the right clock for a
-- JSON attribution: it leaves out SQLite's and the file system's I/O wait, which is the "work" side.
--
-- The *bytes* are what crosses the boundary: the JSON text Lua hands the host and the JSON text the
-- host hands back (for a non-JSON capability, the string it returns). The payloads are written to
-- WA_SEAM_PAYLOAD_DIR so the json-cost example times serde on the exact same bytes - one payload,
-- two parsers, one share. lua_json_us is the p50 of encode+decode of those payloads, and it is
-- measured on strings captured BEFORE the loop, so the JSON column never re-runs the crossing (a
-- share that measures the work it is supposed to be separate from is not a share).
--
-- Local only: the runner's own --db and a scratch WASM_AGENT_HOME, no node, no network, no model.
local json = dofile('lua/vendor/json.lua')
local N = tonumber(host.getenv('WA_SEAM_ITERATIONS') or '') or 200
local WARM = math.min(20, N)
local DIR = host.getenv('WA_SEAM_PAYLOAD_DIR') or ''
local rows = {}

local function pct(samples, p)
  if #samples == 0 then return 0 end
  local i = math.max(1, math.min(#samples, math.ceil(#samples * p)))
  return samples[i]
end

-- One seam row. call() runs the crossing and returns (bytes_in, bytes_out). share() parses
-- already-captured payload strings (never the crossing) and returns nothing.
local function seam(name, call, share)
  for _ = 1, WARM do call() end
  local samples, bytes_in, bytes_out = {}, 0, 0
  for _ = 1, N do
    local t0 = os.clock()
    local ok, bin, bout = pcall(call)
    local dt = os.clock() - t0
    if not ok then
      print(string.format('seam\t%s\t%d\t0\t0\t0\t0\t0\t0\tFAIL:%s', name, N, tostring(bin):gsub('[\t\n]', ' ')))
      return
    end
    samples[#samples + 1] = dt * 1e6
    if bin then bytes_in = bin end
    if bout then bytes_out = bout end
  end
  table.sort(samples)
  local jt = 0
  if share then
    local js = {}
    for _ = 1, N do
      local t0 = os.clock()
      share()
      js[#js + 1] = (os.clock() - t0) * 1e6
    end
    table.sort(js)
    jt = pct(js, 0.5)
  end
  rows[#rows + 1] = name
  print(string.format('seam\t%s\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%.1f\tok',
    name, N, pct(samples, 0.50), pct(samples, 0.99), pct(samples, 1.0), bytes_in, bytes_out, jt))
end

-- The text of a payload is written for the serde half; a name per seam, both directions.
local function dump(name, direction, text)
  if DIR == '' or type(text) ~= 'string' then return end
  local f = assert(io.open(DIR .. '/' .. name .. '.' .. direction .. '.json', 'wb'))
  f:write(text)
  f:close()
end

local memory = dofile('lua/core/memory.lua')
memory.setup()

-- A session with real turns in it, so a journal read is a read of this ledger and not of an empty
-- table. Half the rows carry the two JSON columns a real tool turn writes, because the payload a
-- SELECT * hands Lua is mostly those columns.
local session = memory.start_session('local', 'chat',
  { id = 'seam-bench', user_id = 'master', node_id = 'bench', title = 'seam bench' })
local filler = string.rep('the seam audit measures what crosses a boundary and what it costs. ', 8)
for i = 1, 60 do
  local turn = { role = i % 2 == 0 and 'assistant' or 'user', content = filler .. tostring(i) }
  if i % 2 == 0 then
    turn.tool_calls = { { id = 'call_' .. i, type = 'function', name = 'bash',
      arguments = json.encode({ cmd = 'ls -la', timeout_s = 30 }) } }
    turn.trace = { steps = { { tool = 'bash', ok = true, ms = 12 } } }
  end
  memory.append_turn(session, turn)
end

-- ---- 0. the crossing itself: one capability call, no payload, and the two hottest crossings the
-- per-turn counter names (getenv 995/turn, read_file 740/turn - scripts/bench-core-calls.lua)
seam('capability.floor', function()
  return 0, #tostring(host.monotonic_ms())
end)
seam('capability.getenv', function()
  local v = host.getenv('HOME')
  return 0, #tostring(v)
end)
if DIR ~= '' then
  local f = io.open(DIR .. '/read_file.target', 'wb')
  f:write(string.rep('a line a tool result holds, 60 bytes of it, plus a newline.\n', 70))
  f:close()
end
local read_target = (DIR ~= '' and (DIR .. '/read_file.target')) or '/etc/hostname'
seam('tool.read_file', function()
  local out = host.read_file(read_target)
  return #read_target, #tostring(out)
end)

-- ---- 1. the turn loop's journal read: memory.session_messages, which is SELECT * over a window
-- (lua/core/memory.lua:1424) and then decodes tool_calls/trace per row. The JSON share is measured
-- on the same statement's raw answer, captured once.
local window_sql = "SELECT * FROM (SELECT * FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT ?) ORDER BY seq ASC"
local window_args = json.encode({ 'seam-bench', 50 })
local window_raw = host.sql_query(window_sql, window_args)
seam('journal.session_messages', function()
  local before = #window_raw
  memory.session_messages('seam-bench', { limit = 50 })
  return #window_args, before
end, function()
  json.decode(window_args)
  json.decode(window_raw)
end)
dump('journal.session_messages', 'in', window_args)
dump('journal.session_messages', 'out', window_raw)

-- ---- 2. session journal write: one turn row (the shape memory.append_turn writes)
local write_sql = 'INSERT INTO messages(id,session_id,seq,role,content,created_at) VALUES(?,?,?,?,?,?)'
local seq = 1000
local write_args = json.encode({ 'bench-x', 'seam-bench', 1, 'assistant', filler, os.time() })
local write_out = host.sql_exec(write_sql, write_args)
local function write_row()
  seq = seq + 1
  local args = json.encode({ 'bench-' .. seq, 'seam-bench', seq, 'assistant', filler, os.time() })
  local out = host.sql_exec(write_sql, args)
  return #args, #tostring(out)
end
seam('journal.write', write_row, function()
  json.decode(write_args)
  json.decode(write_out)
end)

-- ---- 3. the whole append_turn path: the seq read, the insert, the FTS insert and the Lua around them
seam('memory.append_turn', function()
  memory.append_turn(session, { role = 'assistant', content = filler })
  return 0, 0
end)

-- ---- 4. node <-> rendezvous: the binding state read the controller makes every turn
local bind_args = '{}'
local bind_out = tostring(host.binding_state('read', bind_args))
seam('rendezvous.binding', function()
  local out = host.binding_state('read', bind_args)
  return #bind_args, #tostring(out)
end, function()
  json.decode(bind_args)
  json.decode(bind_out)
end)
dump('rendezvous.binding', 'out', bind_out)

-- ---- 5. the operation table: start, then the await that settles it (the MCP connector's shape).
-- The JSON share is the four payloads captured from one real pair, not a second start/await.
if type(host.operation) == 'function' then
  local start = json.encode({ program = 'sh', args = { '-c', 'true' }, timeout_seconds = 20 })
  local opened = json.decode(host.operation('start', start)) or {}
  local await_args = json.encode({ id = opened.id, wait_for = 'settled', wait_s = 20 })
  local settled = tostring(host.operation('await', await_args))
  dump('operation', 'in', start)
  dump('operation', 'out', settled)
  seam('operation.start_await', function()
    local s2 = json.encode({ program = 'sh', args = { '-c', 'true' }, timeout_seconds = 20 })
    local o2 = json.decode(host.operation('start', s2)) or {}
    local a2 = json.encode({ id = o2.id, wait_for = 'settled', wait_s = 20 })
    local answer = host.operation('await', a2)
    return #s2 + #a2, #tostring(answer)
  end, function()
    json.decode(start)
    json.decode(await_args)
    json.decode(settled)
  end)
else
  print('seam\toperation.start_await\t0\t0\t0\t0\t0\t0\t0\tSKIP:no host.operation capability')
end

-- ---- 6. TUI <-> core: one transcript line (plain text, no JSON - the control row)
local line = string.rep('a transcript line the terminal draws ', 30)
seam('tui.transcript_write', function()
  host.transcript_write(line .. '\n')
  return 0, #line
end)

-- ---- 7. MCP connector: one tools/call through the component seam, when a server is configured
if type(host.component_mcp) == 'function' then
  local probe = json.encode({ action = 'list' })
  local answer = host.component_mcp(probe)
  local probe_value = json.decode(tostring(answer)) or {}
  if probe_value.ok then
    local request = json.encode({ action = 'call', server = probe_value.server or 'echo', tool = 'echo', arguments = { text = 'seam bench' } })
    local reply = tostring(host.component_mcp(request))
    seam('mcp.component_call', function()
      local out = host.component_mcp(request)
      return #request, #tostring(out)
    end, function()
      json.decode(request)
      json.decode(reply)
    end)
    dump('mcp.component_call', 'in', request)
    dump('mcp.component_call', 'out', reply)
  else
    print('seam\tmcp.component_call\t0\t0\t0\t0\t0\t0\t0\tSKIP:no MCP server configured (' .. tostring(probe_value.error or 'unknown') .. ')')
  end
else
  print('seam\tmcp.component_call\t0\t0\t0\t0\t0\t0\t0\tSKIP:no host.component_mcp capability in this binary')
end

print(string.format('# iterations=%d rows=%d', N, #rows))
