-- wasm-agent CLI, in Lua. Capabilities come from the host (`host.*`).
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

-- Every command this process runs passes the path guard first (lua/core/path_guard.lua): a recursive
-- delete of a home, a root, `~/.wasm-agent` or the install tree is refused by name, whoever asked for
-- it. Installed here, once, so a call site added later cannot forget it. Measured 11/11: a test took
-- its scratch from WASM_AGENT_HOME and deleted the operator's whole home.
dofile("lua/core/path_guard.lua").install(host)

-- Where this Lua came from: the compiled-in copy, or - on an installed node - the pinned tree
-- deploy installs beside the binary (<install>/lua-core, verified against the binary's capability
-- digest; `wa --lua-tree` says which). That tree is the shipping copy, not dev mode: none of the
-- dev-mode rules below apply to it. A Lua-only change reaches a node through that tree with no
-- compile (scripts/deploy.sh "Lua fast path").
--
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
-- `wa --continue` / `wa -c` / `wa --session <id>`: the chat's own flags work without the word
-- `chat`, so the first thing typed after a reboot gets back the thread that was open.
if command == "--continue" or command == "-c" or command == "--session" or command == "--resume" then
  table.insert(args, 1, "chat")
  command = "chat"
end
if command == nil or command == "chat" then
  -- Propagate the REPL's status: `wa chat --session <bogus>` exits non-zero so a
  -- script can tell a rejected session from a successful one.
  local code = dofile("lua/core/chat.lua").run(args)
  if code and code ~= 0 then os.exit(code) end
  return
end

-- `wa update` / `wa --update`: the same request `/update` makes in the chat and the window, from a
-- shell - so one command updates any node: a tree install queues the Sentinel deploy, a release install
-- runs the verifying bootstrap. `--check` is read-only: is this node behind what an update would install?
--
-- `wa update <node> [...]` is the fabric form (lua/core/remote_update.lua, docs/REMOTE-UPDATE.md): a
-- master asks another node to update ITSELF, under that node's own Sentinel and rules. It is checked
-- first and falls through to this node's own update when the second word is not a node name.
-- `wa update --all` is the read-only table of every node this node can see (lua/core/update_all.lua).
if command == "update" or command == "--update" then
  -- `wa update --all`: one read-only table over the fabric (lua/core/update_all.lua). Parsed BEFORE the
  -- fabric form below, because that one reads its first word as a node name and falls through on a flag -
  -- and `--all` must never be mistaken for a node called `--all` on the path that installs things.
  for i = 2, #args do
    if args[i] == "--all" then
      local table_report = dofile("lua/core/update_all.lua").run({})
      print(dofile("lua/core/redact.lua").text(table_report))
      return
    end
  end
  local remote = dofile("lua/core/remote_update.lua").cli(args)
  if remote ~= nil then os.exit(remote) end
  local check = false
  for i = 2, #args do if args[i] == "--check" then check = true end end
  local updater = dofile("lua/core/update.lua")
  local report = check and updater.check({}) or updater.run({ reason = "requested with `wa update`" })
  local redact = dofile("lua/core/redact.lua")
  if check then
    print(redact.text(report.message or json.encode(report)))
    -- The published release, as a second, separate fact (the window's banner reads the same check).
    local feed = updater.run({ check = true })
    if feed.release and feed.release.state == "behind" then print(redact.text("release feed: " .. feed.release.message)) end
  else
    print(redact.text(report.message or json.encode(report)))
    if report.release and report.release.state == "behind" then print(redact.text("release: " .. report.release.message)) end
    if report.observed and not report.ok then print(redact.text("observed: " .. tostring(report.observed))) end
  end
  if report.next then print(redact.text("next: " .. report.next)) end
  if report.ok == false then os.exit(1) end
  return
end

if command == "init" then
  print(json.encode({ schema = "ok" }))
elseif command == "remember" then
  print((memory.remember(args[2], "global", {})))
elseif command == "recall" then
  each(memory.recall(args[2], limit_of(args[3], 10)))
elseif command == "memories" then
  each(memory.memories(nil, limit_of(args[2], 50)))
elseif command == "forget" then
  print(json.encode({ forgotten = memory.forget(args[2]) }))
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
  if args[2]=='pending' then
    local result=dofile('lua/core/binding_cli.lua').run('nodes','pending')
    if result.error or result.ok==false then os.exit(1) end
  else
    local nodes = dofile("lua/core/nodes.lua")
    print(json.encode({ node_id = (nodes.identity() or {}).node_id, nodes = nodes.list() }))
  end
elseif command == "stt" then
  -- The speech queue's node role, changed while the node runs (docs/WHATSAPP-TRANSCRIPTION.md,
  -- "Changing the role live"). `wa stt status` answers with what this node is doing *now* and which
  -- layer said so; `wa stt role ...` persists the setting, and the serving node adopts it on its next
  -- tick (this process only stores it: starting speech threads in a one-shot command would let it
  -- take a job it dies holding). The words, the precedence and the write are the module's
  -- (`lua/core/stt.lua`); this is the dispatch only.
  local result = dofile("lua/core/stt.lua").cli({ table.unpack(args, 2) })
  print(json.encode(result))
  if result and result.ok == false then os.exit(1) end
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
elseif command == "watch" then
  -- Follow a session on another node, read-only (docs/SESSION-WATCH.md). The body is the module's: this
  -- is the dispatch only, and it is next to `call` because it is the same signed peer path.
  local code = dofile("lua/core/session_watch.lua").cli(args)
  if code then os.exit(code) end
