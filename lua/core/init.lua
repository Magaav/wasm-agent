-- wasm-agent CLI, in Lua. Capabilities come from the host (`host.*`).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

-- A dev-mode node must not write the operator's ledger.
--
-- `WASM_AGENT_LUA_ROOT` makes the installed binary read `lua/` from a checkout, which is what
-- makes self-evolution possible - and it is also how one ledger came to hold 39 binaries and
-- four `lua_root`s, both naming generations in the same tables, and 25 full-prompt cache misses
-- worth about half of everything this node had ever spent. `scripts/dev-agent.cmd` gives a dev
-- node its own home; this is the other half, for the run that does not go through the launcher.
--
-- The test is the *ledger about to be opened*, not the flags: the host always sets
-- `WASM_AGENT_DB` (to the resolved default when `--db` is absent), so "no override" cannot be
-- read from the environment. Refused when that path is the operator's own ledger and the Lua
-- came from a checkout; a scratch `--db`, or any `WASM_AGENT_HOME`, is a candidate node and is
-- left alone - the suites and a candidate node run that way. Before `memory.setup()`, so the
-- refusal costs no database work and writes nothing.
do
  local function norm(value)
    return (tostring(value or ""):gsub("\\", "/"):gsub("/+$", "")):lower()
  end
  local root = host.getenv("WASM_AGENT_LUA_ROOT")
  local operator_home = host.getenv("USERPROFILE") or host.getenv("HOME") or ""
  local production_db = norm(operator_home .. "/.wasm-agent/memory.db")
  if root and root ~= "" and norm(host.getenv("WASM_AGENT_DB")) == production_db
     and not host.getenv("WASM_AGENT_HOME")
     and host.getenv("WASM_AGENT_ALLOW_DEV_HOME") ~= "1" then
    print("wa: refusing on-disk Lua (" .. root .. ") against the operator's ledger.")
    print("    " .. tostring(host.getenv("WASM_AGENT_DB")))
    print("    A dev node is a candidate node: give it its own home, or a scratch ledger.")
    print("      scripts/dev-agent.cmd            its own home, gitignored (Windows)")
    print("      WASM_AGENT_HOME=<dir> wa ...     any candidate home")
    print("      wa --db <scratch.db> ...         a scratch ledger")
    print("    Deliberate override: WASM_AGENT_ALLOW_DEV_HOME=1")
    os.exit(2)
  end
end

memory.setup()

local function line(item)
  if item.content then
    local tags = ""
    if item.tags and #item.tags > 0 then tags = " [" .. table.concat(item.tags, ", ") .. "]" end
    return string.format("%s  %s%s  %s", item.id, item.scope or "", tags, item.content)
  elseif item.body then
    return string.format("%s  %s  %s", item.conversation_id, item.sender_id or "-", item.body)
  end
  return json.encode(item)
end

local function each(rows)
  if #rows == 0 then print("(empty)") return end
  for _, row in ipairs(rows) do print(line(row)) end
end

local function limit_of(value, fallback)
  return tonumber(value) or fallback
end

local command = args[1]
if command == nil or command == "chat" then
  -- Propagate the REPL's status: `wa chat --session <bogus>` exits non-zero so a
  -- script can tell a rejected session from a successful one.
  local code = dofile("lua/core/chat.lua").run(args)
  if code and code ~= 0 then os.exit(code) end
  return
end

if command == "init" then
  print(json.encode({ schema = "ok" }))
elseif command == "remember" then
  print(memory.remember(args[2], "global", {}))
elseif command == "recall" then
  each(memory.recall(args[2], limit_of(args[3], 10)))
elseif command == "memories" then
  each(memory.memories(nil, limit_of(args[2], 50)))
elseif command == "forget" then
  print(json.encode({ forgotten = memory.forget(args[2]) }))
elseif command == "search" then
  each(memory.search_ledger(args[2], args[3], limit_of(args[4], 20)))
elseif command == "conversation" then
  each(memory.conversation(args[2], limit_of(args[3], 50)))
elseif command == "conversations" then
  each(memory.conversations(limit_of(args[2], 50)))
elseif command == "skills" then
  local skills = dofile("lua/core/skills.lua").list(true)
  if #skills == 0 then print("(no skills found)") end
  for _, skill in ipairs(skills) do
    print(string.format("%s  %s", skill.name, skill.path))
    print("    " .. skill.description)
  end
elseif command == "stats" then
  print(json.encode(memory.stats()))
elseif command == "status" then
  -- One health line per fact, from this checkout (the Lua core, not the host).
  dofile("lua/core/status.lua").report()
elseif command == "toolchain" then
  -- What this node needs in order to build *itself*, and how to get it on this machine. Asking is
  -- read-only; only `ensure --yes` installs anything. The exit code is useful in scripts: non-zero
  -- when a toolchain is missing.
  os.exit(dofile("lua/core/toolchain.lua").cli(args) or 0)
