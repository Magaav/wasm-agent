-- The one host fake. A test that cannot run a real node uses THIS, and its answers are proved against
-- the real host by scripts/test-contract-host.lua.
--
-- WHY IT EXISTS. Stubs written by hand in each test accepted what the real host refuses (the node-ops
-- await stub, the harness-fixes-1 guard tests): a fake that is kinder than the host turns a real failure
-- into a green row. The shapes here are the ones measured from the real binary (rust/wa-capabilities/src/
-- host.rs, probed 20/11), so a test cannot pass against the fake and fail against the node for a reason
-- the fake invented.
--
-- WHAT IT REFUSES, on purpose:
--   * an unknown capability. The fake's table carries only what it implements, so `host.no_such_cap` is
--     nil exactly as it is on the real host - a test cannot silently depend on a capability nobody has.
--   * a path outside the scratch root it was made for. This is the one place the fake is STRICTER than
--     the real host: a test may not read or write the operator's home through a fake. The contract test
--     asserts this refusal instead of comparing it.
--   * a SQL statement nobody scripted. The real host answers with an error, so the fake does too.
--
-- WHAT IT KEEPS FAITHFUL, measured 20/11 (H=$(mktemp -d); wa --db $H/t.db with a probe script):
--   paths()        -> 1 value, a table with home/config/data/cache/temp
--   getenv(unset)  -> 1 value, nil
--   uuid()         -> a string
--   sleep(ms)      -> 0 values, and it really sleeps
--   list_dir(bad)  -> 1 value, a JSON string carrying {"error":...}
--   read_file(bad) -> 2 values: nil, "read_file_missing:<path>"
--   read_file(ok)  -> the file's text
--   write_file     -> boolean true
--   sql_query      -> a JSON string
--   sql_exec       -> a JSON string
local json = dofile("lua/vendor/json.lua")

local M = {}

