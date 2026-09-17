-- Tools exposed to the head model. Access is gated by the caller's role:
-- masters get everything; guests get on-demand memory plus a way to list
-- what they may do. "spells" means crystallized macros only (spells.lua).
local json = dofile("lua/vendor/json.lua")
local platform = dofile("lua/core/platform.lua")
local spellslib = dofile("lua/core/spells.lua")
local nodeslib = dofile("lua/core/nodes.lua")
local M = {}

local function is_master(role)
  return role == "master" or role == "admin"
end

local function schema(name, description, properties, required)
  -- An empty Lua table encodes as `[]`, which providers reject as a schema, so
  -- only emit `properties`/`required` when they actually have entries.
  local parameters = { type = "object" }
  if properties and next(properties) ~= nil then parameters.properties = properties end
  if required and #required > 0 then parameters.required = required end
  return { type = "function", ["function"] = {
    name = name, description = description, parameters = parameters } }
end

-- Available to everyone.
M.shared = {
  schema("remember", "Store a fact the user asked you to remember, so it can be recalled later. Confirm in one short sentence; do not store your own reasoning.", {
    content = { type = "string", description = "The fact to remember, in full." },
    scope = { type = "string", description = "Optional scope, e.g. global or a conversation id." },
    tags = { type = "array", items = { type = "string" } } }, { "content" }),
  schema("recall", "Look up facts the user previously asked you to remember. Call this before answering any question about the user, their preferences, names, codewords, settings, accounts, or earlier decisions - and before saying you do not know. The store is small and lookup is cheap; guessing is not.", {
    query = { type = "string", description = "What to look for, in the user's own words." },
    scope = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("capabilities", "List the tools available to this account (its capabilities).", {}),
  schema("sessions", "List your own past sessions (resumable threads), most recent first.", {
    limit = { type = "integer", minimum = 1, maximum = 100 } }),
  schema("session", "Read one of your past sessions: the transcript, oldest first.", {
    session_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 1000 } }, { "session_id" }),
  schema("search_turns", "Search your own past sessions for text (what did we decide about X?).", {
    query = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("resume_session", "Fold a past session into this one: its summary and recent turns become context.", {
    session_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 100 } }, { "session_id" }),
}

-- Admin only: the ledger and the pi-style environment tools.
M.admin = {
  schema("search_messages", "Search the message ledger (WhatsApp/chat history) for literal text.", {
    query = { type = "string" },
    conversation_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("conversation", "Read the most recent messages of one conversation, oldest first.", {
    conversation_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 200 } }, { "conversation_id" }),
  schema("list_conversations", "List conversations known to the ledger, most recently active first.", {
    limit = { type = "integer", minimum = 1, maximum = 200 } }),
  -- The dialect is in the description because the model otherwise assumes POSIX
  -- and wastes its tool budget on commands this machine does not have.
  schema("bash", "Run a shell command on this machine and return stdout, stderr and the exit code. This machine runs " ..
    platform.shell() .. (platform.os() == "windows" and ": use dir, type, findstr, copy." or "."), {
    command = { type = "string" }, cwd = { type = "string" } }, { "command" }),
  schema("read", "Read a text file, optionally a line range.", {
    path = { type = "string" },
    offset = { type = "integer", minimum = 1 },
    limit = { type = "integer", minimum = 1, maximum = 2000 } }, { "path" }),
  schema("write", "Create or overwrite a text file with the given content.", {
    path = { type = "string" }, content = { type = "string" } }, { "path", "content" }),
  schema("edit", "Replace the first exact occurrence of old_text with new_text in a file.", {
    path = { type = "string" },
    old_text = { type = "string" },
    new_text = { type = "string" } }, { "path", "old_text", "new_text" }),
  schema("ls", "List a directory (portable: works the same on every platform).", { path = { type = "string" } }),
  schema("grep", "Search files for a pattern and return matching lines. Uses a portable matcher, so it works the same on every platform.", {
    pattern = { type = "string" }, path = { type = "string" } }, { "pattern" }),
  schema("client", "Control the wasm-agent client machine: screenshot, mouse, keyboard and a Chrome DevTools (CDP) session. CDP uses a dedicated Chrome profile and launches Chrome if needed.", {
    action = { type = "string", enum = { "screenshot", "frame", "click", "move", "type", "key", "shell", "cdp" } },
    x = { type = "integer" }, y = { type = "integer" },
    text = { type = "string" }, key = { type = "string" },
    target = { type = "string", description = "CDP: list | open | close | activate | navigate | evaluate | launch" },
    script = { type = "string", description = "CDP evaluate: JavaScript expression" },
    id = { type = "string", description = "CDP target id for close/activate" },
    url = { type = "string" },
    port = { type = "integer", description = "CDP port (default 9222)" },
    profile = { type = "string", description = "Chrome user-data-dir (defaults to the wasm-agent account)" } },
    { "action" }),
  schema("shell", "Run a shell command on the wasm-agent client machine (this is the machine running the desktop UI, which must be open). Prefer `bash` for commands on the node itself.", {
    command = { type = "string" },
    shell = { type = "string", enum = { "cmd", "powershell" }, description = "Default cmd." },
    cwd = { type = "string" } }, { "command" }),
  schema("spell_save", "Crystallize a working sequence of client actions into a named, parameterised, VERIFIED spell. Requires at least one post assertion: a spell must settle its effect, so it can never report success while doing nothing.", {
    name = { type = "string" },
    description = { type = "string" },
    target = { type = "object", description = "{node, app, profile} the spell was recorded against." },
    params = { type = "object", description = "parameter -> {type: string|number|boolean, default}. Reference them as {{name}}." },
    pre = { type = "array", items = { type = "object" }, description = "Assertions checked before the first step." },
    steps = { type = "array", items = { type = "object" }, description = "Steps: {kind=client|wait|assert}. Retries allowed only with idempotent=true." },
    post = { type = "array", items = { type = "object" }, description = "REQUIRED. Assertions checked after the steps (effect settlement)." } }, { "name", "steps", "post" }),
  schema("spell_run", "Replay a saved spell; fails loudly at the first failing step or assertion.", {
    name = { type = "string" },
    params = { type = "object", description = "Values for the spell's declared parameters." } }, { "name" }),
  schema("spell_list", "List saved spells with version and parameter names.", {}),
  schema("spell_get", "Read one saved spell in full.", { name = { type = "string" } }, { "name" }),
  schema("spell_forget", "Delete a saved spell.", { name = { type = "string" } }, { "name" }),
  schema("remote", "Run a capability on another wasm-agent node (peer). Nodes are discovered by ed25519 key through the rendezvous, so the name or node_id is enough.", {
    node = { type = "string", description = "Peer name or node_id (use the nodes panel for the list)." },
    capability = { type = "string", description = "Tool to run on that node, e.g. bash, read, client, shell." },
    args = { type = "object", description = "Arguments for that tool." } }, { "node", "capability" }),
  schema("nodes", "List this node and every peer known to the rendezvous.", {}),
  schema("session_debug", "Set a session's recording mode. debug keeps every turn verbatim and forever, so a failing task can be reproduced and exported as a fixture.", {
    session_id = { type = "string", description = "Defaults to the current session." },
    mode = { type = "string", enum = { "default", "debug" } } }, { "mode" }),
  schema("session_fixture", "Export a session (turns, tool calls, traces) as a reproducible fixture for regression tests.", {
    session_id = { type = "string", description = "Defaults to the current session." } }),
}

-- Which capability tier each tool belongs to (DESIGN.md §8). Anything not
-- listed here is a WASM plugin.
M.tier_of = {
  remember = "memory", recall = "memory",
  capabilities = "capabilities",
  sessions = "sessions", session = "sessions", search_turns = "sessions",
  resume_session = "sessions", session_debug = "sessions", session_fixture = "sessions",
  bash = "environment", read = "environment", write = "environment",
  edit = "environment", ls = "environment", grep = "environment",
  shell = "shell",
  search_messages = "ledger", conversation = "ledger", list_conversations = "ledger",
  client = "client",
  spell_save = "spells", spell_run = "spells", spell_list = "spells",
  spell_get = "spells", spell_forget = "spells",
  nodes = "nodes", remote = "nodes",
}

local TIER_ORDER = {
  "memory", "sessions", "capabilities", "environment", "shell", "ledger",
  "client", "spells", "nodes", "plugins",
}

-- The envelope the model sees, grouped by tier.
function M.tiers(role)
  local groups = {}
  for _, item in ipairs(M.all(role)) do
    local name = item["function"].name
    local tier = M.tier_of[name] or "plugins"
    groups[tier] = groups[tier] or {}
    table.insert(groups[tier], {
      name = name,
      description = item["function"].description or "",
      parameters = item["function"].parameters or {},
    })
  end
  local out = {}
  for _, tier in ipairs(TIER_ORDER) do
    if groups[tier] then out[#out + 1] = { tier = tier, tools = groups[tier] } end
  end
  return out
end

local function wasm_plugins()
  local ok, raw = pcall(host.plugins)
  if not ok or not raw then return {} end
  return json.decode(raw) or {}
end

local function admin_names()
  local names = {}
  for _, item in ipairs(M.admin) do names[item["function"].name] = true end
  return names
end

-- Tool schemas for a role.
function M.all(role)
  role = role or "admin"
  local list = {}
  for _, item in ipairs(M.shared) do list[#list + 1] = item end
  if is_master(role) then
    for _, item in ipairs(M.admin) do list[#list + 1] = item end
    for _, plugin in ipairs(wasm_plugins()) do
      list[#list + 1] = schema(plugin.name, plugin.description or "", plugin.parameters and plugin.parameters.properties, plugin.parameters and plugin.parameters.required)
    end
  end
  return list
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function run(command)
  local ok, raw = pcall(host.exec, command, "")
  if not ok then return { error = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return { error = tostring(raw) } end
  return decoded
end

local function read_lines(path, offset, limit)
  local text = host.read_file and host.read_file(path)
  if not text then return nil end
  if not offset and not limit then return text end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local from = offset or 1
  local to = limit and (from + limit - 1) or #lines
  local slice = {}
  for index = from, math.min(to, #lines) do slice[#slice + 1] = string.format("%6d\t%s", index, lines[index]) end
  return table.concat(slice, "\n")
end

function M.dispatch(memory, name, args, role, ctx)
  args = args or {}
  role = role or "master"
  ctx = ctx or {}
  local user_id = ctx.user_id or "master"
  if not is_master(role) and admin_names()[name] then return { error = "forbidden_for_role:" .. role } end

  if name == "remember" then
    if not args.content or args.content == "" then return { error = "content_required" } end
    return { ok = true, id = memory.remember(args.content, args.scope or "global", args.tags or {}) }
  elseif name == "recall" then
    return memory.recall(args.query or "", args.limit or 10, args.scope)
  elseif name == "capabilities" then
    local list = { "remember", "recall", "capabilities" }
    if is_master(role) then
      for _, extra in ipairs({ "bash", "read", "write", "edit", "ls", "grep", "shell", "client", "spell_save", "spell_run", "spell_get", "nodes", "remote" }) do
        list[#list + 1] = extra
      end
    end
    return { role = role, capabilities = list, note = "ask a master to unlock more" }
  elseif name == "search_messages" then
    return memory.search_messages(args.query or "", args.conversation_id, args.limit or 20)
  elseif name == "conversation" then
    return memory.conversation(args.conversation_id or "", args.limit or 50)
  elseif name == "list_conversations" then
    return memory.conversations(args.limit or 50)
  elseif name == "bash" then
    if not args.command or args.command == "" then return { error = "command_required" } end
    local result = run(args.cwd and ("cd " .. shell_quote(args.cwd) .. " && " .. args.command) or args.command)
    if result.stdout and #result.stdout > 8000 then result.stdout = result.stdout:sub(1, 8000) .. "\n…(truncated)" end
    if result.stderr and #result.stderr > 4000 then result.stderr = result.stderr:sub(1, 4000) .. "\n…(truncated)" end
    return result
  elseif name == "read" then
    local content = read_lines(args.path, args.offset, args.limit)
    if not content then return { error = "not_found" } end
    if #content > 20000 then content = content:sub(1, 20000) .. "\n…(truncated)" end
    return { path = args.path, content = content }
  elseif name == "write" then
    if not args.path then return { error = "path_required" } end
    local ok = host.write_file and host.write_file(args.path, args.content or "")
    return { ok = ok and true or false, path = args.path }
  elseif name == "edit" then
    local text = host.read_file and host.read_file(args.path)
    if not text then return { error = "not_found" } end
    local from, to = text:find(args.old_text or "", 1, true)
    if not from then return { error = "old_text_not_found" } end
    local updated = text:sub(1, from - 1) .. (args.new_text or "") .. text:sub(to + 1)
    host.write_file(args.path, updated)
    return { ok = true, path = args.path }
  elseif name == "ls" then
    -- Native listing: `ls -la` does not exist on Windows, and the description
    -- promises portability.
    if host.list_dir then
      local ok, result = pcall(host.list_dir, args.path or ".")
      if ok and result then return json.decode(result) end
    end
    if platform.os() == "windows" then
      return run("dir /b " .. shell_quote(args.path or "."))
    end
    return run("ls -la -- " .. shell_quote(args.path or "."))
  elseif name == "grep" then
    -- Native matcher: shelling out to `grep` fails on Windows, where the tool
    -- shell is cmd /C.
    local native = host.grep
    if native then
      local ok, result = pcall(native, args.pattern or "", args.path or ".",
        json.encode({ ignore_case = true, limit = args.limit or 100 }))
      if ok and result then return json.decode(result) end
    end
    if platform.os() == "windows" then
      return run("findstr /s /n /i /c:" .. shell_quote(args.pattern or "") .. " " ..
        shell_quote((args.path or ".") .. "\\*"))
    end
    return run("grep -rn -- " .. shell_quote(args.pattern or "") .. " " .. shell_quote(args.path or "."))
  elseif name == "client" then
    local ok, raw = pcall(host.client, args.action or "", json.encode(args))
    if not ok then return { error = tostring(raw) } end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return { result = raw } end
    return decoded
  elseif name == "shell" then
    if not args.command or args.command == "" then return { error = "command_required" } end
    local ok, raw = pcall(host.client, "shell", json.encode(args))
    if not ok then return { error = tostring(raw) } end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return { result = raw } end
    return decoded
  elseif name == "spell_save" then
    return spellslib.save(args)
  elseif name == "spell_run" then
    return spellslib.run(args.name, args.params)
  elseif name == "spell_list" then
    return spellslib.list()
  elseif name == "spell_get" then
    return spellslib.get(args.name) or { error = "unknown_spell" }
  elseif name == "spell_forget" then
    return spellslib.remove(args.name)
  elseif name == "sessions" then
    return { sessions = memory.list_sessions(user_id, args.limit or 30) }
  elseif name == "session" then
    local session = memory.session(args.session_id)
    if not session then return { error = "unknown_session" } end
    if session.user_id ~= user_id and not is_master(role) then return { error = "forbidden" } end
    return { session = session, turns = memory.session_turns(args.session_id, { limit = args.limit or 200 }) }
  elseif name == "search_turns" then
    return { matches = memory.search_turns(args.query or "", is_master(role) and nil or user_id, args.limit or 20) }
  elseif name == "resume_session" then
    local target = memory.session(args.session_id)
    if not target then return { error = "unknown_session" } end
    if target.user_id ~= user_id and not is_master(role) then return { error = "forbidden" } end
    local turns = memory.session_turns(args.session_id, { limit = args.limit or 30 })
    local lines = { "Resumed session " .. args.session_id .. " (" .. (target.title or "") .. "):" }
    if target.summary and target.summary ~= "" then lines[#lines + 1] = target.summary end
    for _, turn in ipairs(turns) do
      if turn.role == "user" or turn.role == "assistant" then
        lines[#lines + 1] = turn.role .. ": " .. (turn.content or ""):sub(1, 400)
      end
    end
    if ctx.session_id then
      local current = memory.session(ctx.session_id) or {}
      local merged = current.summary or ""
      if merged ~= "" then merged = merged .. "\n" end
      memory.set_session_summary(ctx.session_id, current.summarized_until or 0, merged .. table.concat(lines, "\n"))
    end
    return { resumed = args.session_id, turns = #turns }
  elseif name == "session_debug" then
    local id = args.session_id or ctx.session_id
    if not id then return { error = "session_id_required" } end
    return { session_id = id, mode = memory.set_session_mode(id, args.mode) }
  elseif name == "session_fixture" then
    local fixture = memory.session_fixture(args.session_id or ctx.session_id)
    if not fixture then return { error = "unknown_session" } end
    return fixture
  elseif name == "nodes" then
    local list = {}
    for _, node in ipairs(nodeslib.list()) do
      list[#list + 1] = {
        name = node.name, role = node.role, online = node.online,
        local_node = node.local_node, capabilities = node.capabilities,
        endpoints = node.endpoints, node_id = node.node_id,
      }
    end
    return { nodes = list }
  elseif name == "remote" then
    if args.capability == "remote" then return { error = "remote_cannot_recurse" } end
    local node = nodeslib.find(args.node)
    if not node then return { error = "unknown_node:" .. tostring(args.node) } end
    if node.local_node then
      return M.dispatch(memory, args.capability, args.args or {}, role)
    end
    return nodeslib.remote_call(args.node, args.capability, args.args or {})
  end

  -- Fall back to a WASM plugin (admin only; guests never see their schemas).
  if not is_master(role) then return { error = "unknown_tool:" .. tostring(name) } end
  local ok, result = pcall(host.invoke, name, json.encode(args))
  if not ok then return { error = tostring(result) } end
  local decoded = json.decode(result)
  if type(decoded) ~= "table" then return { result = result } end
  return decoded
end

return M