elseif command == "resume" then
  -- Recovery, in two halves: see what was left unfinished, then continue it.
  --
  -- Reporting is read-only on purpose. "Visible" and "recovered" are different
  -- claims: a command that silently repairs what it prints cannot be used to
  -- check whether anything is wrong, and a repair nobody asked for destroys the
  -- evidence of the crash. `wa resume` prints; `wa resume <prompt>` continues the
  -- thread, with the model told what was lost.
  local target, prompt, list_only, index = nil, {}, false, 2
  while args[index] do
    local arg = args[index]
    if arg == "--session" then
      target = args[index + 1]
      index = index + 2
    elseif arg == "--list" then
      list_only = true
      index = index + 1
    else
      prompt[#prompt + 1] = arg
      index = index + 1
    end
  end

  local function report(state)
    local short = string.sub(state.session_id or "", 1, 8)
    print(string.format("  %s  messages=%d  %s", short, state.messages or 0, state.detail))
    if state.question ~= "" then
      print("            asked     " .. tostring(state.question):gsub("%s+", " "):sub(1, 120))
    end
    -- The recorded history is shown even when the thread is settled now: a reply
    -- written after a crash is not the same thing as a reply, and the record is
    -- the only place that difference survives.
    if state.interruptions > 0 then
      print(string.format("            history   left unfinished %d time(s); newest at turn %d: %s",
        state.interruptions, state.recorded_seq, state.recorded_reason))
    end
    if state.state == "unfinished" then
      print(string.format("            recover   wa resume --session %s \"continue where you stopped\"", short))
    end
  end

  local states, targeted = nil, false
  if target and target ~= "" then
    local state = memory.session_state(target)
    if not state then
      print("  no such session: " .. target)
      print("  list them with: wa sessions")
      os.exit(2)
    end
    state.messages = memory.message_count(target)
    states, targeted = { state }, true
  else
    states = memory.unfinished(nil, 40)
  end

  if #states == 0 then
    local latest = memory.latest_session("master", "")
    local settled = latest and memory.session_state(latest.id)
    print("  none - nothing is waiting")
    print("  newest thread: " .. (settled and settled.detail or "no sessions yet"))
    if #prompt > 0 then
      -- Do not swallow the prompt: say what is happening and run it in the
      -- newest thread, which is what `--continue` would do anyway.
      print("  running the prompt in the newest thread instead")
      local code = dofile("lua/core/chat.lua").run({ "chat", "--continue", table.concat(prompt, " ") })
      if code and code ~= 0 then os.exit(code) end
    end
    return
  end

  if #prompt > 0 and not list_only then
    -- Continuing: the report's advice ("run wa resume --session ...") is about to
    -- be carried out, and the banner below repeats the detail. One line of
    -- orientation, then the handoff.
    local first = states[1]
    print(string.format("  resuming %s  messages=%d  %s",
      string.sub(first.session_id, 1, 8), first.messages or 0, first.detail))
  else
    if not targeted then print("  waiting: " .. (#states == 1 and "1 thread" or (#states .. " threads"))) end
    for _, state in ipairs(states) do report(state) end
  end
  if list_only or #prompt == 0 then return end

  local id = target or states[1].session_id
  local argv = { "chat", "--session", id }
  for _, word in ipairs(prompt) do argv[#argv + 1] = word end
  local code = dofile("lua/core/chat.lua").run(argv)
  if code and code ~= 0 then os.exit(code) end
elseif command == "sessions" then
  local rows = memory.list_sessions(nil, limit_of(args[2], 20), { states = true })
  if #rows == 0 then print("(no sessions)") end
  for _, row in ipairs(rows) do
    print(string.format("%s  %-10s messages=%-3d %-12s %s", row.id, row.user_id or "",
      tonumber(row.message_count) or 0, row.state or "-", row.title or ""))
    -- A thread that needs attention says why, on its own line: the state column
    -- is a label, and a label alone would make the reader open every session.
    if row.state == "unfinished" then print("      " .. row.state_detail) end
  end
elseif command == "nodes" then
  local nodes = dofile("lua/core/nodes.lua")
  print(json.encode({ node_id = (nodes.identity() or {}).node_id, nodes = nodes.list() }))
elseif command == "paths" then
  -- What an operator runs first when the agent says "no model configured": where
  -- this node keeps its files, and which file the host actually reads for the
  -- settings. A wrong path here is worse than no path - it sends the user off to
  -- edit a file that will never be loaded (which is what the Git Bash HOME bug
  -- did, silently).
  local paths = dofile("lua/core/paths.lua")
  local all = paths.all()
  local ok, live = pcall(function() return host.paths() end)
  if not ok or type(live) ~= "table" then
    print("note: this host has no host.paths(); the paths below are derived from the environment")
  end
  for _, field in ipairs({ "home", "config", "data", "cache", "temp" }) do
    print(string.format("%-12s %s", field, tostring(all[field])))
  end
  local present = paths.config_file_present()
  print(string.format("%-12s %s  (%s)", "config file", paths.config_file(),
    present and "present, read at startup" or "missing, nothing to read"))
elseif command == "call" then
  local nodes = dofile("lua/core/nodes.lua")
  local payload = {}
  if args[4] and args[4] ~= "" then
    local ok, decoded = pcall(json.decode, args[4])
    if ok and type(decoded) == "table" then payload = decoded end
  end
  print(json.encode(nodes.remote_call(args[2], args[3], payload)))
elseif command == "network" then
  if args[2] ~= "role" or not args[3] then
    print(json.encode({ error = "usage: wa network role <node-id> master|guest" }))
    os.exit(2)
  end
  local result = dofile("lua/core/nodes.lua").network_role(args[3], args[4])
  print(json.encode(result))
  if result.error then os.exit(1) end
elseif command == "access" then
  local access = dofile("lua/core/enrollment.lua")
  print(json.encode(args[2] == "log" and access.events() or access.status()))
elseif command == "help" then
  print("wa: chat [--continue|--session <id>] [prompt]  |  remember <text> | recall <query>")
  print("    memories | forget <id> | search <query> | conversation <id> | conversations")
  print("    sessions | skills | stats | status | nodes | call <node> <capability> [args-json]")
  print("    resume [--list] [--session <id>] [prompt]   see and continue an unfinished thread")
  print("    paths  where this node keeps its files, and the config file it would read")
  print("    network role <node-id> master|guest  administrator-controlled network role")
  print("    access [log]  managed-access status or recent local audit events (no model)")
else
  print("unknown command: " .. tostring(command))
  os.exit(2)
end
