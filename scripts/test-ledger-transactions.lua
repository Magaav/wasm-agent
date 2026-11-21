-- NO NETWORK, CHILD PROCESS OR SLEEP INSIDE A LEDGER TRANSACTION (21/11).
--
-- The rule this asserts is what a turn's latency rests on. The ledger has ONE writer at a time, and a
-- turn's first write is its user message: measured 21/11 on a scratch ledger with a hermetic stub
-- provider, a write lock held by a second process moves the turn's first model call by exactly the
-- hold (12 s hold -> run/start to model_call/start 12.19 s, and the host names the wait:
-- [sql] BEGIN IMMEDIATE: 11982ms). So a transaction that waits on another process - a peer probe, a
-- child admission, an HTTP call, a sleep - is a turn waiting on that process's network I/O, which the
-- mission forbids in the words "a turn must never wait on another process's network I/O".
--
-- This is a SOURCE lint, deliberately: the defect is a SHAPE (what sits inside the block), it spans
-- files and call sites, and a shape test catches the next one before it is written. It parses the
-- text rather than matching lines, so a call on the same line as the opening, or nested three
-- functions deep inside the block, is still seen.
--
-- What it does NOT claim: that a transaction is short. It claims only that no transaction holds the
-- writer lock across a call that can wait on another process.
local json = dofile("lua/vendor/json.lua")

local checks = 0
local failures = 0
local function check(value, why)
  checks = checks + 1
  if not value then
    failures = failures + 1
    print("FAIL " .. why)
  end
end

local home = host.getenv("WASM_AGENT_HOME") or ""
check(home ~= "" and not home:match("/%.wasm%-agent$"),
  "this test must run in a scratch WASM_AGENT_HOME, not the node's own: " .. tostring(home))

local root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local function read(path)
  local ok, text = pcall(host.read_file, root:gsub("/+$", "") .. "/" .. path)
  if ok and type(text) == "string" then return text end
  return nil
end

-- Files that own a transaction: every module here may call memory.transaction / in_transaction.
local FILES = {
  "lua/core/agent.lua", "lua/core/subagents.lua", "lua/core/steering.lua",
  "lua/core/wave_autoflush.lua", "lua/core/orchestration_mode.lua",
  "lua/core/workspaces.lua", "lua/core/server.lua", "lua/core/memory.lua",
}

-- A call that can wait on another process. Each is a named reason, so a failure says which.
local FORBIDDEN = {
  { pattern = "host%.subagent%s*%(", why = "host.subagent (a child-process call)" },
  { pattern = "host%.http%s*%(", why = "host.http (a network call)" },
  { pattern = "host%.http_stream%s*%(", why = "host.http_stream (a network call)" },
  { pattern = "host%.operation%s*%(", why = "host.operation (a supervised child process)" },
  { pattern = "host%.exec%s*%(", why = "host.exec (a shell command)" },
  { pattern = "host%.sleep%s*%(", why = "host.sleep (a wait)" },
  { pattern = "nodes%.remote_call%s*%(", why = "nodes.remote_call (a peer call)" },
  { pattern = "nodes%.probe%s*%(", why = "nodes.probe (a network probe)" },
}

-- The block that follows an opening transaction call: from the "(" after the call to its matching
-- ")", with strings and comments blanked so a bracket or a keyword inside a string is not counted.
local function blank(text)
  local out = {}
  local i, n = 1, #text
  local function push(ch) out[#out + 1] = ch end
  while i <= n do
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)
    if two == "--" then
      -- line comment, unless it is a long comment --[[ ]]
      local long = text:match("^%-%-%[=*%[", i)
      if long then
        local close = "]" .. long:sub(3, -2) .. "]"
        local stop = text:find(close, i + #long, true)
        local limit = stop and (stop + #close - 1) or n
        for _ = i, limit do push(" ") end
        i = limit + 1
      else
        local stop = text:find("\n", i, true) or (n + 1)
        for _ = i, stop - 1 do push(" ") end
        i = stop
      end
    elseif c == '"' or c == "'" then
      -- one string, honouring a backslash escape
      push(" ")
      i = i + 1
      while i <= n do
        local ch = text:sub(i, i)
        if ch == "\\" then push(" "); push(" "); i = i + 2
        elseif ch == c then push(" "); i = i + 1; break
        elseif ch == "\n" then break
        else push(" "); i = i + 1 end
      end
    elseif text:match("^%[=*%[", i) then
      local open = text:match("^(%[=*%[)", i)
      local close = "]" .. open:sub(2, -2) .. "]"
      local stop = text:find(close, i + #open, true)
      local limit = stop and (stop + #close - 1) or n
      for _ = i, limit do push(" ") end
      i = limit + 1
    else
      push(c)
      i = i + 1
    end
  end
  return table.concat(out)
end

-- The body of every transaction block in one source text, as { line, text }.
local function transaction_bodies(source)
  local clean = blank(source)
  local bodies = {}
  local init = 1
  while true do
    local start = clean:find("transaction%s*%(", init)
    if not start then break end
    local open = clean:find("(", start, true)
    -- Find the ")" that closes this call, counting brackets on blanked text.
    local depth, i, close = 0, open, nil
    while i <= #clean do
      local ch = clean:sub(i, i)
      if ch == "(" then depth = depth + 1
      elseif ch == ")" then
        depth = depth - 1
        if depth == 0 then close = i; break end
      end
      i = i + 1
    end
    if not close then break end
    local line = 1
    for _ in clean:sub(1, start):gmatch("\n") do line = line + 1 end
    bodies[#bodies + 1] = { line = line, text = source:sub(open + 1, close - 1) }
    init = close + 1
  end
  return bodies
end

local inspected, bodies_seen = 0, 0
for _, path in ipairs(FILES) do
  local source = read(path)
  if source then
    inspected = inspected + 1
    for _, body in ipairs(transaction_bodies(source)) do
      bodies_seen = bodies_seen + 1
      for _, rule in ipairs(FORBIDDEN) do
        local hit = body.text:match(rule.pattern)
        check(hit == nil, string.format(
          "%s:%d holds the ledger write lock across %s - that is a turn waiting on another "
            .. "process's work; take it out of the transaction",
          path, body.line, rule.why))
      end
    end
  end
end

-- The lint is only evidence if it actually looked at transactions: a parser that silently found none
-- would pass forever.
check(inspected >= 6, "the lint read at least six transaction-owning files (" .. inspected .. ")")
check(bodies_seen >= 10, "the lint found transaction bodies to inspect (" .. bodies_seen .. ")")

-- The parser itself, so a passing file list cannot be a broken parser: the same call the rule bans,
-- inside a transaction, MUST be found. Without this, a blank() that ate the whole file would pass.
do
  local probe = [[
local x = memory.transaction(function()
  return host.subagent("start", "{}")
end)
]]
  local found = false
  for _, body in ipairs(transaction_bodies(probe)) do
    if body.text:match("host%.subagent%s*%(") then found = true end
  end
  check(found, "the parser finds a forbidden call inside a transaction when there is one")
  local clean_probe = [[
local guard = memory.transaction(function() return wave.admission_guard(ctx) end)
local receipt = host.subagent("start", "{}")
]]
  local leaked = false
  for _, body in ipairs(transaction_bodies(clean_probe)) do
    if body.text:match("host%.subagent%s*%(") then leaked = true end
  end
  check(not leaked, "a call AFTER the transaction closes is not reported")
end

if failures > 0 then
  print(failures .. " of " .. checks .. " checks failed")
  os.exit(1)
end
print("ledger transactions ok — " .. checks .. " checks, " .. bodies_seen .. " transaction bodies")
