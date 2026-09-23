-- Tools exposed to the head model. Access is gated by the caller's role:
-- masters get everything; guests get on-demand memory plus a way to list
-- what they may do. "spells" means deterministic, verified executions only (spells.lua).
local json = dofile("lua/vendor/json.lua")
local platform = dofile("lua/core/platform.lua")
local spellslib = dofile("lua/core/spells.lua")
local nodeslib = dofile("lua/core/nodes.lua")
local changeset = dofile("lua/core/changeset.lua")
local tool_output = dofile("lua/core/tool_output.lua")
local file_tools = dofile("lua/core/file_tools.lua")
local evidence_view = dofile("lua/core/evidence_view.lua")
local diagnose = dofile("lua/core/diagnose.lua")
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

-- The foreground shell deadline, read from the host that enforces it
-- (`host.exec_timeout`). Naming the number in the description is what lets a model
-- plan a long command as an operation: the audit found `bash` calls that spent the
-- whole 300s inside one command and lost it to a deadline they did not know about.
local function exec_deadline_seconds()
  if host and host.exec_timeout then
    local ok, seconds = pcall(host.exec_timeout)
    if ok and tonumber(seconds) then return math.floor(tonumber(seconds)) end
  end
  return 300
end

-- Available to everyone.
M.shared = {
  schema("remember", "Store a fact the user asked you to remember, so it can be recalled later. Confirm in one short sentence; do not store your own reasoning. If a stored fact turns out to be wrong, call `forget` on it and then store the corrected version once - never append a correction entry, or the store accumulates contradictions that you will later have to guess between.", {
    content = { type = "string", description = "The fact to remember, in full." },
    scope = { type = "string", description = "Optional scope, e.g. global or a conversation id." },
    tags = { type = "array", items = { type = "string" } } }, { "content" }),
  schema("recall", "Look up facts the user previously asked you to remember. Call this before answering any question about the user, their preferences, names, codewords, settings, accounts, or earlier steps - and before saying you do not know. The store is small and lookup is cheap; guessing is not.", {
    query = { type = "string", description = "What to look for, in the user's own words." },
    scope = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("memories", "List what is stored, most recent first, with each entry's id. Use it when the user asks what you remember or wants the store tidied: reading the ids is how you find what `forget` should remove.", {
    scope = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 200 } }),
  schema("skill", "Load a skill: the full instructions for a specialized task listed in your context. Read the one that matches before starting that kind of work.", {
    name = { type = "string", description = "The skill's name, as listed in <available_skills>." } }, { "name" }),
  schema("capabilities", "List the tools available to this account (its capabilities).", {}),
  schema("subagent", "Start and supervise a local child agent (a subagent) that works on a bounded task with its own fresh context, its own transcript and a restricted tool profile. `start` returns a durable receipt, not a result: the child runs in the background. Use `await` (one bounded wait, never repeated model polling) or `status`/`result` to collect it, and `cancel` to stop it. You may only inspect or cancel the subagents you started. A profile's tools can only narrow your own; they can never grant more than you have. Use `list` to see your subagents and `profiles` to see what is approved.", {
    action = { type = "string", enum = { "start", "status", "list", "result", "await", "cancel", "profiles" } },
    profile = { type = "string", description = "Approved profile id, e.g. explore. Defaults to explore (read-only)." },
    prompt = { type = "string", description = "The bounded task for the child. Required for start." },
    context = { type = "string", description = "Optional extra context; the parent transcript is never sent." },
    id = { type = "string", description = "Subagent id, for status/result/await/cancel." },
    wait_ms = { type = "integer", minimum = 1, maximum = 600000, description = "await: bounded wait in milliseconds." },
    model = { type = "string", description = "Approved model override; inherits the caller's model when absent." },
    reasoning = { type = "string", description = "Approved reasoning level override; inherits the caller's when absent." },
    parent_run_id = { type = "string", description = "Run that owns this child; defaults to the current run." },
    delivery_id = { type = "string", description = "Job delivery this child belongs to, when a job starts it." },
    idempotency_key = { type = "string", description = "Repeat start with the same key collects the existing child instead of starting a second one." },
  }, { "action" }),
  schema("sessions", "List your own past sessions (resumable threads), most recent first.", {
    limit = { type = "integer", minimum = 1, maximum = 100 } }),
  schema("session", "Read a session. Defaults to newest messages; pass next_before_seq back as before_seq to retrieve earlier evidence.", {
    session_id = { type = "string" },
    before_seq = { type = "integer", minimum = 1 },
    message_id = { type = "string", description = "Exact row, with ownership checked against this session." },
    byte_offset = { type = "integer", minimum = 1, description = "With message_id, page exact row JSON without requiring operator artifact access." },
    byte_limit = { type = "integer", minimum = 4, maximum = 20000 }, message_version = {type="string"},
    view = { type = "string", enum = {"full", "compact"}, description = "Full is default; compact omits diagnostic details, not content, with exact-row references." },
    limit = { type = "integer", minimum = 1, maximum = 1000 } }, { "session_id" }),
  schema("search_messages", "Search your own past sessions for text (what did we decide about X?).", {
    query = { type = "string" },
    view = { type = "string", enum = {"full", "compact"} },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("resume_session", "Fold a past session into this one: its summary and recent messages become context.", {
    session_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 100 } }, { "session_id" }),
}

-- Admin only: the ledger and the pi-style environment tools.
M.admin = {
  schema("search_ledger", "Search the message ledger (WhatsApp/chat history) for literal text.", {
    query = { type = "string" },
    conversation_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("conversation", "Read the most recent messages of one conversation, oldest first.", {
    conversation_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 200 } }, { "conversation_id" }),
  schema("list_conversations", "List conversations known to the ledger, most recently active first.", {
    limit = { type = "integer", minimum = 1, maximum = 200 } }),
  -- Master only: deleting is destructive, and memory is shared across roles, so a
  -- guest must not be able to erase the operator's stored facts. Without this
  -- tool the agent could only ever accumulate - it said so itself, and left a
  -- wrong date in the store because it had nothing to delete it with.
  schema("forget", "Delete a stored memory by id (from `recall` or `memories`). Use it for something wrong, outdated or stored by mistake: an append-only store fills with junk and then misleads you later.", {
    id = { type = "string" } }, { "id" }),
  -- The dialect is in the description because the model otherwise assumes POSIX
  -- and wastes its tool budget on commands this machine does not have.
  schema("bash", "Run a foreground command on this machine using " .. platform.shell() .. ". It is killed at " .. exec_deadline_seconds() .. "s unless timeout_seconds says otherwise (1-86400); pass a larger timeout_seconds for anything that may outlast that - a build, the full test gate. If the command leaves a process running (a trailing `&`, or `nohup`), that process is adopted as a supervised operation and the call returns its operation id instead of a result: read it with operation read, stop it with operation cancel. Its entire process tree is owned either way, so nothing can outlive this node. Output and process exit are separate evidence.", {
    command = { type = "string" }, cwd = { type = "string" },
    timeout_seconds = { type = "integer", minimum = 1, maximum = 86400, description = "Kill the command after this many seconds. Defaults to the node's foreground deadline (" .. exec_deadline_seconds() .. "s); raise it for a build or a full test gate, lower it to fail fast." } }, { "command" }),
  schema("operation", "Start, observe, read streamed output, wait briefly for, or cancel a supervised external operation. A launch receipt is not completion. Output read uses byte cursors; when text_lossy is true, decode content_base64 for exact bytes instead of concatenating content. Use await once to wait for settlement without repeated model polling (up to the operation deadline); wait is a short peek. Jobs are automation rules, not operations. No automatic replay after an unknown outcome.", {
    action = { type = "string", enum = {"start", "list", "status", "read", "wait", "await", "cancel"} },
    id = { type = "string" }, command = { type = "string" }, cwd = { type = "string" },
    timeout_seconds = { type = "integer", minimum = 1, maximum = 86400 },
    stream = { type = "string", enum = {"stdout", "stderr"} }, offset = { type = "integer", minimum = 0 },
    limit = { type = "integer", minimum = 1, maximum = 24576 }, wait_ms = { type = "integer", minimum = 0, maximum = 10000 }
  }, {"action"}),
  schema("read", "Read exact text with versioned line/byte-column continuation. Follow next_offset/next_column with version until eof; a long line may span pages.", {
    path = { type = "string" },
    offset = { type = "integer", minimum = 1 },
    column = { type = "integer", minimum = 1 }, version = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 2000 } }, { "path" }),
  schema("read_many", "Read several independent files or line ranges in one step. Results match individual read calls in request order; each item reports its own error.", {
    requests = { type = "array", minItems = 1, maxItems = 8, items = { type = "object",
      properties = { path = { type = "string" }, offset = { type = "integer", minimum = 1 },
        column = { type = "integer", minimum = 1 }, version = { type = "string" },
        limit = { type = "integer", minimum = 1, maximum = 2000 } }, required = { "path" } } }
  }, { "requests" }),
  schema("write", "Create or overwrite a text file with the given content.", {
    path = { type = "string" }, content = { type = "string" } }, { "path", "content" }),
  schema("edit", "Apply exact replacements against one original file. Use old_text/new_text OR edits; every match must be unique and non-overlapping. Optional version rejects a stale read. No multi-file transaction.", {
    path = { type = "string" }, version = { type = "string" },
    old_text = { type = "string" }, new_text = { type = "string" },
    edits = { type = "array", minItems = 1, maxItems = 64, items = { type = "object",
      properties = { old_text = {type="string"}, new_text = {type="string"} }, required = {"old_text","new_text"} } }
  }, { "path" }),
  schema("ls", "List a directory (portable: works the same on every platform).", { path = { type = "string" } }),
  schema("grep", "Literal substring search, not regex. Reports omitted files and clipped lines. Results use the supplied root; extensions are exact suffixes without dots.", {
    pattern = { type = "string" }, path = { type = "string" },
    ignore_case = {type="boolean"}, limit={type="integer",minimum=1,maximum=500},
    max_depth={type="integer",minimum=0,maximum=64}, extensions={type="array",items={type="string"}}
  }, { "pattern" }),
  -- The code graph. This is the cheap first move for a navigation question: it returns
  -- definitions, callers and capabilities directly, where grep returns candidate lines
  -- that still need reading. The node keeps the graph fresh, so `index` is rarely needed.
  schema("graph", "Find symbols and exact call sites with explain; trace known functions with path; use query to discover names or literal HTTP routes (e.g. /subagents). Use graph before grep for code navigation. For 'how A reaches B', call path(A,B) first, then read the returned lines; path crosses Rust call_string to Lua entrypoints. explain returns a definition, uses and exact caller lines. query ranks name matches first and returns 12 compact results by default; increase limit if truncated. caps lists host.* capabilities. stats/index inspect or rebuild the watched index.", {
    action = { type = "string", enum = { "explain", "query", "path", "caps", "stats", "index" } },
    name = { type = "string", description = "explain/query: the identifier to look up." },
    from = { type = "string", description = "path: start identifier." },
    to = { type = "string", description = "path: end identifier." },
    limit = { type = "integer", minimum = 1, maximum = 200 },
    force = { type = "boolean", description = "index: reparse every file, even unchanged ones." },
  }, { "action" }),
  schema("diagnose", "Execute up to eight predetermined read/grep steps once, in order. Stop on failure, incomplete evidence or an unmet expectation. No shell, repair, retry or effects.", {
    steps={type="array",minItems=1,maxItems=8,items={type="object",properties={
      tool={type="string",enum={"read","grep"}},args={type="object"},
      expect={type="object",properties={contains={type="string",description="Literal text assertion for read steps only."},min_matches={type="integer",minimum=0,description="Minimum match count for grep steps only."},max_matches={type="integer",minimum=0,description="Maximum match count for grep steps only."}}}
    },required={"tool","args"}}}
  }, {"steps"}),
  -- Scoped deliberately. It used to read as "here is how you look at a web page",
  -- and an agent verifying its own UI spent 28 calls driving Chrome through CDP:
  -- fighting the debug endpoint, falling back to PowerShell one-liners mangled by
  -- the shell, and briefly overwriting the installed app.js to instrument it.
  -- None of that was needed - the UI is a page this node serves.
  schema("client", "Act on the user's machine at their request: screenshot, mouse, keyboard, a shell on their machine, and a browser (Chrome DevTools). When a call has failed, ask `status` first - it says whether the window is polling, what its browser is doing and on which port. Use `browser` to browse (target: open/read/list/eval/close/activate/quit) and `cdp` only as the low-level escape hatch. This is not how to inspect the wasm-agent UI - that is a page this node serves, so fetch it or load it in a headless browser.", {
    action = { type = "string", enum = { "screenshot", "frame", "click", "move", "type", "key", "shell", "status", "browser", "cdp" } },
    x = { type = "integer" }, y = { type = "integer" },
    text = { type = "string" }, key = { type = "string" },
    button = { type = "string", enum = { "left", "right" }, description = "click: default left" },
    target = { type = "string", description = "browser: list | open | read | eval | close | activate | quit. cdp: launch | list | open | close | activate | navigate | evaluate" },
    script = { type = "string", description = "JavaScript expression to evaluate" },
    id = { type = "string", description = "CDP target id, for close/activate/read/eval" },
    url = { type = "string", description = "browser open/navigate" },
    reuse = { type = "boolean", description = "browser open: reuse a tab already on that URL (default true, so repeats are safe)" },
    max_chars = { type = "integer", description = "browser read: page text to return (default 2000)" },
    timeout_ms = { type = "integer", description = "How long the node waits for the client, default 75000. The client bounds its own work by the same number, so a timeout means the work stopped - collect it with action:'result'" },
    port = { type = "integer", description = "CDP port of a browser you already know about. Normally omit: the port is discovered and reported back" },
    profile = { type = "string", description = "Chrome user-data-dir (defaults to the wasm-agent account)" } },
    { "action" }),
  schema("shell", "Run a shell command on the wasm-agent client machine (this is the machine running the desktop UI, which must be open). Prefer `bash` for commands on the node itself.", {
    command = { type = "string" },
    shell = { type = "string", enum = { "cmd", "powershell" }, description = "Default cmd." },
    cwd = { type = "string" } }, { "command" }),
  schema("spell_save", "Crystallize a deterministic, verified execution into a named, parameterised spell: a shell command or script, a client action, a wait, an assertion, or a supervisor verb. No model in the loop. Requires at least one post assertion: a spell must settle its effect, so it can never report success while doing nothing.", {
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
  schema("spell_export", "Write a spell out as a portable JSON plan for the sentinel to run outside this node. Use it for a spell containing a `sentinel` step (one that restarts or upgrades this node): such a plan cannot run here, because the run doing the work dies with the node it changes and its postconditions could never be observed. Returns the file path; run it with: wa-sentinel request spell --file <path> --reason \"...\".", {
    name = { type = "string" },
    params = { type = "object", description = "Values for the spell's declared parameters." },
    binary = { type = "string", description = "For an `upgrade` step: the wa binary to install. Defaults to the step's own value." },
    path = { type = "string", description = "Where to write the plan. Defaults to <state>/spell-plans/<name>.json." } }, { "name" }),
  schema("remote", "Run a capability on another wasm-agent node (peer). Nodes are discovered by ed25519 key through the rendezvous, so the name or node_id is enough.", {
    node = { type = "string", description = "Peer name or node_id (use the nodes panel for the list)." },
    capability = { type = "string", description = "Tool to run on that node, e.g. bash, read, client, shell." },
    args = { type = "object", description = "Arguments for that tool." } }, { "node", "capability" }),
  schema("nodes", "List this node and every peer known to the rendezvous.", {}),
  schema("session_debug", "Set a session's recording mode. debug keeps every turn verbatim and forever, so a failing task can be reproduced and exported as a fixture.", {
    session_id = { type = "string", description = "Defaults to the current session." },
    mode = { type = "string", enum = { "default", "debug" } } }, { "mode" }),
  schema("session_fixture", "Export a session (messages, tool calls, traces) as a reproducible fixture for regression tests.", {
    session_id = { type = "string", description = "Defaults to the current session." } }),
}

-- Which capability tier each tool belongs to (DESIGN.md §8). Anything not
-- listed here is a WASM plugin.
M.tier_of = {
  remember = "memory", recall = "memory", memories = "memory", forget = "memory",
  skill = "skills",
  capabilities = "capabilities",
  subagent = "subagents",
  sessions = "sessions", session = "sessions", search_messages = "sessions",
  resume_session = "sessions", session_debug = "sessions", session_fixture = "sessions",
  bash = "environment", read = "environment", read_many = "environment", write = "environment",
  diagnose = "environment", operation = "environment",
  edit = "environment", ls = "environment", grep = "environment", graph = "environment",
  shell = "shell",
  search_ledger = "ledger", conversation = "ledger", list_conversations = "ledger",
  client = "client",
  spell_save = "spells", spell_run = "spells", spell_list = "spells",
  spell_get = "spells", spell_forget = "spells", spell_export = "spells",
  whatsapp_read = "whatsapp", whatsapp_conversation = "whatsapp", whatsapp_decide = "whatsapp", whatsapp_send = "whatsapp",
  nodes = "nodes", remote = "nodes",
}

local TIER_ORDER = {
  "memory", "sessions", "capabilities", "subagents", "environment", "shell", "ledger",
  "client", "spells", "nodes", "whatsapp", "plugins",
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

-- The scoped WhatsApp responder tools. Their schemas live in
-- lua/core/whatsapp.lua; they are offered only to a master turn, and dispatch
-- re-checks the profile ceiling before calling the module. A missing module (an
-- older deployment) yields no schemas rather than a broken tool list.
local WHATSAPP_TOOLS = { whatsapp_read = true, whatsapp_conversation = true, whatsapp_decide = true, whatsapp_send = true }

local function whatsapp_schemas()
  local ok, module = pcall(dofile, "lua/core/whatsapp.lua")
  if not ok or type(module) ~= "table" or type(module.schemas) ~= "function" then return {} end
  local listed, list = pcall(module.schemas)
  if not listed or type(list) ~= "table" then return {} end
  return list
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
    list[#list+1]=schema("tool_result","Retrieve an exact byte range of a full tool result saved after output truncation. Use the full_result.sha256 from the result, then follow next_offset until eof.",{
      sha256={type="string"},offset={type="integer",minimum=1},limit={type="integer",minimum=1,maximum=51200}
    },{"sha256"})
    for _, item in ipairs(M.admin) do list[#list + 1] = item end
    for _, item in ipairs(whatsapp_schemas()) do list[#list + 1] = item end
    local plugins=wasm_plugins()
    table.sort(plugins,function(a,b)return tostring(a.name)<tostring(b.name) end)
    for _, plugin in ipairs(plugins) do
      list[#list + 1] = schema(plugin.name, plugin.description or "", plugin.parameters and plugin.parameters.properties, plugin.parameters and plugin.parameters.required)
    end
  end
  return list
end

-- Tool schemas restricted to an exact allowed set (a subagent profile). The
-- schema list is one half of the boundary; `dispatch` re-checks the same set.
function M.all_for(allowed, role)
  local out = {}
  for _, item in ipairs(M.all(role or "master")) do
    local name = item["function"].name
    if allowed and allowed[name] then out[#out + 1] = item end
  end
  table.sort(out, function(a, b) return tostring(a["function"].name) < tostring(b["function"].name) end)
  return out
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function run(command, timeout_seconds)
  local ok, raw = pcall(host.exec, command, "", timeout_seconds)
  if not ok then return { error = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return { error = tostring(raw) } end
  return decoded
end

function M.dispatch(memory, name, args, role, ctx)
  args = args or {}
  role = role or "master"
  ctx = ctx or {}
  local user_id = ctx.user_id or "master"
  -- A subagent runs only the exact tools its profile named. Checked here as well
  -- as in the schema list it was offered: a model can ask for a tool it was not
  -- offered, and a schema filter that is not re-checked is not a boundary.
  if ctx.subagent then
    local allowed = ctx.subagent.allowed or {}
    if not allowed[name] then return { error = "capability_not_in_profile:" .. tostring(name) } end
    if name == "subagent" then return { error = "subagent_recursion_forbidden" } end
  end
  if not is_master(role) and admin_names()[name] then return { error = "forbidden_for_role:" .. role } end
  if name == "operation" then
    if not is_master(role) then return {error="forbidden_for_role:" .. role} end
    args.owner = ctx.session_id or user_id
    local ok, raw = pcall(host.operation, args.action or "status", json.encode(args))
    if not ok then return {error=tostring(raw)} end
    return json.decode(raw)
  end
  if name=="tool_result" then
    if not is_master(role) then return {error="forbidden_for_role:"..role} end
    return tool_output.read(args.sha256,args.offset,args.limit)
  end

  if name == "remember" then
    if not args.content or args.content == "" then return { error = "content_required" } end
    return { ok = true, id = memory.remember(args.content, args.scope or "global", args.tags or {}) }
  elseif name == "recall" then
    return memory.recall(args.query or "", args.limit or 10, args.scope)
  elseif name == "skill" then
    local skills = dofile("lua/core/skills.lua")
    local wanted = args.name or ""
    if wanted == "" then
      local names = {}
      for _, entry in ipairs(skills.list()) do names[#names + 1] = entry.name end
      return { error = "name_required", available = names }
    end
    local found = skills.find(wanted)
    if not found then
      local names = {}
      for _, entry in ipairs(skills.list()) do names[#names + 1] = entry.name end
      return { error = "unknown_skill", requested = wanted, available = names }
    end
    return { name = found.name, path = found.path, dir = found.dir, content = skills.content(found) }
  elseif name == "memories" then
    return memory.memories(args.scope, args.limit or 50)
  elseif name == "forget" then
    if not args.id or args.id == "" then return { error = "id_required" } end
    return { id = args.id, forgotten = memory.forget(args.id) and true or false }
  elseif name == "capabilities" then
    local list = {}
    for _,item in ipairs(M.all(role)) do list[#list+1]=item['function'].name end
    return { role = role, capabilities = list, note = "ask a master to unlock more" }
  elseif name == "subagent" then
    -- One Lua facade for the model and for the HTTP control route; the owner is
    -- derived from `ctx` (server side), never from the arguments the model sent.
    return dofile("lua/core/subagents.lua").control(args, ctx)
  elseif WHATSAPP_TOOLS[name] then
    -- The scoped responder tools. They are only reachable from a subagent whose
    -- approved profile names them, and the trusted profile/event/effects snapshot
    -- arrives on ctx, never from the arguments.
    if not ctx.subagent then return { error = "whatsapp_requires_subagent" } end
    local module = dofile("lua/core/whatsapp.lua")
    if type(module) ~= "table" or type(module.dispatch) ~= "function" then
      return { error = "whatsapp_module_unavailable" }
    end
    return module.dispatch(memory, name, args, {
      profile = ctx.subagent.profile,
      event = ctx.subagent.event,
      effects = ctx.subagent.effects,
      sends = ctx.subagent.sends,
    })
  elseif name == "search_ledger" then
    return memory.search_ledger(args.query or "", args.conversation_id, args.limit or 20)
  elseif name == "conversation" then
    return memory.conversation(args.conversation_id or "", args.limit or 50)
  elseif name == "list_conversations" then
    return memory.conversations(args.limit or 50)
  elseif name == "bash" then
    if not args.command or args.command == "" then return { error = "command_required" } end
    local timeout = args.timeout_seconds
    if timeout ~= nil and (type(timeout) ~= "number" or timeout % 1 ~= 0 or timeout < 1 or timeout > 86400) then
      return { error = "invalid_timeout_seconds" }
    end
    local result = run(args.cwd and ("cd " .. shell_quote(args.cwd) .. " && " .. args.command) or args.command, timeout)
    -- The adopted-tree guidance is *policy*, and policy depends on what this caller may use:
    -- a profile with `bash` but not `operation` cannot read or cancel the operation it has just
    -- been handed, so telling it to would be the same dead end the old refusal was. The host
    -- returns the facts; this decides what to say about them.
    if type(result) == "table" and result.promoted == true then
      local allowed = ctx.subagent and ctx.subagent.allowed or nil
      local id = tostring(result.operation_id or "")
      if allowed == nil or allowed["operation"] == true then
        result.note = "the shell exited leaving live processes; they are adopted as operation " .. id ..
          " and keep running. Read it with operation read; stop it with operation cancel."
      else
        result.note = "the shell exited leaving live processes; they are adopted as operation " .. id ..
          " and keep running. This profile does not allow the `operation` tool, so you cannot read or " ..
          "cancel it from here: it ends at its own deadline, or when the node exits. Start long-lived " ..
          "work from a profile that allows `operation` when you need to watch or stop it."
      end
    end
    return result
  elseif name == "read" then
    return file_tools.read(args)
  elseif name == "diagnose" then
    return diagnose.run(args.steps,function(tool,options)
      return M.dispatch(memory,tool,options,role,ctx)
    end)
  elseif name == "read_many" then
    if type(args.requests) ~= "table" or #args.requests < 1 or #args.requests > 8 then
      return { error = "requests_required_1_to_8" }
    end
    local results, failed = {}, 0
    for index, request in ipairs(args.requests) do
      if type(request) ~= "table" or type(request.path) ~= "string" or request.path == "" then
        results[index] = { error = "path_required" }
      else
        results[index] = file_tools.read(request)
      end
      if results[index].error then failed = failed + 1 end
    end
    return { ok = failed == 0, results = results, failed = failed }
  elseif name == "write" then
    if not args.path then return { error = "path_required" } end
    if type(args.content)~="string" then return {error="content_required"} end
    local before = (host.read_file and host.read_file(args.path)) or ""
    local ok = host.write_file and host.write_file(args.path, args.content or "")
    -- Record what changed while the previous text is still in hand: this is what the diff
    -- topic shows and what its undo replays. A failed write records nothing.
    if ok and ctx and ctx.changes then
      changeset.record(ctx.changes, args.path, before, args.content or "")
    end
    return { ok = ok and true or false, path = args.path, error=not ok and "write_failed" or nil }
  elseif name == "edit" then
    return file_tools.edit(args,ctx.changes and function(path,before,after)
      changeset.record(ctx.changes,path,before,after)
    end or nil)
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
    local allowed={pattern=true,path=true,ignore_case=true,limit=true,max_depth=true,extensions=true}
    for key in pairs(args) do if not allowed[key] then return {error='unsupported_search_option',option=key} end end
    if type(args.pattern)~='string' then return {error='pattern_required'} end
    if args.path~=nil and type(args.path)~='string' then return {error='invalid_search_path'} end
    if args.ignore_case~=nil and type(args.ignore_case)~='boolean' then return {error='invalid_ignore_case'} end
    for key,bounds in pairs({limit={1,500},max_depth={0,64}}) do
      local n=args[key]
      if n~=nil and (type(n)~='number' or n%1~=0 or n<bounds[1] or n>bounds[2]) then return {error='invalid_search_range',option=key} end
    end
    if args.extensions~=nil then
      if type(args.extensions)~='table' then return {error='invalid_extensions'} end
      for key,ext in pairs(args.extensions) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#args.extensions or type(ext)~='string' then return {error='invalid_extensions'} end
      end
    end
    if not host.grep then return {error='native_search_unavailable'} end
    local ok,result=pcall(host.grep,args.pattern,args.path or '.',json.encode(args))
    if not ok then return {error=tostring(result)} end
    return json.decode(result)
  elseif name == "graph" then
    local graph = dofile("lua/core/graph.lua")
    if not graph.available() then return { error = "graph_unavailable" } end
    local action = args.action or "explain"
    local result, err
    if action == "explain" then result, err = graph.explain(args.name)
    elseif action == "query" then result, err = graph.query(args.name, { limit = args.limit })
    elseif action == "path" then result, err = graph.path(args.from, args.to)
    elseif action == "caps" then result, err = graph.caps()
    elseif action == "stats" then result, err = graph.stats()
    elseif action == "index" then result, err = graph.index({ force = args.force })
    else return { error = "unknown_graph_action:" .. tostring(action) } end
    if not result then return { error = err or "graph_error" } end
    return result
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
  elseif name == "spell_export" then
    return spellslib.export_to_file(args.name, args.params, args.binary, args.path)
  elseif name == "sessions" then
    return { sessions = memory.list_sessions(user_id, args.limit or 30) }
  elseif name == "session" then
    local session = memory.session(args.session_id)
    if not session then return { error = "unknown_session" } end
    if session.user_id ~= user_id and not is_master(role) then return { error = "forbidden" } end
    if args.view~=nil and args.view~='full' and args.view~='compact' then return {error='invalid_view'} end
    if args.message_id then
      local row=memory.message(args.message_id)
      if not row or row.session_id~=args.session_id then return {error='unknown_message'} end
      if args.byte_offset~=nil then
        local offset,limit=tonumber(args.byte_offset),tonumber(args.byte_limit) or 20000
        if not offset or offset<1 or offset%1~=0 or limit<4 or limit>20000 or limit%1~=0 then return {error='invalid_message_range'} end
        local encoded=json.encode(row);local version=host.sha256(encoded)
        if offset>#encoded+1 then return {error='message_range_out_of_bounds'} end
        if offset<=#encoded and encoded:byte(offset)>=128 and encoded:byte(offset)<192 then return {error='offset_inside_utf8'} end
        if args.message_version and args.message_version~=version then return {error='message_changed',message_version=version} end
        local content,next_offset=tool_output.slice(encoded,offset,limit)
        return {content=content,encoding='exact_message_json',message_id=row.id,message_version=version,
          next_offset=next_offset,bytes=#encoded,eof=next_offset>#encoded}
      end
      return {message=args.view=='compact' and evidence_view.message(row) or row}
    end
    local messages = memory.session_messages(args.session_id, { limit = math.min(1000,math.max(1,tonumber(args.limit) or 200)),before_seq=tonumber(args.before_seq) })
    if args.view=='compact' then messages=evidence_view.messages(messages) end
    -- Say when it is a window. A model that reads 200 of 260 messages without being told
    -- will treat the oldest row it can see as the start of the thread, which is how
    -- ancient history reads as current state.
    local total = memory.message_count(args.session_id)
    local note
    if total > #messages then
      note = string.format("showing %d of %d messages; %d are outside this page; use before_seq for earlier evidence",
        #messages, total, total - #messages)
      if not args.before_seq then note=string.format("showing the newest %d of %d messages; use before_seq for earlier evidence",#messages,total) end
    end
    return { session = session, messages = messages, note = note,next_before_seq=messages[1] and messages[1].seq }
  elseif name == "search_messages" then
    if args.view~=nil and args.view~='full' and args.view~='compact' then return {error='invalid_view'} end
    local matches=memory.search_messages(args.query or '',is_master(role) and nil or user_id,math.min(50,math.max(1,tonumber(args.limit) or 20)))
    if args.view=='compact' then matches=evidence_view.messages(matches) end
    return {matches=matches,limit_reached=#matches==math.min(50,math.max(1,tonumber(args.limit) or 20))}
  elseif name == "resume_session" then
    local target = memory.session(args.session_id)
    if not target then return { error = "unknown_session" } end
    if target.user_id ~= user_id and not is_master(role) then return { error = "forbidden" } end
    local messages = memory.session_messages(args.session_id, { limit = args.limit or 30 })
    local lines = { "Resumed session " .. args.session_id .. " (" .. (target.title or "") .. "):" }
    local total = memory.message_count(args.session_id)
    if total > #messages then
      lines[#lines + 1] = string.format("(%d earlier turns omitted; showing the newest %d)",
        total - #messages, #messages)
    end
    if target.summary and target.summary ~= "" then lines[#lines + 1] = target.summary end
    for _, message in ipairs(messages) do
      if message.role == "user" or message.role == "assistant" then
        lines[#lines + 1] = message.role .. ": " .. (message.content or ""):sub(1, 400)
      end
    end
    if ctx.session_id then
      local current = memory.session(ctx.session_id) or {}
      local merged = current.summary or ""
      if merged ~= "" then merged = merged .. "\n" end
      memory.set_session_summary(ctx.session_id, current.summarized_until or 0, merged .. table.concat(lines, "\n"))
    end
    return { resumed = args.session_id, messages = #messages }
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