elseif command == "session" and args[2] == "start" then
  -- The operator's half of `session_start`: start a session on another node, print its id at once.
  local code = dofile("lua/core/session_watch.lua").start_cli(args)
  if code then os.exit(code) end
elseif command == 'bind' or command == 'unbind' or command == 'accept' or command == 'promote' or command == 'demote' or command == 'revoke' then
  -- The whole remainder, not args[2]: `wa bind permanent renew <service>` is one intent, and keeping
  -- only the second word made the one-shot CLI unable to express it (it fell back to the service
  -- prompt and to the ordinary consent word).
  local result=dofile('lua/core/binding_cli.lua').run(command,table.concat(args,' ',2))
  if result.error or result.ok==false then os.exit(1) end
elseif command == "network" then
  if not ((args[2] == "role" or args[2] == "forget") and args[3]) then
    print(json.encode({ error = "usage: wa network role <node-id> master|guest | wa network forget <node-id>" }))
    os.exit(2)
  end
  local nodes = dofile("lua/core/nodes.lua")
  local result = args[2] == "forget" and nodes.network_forget(args[3]) or nodes.network_role(args[3], args[4])
  print(json.encode(result))
  if result.error then os.exit(1) end
elseif command == "fleet" then
  -- The fleet bootstrap (docs/MESH.md section 7): install this fleet's roster on a node that already
  -- accepts this one as an operator, then verify it with a mesh call. The body lives in its own module
  -- so the CLI stays a dispatch table; the fleet key never travels.
  local result = dofile("lua/core/fleet.lua").run(args[2], table.concat(args, ' ', 3))
  if result.error or result.ok == false then os.exit(1) end
elseif command == "access" then
  local access = dofile("lua/core/enrollment.lua")
  print(json.encode(args[2] == "log" and access.events() or access.status()))
elseif command == "capabilities" then
  -- The node's own capability inventory, as data. The list comes from the host registry that
  -- *registers* the capabilities (`rust/wa-host/src/capabilities.rs`), so this verb cannot disagree
  -- with what the node can actually do; `docs/HOST.md` is checked against that registry by a test.
  -- `--json` is the machine form (what the sandbox's capabilities() answers with), the default is
  -- one line per capability for a reader.
  local inventory = dofile("lua/core/capability_inventory.lua")
  local text = inventory.json()
  if not text then
    print(json.encode({ error = "capability_inventory_unavailable" }))
    os.exit(1)
  end
  if args[2] == "--json" then print(text) else print(inventory.text()) end
elseif command == "services" then
  -- The operator's door to the service components (lua/core/services_cli.lua): list, status, start,
  -- stop, enable, disable - no turn and no model required, which is the whole point on a model-less
  -- node. Every verb goes through the registry's own master gate (lua/core/services.lua).
  local code = dofile("lua/core/services_cli.lua").run({ table.unpack(args, 2) })
  if code and code ~= 0 then os.exit(code) end
elseif command == "help" then
  print("wa [chat] [--continue|-c|--resume <id>] [prompt]  |  remember <text> | recall <query>")
  print("    memories | forget <id>")
  print("    sessions | skills | stats | status | nodes | call <node> <capability> [args-json]")
  print("    watch <node> <session> [--from <cursor>]  follow a session on another node, read-only")
  print("    session start <node> --prompt <text> [--cwd <dir>]  start a session on another node, print its id")
  print("    stt status | stt role <producer|worker|both|off> [--producer <node>]  this node's speech role, changed live")
  print("    capabilities [--json]  what this node can do: every registered host capability")
  print("    services list|status|start|stop|enable|disable <name>  service components, no turn required")
  print("    resume [--list] [--session <id>] [prompt]   see and continue an unfinished thread")
  print("    paths  where this node keeps its files, and the config file it would read")
  print('    bind [service|status|renew|run] | unbind | nodes pending | accept <pairing-code>')
  print('    promote <node> | demote <node> | revoke <node>  confirmed network controls')
  print("    network role <node-id> master|guest  administrator-controlled network role")
  print("    network forget <node-id>  administrator: remove a stale registration from the rendezvous")
  print("    fleet push-roster <node> [--replace-key <hex>]  install this fleet's roster on a node that already accepts this one, then verify it with a mesh call")
  print("    access [log]  managed-access status or recent local audit events (no model)")
  print("    update [--check] | --update  update this node (tree: Sentinel deploy; release: verified bundle)")
  print("    update --all                 read-only table: what an update would install, per node this node can see")
  print("    update <node> [--status]      ask another node to update itself, then read what it installed")
else
  print("unknown command: " .. tostring(command))
  os.exit(2)
end