-- <spec> -> a host table. spec = { root = <scratch dir>, files = {[path]=text}, sql = {[statement]=<answer>},
--                                 env = {[name]=value}, now = <number|function>, counter = <start> }
-- A spec is data, so a test that needs one answer changed says so instead of writing a new host.
function M.new(spec)
  spec = spec or {}
  local root = assert(spec.root, "a contract fake needs a scratch root: it refuses to stand in for the operator's home")
  -- The paths are the real host's SHAPE, not a guess: measured 20/11, `home` is the scratch home and
  -- `temp` is NOT under it, so a fake that derived one from the other answered a different contract and
  -- the contract test said so. A spec may name them; the default keeps every one inside the root.
  local named = spec.paths or {}
  local paths = {
    home = named.home or root,
    config = named.config or (root .. "/config"),
    data = named.data or (root .. "/data"),
    cache = named.cache or (root .. "/cache"),
    temp = named.temp or (root .. "/tmp"),
  }
  -- Every path the fake was given is a place it may touch; nothing else is.
  local owned_roots = { root }
  for _, value in pairs(named) do if type(value) == "string" and value ~= "" then owned_roots[#owned_roots + 1] = value end end
  local files, sql_answers, env = {}, spec.sql or {}, spec.env or {}
  for path, text in pairs(spec.files or {}) do files[path] = text end
  local uuid_count = tonumber(spec.counter) or 0
  local slept_ms = 0
  local clock = spec.now or function() return os.time() end

  -- Ownership. A path is the fake's business only inside its own root; `..` is resolved before the
  -- comparison so a test cannot walk out of the scratch tree with a dotted path.
  local function owned(path, what)
    local p = tostring(path)
    local parts = {}
    for segment in p:gmatch("[^/]+") do
      if segment == ".." then
        if #parts > 0 then parts[#parts] = nil end
      elseif segment ~= "." then
        parts[#parts + 1] = segment
      end
    end
    local resolved = "/" .. table.concat(parts, "/")
    for _, candidate in ipairs(owned_roots) do
      local base = candidate:gsub("/+$", "")
      if resolved == base or resolved:sub(1, #base + 1) == base .. "/" then return resolved end
    end
    return nil, what .. "_outside_scratch_root:" .. resolved
  end

  local api = {}

  api.paths = function()
    return { home = paths.home, config = paths.config, data = paths.data, cache = paths.cache, temp = paths.temp }
  end

  api.getenv = function(name) return env[tostring(name)] end

  api.uuid = function()
    uuid_count = uuid_count + 1
    return string.format("00000000-0000-4000-8000-%012d", uuid_count)
  end

  api.now = function() return clock() end
  api.monotonic_ms = function() return math.floor(clock() * 1000) + slept_ms end

  -- Zero values, like the real one: `select("#", host.sleep(n))` is 0, and the sleep is real because a
  -- test that only pretends to wait proves nothing about a timeout or a backoff.
  api.sleep = function(ms)
    local n = tonumber(ms) or 0
    slept_ms = slept_ms + n
    if spec.real_sleep ~= false and n > 0 then
      local target = os.clock() + (n / 1000)
      while os.clock() < target do end
    end
  end

  -- The real host's content address (`sha256` in rust/wa-capabilities/src/host.rs answers a stable
  -- digest STRING). Not the real algorithm: a value comparison against the node would be a different
  -- claim and nothing here makes one. What it must not do is collide for two texts of the same length -
  -- a length-only stand-in did exactly that in this session's own test, and two sides of a diff then
  -- shared one content address. Two rounds of djb2 over the bytes, printed in a shape no real digest
  -- has, so a test can never mistake it for one.
  api.sha256 = function(text)
    local s = tostring(text)
    local a, b = 5381, 52711
    for i = 1, #s do
      local byte = s:byte(i)
      a = (a * 33 + byte) % 4294967296
      b = (b * 31 + byte) % 4294967296
    end
    return string.format("0000%08x%08x", math.floor(a), math.floor(b))
  end
  api.write_file = function(path, text)
    local resolved, why = owned(path, "write_file")
    if not resolved then return false, why end
    files[resolved] = tostring(text)
    return true
  end

  api.read_file = function(path)
    local resolved, why = owned(path, "read_file")
    if not resolved then return nil, why end
    local text = files[resolved]
    if text == nil then return nil, "read_file_missing:" .. resolved end
    return text
  end

  api.list_dir = function(path)
    local resolved, why = owned(path, "list_dir")
    if not resolved then return json.encode({ error = why, path = tostring(path) }) end
    local entries, prefix = {}, resolved:gsub("/+$", "") .. "/"
    local seen = {}
    for name in pairs(files) do
      if name:sub(1, #prefix) == prefix then
        local rest = name:sub(#prefix + 1)
        local first = rest:match("^[^/]+")
        if first and not seen[first] then
          seen[first] = true
          entries[#entries + 1] = { name = first, kind = (rest:find("/") and "dir" or "file") }
        end
      end
    end
    if #entries == 0 then return json.encode({ error = "No such file or directory (os error 2)", path = resolved }) end
    table.sort(entries, function(a, b) return a.name < b.name end)
    return json.encode(entries)
  end

  -- The real host answers SQL as JSON text, never as a Lua table (the list_dir lesson, 12/11).
  api.sql_query = function(statement)
    local answer = sql_answers[tostring(statement)]
    if answer == nil then return json.encode({ error = "the contract fake scripts no answer for: " .. tostring(statement) }) end
    if type(answer) == "string" then return answer end
    return json.encode(answer)
  end

  api.sql_exec = function(statement, params)
    local answer = sql_answers[tostring(statement)]
    if answer == nil then
      return json.encode({ error = "the contract fake scripts no answer for: " .. tostring(statement) .. " " .. tostring(params or "[]") })
    end
    if type(answer) == "string" then return answer end
    return json.encode(answer)
  end

  -- host.operation: THE ONE CAPABILITY A TEST MUST NOT GET FOR FREE (item 2 of the harness-fixes-2 round).
  --
  -- It is how a probe child is started (`wa nodes probe <peer>`, lua/core/nodes.lua probe_peers), and every
  -- row that called nodes.list() unstubbed started REAL probe children against the live fleet. So this fake
  -- REFUSES to start anything and COUNTS the attempt: a row asserts `starts == 0`, which is a measured fact
  -- and not a promise. A row that tests probing opts in by scripting its own host.operation, as the
  -- nodes-probe rows do - and then the count is that row's business, not the fixture's.
  --
  -- Only the shapes the real host answers are here (await/read/list/cancel of an id it refused), so a row
  -- cannot pass against the fake and fail against the node for a reason the fake invented.
  local starts, operations = 0, {}
  api.operation = function(action, request)
    local req = request and json.decode(request) or {}
    if type(req) ~= "table" then req = {} end
    if action == "start" then
      starts = starts + 1
      return json.encode({ ok = false, error = "operation_disabled_for_test", action = action,
        detail = "a test process starts no child process: a probe that needs one opts in explicitly (scripts/lib/contract-host.lua)" })
    elseif action == "list" then
      return json.encode({ operations = operations })
    end
    -- await/read/cancel name an operation no caller here owns: the real host refuses these by name too.
    return json.encode({ ok = false, error = "operation_not_found_or_not_owned", action = tostring(action),
      id = tostring(req.id or "") })
  end

  api.spec = nil -- never a capability: the spec is the test's, not the host's

  -- What the test did, for its own assertions (never reached through a capability name the host has).
  M.observed = M.observed or {}
  return api, { slept_ms = function() return slept_ms end, files = files,
    operation_starts = function() return starts end }
end

-- <host_table> -> the observations the contract test compares between the fake and the real host.
-- One entry per capability: its arity and the TYPE of each answer, plus the answer itself where the
-- value is stable (uuids, clocks and paths are not).
function M.contract(host_like)
  local out = {}
  -- A string answer is compared by SHAPE, not only by type: the concrete path, uuid or clock is not the
  -- contract, but "read_file_missing:<path>" and "read_file_missing" are different promises to a caller
  -- and a fake that drops the path lies about which one it keeps. Everything that varies per run is
  -- redacted to a token before the comparison.
  local paths = host_like.paths() or {}
  local function shape(value)
    if type(value) ~= "string" then return type(value) end
    local text = value
    -- LONGEST FIRST. The paths nest (the fake's temp lives under its home), so redacting the parent
    -- before the child turns `<home>/tmp/x` into a different token than the host's `<temp>/x` and the
    -- comparison then reports a difference in the redaction instead of one in the answer.
    local ordered = {}
    for _, key in ipairs({ "home", "data", "config", "cache", "temp" }) do
      if type(paths[key]) == "string" and paths[key] ~= "" then ordered[#ordered + 1] = { key, paths[key] } end
    end
    table.sort(ordered, function(a, b) return #a[2] > #b[2] end)
    for _, entry in ipairs(ordered) do
      text = text:gsub(entry[2]:gsub("[%^%$%(%)%%%.%[%]%*%+%?]", "%%%0"), "<" .. entry[1] .. ">")
    end
    text = text:gsub("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "<uuid>")
    return text
  end
  local function record(name, ...)
    local n = select("#", ...)
    local types, shapes = {}, {}
    for i = 1, n do
      local value = select(i, ...)
      types[i] = type(value)
      shapes[i] = shape(value)
    end
    out[name] = { arity = n, types = table.concat(types, ","), shapes = table.concat(shapes, "\1") }
    return ...
  end
  record("paths", host_like.paths())
  record("getenv-unset", host_like.getenv("WA_CONTRACT_FAKE_UNSET"))
  record("uuid", host_like.uuid())
  record("sleep", host_like.sleep(0))
  record("read_file-missing", host_like.read_file((host_like.paths() or {}).temp .. "/contract-absent.txt"))
  record("sql_query", host_like.sql_query("select 1 as one"))
  -- An ABSENT directory, so both are asked about the same thing: a real one would differ by whatever else
  -- the host happens to hold, and the comparison would report the fixture instead of the contract.
  record("list_dir-missing", host_like.list_dir((host_like.paths() or {}).temp .. "/contract-absent-dir"))
  -- The clocks are numbers on both sides; only the TYPE is compared, because the value moves.
  record("now", host_like.now())
  record("monotonic_ms", host_like.monotonic_ms())
  record("write_file", host_like.write_file((host_like.paths() or {}).temp .. "/contract.txt", "x"))
  record("read_file-present", host_like.read_file((host_like.paths() or {}).temp .. "/contract.txt"))
  return out
end

return M
