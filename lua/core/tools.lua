-- Tools exposed to the head model. Access is gated by the caller's role:
-- masters get everything; guests get on-demand memory plus a way to list
-- what they may do. "spells" means deterministic, verified executions only (spells.lua).
local json = dofile("lua/vendor/json.lua")
-- Loaded at first use: the ONE argument validator (lua/core/tool_arguments.lua).
local tool_arguments
-- The one WhatsApp surface (#118): the nine `mcp_whatsapp_*` tools, and which node answers them.
local whatsapp_lib = dofile("lua/core/whatsapp.lua")
local platform = dofile("lua/core/platform.lua")
local spellslib = dofile("lua/core/spells.lua")
local nodeslib = dofile("lua/core/nodes.lua")
local changeset = dofile("lua/core/changeset.lua")
local bash_changes = dofile("lua/core/bash_changes.lua")
local patch_audit = dofile("lua/core/patch_audit.lua")
local tool_output = dofile("lua/core/pure.lua")("lua/core/tool_output.lua")
local file_tools = dofile("lua/core/file_tools.lua")
local canonical_guard = dofile("lua/core/canonical_guard.lua")
-- The path guard, once: `run()` below is where every shell command this tool launches passes, and the
-- runtime wall (the shell prelude) has to be added here, not only in init.lua - a WA_SCRIPT run does not
-- load init.lua, and that is exactly how a test runs.
local path_guard = dofile("lua/core/path_guard.lua")
local mcp = dofile('lua/core/mcp.lua')
local envelope = dofile('lua/core/envelope.lua')
local web = dofile('lua/core/web.lua')
local diagnose = dofile("lua/core/diagnose.lua")
local workspaces = dofile("lua/core/workspaces.lua")
local resources = dofile("lua/core/resources.lua")
-- Hook points around one tool call (docs/HOOKS.md). Declared with the other module dependencies
-- because both the dispatch wrapper at the bottom of this file and the parallel-bash gate read it.
local hookslib = dofile("lua/core/hooks.lua")
local redact = dofile("lua/core/redact.lua")
-- What a refusal says, in one place (lua/core/refusal.lua): every refusal a model can read leaves this
-- module through the wrapper at the bottom, so the four fields are added there and nowhere else.
local refusal = dofile("lua/core/refusal.lua")
local M = {}

local function is_master(role)
  return role == "master" or role == "admin"
end

-- Retired batches (operator's decision, 12/11: "many can be retired as naturally code mode can queue
-- many"). The table and the one sentence live in `lua/core/retired.lua`, so the dispatcher,
-- `tool_call`, a peer capability, code mode's `describeTool` and the gate test cannot drift apart.
-- Refused HERE, in the dispatcher every route reaches, so no route keeps a working alias of a retired
-- name: reading one is one sentence naming the primitive and the form, never a batch result.
local retired_lib = dofile('lua/core/retired.lua')
function M.retired(name) return retired_lib.text(name) end

-- Image references name files in this node's content-addressed store. Returning
-- one through `remote` would look successful but point at the wrong machine; fail
-- visibly until the node protocol has a bounded binary transfer.
local function carries_local_images(result)
  if type(result) ~= "table" then return false end
  if type(result._images) == "table" and #result._images > 0 then return true end
  for _, item in ipairs(result.results or {}) do
    if type(item) == "table" and type(item._images) == "table" and #item._images > 0 then return true end
  end
  return false
end

-- A local write or edit names the node it wrote on (mission write-names-its-node). A `remote` result
-- already carries its peer's name - {"node":"nextcloud","ok":true,"path":...} - and the local one did
-- not, so a path meant for a peer that landed here read as a plain success: the model's only evidence
-- was the path it had typed. The word is the one `nodes` uses for this node, so a script compares it
-- with a `remote` answer's node and learns nothing new. Read once per process: the name does not change
-- inside a session and node_name() costs a file read. When it cannot be read the field is absent - a
-- receipt never invents a node.
local this_node
local function on_this_node(result)
  if type(result) ~= "table" then return result end
  if this_node == nil then
    local ok, name = pcall(nodeslib.node_name)
    this_node = ok and type(name) == "string" and name ~= "" and name or false
  end
  if this_node and result.node == nil then result.node = this_node end
  return result
end

-- `remote` arguments, flattened. The canonical form is ONE level:
-- {node, capability, <the capability's own params>}; the older nested form
-- {node, capability, args={...}} still works. Measured on a DeepSeek session: 38 of 114 routed
-- calls closed a brace early and sent {args={command, capability, node}}, then read the bare
-- `unknown_node:nil` as a flaky network. Two repairs, both deterministic:
--  * a missing `node`/`capability` found exactly once inside `args` (or `args.args`) is hoisted,
--    unless the target capability declares that name as its own parameter - then the key could
--    belong to either call, and the call is refused with both readings named;
--  * a key given both at the top level and inside `args` with different values is refused.
-- A refusal says what arrived (keys, never values), where a misplaced key was found, which nodes
-- are online, and a minimal correct call, so the retry differs from the failed call.
local REMOTE_OWN = { node = true, capability = true, args = true }

-- The fields THIS node added to a capability, per capability: a peer whose own catalogue does not declare
-- one of them would ignore it (mission tool-args-honest-and-same-on-peers, mixed-fleet follow-up). Only
-- what this node learned to send in that mission is named; a capability absent from this table sends
-- everything, exactly as before.
local PEER_FIELD_SUPPORT = { bash = { 'stdin' }, operation = { 'stdin' }, grep = { 'context' } }
local REMOTE_EXAMPLE = '{"node":"<name>","capability":"bash","command":"ls -la"}'

local function sorted_keys(value)
  local keys = {}
  if type(value) == "table" then for key in pairs(value) do keys[#keys + 1] = tostring(key) end end
  table.sort(keys)
  return keys
end

-- The next step for each remote refusal the model can act on. Paired with `online_nodes` so the
-- model can pick another peer instead of probing the same refusal again.
local REMOTE_REFUSALS = {
  not_peer_operator = "Pick a peer whose `nodes` entry says operator_of_peer: true, or ask an administrator to bind the peer with this node as an operator. Do not retry this peer, and never sign as another node.",
  remote_refused = "Act on `hint`; the same call will be refused again until that changes. Run `nodes` to see operator_of_peer before retrying.",
  relay_refused = "Act on `hint`; the relay refuses before the peer sees the call, so retrying unchanged will not help.",
  unsigned_reply = "The peer's answer was neither signed nor a readable refusal: treat it as a transport fault, not a result. Retry once; if it repeats, check the peer's version.",
  remote_reply_unverified = "The answer's signature did not verify against the peer's registered key: do not trust it. Re-run `nodes` (the key may have changed) and retry once.",
}

local function online_nodes()
  local ok, list = pcall(nodeslib.list)
  local names = {}
  if ok and type(list) == "table" then
    for _, node in ipairs(list) do
      if node.online ~= false then names[#names + 1] = tostring(node.name or node.node_id) end
    end
  end
  return names
end

-- What a peer may be asked for where no effect is allowed: inside code mode and in a `calls` batch
-- (29/10). Reads, history and discovery on the peer; bash only when the orchestration classifier
-- calls the whole command read-only. Anything else names its route instead of running.
local REMOTE_READ = { read = true, ls = true, grep = true, graph = true,
  tool_result = true, diagnose = true, capabilities = true, nodes = true,
  sessions = true, session = true, search_messages = true,
  recall = true, memories = true, spell_list = true, spell_get = true, skill = true,
  -- The turn feed's peer half (lua/core/turnfeed.lua): a peer answers its own `<turn>` notes, already
  -- redacted. A read by construction - the handler opens the ledger for SELECT and writes nothing -
  -- so it may travel inside a code-mode read set and a `calls` batch like any other read.
  turns = true }
M.REMOTE_READ = REMOTE_READ
-- ONE INSTANCE OF THE ORCHESTRATION MODE MODULE, NOT ONE COMPILE PER CALL (23/11). `dofile` re-reads and
-- re-compiles the file on every call, and this module's own header loads json, memory, users and NODES
-- (1,969 lines): measured 9 ms for every tool dispatch on this node, paid whether the dispatch had
-- anything to do with orchestration or not. One instance answers exactly as a fresh one did - the mode,
-- the route and the admitted children live in the memory ledger keyed by session, never in an upvalue -
-- and the load stays LAZY, so a process that never dispatches a tool never compiles it. The disk is still
-- the source of truth on every call: nothing is cached but the compiled chunk.
local orchestration_module
local function orchestration()
  if not orchestration_module then orchestration_module = dofile('lua/core/orchestration_mode.lua') end
  return orchestration_module
end

function M.remote_read_refusal(capability, args)
  local retired = M.retired(capability)
  if retired then return { error = retired, capability = tostring(capability), effect = "none" } end
  if REMOTE_READ[capability] then return nil end
  if capability == "bash" then
    local command = type(args) == "table" and args.command or nil
    if orchestration().read_only_command(command) then return nil end
    return { error = "remote_effect_outside_codemode", capability = "bash", effect = "none",
      note = "A `calls` batch carries reads only (1-8 in one signed round trip): read-only bash is ls/cat/grep/rg/git status|log|diff|show..., no redirection or substitution; use cwd instead of cd or git -C. Send an effectful command as its own remote call - a script may, a batch may not." }
  end
  return { error = "remote_effect_outside_codemode", capability = tostring(capability), effect = "none",
    note = "A `calls` batch carries reads only, so remote " .. tostring(capability) .. " travels as its own call, not inside one. Batches accept: "
      .. "read, ls, grep, graph, sessions, session, search_messages, recall, memories, tool_result, read-only bash." }
end

local function declares_param(catalog, capability, key)
  if type(capability) ~= "string" then return false end
  if type(catalog) == "function" then
    -- An unreadable catalogue cannot prove the key is not the capability's own: refuse the hoist.
    local ok, list = pcall(catalog)
    if not ok or type(list) ~= "table" then return true end
    catalog = list
  end
  for _, item in ipairs(catalog or {}) do
    local fn = item["function"] or {}
    if fn.name == capability then
      local properties = (fn.parameters or {}).properties
      return type(properties) == "table" and properties[key] ~= nil
    end
  end
  return false
end

function M.remote_arguments(args, catalog)
  if type(args) ~= "table" then args = {} end
  local inner = args.args
  if type(inner) == "string" then
    local ok, decoded = pcall(json.decode, inner)
    if ok and type(decoded) == "table" then inner = decoded
    else return nil, { error = "remote_args_object_required", received_type = "string",
      note = "`args` must be an object; or leave it out and pass the capability's parameters at the top level.",
      example = REMOTE_EXAMPLE } end
  elseif inner ~= nil and type(inner) ~= "table" then
    return nil, { error = "remote_args_object_required", received_type = type(inner), example = REMOTE_EXAMPLE }
  end
  local params = {}
  for key, value in pairs(inner or {}) do params[key] = value end
  local node, capability = args.node, args.capability
  local hoisted = {}
  for _, key in ipairs({ "capability", "node" }) do
    if args[key] == nil then
      local places = {}
      if params[key] ~= nil then places[#places + 1] = { "args", params } end
      if type(params.args) == "table" and params.args[key] ~= nil then places[#places + 1] = { "args.args", params.args } end
      if #places > 1 then
        return nil, { error = "remote_" .. key .. "_ambiguous", found_in = { places[1][1], places[2][1] },
          note = "`" .. key .. "` is missing at the top level and appears more than once inside args; nothing was run. Put it at the top level, once.",
          example = REMOTE_EXAMPLE }
      end
      if #places == 1 then
        local where, holder = places[1][1], places[1][2]
        local value = holder[key]
        if type(value) ~= "string" or value == "" then
          return nil, { error = "remote_" .. key .. "_required", found_in = where, found_type = type(value),
            note = "`" .. key .. "` must be a non-empty string at the top level.", example = REMOTE_EXAMPLE }
        end
        local target = key == "node" and capability or value
        -- BOTH MISSING, BOTH INSIDE: the pair is the remote call's own routing words, not a capability's
        -- parameter. A call that names no capability at the top level cannot be addressing a capability's own
        -- `node` argument, so hoisting the pair is the only reading that can be acted on - the mis-nested
        -- shape weaker models produce (38 of 114 routed calls in the evidence behind this repair). The
        -- ambiguity refusal below stays for the case where the top level DID name the capability: then the
        -- inner `node` really could be either (mission tool-args-honest-and-same-on-peers: `read`/`grep`/
        -- `write`/`edit`/`ls` now declare their own `node`, which is what made this pair ambiguous).
        local pair_inside = function(want)
          if params[want] ~= nil then return true end
          return type(params.args) == "table" and params.args[want] ~= nil
        end
        local both_misnested = args.node == nil and args.capability == nil and pair_inside("node") and pair_inside("capability")
        if declares_param(catalog, target, key) and not both_misnested then
          return nil, { error = "remote_" .. key .. "_ambiguous", found_in = where,
            note = "`" .. key .. "` is missing at the top level, and " .. tostring(target)
              .. " has its own `" .. key .. "` parameter, so the key inside " .. where
              .. " could mean either. Nothing was run; put the remote " .. key .. " at the top level.",
            example = REMOTE_EXAMPLE }
        end
        if holder ~= params then
          local copy = {}
          for k, v in pairs(holder) do copy[k] = v end
          params.args, holder = copy, copy
        end
        holder[key] = nil
        if key == "node" then node = value else capability = value end
        hoisted[#hoisted + 1] = key .. " from " .. where
      end
    end
  end
  -- What is left of an args.args emptied by a hoist is the same misplaced object one level down.
  if #hoisted > 0 and type(params.args) == "table" and next(params) == "args" and next(params, "args") == nil then
    params = params.args
  end
  if node == nil or node == "" then
    return nil, { error = "remote_node_required",
      received = { top_level_keys = sorted_keys(args), args_keys = sorted_keys(args.args) },
      online_nodes = online_nodes(),
      note = "Name the peer in `node`, at the top level next to `capability`; the capability's own parameters go at that same level.",
      example = REMOTE_EXAMPLE }
  end
  if type(node) ~= "string" then
    return nil, { error = "remote_node_required", received_type = type(node), online_nodes = online_nodes(), example = REMOTE_EXAMPLE }
  end
  if type(capability) ~= "string" or capability == "" then
    return nil, { error = "remote_capability_required",
      received = { top_level_keys = sorted_keys(args), args_keys = sorted_keys(args.args) },
      note = "Name the tool to run on " .. node .. " in `capability` (for example bash or read), at the top level.",
      example = REMOTE_EXAMPLE }
  end
  for key, value in pairs(args) do
    if not REMOTE_OWN[key] then
      if params[key] ~= nil and json.encode(params[key]) ~= json.encode(value) then
        return nil, { error = "remote_argument_conflict", key = tostring(key),
          note = "`" .. tostring(key) .. "` was given at the top level and inside args with different values; nothing was run. Give it once, at the top level.",
          example = REMOTE_EXAMPLE }
      end
      params[key] = value
    end
  end
  return { node = node, capability = capability, args = params, hoisted = #hoisted > 0 and hoisted or nil }
end

local function schema(name, description, properties, required, extra)
  -- An empty Lua table encodes as `[]`, which providers reject as a schema, so
  -- only emit `properties`/`required` when they actually have entries.
  local parameters = { type = "object" }
  if properties and next(properties) ~= nil then parameters.properties = properties end
  if required and #required > 0 then parameters.required = required end
  -- A keyword the schema needs but this helper cannot derive (`additionalProperties` for a tool that
  -- forwards another tool's arguments). Merged last, so a caller names it once and it lands on the
  -- parameters object a provider and the node's own argument validator both read.
  if type(extra) == "table" then for key, value in pairs(extra) do parameters[key] = value end end
  return { type = "function", ["function"] = {
    name = name, description = description, parameters = parameters } }
end

-- A catalogue entry from a parameters object that is already in the server's own shape.
--
-- `schema()` above builds a schema from the per-property map, which is right for the tools this file
-- declares by hand and wrong for anything that arrives declaratively: rebuilding a plugin's schema from
-- `properties` and `required` alone dropped every other keyword it declared (`additionalProperties`,
-- `items`, a pydantic `$defs`), and a plugin whose declaration is not the map shape lost its properties
-- altogether - the empty-`properties` a model saw in `searchTools("select:...")` on 13/11 and then had
-- to guess argument names for. Passed through verbatim, apart from the one thing a provider refuses: an
-- empty table, which encodes as `[]`. `scripts/test-tool-schema-fidelity.lua` guards it.
local function schema_from(name, description, parameters)
  local shaped = type(parameters) == "table" and parameters or {}
  if next(shaped) == nil then shaped = { type = "object" } end
  return { type = "function", ["function"] = {
    name = name, description = description, parameters = shaped } }
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

-- The most text a caller may feed a command's standard input (`bash {stdin=...}`, `operation start`).
-- One number in one place: the schemas state it (maxLength), the bash handler refuses above it, and the peer
-- path inherits both because it is this same code. 1 MiB is ten times the largest heredoc a real call in the
-- ledger carried, and small enough that the temp file the launcher hands the child stays in the node root.
local STDIN_MAX_BYTES = 1048576
M.STDIN_MAX_BYTES = STDIN_MAX_BYTES

-- THE GRAPH IS OFF BY DEFAULT ON EVERY NODE FROM G (docs/GRAPH.md, 23/11). A dormant feature must cost the
-- model nothing: no catalogue line, no `searchTools` hit, no schema bytes in the prompt. The switch is the
-- `graph` row of the one feature resolver, so it is `policy.json`'s `features.graph` (live: the resolver
-- re-reads the file about once a second) or `WA_GRAPH_COMPONENT=1` for this process - the same answer
-- `wa features` prints and the host's own capabilities refuse by. Read per catalogue build, not once at
-- load, so switching it on reaches the next turn without a restart.
local function graph_offered()
  local ok, on = pcall(function() return dofile('lua/core/features.lua').on('graph') end)
  return ok and on == true
end

-- Available to everyone.
M.shared = {
  schema("time", "Current local date/time on this node with its UTC offset, zone, weekday and epoch.", {}),
  schema("remember", "Store a fact the user asked you to keep; confirm in one short sentence. To correct a fact, pass its `id`: the entry is replaced in place. Do not store your own reasoning.", {
    content = { type = "string", description = "The fact to remember, in full." },
    id = { type = "string", description = "Existing memory id; replaces that entry." },
    scope = { type = "string", description = "Optional scope, e.g. global or a conversation id." },
    tags = { type = "array", items = { type = "string" } } }, { "content" }),
  schema("recall", "Search facts the user asked you to keep. Call it before answering about the user (names, preferences, codewords, settings, accounts) and before saying nothing is stored. Without a query it answers the most recent facts.", {
    query = { type = "string", description = "What to look for, in the user's own words." },
    scope = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 50 } }),
  schema("memories", "List what is stored, most recent first, with each entry's id. Use it when the user asks what you remember or wants the store tidied: reading the ids is how you find what `forget` should remove.", {
    scope = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 200 } }),
  -- ---- the self-loop (docs/SELF-LOOP.md): controls the model owns, never a required schema ----
  schema("wake", "Schedule your own next turn in this session: a durable task loop you own, not an automation rule installed by the operator. Give `in_seconds` (or `at`, Unix epoch seconds) for a time wake, or `on` for an event wake: bus topics (dotted; a trailing `.*` matches children), job ids (matched as job.<id>), or \"message\" (a new user message in this session). `every_seconds` re-arms the wake after each turn; `prompt` is the text you are woken with (default \"scheduled wake: <reason>\"). Optional `probe` is a small code-mode script that runs before the wake with read-only tools only: return {changed:false} to skip the model turn and re-arm as asked (a time wake needs every_seconds for that), {changed:true, ...} to be woken with the result; a probe that fails wakes you with its error so you decide. A wake survives a node restart and re-enters this session as a normal turn marked [self-wake], with your notes offered. Write the goal and done-criteria into `notes_write`, re-read them on each wake, prefer event wakes to fast polling, and cancel wakes when the goal is done (wake_list / wake_cancel).", {
    in_seconds = { type = "number", minimum = 0, description = "Wake after this many seconds." },
    at = { type = "number", description = "Wake at this Unix epoch time in seconds. Exclusive with in_seconds." },
    on = { type = "array", minItems = 1, maxItems = 16, items = { type = "string", maxLength = 256 }, description = "Event subscriptions: bus topics, job ids, or \"message\". Exclusive with in_seconds/at/every_seconds." },
    every_seconds = { type = "number", minimum = 1, description = "Time wakes: re-arm after each turn. Also the recheck cadence when a probe returns changed=false." },
    reason = { type = "string", maxLength = 500, description = "Why this wake exists; it labels the transcript turn." },
    prompt = { type = "string", maxLength = 8000, description = "The user-side text of the wake turn. Defaults to scheduled wake: <reason>." },
    probe = { type = "string", maxLength = 20000, description = "Code-mode script (read-only tools) returning {changed:boolean, ...}. Runs before the wake; only change wakes the model for nothing." },
  }, { "reason" }),
  schema("wake_list", "List your pending wakes for this session: when each is next due, its cadence or event subscription, its last error, and whether it is being dispatched. `all=true` includes delivered, failed, cancelled and unknown rows.", {
    all = { type = "boolean", description = "Include settled history, not only pending wakes." } }),
  schema("wake_cancel", "Cancel one of your pending wakes by id (from wake_list). A wake already handed to the run scheduler refuses: cancelling there would claim an effect this call cannot observe.", {
    id = { type = "string", description = "Wake id from wake_list." } }, { "id" }),
  schema("notes_read", "Read the plan/notes document you own for this session. `version` reads an archived version; `versions=true` lists recent archived versions. A write or compact archives the previous document, so nothing you wrote is lost.", {
    version = { type = "string", description = "Archived version id to read." },
    versions = { type = "boolean", description = "List recent archived versions instead of the current text." } }),
  schema("notes_write", "Replace your session notes with `text` (the previous non-empty document is archived). Use it for the goal, done-criteria, what is verified, open questions and the next action, so a wake can resume without re-deriving the mission.", {
    text = { type = "string", maxLength = 65536 } }, { "text" }),
  schema("notes_append", "Append a block to your session notes. Cheaper than rewriting a long plan for one fact; compact when it grows.", {
    text = { type = "string", maxLength = 65536 } }, { "text" }),
  schema("notes_compact", "Keep only the last `keep_lines` lines of your notes and archive the full previous document. The model decides what to drop; the archive is retrievable with notes_read {version}.", {
    keep_lines = { type = "integer", minimum = 1, maximum = 1000, description = "Lines to keep (default 40)." } }),
  -- The done gate (docs/DONE-GATE.md): the acceptance checks the harness runs at each turn end.
  schema("done_criteria", "The acceptance checks for the operator's request, next to their verbatim words. On a request that asks for a change in the world, `capture` BEFORE the first effect: a command check is run by the harness at every turn end, a written criterion is judged by a fresh verifier. While one fails the harness continues the run with the operator's words and the failing output; it does not end the turn. `add` records another check at any time. Removing or weakening a check needs the operator's own instruction, quoted verbatim from this session's transcript (`operator_quote`), because a check the model can quietly drop is not a check. `impossible` ends the turn on evidence: `reason` plus `probes` the harness reruns (each must meet its own expect/expect_exit now), or a quoted operator instruction to stop. `exempt` records why a request needs no state change. `status` reads the gate and its history.", {
    action = { type = "string", enum = { "capture", "add", "remove", "weaken", "exempt", "impossible", "status" },
      description = "capture: record the request's checks; add: one more; remove/weaken: operator words required; exempt: no state change requested; impossible: measured blocker; status: read." },
    request = { type = "string", maxLength = 20000, description = "capture: the operator's words, verbatim (default: the newest user turn). A paraphrase is refused." },
    checks = { type = "array", minItems = 1, maxItems = 24, items = { type = "object", properties = {
      command = { type = "string", maxLength = 4000, description = "A command the harness runs in the session workdir; exit code must be 0 unless expect_exit says otherwise." },
      expect = { type = "string", maxLength = 500, description = "Optional literal substring the output must contain." },
      expect_exit = { type = "integer", minimum = -255, maximum = 255, description = "Required exit code (default 0)." },
      text = { type = "string", maxLength = 2000, description = "A written criterion instead of a command; a fresh verifier judges it against the evidence." },
      why = { type = "string", maxLength = 400, description = "What this proves." },
      timeout_seconds = { type = "number", minimum = 1, maximum = 3600 } } },
      description = "capture/add: the checks. A check is a command, or a written criterion." },
    id = { type = "string", description = "remove/weaken: the check id from capture/status (default: every live check)." },
    operator_quote = { type = "string", maxLength = 4000, description = "remove/weaken/impossible: the operator's instruction, verbatim, as it appears in a user turn of this session." },
    reason = { type = "string", maxLength = 4000, description = "impossible: the named blocker." },
    probes = { type = "array", minItems = 1, maxItems = 8, items = { type = "object", properties = {
      command = { type = "string", maxLength = 4000 },
      expect = { type = "string", maxLength = 500 },
      expect_exit = { type = "integer", minimum = -255, maximum = 255 },
      why = { type = "string", maxLength = 400 } }, required = { "command" } },
      description = "impossible: commands the harness reruns to measure the blocker." },
    why = { type = "string", maxLength = 1000, description = "exempt: why this request needs no change in the world." } },
  { "action" }),
  schema("skill", "Find procedures by `query`, or load one skill's full instructions by `name` (not both). Load a matching skill before specialized work.", {
    name = { type = "string", description = "Exact skill name to load." },
    query = { type = "string", maxLength = 256, description = "Task keywords; * lists all visible metadata." },
    limit = { type = "integer", minimum = 1, maximum = 8 },
    offset = { type = "integer", minimum = 0 },
    snapshot = { type = "string", description = "Carry the returned snapshot when continuing a metadata page." } }),
  schema("capabilities", "List permitted tools and their current workspace execution limits; permission is not executability.", {}),
  -- Fleet knowledge and the fleet's own view (docs/FLEET-OPS.md). Both are looked up on purpose:
  -- nothing from `lessons` is injected into a session, and `fleetview` changes nothing.
  schema("lessons", "Recall or add what this fleet learned the hard way (symptom, cause, fix, rule). Look it up on purpose with action=recall before touching fleet control - the fleetops skill says when - and add one with action=add when a failure would otherwise repeat. Nothing here is injected automatically: an empty recall means these words are not in the store, not that no lesson exists.", {
    action = { type = "string", enum = { "recall", "list", "add", "stats" }, description = "recall: search by words; list: newest first; add: store one lesson; stats: counts only." },
    query = { type = "string", maxLength = 512, description = "recall: what happened, in your words (e.g. 'rendezvous admin list')." },
    limit = { type = "integer", minimum = 1, maximum = 20 },
    id = { type = "string", maxLength = 120, description = "add: exact id of an existing lesson to correct; omit to derive it from symptom+rule." },
    symptom = { type = "string", maxLength = 2000, description = "add: what was observed, with no message text or secret." },
    cause = { type = "string", maxLength = 2000, description = "add: why it happened, or 'unknown'." },
    fix = { type = "string", maxLength = 2000, description = "add: what actually repaired it, or 'unknown'." },
    rule = { type = "string", maxLength = 2000, description = "add: the rule a later session should follow. Required." },
    tags = { type = "array", items = { type = "string", maxLength = 60 } },
    source = { type = "string", maxLength = 200, description = "add: where the lesson came from (a node name, an incident id)." } }, { "action" }),
  schema("fleetview", "One read-only call for the whole fabric: every node's online/last_seen, version/commit, health, disk, components and the features they carry, running operations and jobs, and recent incidents from telemetry and lessons. Unknown facts are named in each node's `missing` and left absent - never a zero - so read `missing` before concluding a node is healthy. Changes nothing.", {
    lessons = { type = "boolean", description = "Attach matching lessons to the nodes they name (default true)." } }),
  schema('tool_search','Find tools by keyword, or load an exact list: `query` for keywords, or `names` to load several known tools at once with names=[...] (exact tool names, as many as you need; query="select:a,b,c" is the same request). Each permitted name is loaded and pinned like a keyword hit; a name that is unknown or not permitted comes back in `missing` with the nearest permitted names instead. A tool you already know needs no search: call it with tool_call.',{query={type='string',maxLength=256,description='Keywords. Or "select:a,b,c" - the batch spelling of names.'},names={type='array',minItems=1,items={type='string',maxLength=256},description='Exact tool names to load in one atomic batch (limit does not truncate it); exclusive with query.'},limit={type='integer',minimum=1,maximum=8}},{}),
  schema('tool_call','Call any permitted tool by `name` with `arguments`. checked=true validates the arguments against its schema first. `calls` runs 1-8 known independent pure reads in one call (serially); `cursor` pages a large batch result.',{name={type='string'},arguments={type='object'},checked={type='boolean'},calls={type='array',minItems=1,maxItems=8,items={type='object',properties={name={type='string'},arguments={type='object'}},required={'name','arguments'}}},cursor={type='string'}}),
  schema("subagent", "Start and supervise a child agent on a bounded task, with its own context, transcript and a restricted tool profile (`profiles` lists approved ones; a profile only narrows your tools). `start` returns a receipt, not a result: collect with `await` (one bounded wait) or `status`/`result`, stop with `cancel`. Reuse the exact recorded subagent/dispatch or native attempt ID for `status`: one direct lookup, not `list` rediscovery. Never guess or strip a `child:` session name into an ID; if the ID is missing, use `lookup_session` with its `conversation_id`. A placed task in state `unknown` may or may not have arrived: only `reconcile` may retry or cancel it. `session` reads the child's conversation; `message` queues its next turn. `message`, `steer` and `steer_session` require a non-empty `idempotency_key`; reuse it only for the same request.", {
    action = { type = "string", enum = { "start", "status", "list", "lookup_session", "result", "await", "cancel", "reconcile", "profiles", "message", "steer", "steer_session", "steering_status", "session", "events", "fleet" } },
    text = { type = "string", description = "message: queue a follow-up; steer: amend active child; steer_session: amend active main session. Steering fences calls not yet admitted, never undoes in-flight effects." },
    conversation_id = { type = "string", description = "lookup_session only: required, non-empty exact child session ID (including child: prefix). Read-only owner-scoped latest continuation summary; remote state is recorded, not refreshed. No global task array." },
    session_id = { type = "string", description = "steer_session / steering_status: owned main session." },
    run_id = { type = "string", description = "Optional expected steering target; stale targets are refused." },
    before_seq = { type = "integer", description = "session: read original messages before this sequence." },
    after_seq = { type = "integer", minimum = 0 },
    offset = { type = "integer", minimum = 0, description = "list: next_offset from previous page." },
    limit = { type = "integer", minimum = 1, maximum = 1000 },
    byte_limit = { type = "integer", minimum = 4, maximum = 20000 },
    view = { type = "string", enum = { "full", "compact", "tool_calls" } },
    message_id = { type = "string" },
    byte_offset = { type = "integer", minimum = 1 },
    message_version = { type = "string" },
    profile = { type = "string", description = "Approved profile id, e.g. explore. Defaults to explore (read-only)." },
    title = { type = "string", description = "Short task-specific heading for the child conversation, not its profile name." },
    prompt = { type = "string", description = "The bounded task for the child. Required for start." },
    context = { type = "string", description = "Optional extra context; the parent transcript is never sent." },
    id = { type = "string", description = "Exact recorded subagent/dispatch or native task/attempt ID, not a child session ID. Reuse unchanged for status/result/await/cancel/session/message/steer/events/reconcile; never guess, strip child:, or auto-resolve a mutating target." },
    wait_ms = { type = "integer", minimum = 1, maximum = 600000, description = "await: bounded wait in milliseconds." },
    model = { type = "string", description = "Approved model override; inherits the caller's model when absent." },
    reasoning = { type = "string", description = "Approved reasoning level override; inherits the caller's when absent." },
    parent_run_id = { type = "string", description = "Run that owns this child; defaults to the current run." },
    delivery_id = { type = "string", description = "Job delivery this child belongs to, when a job starts it." },
    idempotency_key = { type = "string", description = "Required, non-empty for message, steer and steer_session; optional for start. Reuse the same key for the same request to collect its receipt without a second effect. No key is needed for read-only actions." },
  }, { "action" }),
  -- `node` (29/10): history lives on the node that did the work, so the same read runs on a peer
  -- through `remote` under that peer's own authorization; read-only, never forwarded a second hop.
  schema("sessions", "List your own past sessions (resumable threads), most recent first. node=<peer> lists that peer's sessions instead. all_owners (master) lists every owner's sessions, e.g. the peer's own agent work; path keeps the sessions bound to that repository/worktree or whose recorded file changes are under it - newest first, so the first row answers \"what was the last agent session on that repo\".", {
    limit = { type = "integer", minimum = 1, maximum = 100 },
    node = { type = "string", description = "Peer name or node_id (from nodes): run this read on that node." },
    all_owners = { type = "boolean", description = "Master only: every owner's sessions, not only yours." },
    path = { type = "string", description = "Absolute repository or directory path on that node." } }),
  schema("session", "Read a session. Defaults to newest messages; pass next_before_seq back as before_seq to retrieve earlier evidence. For failure diagnosis use view=full and a small limit or exact message_id; oversized rows keep a last-failure excerpt and exact-original pointer. node=<peer> reads a session held by that peer.", {
    session_id = { type = "string" },
    node = { type = "string", description = "Peer name or node_id (from nodes): read the session on that node." },
    before_seq = { type = "integer", minimum = 1 },
    around_seq = { type = "integer", minimum = 1, description = "Centre on a search hit; includes nonmatching neighbours in chronological order." },
    before = { type = "integer", minimum = 0, maximum = 20, description = "With around_seq: how many messages before it (a count, not a seq)." },
    after = { type = "integer", minimum = 0, maximum = 20, description = "With around_seq: how many messages after it (a count, not a seq)." },
    message_ids = { type = "array", minItems = 1, maxItems = 20, items = {type="string"}, description = "Batch selected originals in this session; missing or foreign rows refuse the entire batch." },
    message_id = { type = "string", description = "Exact row, with ownership checked against this session." },
    byte_offset = { type = "integer", minimum = 1, description = "With message_id, page selected view JSON; full preserves the original, tool_calls avoids encrypted reasoning." },
    byte_limit = { type = "integer", minimum = 4, maximum = 20000 }, message_version = {type="string"},
    view = { type = "string", enum = {"full", "compact", "tool_calls"}, description = "Full is default; tool_calls returns exact calls/arguments and tool outcomes without loading encrypted reasoning. Projections retain full-original references; compact omits diagnostics." },
    limit = { type = "integer", minimum = 1, maximum = 1000 } }, { "session_id" }),
  schema("search_messages", "Search history: dialogue-first exact excerpts with original evidence references. Local by default; node=<peer> searches that peer's history (work done on another node lives there). Use scope=evidence for execution/tool results, all for unrestricted history including retrieval echoes. Filters apply before ranking. session around_seq reads neighbouring context.", {
    query = { type = "string", maxLength = 4096 },
    node = { type = "string", description = "Peer name or node_id (from nodes): search that node's history instead of this one." },
    scope = { type = "string", enum = {"dialogue", "evidence", "all"} },
    view = { type = "string", enum = {"snippets", "full", "compact"}, description = "Snippets default: exact matching excerpts, not generated summaries. Full/compact explicit; originals always accessible." },
    roles = { type = "array", minItems = 1, maxItems = 6, items = {type="string",enum={"user","assistant","tool","summary","retry","system"}} },
    session_id = {type="string"}, tool_name = {type="string"},
    after = {type="number",description="Inclusive Unix seconds."}, before = {type="number",description="Inclusive Unix seconds."},
    sort = {type="string",enum={"relevance","newest"}}, match = {type="string",enum={"terms","phrase"}},
    group_by = {type="string",enum={"session","message"},description="Session default: at most two hits per session; message disables diversity."},
    offset = {type="integer",minimum=0,maximum=1000000,description="Follow next_offset; pagination uses live ranks, not a frozen snapshot."},
    byte_limit = {type="integer",minimum=2048,maximum=20000},
    limit = { type = "integer", minimum = 1, maximum = 50 } }, { "query" }),
  schema("resume_session", "Fold a past session into this one: its summary and recent messages become context.", {
    session_id = { type = "string" },
    limit = { type = "integer", minimum = 1, maximum = 100 } }, { "session_id" }),
}

-- Admin only: the pi-style environment tools.
M.admin = {
  -- Master only: deleting is destructive, and memory is shared across roles, so a
  -- guest must not be able to erase the operator's stored facts. Without this
  -- tool the agent could only ever accumulate - it said so itself, and left a
  -- wrong date in the store because it had nothing to delete it with.
  schema("forget", "Delete a stored memory by id (from `recall` or `memories`). Use it for something wrong, outdated or stored by mistake: an append-only store fills with junk and then misleads you later.", {
    id = { type = "string" } }, { "id" }),
  -- The dialect is in the description because the model otherwise assumes POSIX
  -- and wastes its tool budget on commands this machine does not have.
  schema("bash", "Run a command on this machine with " .. platform.shell() .. ". Killed after " .. exec_deadline_seconds() .. "s unless timeout_seconds (1-86400) is larger; raise it for builds and long tests. Returns when the shell exits; descendants that remain continue as a supervised operation the result names. stdin is the text the command takes as its standard input, then closed. For deliberate long-lived work use operation start.", {
    command = { type = "string" }, cwd = { type = "string" },
    stdin = { type = "string", maxLength = 1048576, description = "Text fed to the command's standard input, then closed. It is delivered as the command's input, not pasted into the command line." },
    timeout_seconds = { type = "integer", minimum = 1, maximum = 86400, description = "Kill the command after this many seconds. Defaults to the node's foreground deadline (" .. exec_deadline_seconds() .. "s); raise it for a build or a full test gate, lower it to fail fast." } }, { "command" }),
  schema("operation", "Start, observe, read streamed output, wait briefly for, or cancel a supervised external operation. A launch receipt is not completion. Output read uses byte cursors; when text_lossy is true, decode content_base64 for exact bytes instead of concatenating content. `await` on work adopted by foreground bash defaults to the shell command result after output reaches EOF or is idle for 100ms; descendants remain supervised and may still produce output. Set wait_for=`settled` to await their full operation. Explicitly started operations always await full settlement. Jobs are automation rules, not operations. No automatic replay after an unknown outcome.", {
    action = { type = "string", enum = {"start", "list", "status", "read", "wait", "await", "cancel", "background"},
      description = "background only lowers a running operation's CPU priority once nobody is waiting for it; code mode does that by itself when a call goes pending." },
    id = { type = "string" }, command = { type = "string" }, cwd = { type = "string" },
    timeout_seconds = { type = "integer", minimum = 1, maximum = 86400 },
    stdin = { type = "string", maxLength = 1048576, description = "start only: text fed to the command's standard input, then closed." },
    stream = { type = "string", enum = {"stdout", "stderr"} }, offset = { type = "integer", minimum = 0 },
    -- The ceiling is codemode_pending.STDOUT_PAGE_BYTES (24 KiB, the Rust page). It is written out
    -- because a schema table is a literal; scripts/test-turn-signal.lua asserts the two agree, so
    -- the copy cannot drift silently (item 4).
    limit = { type = "integer", minimum = 1, maximum = 24576 }, wait_ms = { type = "integer", minimum = 0, maximum = 10000 },
    wait_for = { type = "string", enum = {"command", "settled"}, description = "await only: foreground adoption defaults to command completion; settled waits for the complete owned process tree." },
    scope = { type = "string", enum = { "node" },
      description = "Only for an operator surface or a session the operator has marked mastermind: scope=\"node\" reaches every session's operations on this node, and is written to the audit journal. A model call in an ordinary session is refused (scope_node_forbidden) and does not get it; read your own operations without a scope." }
  }, {"action"}),
  schema("read", "Read text with line/byte continuation, or a PNG/JPEG/WebP/GIF (up to 4 MB) as an image. Every text page reports bytes_read against file_size plus its line range and total_lines, and sets truncated with the range it returned and how to read the rest whenever it did not return the whole file; a whole file says truncated: false. Ask for the range you need and follow next_offset/next_column with `version` until eof. A whole-line page returns `selection` and `edit_lines`, the receipt edit's range_edits form takes.", {
    path = { type = "string" },
    offset = { type = "integer", minimum = 1 },
    column = { type = "integer", minimum = 1 }, version = { type = "string" },
    node = { type = "string", description = "Peer name or node_id (from nodes): that node's file instead of this one's." },
    limit = { type = "integer", minimum = 1, maximum = 2000 } }, { "path" }),
  schema("write", "Create or overwrite a text file. In a required session workspace, writes are limited to the worktree and its session scratch root; a refusal lists both in allowed_writes. node=<peer> answers from that peer, and the result names the node the bytes landed on.", {
    path = { type = "string" }, content = { type = "string" },
    node = { type = "string", description = "Peer name or node_id (from nodes): that node's file instead of this one's." } }, { "path", "content" }),
  schema("edit", "Replace text in one file, using exactly one form. `edits` (old_text/new_text) quotes bytes that must occur exactly once; a miss returns the nearest region. An anchor that lies outside every byte range this session read from that file is refused by name (`edit_anchor_outside_read_page`): read the page that holds it. `range_edits` copies a read `selection` unchanged with replacement_lines (optional start_line/end_line inside its edit_lines), for text you cannot quote; shell output does not provide an edit receipt. All ranges apply atomically; check the echo of what each replaced. node=<peer> answers from that peer.", {
    path = { type = "string" },
    node = { type = "string", description = "Peer name or node_id (from nodes): that node's file instead of this one's; the result names the node the bytes landed on." },
    edits = { type = "array", minItems = 1, maxItems = 64, items = { type = "object",
      properties = {
        old_text = { type = "string", description = "Exact bytes to replace, copied from a read; must occur exactly once in the file." },
        new_text = { type = "string", description = "Replacement bytes; empty deletes the quoted text." }
      }, required = {"old_text","new_text"} } },
    range_edits = { type = "array", minItems = 1, maxItems = 64, items = { type = "object",
      properties = {
        selection = { type = "string", description = "Opaque receipt returned by read.selection. Copy it unchanged." },
        start_line = {type="integer",minimum=1,description="Optional inclusive source line inside the receipt's edit_lines frame; provide together with end_line."},
        end_line = {type="integer",minimum=1,description="Optional inclusive source line inside the receipt's edit_lines frame; provide together with start_line."},
        replacement_lines = {type="array",maxItems=2000,items={type="string"}}
      }, required = {"selection","replacement_lines"} } }
  }, { "path" }),
  schema("ls", "List a directory (portable: works the same on every platform). node=<peer> answers from that peer.", {
    path = { type = "string" },
    node = { type = "string", description = "Peer name or node_id (from nodes): that node's directory instead of this one's." } }),
  schema("grep", "Literal substring search, not regex. Reports omitted files and clipped lines. Use a path to narrow the search, and read the matched range afterwards rather than whole files. Results use the supplied root; extensions are exact suffixes without dots. context adds the lines around each match; node=<peer> answers from that peer.", {
    pattern = { type = "string" }, path = { type = "string" },
    ignore_case = {type="boolean"}, limit={type="integer",minimum=1,maximum=500},
    max_depth={type="integer",minimum=0,maximum=64}, extensions={type="array",items={type="string"}},
    context={type="integer",minimum=0,maximum=10,description="Lines of context before and after each match; 0, the default, returns the matches alone."},
    node = { type = "string", description = "Peer name or node_id (from nodes): that node's tree instead of this one's." }
  }, { "pattern" }),
  -- Retrieval returns selected implementation text; relationship and audit actions remain
  -- explicitly separate so their evidence can be evaluated independently.
  schema("graph", "Concept discovery, exact source (including bounded source batches), overview and patch reachability. Queries capture content evidence, automatically await a committed invocation revision and never silently return stale results; use read/grep after explicit indexing failures. After using graph, state in the final answer whether it helped your reasoning and why.", {
    action = { type = "string", enum = { "search_symbols", "symbol_source", "overview", "impact", "explain", "query", "path", "caps", "stats", "index", "audit", "audit_assess", "audit_report", "audit_feedback" } },
    name = { type = "string", description = "search_symbols: concept or identifier; symbol_source/explain/query: exact selected name." },
    prefer_implementations = { type = "boolean", description = "search_symbols: opt-in ranking that demotes partial local-variable matches; useful when looking for a component/function implementation, not a state binding." },
    path = { type = "string", description = "symbol_source: path from a search_symbols result." },
    line = { type = "integer", minimum = 1, description = "symbol_source: definition line from a search_symbols result." },
    kind = { type = "string", description = "symbol_source: optional definition kind from the selected result." },
    source_version = {type='string',description='symbol_source: optional exact file SHA-256 from discovery/source; refuses changed source, including continuation pages.'},
    byte_offset = { type = "integer", minimum = 0, description = "symbol_source: continue a large definition at this returned byte offset." },
    max_bytes = { type = "integer", minimum = 256, maximum = 200000, description = "symbol_source: source bytes/page (clamped to 20000); overview/impact: whole-response budget (default 24000)." },
    aspects = { type = "array", maxItems = 8, items = {type="string", enum={"overview","languages","modules","entry_points","routes","capabilities","hotspots","boundaries","resolution"}}, description = "overview: optional sections; omitted returns the bounded overview." },
    direction = { type = "string", enum = {"inbound","outbound","both"}, description = "impact: callers, dependencies, or both; default both." },
    depth = { type = "integer", minimum = 1, maximum = 4, description = "impact: resolved edge depth; default 2." },
    offset = { type = "integer", minimum = 0, description = "impact: initial live offset; prefer the returned cursor for continuation." },
    cursor = { type = "string", description = "impact: snapshot-bound continuation token; keep direction/depth unchanged." },
    from = { type = "string", description = "path: start identifier." },
    to = { type = "string", description = "path: end identifier." },
    limit = { type = "integer", minimum = 1, maximum = 200 },
    force = { type = "boolean", description = "index: reparse every file, even unchanged ones." },
    hours = { type = "integer", minimum = 1, maximum = 720, description = "audit_report: telemetry window, default 48 hours." },
    grade = { type = "integer", minimum = 0, maximum = 3, description = "audit_assess: 0 irrelevant/noisy; 1 related but no new information; 2 useful check/confirmation; 3 prompted a patch or test revision. This is your opinion, not a confirmed catch." },
    reason = { type = "string", description = "audit_assess: concrete reason tied to what you inspected." },
    critique = { type = "string", description = "audit_assess: specific graph limitation/noise, or say none observed." },
    evidence = { type = "string", description = "audit_assess: optional path:line or test/patch evidence; never paste secrets." },
    run_id = { type = "string", description = "audit_feedback: run with an audit lead." },
    outcome = { type = "string", enum = { "confirmed_catch", "false_positive", "unresolved" }, description = "audit_feedback: operator-reviewed outcome; never self-certify a catch." },
    commit = { type = "string", description = "audit_feedback: optional commit hash for evidence." },
    source = { type = "string", enum = { "native", "git" }, description = "audit/impact: native changeset or current Git working-tree patch; impact defaults to git." },
    cwd = { type = "string", description = "Source actions: indexed directory; defaults to the session worktree. Git audit/impact also collect the patch from this repository (subdirectories resolve to its root)." },
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
  schema("client", "Act on the user's machine at their request: screenshot, mouse, keyboard, a shell on their machine, and a browser (Chrome DevTools). Workspace-bound sessions cannot invoke client, including status; inspect tool_search/capabilities execution metadata first. After a runtime client failure ask `status`; after a workspace refusal do not retry client/status. Use `browser` to browse (target: open/read/list/eval/close/activate/quit) and `cdp` only as the low-level escape hatch. This is not how to inspect the wasm-agent UI - that is a page this node serves, so fetch it or load it in a headless browser.", {
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
    steps = { type = "array", items = { type = "object" }, description = "Steps: {kind=client|run|wait|assert|sentinel}. Run: {script, expect?, timeout_seconds?} - the script must print ONE JSON object on stdout (exit 0), and expect is an object naming fields of it, compared by equality; a string expect is refused, and 'stdout contains' is not a thing here. Retries allowed only with idempotent=true." },
    post = { type = "array", items = { type = "object" }, description = "REQUIRED. The assertions that settle the effect. Browser form {script, <operator>} evaluated by CDP. Node form {kind='run', script, expect={field=value}}: the command must print ONE JSON object on stdout and every named field must equal its value - a string expect is refused, an empty expect is refused, and a run check with no expect is refused. Use this for any effect a browser cannot see." } }, { "name", "steps", "post" }),
  schema("spell_compose", "Snapshot an already verified sequence into one spell. Preserves source pre/post checks and step retries, records source versions in its trace. No intervening inference; inspect and reconcile failures with inference before repairing or retiring a spell.", {
    name = { type = "string" }, description = { type = "string" },
    parts = { type = "array", items = { type = "object" }, description = "Ordered {name,params?} source spells. Parameters are exposed as p1_name, p2_name, etc.; provided values become defaults. Node spells with the same target only." } }, { "name", "parts" }),
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
  schema("remote", "Run a capability on another wasm-agent node (peer). Nodes are discovered by ed25519 key through the rendezvous, so the name or node_id is enough. Put the capability's own parameters at this same level, flat: {\"node\":\"<name>\",\"capability\":\"bash\",\"command\":\"ls\"} or {\"node\":\"<name>\",\"capability\":\"read\",\"path\":\"/etc/hosts\"} or {\"node\":\"<name>\",\"capability\":\"edit\",\"path\":\"...\",\"edits\":[{\"old_text\":\"...\",\"new_text\":\"...\"}]}: an edit there is the edit you know here - exactly-once match, the nearest region on a miss, the read-before-edit fence judged by what this session read on that node - and the change is recorded here, so /undo restores that file there. Text reads work; image results are refused until the node protocol has bounded binary transfer. Inside codemode tools.remote runs the read-only capabilities (read, ls, grep, sessions, session, search_messages, recall, read-only bash ...); effects run here, outside. capability:\"batch\" with calls:[{capability,...},...] runs up to 8 reads in one round trip.", {
    node = { type = "string", description = "Peer name or node_id (the nodes tool lists them)." },
    capability = { type = "string", description = "Tool to run on that node, e.g. bash, read, client, shell." },
    command = { type = "string", description = "For bash/shell: the command." },
    path = { type = "string", description = "For read/ls/write/edit: the path on that node." },
    args = { type = "object", description = "Optional older form: the capability's parameters nested here. Prefer the flat form." },
    calls = { type = "array", minItems = 1, maxItems = 8, description = "With capability \"batch\": 1-8 read-only entries {capability, <its params>} run on the peer in ONE signed round trip, ordered results. Reads, history and read-only bash only.",
      items = { type = "object", properties = { capability = { type = "string" } }, required = { "capability" } } }
    -- This schema does NOT declare the capability's own parameters and cannot: they are the other tool's
    -- (a bash `cwd`, an edit's `edits`, a read's `offset`). Saying so keeps the one argument validator from
    -- refusing a field `remote` is meant to forward - the open declaration is the honest one here, not a
    -- list that silently falls behind every capability it carries.
  }, { "node", "capability" }, { additionalProperties = true }),
  -- Item 4 of the node-ops round (#45): a build is graded against the bytes it embeds. A binary built
  -- from another commit, or from this commit with uncommitted edits under lua/ or rust/, is not this
  -- tree, and the answer says WHICH (fresh, stale, edited, unknown) instead of a bare yes.
  schema("build", "What this node is running against what the tree says: the binary path, sha256 and build commit; the tree HEAD, branch and whether the embedded paths are unmodified; and the relation between them (fresh, stale, edited or unknown). Call it before trusting a build or a test result, and after a rebuild. Unknown is never fresh.", {}),
  schema("nodes", "List this node and every peer known to the rendezvous.", {}),
  schema("session_debug", "Set a session's recording mode. debug keeps every turn verbatim and forever, so a failing task can be reproduced and exported as a fixture.", {
    session_id = { type = "string", description = "Defaults to the current session." },
    mode = { type = "string", enum = { "default", "debug" } } }, { "mode" }),
  schema("session_fixture", "Export a session (messages, tool calls, traces) as a reproducible fixture for regression tests.", {
    session_id = { type = "string", description = "Defaults to the current session." } }),
  -- Master only: it changes where a session's shell and file tools point, so it can move a
  -- guest's tools outside the tree a guest was scoped to.
  schema("session_worktree", "Inspect, allocate, recover or release this session's own git worktree. allocate/recover creates a clean worktree from the parent session (a dirty source refuses); release removes only a clean, inactive, merged one and keeps its branch. Run release from another conversation, never the run being removed.", {
    action = { type = "string", enum = { "status", "allocate", "recover", "release", "set", "clear" } },
    path = { type = "string", description = "set: an existing directory for a legacy non-managed session." },
    session_id = { type = "string", description = "Defaults to the current session." } }, { "action" }),
  schema("wave_autoflush", "Master coordinator only, outside code mode: one-time enable/off/status for durable SELF wave closure. Normal published-source review/integration plus the usual verified build is consumed automatically; no per-child accept, qualify, checklist, special build flag or runtime test gate. Optional accept/qualify are audit diagnostics only. Source/binary identity, native ownership and unknown-effect protections remain.", {
    action={type='string',enum={'enable','off','status','accept','qualify','reconcile'}}, request_id={type='string'}, revision={type='integer'}, child_id={type='string'}, tip={type='string'}, digest={type='string'}, sha={type='string'}, tree={type='string'}, binary_receipt={type='string'}, evidence={type='string'} }, {'action'}),
  schema("integrate", "Orchestration worker only: land your clean tested tip through canonical main under a repository claim, push and verify remote. Conflicts refuse for owned-tree refactoring; unknown effects must be inspected, never replayed. Does not deploy.", {}),
  schema("resource", "Inspect durable resource claims. Reconcile only after checking the recorded owner's effects; name the exact key, run, principal and evidence. Live owners cannot be released. No automatic timeout or effect replay.", {
    action={type="string",enum={"list","reconcile"}},key={type="string"},run={type="string"},
    principal={type="string"},evidence={type="string"} }, {"action"}),
}

-- The `*_many` tool schemas are NOT declared here any more (see RETIRED above): one name, one tool, and
-- the batch is a script. `graph` lost its `requests` compatibility form with them, `lua/core/batch_tools.lua`
-- (their shared item-shape helper) is deleted with the last caller, and no wrapper stays registered to keep
-- a second contract alive.

-- Operator schemas only: guest surfaces and artifact access do not expand.
-- WhatsApp (#118): ONE surface on every node - nine exact names, no namespace hash and no peer prefix.
-- The schemas live in `lua/core/whatsapp.lua`, beside the routing that answers them, so the description
-- a model reads and the call that runs cannot drift apart; this file only registers the family, the way
-- it registers every other built-in.
do
  local whatsapp = dofile('lua/core/whatsapp.lua')
  for _, entry in ipairs(whatsapp.schemas()) do M.admin[#M.admin+1] = entry end
end
-- Email (docs/EMAIL-CONNECTOR.md): the same two shapes as WhatsApp - an effect through the durable
-- outbox, questions through the query queue - with the connector as the only owner of the mailbox.
M.admin[#M.admin+1]=schema('email_send','Send one email yourself, through the durable email.outbox queue: the wa-email component submits it over SMTP and the answer here is a job id, not a delivery - read the outcome with email_send_status. Governance applies (the node policy email.send rule: rate limits, daily cap, audit), and a refusal comes back as an error word with nothing sent. Addresses are exact addr-specs (ana@example.com); a display name is refused. Attachments are small (a few KiB) and travel in the job payload as base64; bigger files are not supported yet. The same to+cc+subject+body+in_reply_to is one job, so a repeated call does not send twice.',{
 to={type='array',minItems=1,maxItems=50,items={type='string',maxLength=254},description='Recipients as exact addr-specs (local@domain). A bare number or a display name is refused.'},
 cc={type='array',maxItems=50,items={type='string',maxLength=254},description='Optional copies, same rule.'},
 subject={type='string',maxLength=900,description='One line. A control character is refused (it would be a header injection).'},
 body={type='string',maxLength=40000,description='The message body, plain text.'},
 in_reply_to={type='string',maxLength=250,description='Optional Message-ID to answer (a reply thread).'},
 attachments={type='array',maxItems=3,items={type='object',properties={filename={type='string',maxLength=200},mime={type='string',maxLength=127},bytes={type='string',description='base64 of the file'}},required={'filename','mime','bytes'}},description='Optional small attachments (24 KiB total, base64).'}},{'to','subject','body'})
M.admin[#M.admin+1]=schema('email_send_status','State of a message you asked email_send to send: queued, done with the message id the mail server gave it, or failed with a reason. An id this node never allocated is refused, not guessed.',{
 id={type='integer',minimum=1,description='The job id email_send returned.'}},{'id'})
M.admin[#M.admin+1]=schema('email_search','Search every email this node has indexed: subject, sender and the plain-text body, accent-folded, so "acao" finds "Acao" with an accent and "relatorio" finds "Relatorio". Narrow with at least one of q, from, subject, mailbox, since or until; the filters combine (since/until is a time window, epoch milliseconds, seconds accepted). The best match comes first (an exact phrase beats scattered words, a subject hit beats a body hit) and the answer is bounded: a search that matched more than it could return says truncated=true and matched=N. Attachment text is not searched; the attachment metadata is.',{
 q={type='string',maxLength=200,description='Words to look for (all of them must match). Accents and case are folded on both sides.'},
 ['from']={type='string',maxLength=200,description='Only messages whose sender (name or address) contains this.'},
 subject={type='string',maxLength=200,description='Only messages whose subject contains this.'},
 mailbox={type='string',maxLength=64,description='Only this mailbox (default: every indexed mailbox).'},
 ['since']={type='integer',description='Earliest message time, epoch milliseconds (seconds accepted).'},
 ['until']={type='integer',description='Latest message time, epoch milliseconds (seconds accepted).'},
 has_attachment={type='boolean',description='Only messages with (true) or without (false) an attachment.'},
 limit={type='integer',minimum=1,maximum=50,description='Most messages to return (default 20).'}},nil)
M.admin[#M.admin+1]=schema('email_read','Read one mailbox newest first, or one message by uid. A message carries its envelope, subject, the plain-text body (bounded) and attachment metadata - never the attachment bytes. Returns has_more and next_before: pass next_before back as before to read the next older page.',{
 mailbox={type='string',maxLength=64,description='The mailbox to read (default INBOX).'},
 uid={type='integer',minimum=1,description='Optional: read exactly this message instead of a page.'},
 before={type='integer',minimum=1,description='Optional: read older than this uid. Use next_before from the previous answer.'},
 limit={type='integer',minimum=1,maximum=50,description='Most messages to return (default 20).'}},nil)
M.admin[#M.admin+1]=schema('email_media','The attachment metadata of one indexed email: filename, mime, size and sha256 per attachment, plus the media handle a download names. No bytes; the connector keeps small attachments in its own state, bigger ones are metadata only and say downloadable=false.',{
 uid={type='integer',minimum=1,description='The message uid (as email_read shows it).'},
 mailbox={type='string',maxLength=64,description='Optional mailbox (default INBOX).'}},{'uid'})
M.admin[#M.admin+1]=schema('mcp','List/manage explicit MCP connectors. New/edited definitions remain disabled; probe never grants tool/send/job authority.',{
 action={type='string',enum={'list','put','probe','enable','disable','remove'}},id={type='string'},expected_revision={type='integer',minimum=0,description='Required for changes/probes: exact registry revision from list. Stale state refuses.'},definition={type='object',description='Reviewed connector: id/name, transport stdio or http, program/args or url, optional cwd, environment-reference env/headers, timeout_seconds; tools maps exact tool names to locally approved read/write.'}},nil)
M.admin[#M.admin+1]=schema('services','List/manage long-lived WASI service components (docs/SERVICE-COMPONENTS.md): put a definition (disabled), enable (start now and at boot), disable, restart, remove, status, logs, upgrade (transactional install of a new artifact: stage, verify pin, check imported interfaces are served, migrate state on a snapshot copy, retire the running instance, start the candidate, health, switch - one instance per service name at every step, and any failure puts the previous pin back), profile_dump (the effective configuration after base -> node -> user -> patch, rows by id), stt (the speech queue this node produces or works for: role, attached workers, their recent latency and the local/remote decode counts - ids and durations only, never a transcript; with set_role it becomes the durable role change a running node applies on its next tick, admin/master only and audited). Grants are references: env/file_env names or a file path, exact net addresses. A component whose manifest declares `state_version` is migrated on a snapshot copy of its kv before it starts, and the start answer reports it under `state` (`fresh`, `up-to-date` or `migrated` with the versions); a refused migration (`state_no_migration_path`, `state_owner_mismatch`) starts nothing and leaves the old state at its old version. Read a namespace, its journal and its snapshots with `host.state` (action status), not by asking the component.',{
 action={type='string',enum={'list','put','enable','disable','restart','remove','status','logs','upgrade','profile_dump','stt'}},name={type='string'},set_role={type='string',enum={'producer','worker','both','off'},description='stt: the speech role this node takes from now on, without a restart (admin/master only, audited). The environment, when set, still wins.'},producer={type='string',description='stt set_role on a worker: the producer node (name or id) to long-poll. Omit to keep the one already configured.'},expected_revision={type='integer',minimum=0,description='Required for changes: exact registry revision from list.'},bytes={type='integer',minimum=1,maximum=262144},ready_ms={type='integer',minimum=1,maximum=600000,description='upgrade: how long the new instance gets to report health before the old one is kept (default 10000).'},source={type='object',description='upgrade: the artifact to install - wasm (path to the built .wasm), manifest (object) or manifest_path (file), pin (sha256 or a .sha256 file). A component without a pin is refused; a candidate whose imports nobody serves, or that never becomes healthy, leaves the running instance untouched.'},definition={type='object',description='name (an installed kind:service component), env/file_env references, net addresses (host:port, *.suffix:port), config object.'}},nil)
M.admin[#M.admin+1]=schema('capture_inspect','Inspect retained JSON model-request captures as bounded structural metadata before reading raw dumps. Exact request/tool/message views and complete hash-bound originals remain available. No inference or app calls.',{
 path={type='string'},view={type='string',enum={'summary','request','tool','message'}},
 offset={type='integer',minimum=0},limit={type='integer',minimum=1,maximum=8},snapshot={type='string'},
 request_index={type='integer',minimum=1},item_index={type='integer',minimum=1}},{'path'})

M.admin[#M.admin+1]=schema('web_search','Search the public web; results keep their evidence behind a cache ref. Use it and web_read instead of curl for public pages; use curl in bash for authenticated APIs, POST or private hosts.',{query={type='string',maxLength=512},limit={type='integer',minimum=1,maximum=10},refresh={type='boolean'}},{'query'})
M.admin[#M.admin+1]=schema('web_read','Read a public HTTPS page (static text/HTML/JSON/XML) or a cache ref, paged by bytes. A challenge returns a human handoff: do not retry it with curl. pending_ref reads one async result.',{url={type='string'},ref={type='string'},pending_ref={type='string'},offset={type='integer',minimum=0},limit={type='integer',minimum=4,maximum=16384},refresh={type='boolean'}})
M.admin[#M.admin+1]=schema('node_update','Ask another node of the fabric to update ITSELF from distance - the node runtime, or the rendezvous where that node runs one. The peer performs it with its own Sentinel under its own rules (prebuilt binary when the commit is covered, disk floor, deploy lock, one outcome record); this tool only asks and reads back, it installs nothing itself and cannot run on a guest. "Queued" is not installed: `action="status"` reads the peer\'s own records (installed.txt, the installer\'s deploy-result.json and the sentinel\'s done/failed and deploy-outcome files) and answers once per request; a request made from a turn also schedules one wake so the outcome comes back to this session. Restating the target commit: with no `commit` the node installs origin/main; with `commit` it installs that landed commit and refuses one that is not on main, or that would need a reset.',{
  node={type='string',description='Peer name or node id.'},
  action={type='string',enum={'request','status','check'},description='request (default) asks for an install; status reads one back; check is read-only.'},
  commit={type='string',description='Full or short commit id that must be on origin/main; omitted means origin/main.'},
  rendezvous={type='boolean',description='Also update the rendezvous registry this node runs (scripts/deploy-rendezvous.sh, through that node\'s Sentinel).'},
  reason={type='string',maxLength=400,description='Why; recorded in the peer\'s audit record and its Sentinel log.'},
  id={type='string',description='status: the record id a request answered with.'},
  follow_up_seconds={type='integer',minimum=30,maximum=3600,description='Seconds before the session is woken to read the outcome (default 180).'},
},{'node'})

-- Which capability tier each tool belongs to (DESIGN.md §8). Anything not
-- listed here is a WASM plugin.
M.tier_of = {
  capture_inspect='environment',
  mcp='mcp', web_search='mcp', web_read='mcp', services='mcp',
  remember = "memory", recall = "memory", memories = "memory", forget = "memory",
  notes_read = "memory", notes_write = "memory", notes_append = "memory", notes_compact = "memory",
  done_criteria = "memory",
  wake = "sessions", wake_list = "sessions", wake_cancel = "sessions",
  skill = "skills",
  capabilities = "capabilities", tool_search='capabilities', tool_call='capabilities',
  subagent = "subagents",
  sessions = "sessions", session = "sessions", search_messages = "sessions",
  resume_session = "sessions", session_debug = "sessions", session_fixture = "sessions",
  session_worktree = "sessions",
  resource = "sessions", integrate = "sessions", wave_autoflush = "sessions",
  bash = "environment", read = "environment", write = "environment",
  diagnose = "environment", operation = "environment",
  edit = "environment", ls = "environment", grep = "environment", graph = "environment",
  shell = "shell",
  client = "client",
  spell_save = "spells", spell_run = "spells", spell_list = "spells",
  spell_get = "spells", spell_forget = "spells", spell_export = "spells", spell_compose = "spells",
  lessons = "memory", fleetview = "nodes",
  nodes = "nodes", remote = "nodes",
  node_update = "nodes",
}

local TIER_ORDER = {
  "memory", "sessions", "capabilities", "subagents", "environment", "shell",
  "client", "spells", "nodes", "mcp", "plugins",
}

-- The advertised tool surface, grouped by tier (not a complete model request).
function M.tiers(role)
  local groups = {}
  for _, item in ipairs(M.all(role)) do
    local name = item["function"].name
    local tier = (name:sub(1,4)=='mcp_' or name:sub(1,5)=='peer_') and 'mcp' or M.tier_of[name] or "plugins"
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

-- The prompt index's per-tool line: a short, authored *discovery cue*, never a slice of the
-- schema description. The two answer different questions - "is there a capability for
-- this?" against "how do I call it, and within what limits?" - so they are separate
-- artifacts. Deriving the cue with `description:match("^[^.]*")` duplicated the same text
-- in the index and the schema, and the description's opening sentence (written to start an
-- explanation) is a poor cue. A tool with no cue here (a plugin) is listed by name alone.
-- scripts/test-tool-cues.lua guards that every built-in has one and that none is stale.
local CUES = {
  time = "Ask this node's OS clock (local time with its offset)",
  remember = "Store a fact the user asked you to keep",
  recall = "Look up stored facts before answering about the user",
  memories = "List stored facts, with their ids",
  notes_read = "Read the plan/notes document you own for this session",
  notes_write = "Replace your session notes (previous version archived)",
  notes_append = "Append to your session notes",
  notes_compact = "Keep the last lines of your notes and archive the rest",
  done_criteria = "Record the acceptance checks a turn must pass, or close the gate on measured impossibility",
  wake = "Schedule your own next turn (time, event or repeating)",
  wake_list = "List your pending self-wakes",
  wake_cancel = "Cancel a pending self-wake by id",
  forget = "Delete a stored fact by id",
  skill = "Discover procedures by query or load a full skill by name",
  capabilities = "List the tools this account may use",
  tool_search = 'Discover and load a permitted tool definition',
  tool_call = 'Call a permitted tool by name without expanding permanent declarations',
  web_search='Search public web sources with retained evidence',
  web_read='Read a public source or page an immutable cache ref',
  subagent = "Start and collect a child agent on a bounded task",
  route_task = "Record whether this turn is done here or delegated (orchestration mode)",
  sessions = "List your past sessions",
  session = "Read a session, paging earlier evidence",
  search_messages = "Search your own past sessions for text",
  resume_session = "Fold a past session into this one as context",
  session_debug = "Set a session's recording mode (debug or default)",
  session_fixture = "Export a session as a reproducible fixture",
  session_worktree = "Point this session's tools at their own checkout",
  resource = "Inspect resource ownership and reconcile interrupted effects",
  bash = "Run a shell command on this machine",
  operation = "Run or collect a supervised long command",
  read = "Read a file (text or image), paged",
  write = "Create or overwrite a file",
  edit = "Replace a versioned range returned by read",
  ls = "List a directory",
  grep = "Find lines matching literal text",
  graph = "Retrieve symbol source, trace relationships, or audit patch impact",
  diagnose = "Run a fixed read/grep check sequence once",
  client = "Act on the user's machine: screen, mouse, keyboard, browser",
  shell = "Run a shell command on the client machine",
  wave_autoflush = "Control coordinator acceptance and durable wave-end installation obligation",
  integrate = "Land an orchestration worker's tested tip; never deploy",
  mcp = "List and manage MCP connectors; new or edited ones stay disabled until enabled",
  services = "List and manage long-lived WASI service components: start, stop, logs",
  mcp_whatsapp_contacts = "Which WhatsApp chat a name means, with the candidates when a name is ambiguous",
  mcp_whatsapp_search = "Search every indexed WhatsApp message by text, chat, kind, sender or time window",
  mcp_whatsapp_read = "Read one WhatsApp chat by JID or name, newest first, with a header and a cursor",
  mcp_whatsapp_reactions = "Who reacted to one WhatsApp message, with which emoji",
  mcp_whatsapp_media = "The media metadata of one WhatsApp message: mime, filename, size, sha256, duration",
  mcp_whatsapp_download = "Decrypt one WhatsApp message's media on the account node and return its file path there",
  mcp_whatsapp_backfill = "Ask the phone for older WhatsApp messages so search covers the account's past",
  mcp_whatsapp_send = "Send one WhatsApp message to an exact chat and answer WhatsApp's message id or its reason",
  email_send = "Send one email through the durable outbox, with the message id readable afterwards",
  email_send_status = "Read the state of a queued email send, with its message id when delivered",
  email_search = "Search every indexed email by text, sender, subject, mailbox or time window",
  email_read = "Read one mailbox newest first, or one message by uid, with its attachments listed",
  email_media = "The attachment metadata of one email, with the handle a download names",
  capture_inspect = "Inspect retained model-request captures as bounded metadata before reading raw dumps",
  node_update = "Ask another node to update itself, and read its outcome",
  spell_save = "Save a verified command sequence as a reusable spell",
  spell_run = "Replay a saved spell",
  spell_compose = "Combine a verified spell sequence with its checks intact",
  spell_list = "List saved spells",
  spell_get = "Read one saved spell in full",
  spell_forget = "Delete a saved spell",
  spell_export = "Export a spell for the sentinel to run",
  remote = "Run a capability on another node",
  build = "What this node is running against the tree: binary path, sha256 and build commit, and the verdict between them (fresh, stale, edited, unknown)",
  nodes = "List this node and its peers",
  fleetview = "One read-only view of the whole fleet: liveness, version, health, disk, components, work, incidents",
  lessons = "Recall or add what this fleet learned the hard way (symptom, cause, fix, rule)",
  tool_result = "Read an exact byte range of a truncated tool result",
}

function M.snippet(name) return CUES[name] end

-- THE CUE NAMES ARE THE ONES THE INDEX CAN USE. A cue belongs to a tool, and the graph's tool is not in the
-- catalogue while the feature is dormant (docs/GRAPH.md): reporting its cue would be the same lie as
-- offering the tool. The cue text itself stays in the table, so switching the graph on brings its index
-- line back without a second edit.
function M.cue_names()
  local names = {}
  local graph = graph_offered()
  for name in pairs(CUES) do
    if graph or name ~= 'graph' then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- Every schema a role may load or delegate, before prompt visibility. This is the
-- *catalog*: what the principal can execute or hand to a child. Prompt visibility is a
-- separate projection (`M.all`), because advertising a tool the principal cannot execute
-- is not the same as authorizing it - and hiding one from the prompt must not revoke the
-- authority to delegate it.
function M.catalog(role)

  role = role or "admin"
  local list = {}
  for _, item in ipairs(M.shared) do list[#list + 1] = item end
  if is_master(role) then
    list[#list+1]=schema("tool_result","Retrieve an exact byte range of a full tool result saved after output truncation. Use the full_result.sha256 from the result, then follow next_offset until eof.",{
      sha256={type="string"},offset={type="integer",minimum=1},limit={type="integer",minimum=1,maximum=51200}
    },{"sha256"})
    -- Orchestration mode's routing decision. It stays in the catalog so its definition and cue
    -- are registered, but `M.all` shows it only to a coordinator whose conversation has the mode
    -- on (and dispatch re-checks). Recording a route is not an action: nothing starts or runs.
    list[#list+1]=schema('route_task','Orchestration mode only: record how this user turn is routed before any effect runs. `direct` for a quick answer, a read-only inspection or a short one-step task you will do here; `delegate` for a concrete implementation or multi-step change, which you then hand to a subagent with the bounded prompt and context. State the task in your own words (never a copy of the raw user text) and a one-line reason. A concrete implementation routed direct is a misroute, not a shortcut, and blind delegation is a failure too. Recording a route starts no child and executes nothing.',{
      route={type='string',enum={'direct','delegate'}},
      task={type='string',description='One sentence: the task as you understood it, in your own words.'},
      reason={type='string',description='One line: why this route - a quick answer, read-only or short one-step work, or a concrete implementation or multi-step change.'}
    },{'route','task'})
    for _, item in ipairs(M.admin) do list[#list + 1] = item end
    if host.quickjs then
      -- The native transport of the same action (docs/AGENT-SEAT.md, principle 2): the run tool is the
      -- fenced js run block as a tool call, so a model that prefers tool calls acts the same way and its
      -- results come back through the same pathway.
      local run_tool=dofile('lua/core/raw_code.lua').run_tool_schema()
      list[#list+1]=schema(run_tool.name,run_tool.description,run_tool.schema.properties,run_tool.schema.required)
      list[#list+1]=schema('codemode','JavaScript sandbox that calls approved native tools: await tools.<name>(args), text(value), return. Preferred for multi-step programmatic work. Connector tools (MCP servers such as mail and WhatsApp, peers) are callable only here; peers are read with tools.remote. searchTools("text"|"*") finds tools (searchTools("select:a,b") adds their schemas). Await every call; effectful calls run serially. A call still running after wait_s (default 60) returns {state:"pending", op}; wait(op | [ops]) resumes it and batches with other calls. No filesystem, network or Node APIs. '..dofile('lua/core/raw_code.lua').BATCHING:gsub('run%(code%)','codemode')..'',{code={type='string'},timeout_ms={type='integer',minimum=1,maximum=300000}},{'code'})
    end
    for _, item in ipairs(mcp.schemas()) do list[#list+1]=item end
    -- Every online peer's connectors, run on that peer (lua/core/federation.lua). Masters only.
    if is_master(role) then
      local fok, federated = pcall(function() return dofile('lua/core/federation.lua').schemas() end)
      for _, item in ipairs(fok and federated or {}) do list[#list+1]=item end
    end
    local plugins=wasm_plugins()
    table.sort(plugins,function(a,b)return tostring(a.name)<tostring(b.name) end)
    for _, plugin in ipairs(plugins) do
      list[#list + 1] = schema_from(plugin.name, plugin.description or "", plugin.parameters)
    end
  end
  -- THE GRAPH IS OFF BY DEFAULT (docs/GRAPH.md, 23/11), and a dormant feature costs the model nothing: no
  -- catalogue line, no `searchTools` hit, no schema bytes in the prompt. One filter over the assembled
  -- list, because the graph arrives by several roads (its own admin schema, a plugin, a peer's connector)
  -- and a rule that hid only one of them would be a rule with a hole in it. Asked per build, so the switch
  -- reaches the next turn without a restart.
  if not graph_offered() then
    local kept = {}
    for _, item in ipairs(list) do
      if (item['function'] or {}).name ~= 'graph' then kept[#kept + 1] = item end
    end
    list = kept
  end
  return list
end

-- Tools the prompt must not offer, though the catalog keeps them executable; a child still
-- receives them through `all_for`, which reads the catalog.
local PROMPT_HIDDEN = {}
PROMPT_HIDDEN.integrate=true -- Task-owner-only; parent cannot execute it. Child all_for reads catalog.
PROMPT_HIDDEN.route_task=true -- Orchestration-mode-only; `M.all` re-adds it for that coordinator.

-- The mode's own coordinator surface. `subagent` is declared from the start in orchestration
-- mode (no tool_search discovery), and `route_task` records the turn's routing decision. Both
-- stay absent when the mode is off, and a child never sees either.
local function orchestration_surface(role,ctx)
  if not is_master(role or 'guest') then return false end
  if not ctx or ctx.subagent then return false end
  local ok,mode=pcall(orchestration)
  return ok and mode.mode_on(ctx) or false
end

-- The schemas a role's prompt shows, and what `capabilities` reports.
local codemode_policy=dofile('lua/core/codemode_policy.lua')
local function show_codemode(role,ctx,memory)
  if ctx then return codemode_policy.pin(memory,role,ctx).enabled end
  -- Schema-only legacy callers cannot establish default workspace eligibility.
  return codemode_policy.setting()=='native' and host.quickjs~=nil
end
-- The email index tools answer only where a wa-email service is stored and enabled (the dispatcher
-- refuses them elsewhere with email_component_absent). A tool the node cannot run is not offered: 17/11 on
-- work the model saw five email_* tools that could only fail. Read once a minute - it is a local read.
local EMAIL_TOOLS={email_search=true,email_read=true,email_media=true,email_send=true,email_send_status=true}
local email_seen={at=-1,served=true}
local function email_served()
  local now=tonumber(host.now()) or 0
  if now-email_seen.at<60 then return email_seen.served end
  local served=true
  local ok,inv=pcall(function() return dofile('lua/core/services.lua').inventory() end)
  if ok and type(inv)=='table' and type(inv.services)=='table' then
    served=false
    for _,service in ipairs(inv.services) do if service.name=='wa-email' and service.enabled~=false then served=true end end
  end
  email_seen.at,email_seen.served=now,served
  return served
end
M.email_served=email_served

-- Whether this session has a worktree to inspect or bind. A session that needs none is not offered
-- `session_worktree`: on a node with no wave registration the model called it three times in a row
-- instead of working (18/11), and a tool that answers nothing is worse than absent. It stays
-- dispatchable, so a caller that names it by hand is still answered.
local function offers_worktree(ctx, memory)
  if not ctx or not ctx.session_id then return false end
  memory = memory or dofile('lua/core/memory.lua')
  local ok, workspace = pcall(memory.session_workspace, ctx.session_id)
  if ok and type(workspace) == 'table' then
    if workspace.required == true then return true end
    local state = tostring(workspace.state or '')
    if state ~= '' and state ~= 'unbound' then return true end
  end
  local bound_ok, bound = pcall(memory.session_worktree, ctx.session_id)
  return bound_ok and type(bound) == 'string' and bound ~= ''
end

function M.all(role,ctx,memory)
  local shown = {}
  local code=show_codemode(role,ctx,memory)
  local orchestration=orchestration_surface(role,ctx)
  local email=nil
  for _, item in ipairs(M.catalog(role)) do
    local name=item['function'].name
    local visible=not PROMPT_HIDDEN[name] and (name~='codemode' or code)
    if name=='route_task' then visible=orchestration end
    if visible and EMAIL_TOOLS[name] then
      if email==nil then email=email_served() end
      visible=email
    end
    if visible then shown[#shown + 1] = item end
  end
  return shown
end

function M.envelope(role,ctx)
  ctx=ctx or {};ctx.role=role or 'guest'
  local list=M.all(role,ctx,dofile('lua/core/memory.lua'))
  -- A session that needs no worktree is NOT OFFERED the tool that binds one (item 3, 18/11): with no
  -- workspace to inspect, `status` answered nothing a model could act on and it called the tool three
  -- times in a row until the repetition guard ended the turn. It stays in the catalogue, so
  -- `searchTools` and a caller that names it still reach it: out of sight at the top level, not out of
  -- reach (the same rule as the outer facades, 29/10).
  if not offers_worktree(ctx,nil) then
    local kept={}
    for _,item in ipairs(list) do
      if ((item['function'] or {}).name or '')~='session_worktree' then kept[#kept+1]=item end
    end
    list=kept
  end
  -- With code mode on, connectors are reached through it alone; the prompt names them in its hint.
  if codemode_policy.enforced(ctx) then
    local outer={}
    for _,item in ipairs(list) do if not codemode_policy.connector(item['function'].name) then outer[#outer+1]=item end end
    list=outer
  end
  -- ONE PATH (Victor 21/11): no mode empties the declared surface any more, so the ordinary tools are
  -- always declared beside the run tool. A list that hides some tools only moves the shortcut to the
  -- next one (measured 17/11: bash hidden, the model called `session_worktree` three times and the
  -- repetition guard stopped the turn).
  return envelope.schemas(list,ctx),envelope.mode(ctx)
end

-- Tool schemas restricted to an exact allowed set (a subagent profile). The
-- schema list is one half of the boundary; `dispatch` re-checks the same set. It reads the
-- catalog, not the prompt projection, so a tool hidden from a parent can still be
-- delegated to the child whose profile names it.
function M.all_for(allowed, role,ctx,memory)
  local out = {}
  local code=show_codemode(role,ctx,memory)
  for _, item in ipairs(M.catalog(role or "master")) do
    local name = item["function"].name
    if allowed and allowed[name] and (name~='codemode' or code) then out[#out + 1] = item end
  end
  table.sort(out, function(a, b) return tostring(a["function"].name) < tostring(b["function"].name) end)
  return out
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- THE CALLER'S DIRECTORY GOES WITH A PEER CALL (24/11). A peer runs under the synthetic session
-- `peer:<node_id>`, which has no worktree and no recorded directory on the RECEIVING node, so its bash or
-- operation otherwise starts in whatever directory that node's serving process happens to be in - measured:
-- the canonical checkout. The caller's own directory is a fact this side has, so it travels as an ordinary
-- `cwd` argument (the receiving side records it as `source = "explicit"`, honestly: it came from the
-- caller, not from a session there). Nothing is invented: no directory on this side means no cwd is added,
-- and the peer's answer says the node's own directory was used.
-- Forward declaration: a Lua local is in scope only from its definition, and this file is one chunk, so the
-- helper below would otherwise call the GLOBAL of that name, which is nil (measured: tools.lua:1097, caught by
-- scripts/test-federation.lua before this shipped). Assigned right after session_cwd is defined.
local session_cwd_for_peer
local function peer_args_with_cwd(memory, ctx, capability, args)
  if capability ~= "bash" and capability ~= "operation" then return args end
  if type(args) ~= "table" then return args end
  if args.cwd ~= nil and args.cwd ~= "" then return args end
  local cwd = session_cwd_for_peer and session_cwd_for_peer(memory, ctx) or ""
  if cwd == "" then return args end
  local copy = {}
  for key, value in pairs(args) do copy[key] = value end
  copy.cwd = cwd
  copy.cwd_source = "caller_session"
  return copy
end

-- The directory this session's tools operate in. "" is the node's own working directory - the
-- behavior every session had before a session could own a worktree - so an untouched session is
-- unchanged. `memory` may be nil (a schema-only dispatch), which is why this is guarded.
-- The session's directory AND where it came from, so a receipt can be honest about it (24/11):
-- "worktree" (a bound checkout), "run" (the directory its first run was served from) or "node" (nothing
-- recorded - the node's own directory, which is the old behaviour and now the ONLY case that borrows it).
local function session_dir(memory, ctx)
  if not memory or not ctx or not ctx.session_id then return "", "node" end
  if memory.session_worktree then
    local ok, path = pcall(memory.session_worktree, ctx.session_id)
    if ok and type(path) == "string" and path ~= "" then return path, "worktree" end
  end
  -- THIS TURN'S OWN DECISION, when the run that is serving it made one (an attended run re-records the
  -- person's terminal directory, lua/core/agent.lua M.record_run_directory). It travels in the context, so the
  -- prompt's directory, this answer and the child's cwd are one tree for the length of the turn.
  if type(ctx.run_dir) == "string" and ctx.run_dir ~= "" then return ctx.run_dir end
  if memory.session_cwd then
    local ok, run = pcall(memory.session_cwd, ctx.session_id)
    if ok and type(run) == "string" and run ~= "" then return run, "run" end
  end
  return "", "node"
end

local function session_cwd(memory, ctx)
  if not memory or not ctx or not ctx.session_id then return "" end
  if memory.session_worktree then
    local ok, path = pcall(memory.session_worktree, ctx.session_id)
    if ok and type(path) == "string" and path ~= "" then return path end
  end
  -- THE DIRECTORY THE SESSION'S FIRST RUN WAS SERVED FROM (24/11). With no worktree this used to answer
  -- "" - "the node's own directory" - and the child inherited whatever process served the turn, so the
  -- same session ran in its mission directory under the CLI and in the canonical checkout when the NODE
  -- served it (resume after a deploy pause, a wake, a peer's call). Measured by change/worker-write-guard
  -- (docs/missions/reports/worker-write-guard.md, section 15). A worktree still WINS: a bound checkout is a
  -- stronger statement than a starting directory.
  if memory.session_cwd then
    local ok, run = pcall(memory.session_cwd, ctx.session_id)
    if ok and type(run) == "string" and run ~= "" then return run end
  end
  return ""
end

-- A SESSION DIRECTORY THAT IS GONE IS REFUSED BY NAME (24/11), never silently replaced. The node's own
-- directory is not this session's: substituting it is how an operation came to run in the canonical
-- checkout, and a silent substitution also turns "your worktree was released" into a write in the wrong
-- tree. Answers nil when there is nothing to refuse (no directory, or it is there).
session_cwd_for_peer = session_cwd

local function session_cwd_refusal(path)
  if type(path) ~= "string" or path == "" then return nil end
  if not host.list_dir then return nil end
  local ok, raw = pcall(host.list_dir, path)
  if not ok then return nil end
  -- Three shapes, each decided explicitly: a table (this host), a JSON string (the shape the workspace
  -- preflight reads), or something this code does not understand - and an answer it cannot read is NOT
  -- "gone", because refusing a valid directory is worse than letting the launch fail loudly.
  local decoded = raw
  if type(decoded) == "string" then
    local good
    good, decoded = pcall(json.decode, raw)
    if not good then return nil end
  end
  if type(decoded) ~= "table" then return nil end
  if decoded.error == nil then return nil end
  return { error = "session_cwd_gone", cwd = path, cwd_source = "session_run", effect = "none",
    note = "this session's directory (" .. path .. ") is not there any more, so nothing was started. The node "
      .. "does not substitute its own directory for a session's: bind a worktree (session_worktree) or pass "
      .. "cwd explicitly." }
end

-- Resolve a tool path against the session's directory. An absolute path is left alone; a relative
-- path joins the session's worktree, so `read foo.lua` reads the session's copy, not the node's.
-- With no session worktree the path is unchanged and the host resolves it against the node cwd.
-- The before/after text a change record needs, bounded by the store that will hold it (mission
-- remote-edit-first-class, item 2). A text past the cap is not sent at all: the row says why, instead of
-- putting a megabyte through the relay only for the receiving store to refuse it.
local function change_for_wire(change)
  if type(change) ~= "table" then return nil end
  local path, before, after = change.path, change.before, change.after
  if type(before) ~= "string" or type(after) ~= "string" then
    return { path = path, recorded = false, reason = "text_unavailable" }
  end
  if #before > changeset.RECORD_CAP or #after > changeset.RECORD_CAP then
    return { path = path, recorded = false, reason = "larger_than_record_cap" }
  end
  return { path = path, before = before, after = after, recorded = true }
end

-- The page record of a CALLER ON ANOTHER NODE, as this node's `edit` takes it (server.lua
-- wa_peer_dispatch hands it over from the signed body): nil when the caller predates the field - this
-- node's own record for that caller is then used exactly as before - false when the caller's own
-- process says this session was served nothing for the file, and the record itself otherwise. Any other
-- shape becomes `{}`, which `file_tools.edit` refuses by name (`edit_read_page_invalid`) rather than
-- reading as "no record" and turning the fence off.
local function remote_pages(ctx)
  local envelope = ctx and ctx.read_pages
  if envelope == nil then return nil end
  -- Not "and ... or nil": a bare `false` here is the caller saying it served this session NOTHING, and
  -- collapsing it to nil would read as "an older caller" - the one answer that silently changes which
  -- record the fence uses.
  local record
  if type(envelope) == "table" then record = envelope.record end
  if record == false then return false end
  if type(record) == "table" then return record end
  return {}
end

local function resolve_path(memory, ctx, path)
  if type(path) ~= "string" or path == "" then return path end
  local first = path:sub(1, 1)
  if first == "/" or first == "~" or path:match("^%a:[/\\]") or path:sub(1, 2) == "\\\\" then
    return path
  end
  local base = session_cwd(memory, ctx)
  if base == "" then return path end
  return (base:gsub("[/\\]+$", "")) .. "/" .. path
end

local function normalized_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  local drive = path:match("^(%a:)") or ""
  path = path:gsub("^%a:", "")
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) else parts[#parts + 1] = part end
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return drive .. "/" .. table.concat(parts, "/")
end

local function inside_workspace(root, path)
  local base, candidate = normalized_path(root), normalized_path(path)
  if platform.os() == "windows" then base, candidate = base:lower(), candidate:lower() end
  return candidate == base or candidate:sub(1, #base + 1) == base .. "/"
end

-- Resolve the nearest existing ancestor before granting scratch access. Missing host
-- support fails closed; junctions/symlinks cannot turn staging into another-tree writes.
local function inside_scratch(root, target)
  local paths = dofile("lua/core/paths.lua")
  if not inside_workspace(root, target) or not host.canonical_path then return false end
  local data = host.canonical_path(paths.data())
  if not data then return false end
  local probe = normalized_path(target)
  while probe ~= '' do
    local real = host.canonical_path(probe)
    if real then
      local expected = normalized_path(probe)
      local lexical_data = normalized_path(paths.data())
      if not inside_workspace(lexical_data, expected) then return false end
      local suffix = expected:sub(#lexical_data + 1)
      local actual, expected_real = normalized_path(real), normalized_path(data .. suffix)
      if platform.os() == 'windows' then actual, expected_real = actual:lower(), expected_real:lower() end
      return actual == expected_real
    end
    local parent = probe:match('^(.*)/[^/]+$')
    if not parent or parent == probe then return false end
    probe = parent
  end
  return false
end

local function target_identity(path)
  local probe,suffix=path,''
  while host.canonical_path and probe~='' do
    local real=host.canonical_path(probe)
    if real then path=real..suffix;break end
    local parent,leaf=probe:gsub('\\','/'):match('^(.*)/([^/]+)$')
    if not parent then
      local cwd=host.canonical_path('.')
      if cwd then path=cwd..'/'..probe..suffix end
      break
    end
    if parent==probe then break end
    suffix='/'..leaf..suffix;probe=parent
  end
  -- Rust canonicalize uses Windows verbatim prefixes; compare the same path
  -- representation as ordinary workspace bindings, without changing authority.
  path=tostring(path):gsub('\\','/')
  if platform.os()=='windows' then
    path=path:gsub('^//%?/[Uu][Nn][Cc]/','//'):gsub('^//%?/','')
  end
  path=normalized_path(path)
  return platform.os()=='windows' and path:lower() or path
end

local WORKSPACE_UNSUPPORTED={shell=true,client=true,remote=true,spell_run=true}
local WORKSPACE_FIXED={write=true,edit=true,bash=true,codemode=true}
local function workspace_effectful(name,args)
  return WORKSPACE_FIXED[name] or WORKSPACE_UNSUPPORTED[name]
    or name=='mcp' and args.action=='probe'
    or name:sub(1,4)=='mcp_' and not mcp.is_read(name)
    or name:sub(1,5)=='peer_' and not dofile('lua/core/federation.lua').is_read(name)
    or name=='operation' and (args.action or '')=='start'
end

-- Pure, caller-scoped discovery: read one workspace snapshot, never probe a client,
-- app or executor. The scope is workspace policy only, not complete executability.
function M.discovery_execution(memory,ctx)
  local workspace,unreadable
  if memory and ctx.session_id and memory.session_workspace then
    local ok,value=pcall(memory.session_workspace,ctx.session_id)
    if ok and (value==nil or type(value)=='table') then workspace=value else unreadable=true end
  end
  local required=workspace and workspace.required and true or false
  local summary={scope='workspace_policy_only',required=required,
    state=unreadable and 'unknown' or required and (workspace.state or 'unknown') or 'not_required'}
  if unreadable then summary.required=nil end
  local function describe(name)
    local conditional=name=='operation' or name=='mcp' or name:sub(1,4)=='mcp_' or name:sub(1,5)=='peer_'
    local affected=WORKSPACE_FIXED[name] or WORKSPACE_UNSUPPORTED[name] or conditional
    local binding=WORKSPACE_UNSUPPORTED[name] and 'unsupported'
      or conditional and 'action_dependent' or WORKSPACE_FIXED[name] and 'supported' or 'not_applicable'
    local result={scope='workspace_policy_only',workspace_binding=binding,status='not_blocked'}
    if not affected then return result end
    if unreadable then result.status='unknown';result.reason='workspace_metadata_unreadable';return result end
    if not required then return result end
    if conditional then
      result.status='argument_dependent'
      result.reason='workspace_preflight_required'
      result.detail=name=='operation' and 'Only start requires a valid bound workspace/cwd; observations remain separately checked.'
        or 'Probe and non-read MCP calls do not support enforced workspaces; reads and registry actions retain their own checks.'
      return result
    end
    if workspace.state~='allocated' or not workspace.worktree or workspace.worktree=='' then
      result.status='blocked';result.available=false;result.reason='session_workspace_unavailable'
      result.detail='Required workspace has no allocated durable binding; do not fall back to another tree.'
    elseif WORKSPACE_UNSUPPORTED[name] then
      result.status='blocked';result.available=false;result.reason='workspace_execution_context_unsupported'
      result.detail='This capability does not accept an enforced session worktree binding.'
      result.next=name=='client' and 'Do not invoke client or retry status. Provide an existing artifact link or report the limitation; never bypass the binding with another executor.'
        or 'Use only an explicitly supported, authorized node-local procedure with equivalent checks; never bypass the binding.'
    else
      result.status='argument_dependent';result.reason='workspace_preflight_required'
      result.detail='Invocation still validates the bound directory, requested path/cwd and native permissions.'
    end
    return result
  end
  return describe,summary
end

local function required_workspace_error(memory, ctx, name, args)
  local writes_files=workspace_effectful(name,args)
  if not writes_files or not memory or not ctx.session_id or not memory.session_workspace then return nil end
  local workspace = memory.session_workspace(ctx.session_id)
  if not workspace or not workspace.required then return nil end
  if workspace.state ~= "allocated" or not workspace.worktree or workspace.worktree == "" then
    return {error="session_workspace_unavailable",state=workspace.state or "unknown",
      detail=workspace.error or "required workspace has no durable binding"}
  end
  if WORKSPACE_UNSUPPORTED[name] or name=='mcp' or name:sub(1,4)=='mcp_' or name:sub(1,5)=='peer_' then
    return {error="workspace_execution_context_unsupported",tool=name,
      detail="this capability does not yet accept an enforced session worktree binding"}
  end
  if host.list_dir then
    local ok, raw = pcall(host.list_dir, workspace.worktree)
    local good, result = ok and pcall(json.decode, raw) or false, nil
    if good then result = json.decode(raw) end
    if not good or type(result) ~= "table" or result.error then
      return {error="session_workspace_unavailable",state="binding_missing",detail="bound workspace directory is unavailable"}
    end
  end
  if name == "write" or name == "edit" then
    local target = resolve_path(memory, ctx, args.path)
    local scratch = workspaces.scratch_root(ctx.session_id)
    if target and scratch and inside_scratch(scratch, target) then return nil end
    if target and not inside_workspace(workspace.worktree, target) then
      return {error="workspace_path_outside_binding",path=target,
        allowed_writes={workspace.worktree,scratch}}
    end
  elseif (name == "bash" or name == "operation" and args.action == "start") and args.cwd and args.cwd ~= "" then
    local cwd = args.cwd
    if cwd:sub(1,1) ~= "/" and not cwd:match("^%a:[/\\]") and cwd:sub(1,2) ~= "\\\\" then
      cwd = workspace.worktree:gsub("[/\\]+$", "") .. "/" .. cwd
    end
    local scratch = workspaces.scratch_root(ctx.session_id)
    if not inside_workspace(workspace.worktree, cwd)
        and not (scratch and inside_scratch(scratch, cwd)) then
      return {error="workspace_cwd_outside_binding",cwd=args.cwd,
        allowed_writes={workspace.worktree,scratch}}
    end
    args.cwd = cwd
  end
  return nil
end

local function launch_cwd(memory, ctx, requested, asked_source)
  local workspace = memory and ctx.session_id and memory.session_workspace and memory.session_workspace(ctx.session_id)
  -- `session` is not a launch detail: it is WHOSE work this is. The operation record carries it, so the
  -- shell an agent starts belongs to the session that asked and to no other (session isolation,
  -- findings 1 and 2). An empty value stays empty - a call nobody names is nobody's.
  -- THE SOURCE IS A FACT, NOT A GUESS (24/11): explicit | caller_session (a peer's directory travelled with
  -- the call) | session_workspace | session_run (the directory the session's first run was served from) |
  -- node (nothing recorded - the node's own directory, the only case that borrows it).
  local source
  if requested ~= nil and requested ~= "" then
    source = (asked_source == "caller_session") and "caller_session" or "explicit"
  else
    local _, from = session_dir(memory, ctx)
    source = (from == "worktree") and "session_workspace" or (from == "run") and "session_run" or "node"
  end
  return {requested=requested or "", source=source,
    required=workspace and workspace.required == true or false, session=(ctx and ctx.session_id) or ""}
end

local function run(command, timeout_seconds, cwd, provenance, stdin)
  -- Set the process launch directory, never hide it in shell command text. Later shell `cd`
  -- remains command behavior, not something the operation receipt claims to observe.
  -- A recursive delete of a protected path never reaches the shell: the guard names the path and the
  -- rule. init.lua installs the same check around `host.exec`; this is the second wall, because a test
  -- or a host that swaps `host.exec` after init would otherwise be enough to lose a home.
  local allowed, refused = path_guard.command(command, cwd)
  if not allowed then return { error = refused, effect = "none", blocked_by = "path_guard" } end
  -- stdin (5th): the caller's text for the command's own standard input, fed by the one spawn path. Absent
  -- is the null device, which is what every call without it got before the argument existed.
  local ok, raw = pcall(host.exec, path_guard.wrap(command), cwd or "", timeout_seconds, json.encode(provenance), stdin)
  if not ok then return { error = tostring(raw) } end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return { error = tostring(raw) } end
  return decoded
end

-- The one client action that only reports and holds no state on the client. It takes no
-- claim, because a held or uncertain effect claim must never stop a caller from asking
-- the client what it is doing - that answer is how a refusal is diagnosed and how an
-- uncertain effect gets inspected. `screenshot` and `frame` deliberately keep the
-- claim: the client writes one screenshot file per client and the frame action keeps a
-- diff cache, so both are stateful even though they only look.
local OBSERVING_CLIENT_ACTIONS={status=true}

-- The run that owns an uncertain `client:local` claim may use the client again once
-- it has looked at the thing it owns. Two limits keep this from being a blind retry:
-- only the owning run in the granting process may do it, and the evidence must be the
-- client's own answer - a disconnected or still-busy client is a real answer, and it
-- refuses. The actions that were lost are never replayed; only a new request proceeds.
local function reuse_own_client_claim(ctx,refused)
  local prior=type(refused)=="table" and refused.claim
  if type(prior)~="table" or prior.key~="client:local" or prior.uncertain~=true
      or prior.run~=ctx.run_id or prior.principal~=ctx.user_id then
    refused.observed=refused.observed or
      "client:local is held by someone else, and only an owner may clear its own uncertainty"
    refused.next=refused.next or
      "read it with client{action:'status'} or resource{action:'list'}; another owner's claim needs an operator's reconcile"
    return refused
  end
  local ok,raw=pcall(host.client,"status",json.encode({action="status"}))
  local seen=ok and json.decode(raw) or nil
  local busy=type(seen)=="table" and type(seen.busy)=="table" and (seen.busy.action or seen.busy.id) or nil
  if type(seen)~="table" or seen.connected~=true or busy then
    local because="the client did not answer"
    if type(seen)=="table" and seen.connected~=true then because="the client is not connected" end
    if busy then because="the client is still running "..tostring(busy) end
    refused.observed="this run owns client:local as an uncertain effect, and "..because
    refused.next="inspect it with client{action:'status'} or client{action:'screenshot'}, "..
      "then decide: no operator action is needed for your own claim once the client is idle"
    return refused
  end
  local recovered=resources.recover(ctx,"client:local",
    "this run's client call failed without a receipt; the client answered status as connected and idle, "..
    "the lost action was not replayed")
  if not recovered.ok then
    refused.observed="the client answered status, but this run could not clear its own uncertain claim"
    refused.detail=recovered
    return refused
  end
  return resources.claim(ctx,{"client:local"})
end

local function graph_hint(memory,ctx,path)
  -- A DORMANT NODE CALLS NOTHING (docs/GRAPH.md): no hint is sent, so no scheduler entry, OS watch or
  -- store can appear because a file was written. The write's answer carries no `graph_index` field at
  -- all, which is the truth - there is no graph here to tell.
  if not graph_offered() then return nil end
  if type(host.graph_notify)~='function' then return {error='graph_notify_unavailable'} end
  local root,err=patch_audit.workspace_root(memory,ctx)
  if err then return {error=err} end
  local called,raw=pcall(host.graph_notify,json.encode({root=root,path=path}))
  return called and json.decode(raw or '') or {error='graph_notification_failed',detail=tostring(raw)}
end

-- Graph source batches were the `symbol_source_many` compatibility alias and are retired with it: one
-- definition is `graph {action:'symbol_source', ...}`, and N of them are a script's Promise.all over
-- that call.

local HISTORY_ON_NODE = { sessions = true, session = true, search_messages = true }

-- The file tools take the same optional `node` (mission tool-args-honest-and-same-on-peers, item 7). A path
-- meant for a peer used to land HERE without a word: one worker wrote a peer's file onto this node and the
-- only evidence was the path it had typed. These five are routed through the SAME call `remote` makes - one
-- code path, so a local call and a peer call cannot drift - and the answer names the node that ran it.
local NODE_ON_TOOL = { read = true, ls = true, grep = true, write = true, edit = true }

-- `remote` with capability "batch" and calls:[...] (29/10): up to eight reads on one peer in ONE signed round trip (~350 ms
-- each measured against openclaw), so a script or an outer turn pays one hop, not N. Read-only on both
-- ends: this side fences every entry, the peer's `batch` capability fences again under its own
-- authorization. A peer that predates `batch` gets the same entries one call each, said in the answer.
local REMOTE_TRANSPORT = { remote_unreachable = true, remote_error = true, bad_reply = true, not_peer_operator = true,
  unsigned_reply = true, remote_reply_unverified = true, relay_refused = true, remote_refused = true }
local function remote_batch(memory, args, role, ctx)
  local calls = args.calls
  if type(calls) ~= "table" or #calls < 1 or #calls > 8 then
    return { error = "remote_calls_1_to_8", effect = "none", example = '{"node":"<name>","capability":"batch","calls":[{"capability":"read","path":"/etc/hostname"},{"capability":"bash","command":"git status --short","cwd":"/repo"}]}' }
  end
  if args.capability ~= nil and args.capability ~= "batch" then return { error = "remote_calls_or_capability", effect = "none", note = "calls goes with capability \"batch\"; a single call names its capability and no calls." } end
  if type(args.node) ~= "string" or args.node == "" then return { error = "remote_node_required", online_nodes = online_nodes(), effect = "none" } end
  local entries = {}
  for index, entry in ipairs(calls) do
    if type(entry) ~= "table" or type(entry.capability) ~= "string" or entry.capability == "" then
      return { error = "remote_calls_entry_invalid", index = index, effect = "none" }
    end
    local params = {}
    if type(entry.args) == "table" then for key, value in pairs(entry.args) do params[key] = value end end
    for key, value in pairs(entry) do if key ~= "capability" and key ~= "args" then params[key] = value end end
    if entry.capability == "remote" or entry.capability == "batch" then return { error = "remote_cannot_recurse", index = index, effect = "none" } end
    local fenced = M.remote_read_refusal(entry.capability, params)
    if fenced then fenced.index = index; return fenced end
    entries[#entries + 1] = { capability = entry.capability, args = params }
  end
  local node = nodeslib.find(args.node)
  if not node then return { error = "unknown_node:" .. tostring(args.node), online_nodes = online_nodes(), effect = "none" } end
  local function one(entry)
    if node.local_node then return M.dispatch(memory, entry.capability, entry.args, role, ctx) end
    return nodeslib.remote_call(node.node_id or args.node, entry.capability, peer_args_with_cwd(memory, ctx, entry.capability, entry.args))
  end
  local results, round_trips, fallback = {}, 0, nil
  if node.local_node then
    for index, entry in ipairs(entries) do results[index] = one(entry) end
  else
    local ok, status = pcall(nodeslib.operator_status, node)
    -- The pins are the door for the legacy path; a node whose mesh is on has a second door, and the
    -- target is the one that decides (docs/MESH.md §2, "The roster decides what executes"). Refusing on
    -- the pins alone made that second door unreachable from this CLI: measured 16/11 on `avell` (roster
    -- level 0, mesh mount up) which refused its own outbound call with `not_peer_operator` before
    -- anything was sent, so the roster's hierarchy could never be exercised.
    if ok and type(status) == "table" and status.operator_of_peer == false and not nodeslib.mesh_enabled() then
      return { error = "not_peer_operator", node = node.name, online_nodes = online_nodes(), next = REMOTE_REFUSALS.not_peer_operator, effect = "none" }
    end
    local answer = nodeslib.remote_call(node.node_id or args.node, "batch", { calls = entries })
    round_trips = 1
    if type(answer) == "table" and answer.batch == 1 and type(answer.results) == "table" then
      results = answer.results
    elseif type(answer) == "table" and answer.error and (REMOTE_TRANSPORT[answer.error] or tostring(answer.error):match("^remote_http_")) then
      if REMOTE_REFUSALS[answer.error] then answer.online_nodes = online_nodes(); answer.next = REMOTE_REFUSALS[answer.error] end
      return answer
    else
      fallback = "peer_has_no_batch: " .. tostring(type(answer) == "table" and answer.error or "unrecognized_answer")
      for index, entry in ipairs(entries) do results[index] = one(entry); round_trips = round_trips + 1 end
    end
  end
  local failed = 0
  for index, entry in ipairs(entries) do
    local value = results[index]
    if carries_local_images(value) then
      value = { error = "remote_image_transport_unsupported", capability = entry.capability }; results[index] = value
    end
    if type(value) ~= "table" or value.error or value.ok == false then failed = failed + 1 end
    -- A page read in a BATCH was still served to this session (mission remote-edit-first-class). Without
    -- this, the cheapest read left no record here, a later edit of that file on that node would state
    -- "this session was served nothing", and the fence would have a hole exactly where the batch is.
    if entry.capability == "read" and not node.local_node and type(value) == "table" then
      file_tools.record_peer_page(ctx and ctx.session_id, node.name or node.node_id, entry.args.path, value)
    end
  end
  return { ok = failed == 0, node = node.name, results = results, failed = failed, round_trips = round_trips, fallback = fallback,
    note = "Ordered per-entry results; every entry was a read." }
end

-- The change a write/edit made, for the READER only.
--
-- Victor, 22/11: "everything once we create/edit/delete a file must appear as claude code. we like to
-- see everything. right now we only see like a row 'write 24ms'". Before this, the only change event
-- came from the agent loop and only for a call NAMED write or edit, so a write inside a `run` script -
-- the one execution path code mode has - drew nothing: the call was named run.
--
-- It is emitted HERE, in the tool's own branch, because this is the single door every call passes
-- whether the model called it directly or a script did (lua/core/agent.lua hands the same ctx to
-- lua/core/codemode.lua, which dispatches each inner call through this function). The record it shows
-- is THE CALL'S OWN before/after text, taken while the previous text is still in hand - not the run's
-- summarized entry, which keeps the run's starting point: a script that writes a file and then edits it
-- has two changes to show, and the second one is an Update of what the first wrote.
--
-- The model's bytes do not move: the event rides beside the result, the result is exactly what the
-- branch below returns, and a caller with no listener emits into nothing (ctx.watch_changes/ctx.emit
-- are the view's, lua/core/agent.lua).
-- Where a reader's event goes. The agent hands every call a queue (lua/core/agent.lua,
-- dispatch_ctx.change_queue) and drains it after that call's own result row: a card written while a
-- code-mode block is still open would land inside it and be overwritten when the block settles. The
-- order a reader sees is therefore the one it saw before this change - result row, then its cards -
-- and a caller with no queue (a bare dispatch, a test) gets the event directly.
local function deliver(ctx, event)
  local queue = type(ctx) == "table" and ctx.change_queue or nil
  if type(queue) == "table" then queue[#queue + 1] = event; return end
  ctx.emit(event)
end

local function announce_change(ctx, name, path, before, after)
  if type(ctx) ~= "table" or type(ctx.emit) ~= "function" or not ctx.watch_changes then return end
  if type(path) ~= "string" or path == "" or type(after) ~= "string" then return end
  -- An existing file whose text could not be read has no before side (changeset.record's own rule: it
  -- records false). The card then says it cannot be drawn instead of drawing an empty file.
  local recorded, original = true, before
  if type(original) ~= "string" then recorded, original = false, "" end
  if #original > changeset.RECORD_CAP or #after > changeset.RECORD_CAP then recorded = false end
  local before_id, after_id
  if recorded then
    -- The two texts go to the same content-addressed store the record uses, so the view reads them
    -- back by address (lua/core/diff_view.lua) and the event stays small.
    before_id, after_id = changeset.store(original), changeset.store(after)
    if not before_id or not after_id then recorded = false end
  end
  local added, removed = changeset.line_delta(original, after)
  deliver(ctx, { type = "change", name = name, path = path, before = before_id, after = after_id,
    recorded = recorded, added = added, removed = removed, created = original == "" })
end

-- A file this RUN wrote that a command then removed.
--
-- The run's own record still holds the text it wrote, so the card is a Delete with its real lines
-- instead of nothing at all. PROBED, never parsed from the command line: only a path this run recorded,
-- and only when the host can SAY the path is gone (`path_kind` -> "missing"). A read that answers nil is
-- also what a binary file answers, and guessing there would draw a deletion that never happened.
--
-- Called where a command's effect first becomes known: right after a foreground command
-- (lua/core/tools.lua, the bash branch) and when a managed operation settles (the operation branch -
-- which is how a script's bash runs, lua/core/codemode_pending.lua). Each path is reported once, so a
-- poll costs one flag read.
local function announce_gone(ctx, reported)
  if type(ctx) ~= "table" or type(ctx.emit) ~= "function" or not ctx.watch_changes then return end
  if not host.path_kind then return end
  local files = type(ctx.changes) == "table" and ctx.changes.files or nil
  if type(files) ~= "table" then return end
  for _, file in ipairs(files) do
    if not (reported and reported[file.path]) and not file.deleted_reported
        and host.path_kind(file.path) == "missing" then
      file.deleted_reported = true
      local before_id = file.after
      local after_id = changeset.store("")
      deliver(ctx, { type = "change", name = "bash", path = file.path, before = before_id,
        after = after_id, recorded = before_id ~= nil and after_id ~= nil, created = false,
        deleted = true })
    end
  end
end
M.announce_gone = announce_gone

-- A BODY IS NEVER SILENTLY ALTERED (23/11). Measured first, because the ledger says the write path
-- corrupts a file and the measurement says it does not: a body containing a LITERAL backslash-n (`A\nB`)
-- went through tools.write and arrived as the four bytes it was (`od -c`: `A \ n B`), and the same body in
-- a run call's raw block arrived byte for byte too. The double decoding the ledger reports (notes 83, 116:
-- "a literal \n became a newline inside a Lua string") happens in the MODEL's own string literal, one layer
-- above this one - the harness never sees the pre-decoding text, so it cannot undo it. What the harness can
-- see is the file after the write, so it compares: a caller told ok=true about a file that does not hold
-- the bytes it sent has no way to find out, and a body silently altered is the expensive class. A mismatch
-- is a REFUSAL (effect unknown: something did happen to that path), never a success.
local WRITE_VERIFY_MAX = 8 * 1024 * 1024
function M.written_body(path, content, read_back)
  -- nil when the file holds exactly `content` (or when nothing can be compared), else the refusal table.
  if type(path) ~= 'string' or type(content) ~= 'string' then return nil end
  local read = read_back or host.read_file
  if type(read) ~= 'function' then return nil end
  if #content > WRITE_VERIFY_MAX then
    -- Not compared: say so on the way out rather than pretend. The size is the one fact that is cheap.
    return { unverified = true, bytes_sent = #content, why = 'body_too_large_to_compare' }
  end
  local held = read(path)
  if held == content then return nil end
  if type(held) ~= 'string' then
    return { error = 'write_unverified', effect = 'unknown', path = path, bytes_sent = #content,
      note = 'the file could not be read back, so nothing here can say it holds the bytes this call sent: '
        .. 'check it with tools.read before relying on it' }
  end
  local at = 1
  local limit = math.min(#held, #content)
  while at <= limit and held:byte(at) == content:byte(at) do at = at + 1 end
  local function shown(text, from)
    local piece = text:sub(from, from + 40)
    return (piece:gsub('[^%g ]', function(ch) return string.format('\\%03d', ch:byte()) end))
  end
  return { error = 'write_mismatch', effect = 'unknown', path = path, at_byte = at,
    bytes_sent = #content, bytes_on_disk = #held,
    note = 'the file does not hold the bytes this call sent - they first differ at byte ' .. at
      .. ' (sent ' .. #content .. ' bytes, the file holds ' .. #held .. '): sent "' .. shown(content, at)
      .. '", on disk "' .. shown(held, at) .. '". Nothing here can say what wrote the rest, so this call '
      .. 'does not report success.' }
end

function M.dispatch(memory, name, args, role, ctx, cwd_provenance)
  args = args or {}
  local requested_cwd = args.cwd
  -- No role means the least one, not the most: a future caller that forgets to pass a role must not
  -- get the shell.
  role = role or "guest"
  ctx = ctx or {}
  local user_id = ctx.user_id or "master"
  ctx.role=role
  -- A retired batch name is answered before any other check, so every route - an ordinary call, a
  -- `tool_call`, a peer capability and a script's `tools.<name>` - gets the same one sentence, with no
  -- effect and no uncertainty record: nothing ran, so nothing is unknown.
  local retired = M.retired(name)
  if retired then return { error = retired, tool = tostring(name), effect = "none" } end
  -- Credentials are never an agent tool's to read (lua/core/secret_guard.lua, 15/11).
  local secret = dofile("lua/core/secret_guard.lua").check(name, args)
  if secret then return secret end
  -- A subagent runs only the exact tools its profile named. Checked here as well
  -- as in the schema list it was offered: a model can ask for a tool it was not
  -- offered, and a schema filter that is not re-checked is not a boundary.
  if ctx.subagent then
    local allowed = ctx.subagent.allowed or {}
    if not allowed[name] then return { error = "capability_not_in_profile:" .. tostring(name) } end
    if name == "subagent" then return { error = "subagent_recursion_forbidden" } end
  end
  if not is_master(role) and (admin_names()[name] or whatsapp_lib.hidden(name)) then return { error = "forbidden_for_role:" .. role } end
  -- A WhatsApp name from an older build (`whatsapp_read`, `peer_openclaw__whatsapp_read`,
  -- `mcp_whatsapp_native_read_newest_47452e4e`) is refused with the name to use instead - and this check
  -- comes BEFORE the code-mode fence, because that fence would gladly tell the model to call the retired
  -- name inside a script (`#118`, `lua/core/whatsapp.lua`). A RETIRED name (`whatsapp_operator`) takes the
  -- same door and gets its own one sentence, never a handler.
  if (whatsapp_lib.renamed(name) or whatsapp_lib.retired_name(name)) and not whatsapp_lib.tool(name) then
    return whatsapp_lib.call(name, args, ctx)
  end
  -- A FIELD THE TOOL DOES NOT DECLARE IS REFUSED BY NAME, HERE, BEFORE ANYTHING RUNS (mission
  -- tool-args-honest-and-same-on-peers). This is the one dispatch a local call, a script's `tools.<name>`,
  -- a `tool_call` batch and a peer's capability all pass, so one refusal covers every route and a field
  -- added to a schema later is accepted here the moment it is declared. A dropped argument used to be a
  -- call that ran as a different call and answered as if it had not; see lua/core/tool_arguments.lua.
  if not tool_arguments then tool_arguments = dofile('lua/core/tool_arguments.lua') end
  local argument_refusal = tool_arguments.refusal(name, args, M.parameters(name, role), ctx)
  if argument_refusal then return argument_refusal end
  -- Connectors run only inside code mode when this run has it; a direct or routed call is pointed there.
  -- One pathway (operator 14/11): under code mode a tool the MODEL calls directly runs as the one-line
  -- script it stands for, so its inputs, outputs, waits and errors are exactly the in-script ones - no
  -- refusal, and no second route to keep in sync. Connectors from every caller (they were script-only);
  -- any other script member only when the call is the model's own (`tool_call_id` + `tool_call_name`, set
  -- by the tool loop; a facade's inner calls share the ctx but not the name),
  -- so an internal or peer caller keeps the answer shape it was built on. DIRECT_ONLY stays direct.
  if codemode_policy.enforced(ctx) and not ctx.codemode_nested and name ~= 'codemode' then
    local wrap = codemode_policy.connector(name)
    if not wrap and ctx.tool_call_id ~= nil and ctx.tool_call_name == name and not dofile('lua/core/codemode.lua').DIRECT_ONLY[name] then
      for _, schema in ipairs(M.all(role, ctx)) do
        if schema['function'] and schema['function'].name == name then wrap = true; break end
      end
    end
    if wrap then
      -- Same output as inside: the value `await tools.<name>(args)` gives the script - the tool's own
      -- result - not the script envelope around it; a failure keeps the script's one-sentence error.
      local ran = M.dispatch(memory, 'codemode', {code = codemode_policy.one_line(name, args)}, role, ctx, cwd_provenance)
      if type(ran) == 'table' and ran.ok == true and ran.value ~= nil then
        local value = ran.value
        if type(value) == 'string' then
          local decoded_ok, decoded = pcall(json.decode, value)
          if decoded_ok and decoded ~= nil then value = decoded end
        end
        if type(value) == 'table' then
          -- A picture the call brought back rides on the RUN result (lua/core/codemode.lua,
          -- take_result_images): the value handed back here is the tool's own answer, so the transport
          -- key travels with it. Without this a direct `read` of a PNG - which is this same one-line
          -- script - would read the picture and then drop it, which is the failure this mission exists
          -- to close.
          if type(ran._images) == 'table' then value._images = ran._images end
          return value
        end
        return { value = value }
      end
      return ran
    end
  end
  -- Orchestration mode's floor: a direct effect is the work itself, so it is refused until this
  -- turn has a recorded route ('direct' allows short work here, 'delegate' hands it to a child)
  -- or a child admitted for the turn. The floor reads the mode, route and admission records only -
  -- never the user's text - and it starts nothing: the route and the child are the model's.
  local delegation = orchestration().guard(name, args, ctx)
  if delegation then return delegation end
  if name=='route_task' then
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    return orchestration().record_route(args,ctx)
  end
  -- History on a peer (29/10): the same read, run there through `remote` and its refusals. A peer that
  -- receives one never forwards it again (`peer_call`), so a node cannot be used as a hop.
  if (HISTORY_ON_NODE[name] or NODE_ON_TOOL[name]) and type(args)=='table' and args.node~=nil and args.node~='' then
    if ctx.peer_call then
      if HISTORY_ON_NODE[name] then
        return {error='history_node_not_forwarded',effect='none',note='A peer answers history reads about itself only.'}
      end
      -- The same rule one tool family over: a call that arrived from a peer is answered here or refused
      -- here, never forwarded a second hop, so no node can be used as a relay for another's files.
      return {error='node_not_forwarded',effect='none',node=args.node,
        note='This call already arrived from another node, so it is answered on this one or refused; it is never forwarded again. Name the peer in a call made on the node you are talking from.'}
    end
    local target=nodeslib.find(args.node)
    local forwarded={};for key,value in pairs(args)do if key~='node' then forwarded[key]=value end end
    if not target or not target.local_node then
      -- The same logical call, one hop away: the hook that saw `sessions {node=…}` is the one that
      -- decides it, so the forwarded `remote` does not ask again.
      local result=M.dispatch(memory,'remote',{node=args.node,capability=name,args=forwarded},role,ctx,nil,true)
      -- An older peer ignores the filters it does not know and answers with only the caller's own rows.
      if name=='sessions' and type(result)=='table' and not result.error and result.filter==nil and (forwarded.path or forwarded.all_owners) then
        result.filter_ignored=true
        result.note='This peer predates sessions path/all_owners: the list is unfiltered and only your own sessions there. Use search_messages {node, query:"<repo path>", scope:"evidence", sort:"newest"} to find the latest work on that repo.'
      end
      return result
    end
    args=forwarded
  end
  -- THE CATALOGUE IS BUILT WHERE IT IS READ (23/11). This line used to build every tool schema - measured
  -- 11-18 ms - for EVERY dispatch, including a peer's `operation await` and a model's `bash`, neither of
  -- which ever reads it. The five readers below (tool_search, tool_call, run/codemode, capabilities) get
  -- exactly the same table as before; a dispatch that reads none of them pays nothing. Laziness, not a
  -- different answer: `M.all` is asked at the same points, in the same order, with the same arguments.
  local catalog_built, catalog_value = false, nil
  local function routed_catalog()
    if not catalog_built then
      catalog_built = true
      catalog_value = ctx.subagent and M.all_for(ctx.subagent.allowed or {},role,ctx,memory) or M.all(role,ctx,memory)
    end
    return catalog_value
  end
  if name=='tool_search' then
    local describe=M.discovery_execution(memory,ctx)
    return envelope.search(routed_catalog() or M.all(role),args,ctx,describe)
  end
  if name=='tool_call' then
    local scope=''
    if args.calls~=nil or args.cursor~=nil then
      local workspace=memory and ctx.session_id and memory.session_workspace and memory.session_workspace(ctx.session_id) or nil
      -- THE SCOPE IS WHO, NOT WHERE (red on main, 24/11). This hash used to include the session's working
      -- directory, and a session's directory can now legitimately CHANGE while it runs: the first run of a
      -- session RECORDS it (lua/core/agent.lua, M.record_run_directory), so a cursor issued before the first
      -- run and resumed after it computed a different hash and answered
      -- `batch_cursor_scope_changed` to a session that had done nothing wrong (measured:
      -- scripts/test-codemode-model-boundary.lua, "the cached continuation answers after the live files
      -- changed"). The identity that matters is the session and its workspace binding; the retained page is
      -- absolute content, so resuming it from another directory discloses nothing new.
      scope=host.sha256(json.encode({kind='routed_read_batch',user=ctx.user_id or user_id,role=role,
        session=ctx.session_id or '',workspace=workspace,profile=ctx.subagent and ctx.subagent.allowed or nil}))
    end
    return dofile('lua/core/routed_calls.lua').invoke(routed_catalog() or M.all(role),args,ctx,scope,function(target,parameters,fragment)
      local original=ctx.tool_arguments_json;ctx.tool_arguments_json=fragment
      local ok,result=pcall(M.dispatch,memory,target,parameters,role,ctx);ctx.tool_arguments_json=original
      if not ok then error(result) end;return result
    end)
  end
  -- A retired batch name never reaches a reader, a handler or a fallback: the refusal at the top of
  -- this dispatcher already answered it.
  local workspace_error = required_workspace_error(memory, ctx, name, args)
  if workspace_error then return workspace_error end
  if name=="resource" then
    if args.action=="list" then return resources.inspect() end
    if args.action=="reconcile" then return resources.reconcile(args) end
    return {error="unknown_resource_action"}
  end
  local observing=name=="client" and OBSERVING_CLIENT_ACTIONS[args.action or ""]
  local client_bound_spell=name=="spell_run" and spellslib.needs_client(args.name)
  if ctx.run_id and not observing and (name=="client" or name=="shell" or client_bound_spell) then
    local claimed=resources.claim(ctx,{"client:local"})
    if not claimed.ok then claimed=reuse_own_client_claim(ctx,claimed) end
    if not claimed.ok then return claimed end
    ctx.resource_effect_generation=(ctx.resource_effect_generation or 0)+1
  end
  if name=='web_search' or name=='web_read' then
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    ctx.cwd=session_cwd(memory,ctx)
    return web.call(mcp,name=='web_search' and 'search' or 'read',args,ctx)
  end
  if name=='mcp' then
    local control={role=role,subagent=ctx.subagent,session_id=ctx.session_id,cwd=session_cwd(memory,ctx)}
    if (args.action==nil or args.action=='list') and (role=='master' or role=='admin') and not ctx.subagent then
      return mcp.summary(args.id)
    end
    return mcp.control(args,control)
  end
  if name=='services' then
    return dofile('lua/core/services.lua').control(args,{role=role,subagent=ctx.subagent,session_id=ctx.session_id})
  end
  local whatsapp_tool = whatsapp_lib.tool(name)
  if whatsapp_tool then
    -- #118: the one WhatsApp surface. It answers here when this node holds the account, and asks the
    -- node that does when this node runs no component - every verb, reads and effects alike (11/11).
    -- The effect happens on the account node under its own guards; nothing is queued on a node that
    -- cannot settle it (`lua/core/whatsapp.lua`, #99).
    return whatsapp_lib.call(name, args, ctx)
  end
  if name=='email_send' or name=='email_send_status' then
    -- The explicit email send (docs/EMAIL-CONNECTOR.md): the host capability validates the addresses,
    -- asks the `email.send` policy and enqueues on `wa:queue`; the wa-email component submits it. A
    -- binary without the capability is told apart from a refusal.
    if type(host[name])~='function' then return {error=name..'_unavailable',effect='none'} end
    local request
    if name=='email_send' then
      request={to=args.to,cc=args.cc,subject=args.subject,body=args.body,in_reply_to=args.in_reply_to,attachments=args.attachments}
    else
      request={id=tonumber(args.id) or args.id}
    end
    local ok,answer=pcall(host[name],json.encode(request))
    if not ok then return {error=name..'_failed',detail=tostring(answer):sub(1,160),effect='none'} end
    local decoded=json.decode(tostring(answer or ''))
    if type(decoded)~='table' then return {error=name..'_answer_unreadable',effect='none'} end
    return decoded
  end
  if name=='whatsapp_archive' then
    -- The index archives (docs/WHATSAPP-ARCHIVE.md). Not a model tool and never offered in a catalogue:
    -- it is the operator's CLI verb (`wa whatsapp archive`) and the capability a peer calls to receive a
    -- pushed archive (`receive`). Master only, because it cuts the index the account node owns and
    -- deletes archives past their 360 days.
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    if type(host.whatsapp_archive) ~= 'function' then return {error='whatsapp_archive_unavailable',effect='none'} end
    local ok,answer=pcall(host.whatsapp_archive,json.encode(args or {}))
    if not ok then return {error='whatsapp_archive_failed',detail=tostring(answer):sub(1,160),effect='none'} end
    local decoded=json.decode(tostring(answer or ''))
    if type(decoded)~='table' then return {error='whatsapp_archive_answer_unreadable',effect='none'} end
    return decoded
  end
  if name=='email_search' or name=='email_read' or name=='email_media' then
    -- The mailbox index (docs/EMAIL-CONNECTOR.md): a question is a job on `email.query`, answered by the
    -- wa-email component out of its own kv.
    if type(host[name])~='function' then return {error=name..'_unavailable',effect='none'} end
    -- A node whose wa-email service is not stored, or stored but disabled, has no worker for email.query:
    -- a job written there is never answered (15/11 replays: email_search sat at 202 'running' and the model
    -- gave the tool up). That is said at once, with the working way to read mail, and nothing is queued.
    -- An enabled service keeps the queue path (a CLI process cannot see whether it is running right now).
    -- A request missing its essentials goes to the host's own validator first, which refuses it before
    -- anything is queued: fixing the call is the first thing to say.
    local essentials=true
    if name=='email_search' then
      essentials=args.q~=nil or args['from']~=nil or args.subject~=nil or args.mailbox~=nil or args['since']~=nil or args['until']~=nil or args.has_attachment~=nil
    elseif name=='email_media' then essentials=args.uid~=nil end
    if essentials then
      local ok_inv,inv=pcall(function() return dofile('lua/core/services.lua').inventory() end)
      if ok_inv and type(inv)=='table' and type(inv.services)=='table' then
        local row
        for _,service in ipairs(inv.services) do if service.name=='wa-email' then row=service end end
        if not row or row.enabled==false then
          return {ok=false,error='email_component_absent',status=404,effect='none',component='wa-email',
            state=row and 'disabled' or 'not_stored',
            note='this node runs no wa-email service, so its email index cannot answer: read mail with the mcp_google_imap_* tools (mcp_google_imap_search_messages, mcp_google_imap_get_message)'}
        end
      end
    end
    local request
    if name=='email_search' then
      request={q=args.q,['from']=args['from'],subject=args.subject,mailbox=args.mailbox,['since']=args['since'],['until']=args['until'],has_attachment=args.has_attachment,limit=args.limit}
    else
      request={mailbox=args.mailbox,uid=args.uid,before=args.before,limit=args.limit}
    end
    local ok,answer=pcall(host[name],json.encode(request))
    if not ok then return {error=name..'_failed',detail=tostring(answer):sub(1,160),effect='none'} end
    local decoded=json.decode(tostring(answer or ''))
    if type(decoded)~='table' then return {error=name..'_answer_unreadable',effect='none'} end
    return decoded
  end
  if name:sub(1,5)=='peer_' then
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    return dofile('lua/core/federation.lua').call(name,args)
  end
  if name:sub(1,4)=='mcp_' then
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    local id,row,tool=mcp.resolve_tool(name)
    if not id then return {error='mcp_tool_not_approved',effect='none'} end
    if row.definition.tools[tool.name]=='write' and ctx.run_id then
      local claimed=resources.claim(ctx,{'mcp:'..id});if not claimed.ok then return claimed end
      ctx.resource_effect_generation=(ctx.resource_effect_generation or 0)+1
    end
    ctx.cwd=session_cwd(memory,ctx);return mcp.call(name,args,ctx)
  end
  if name == "operation" then
    if not is_master(role) then return {error="forbidden_for_role:" .. role} end
    -- WHOSE operation this is, and whether this caller may reach past its own (session isolation,
    -- finding 2; lua/core/session_scope.lua). The owner has always been stamped here and never
    -- compared, so `list` answered with every operation on the node and `status`/`read`/`wait`/
    -- `cancel` answered for any id - and the ids are guessable (`op-<micros>-<pid>-<n>`). The
    -- session travels with every action so the runtime can refuse a call it does not own, and
    -- `scope:"node"` - the operator's alone, audited - is the one way to act beyond it.
    local grant, refusal = dofile('lua/core/session_scope.lua').grant(memory, args, ctx, role, user_id, name)
    if refusal then return refusal end
    -- A CONTROL start is the node's own short read and is the only kind admitted into the two slots no
    -- workload may hold (finding 7). It is a property of the read path, never of the model's arguments:
    -- dropped here, so no tool call can claim the reserve (item 7, round 2).
    args.control = nil
    args.owner = ctx.session_id or user_id
    -- A vault entry reaches a child only through the kernel's own MCP launch (lua/core/mcp.lua), never a
    -- tool call: a model that could name an entry here could start a program that prints it. The
    -- approval that goes with it (docs/VAULT.md) is stripped for the same reason - it is the operator's
    -- record, not a field a caller supplies.
    args.vault_env = nil
    args.vault_approval = nil
    args.session = grant.session or ""
    args.node_scope = grant.node == true
    if args.action == "start" then
      -- An explicit start is backgrounded by definition - the caller gets a receipt and moves on - so
      -- it runs at low CPU priority unless a caller that DOES wait for a while says otherwise
      -- (18/11 round 2, finding 9).
      if args.background == nil then args.background = true end
      args._launch_cwd = cwd_provenance or launch_cwd(memory,ctx,requested_cwd,args.cwd_source)
      if args.cwd == nil or args.cwd == "" then
        local from_session = session_cwd(memory,ctx)
        -- Same rule as `bash`: a session directory that is gone refuses the start by name instead of
        -- launching the operation in the node's own directory (24/11).
        local gone = session_cwd_refusal(from_session)
        if gone then return gone end
        args.cwd = from_session
      end
      -- The same two walls `bash` has had since the 11/11 home wipe: the text is refused before
      -- anything is launched, and the shell runs a command whose resolved targets refuse too. This
      -- path had neither - `host.exec` is wrapped by `path_guard.install`, `operation start` was not -
      -- so an explicit operation (or a code-mode pending `bash`, which starts one) could carry a
      -- recursive delete past the guard. Wall one here, wall two through `wrap`, one answer shape.
      if type(args.command) == "string" and args.command ~= "" then
        local allowed, refused = path_guard.command(args.command, args.cwd)
        if not allowed then return { error = refused, effect = "none", blocked_by = "path_guard" } end
        args.command = path_guard.wrap(args.command)
      end
    end
    -- The name the reader knows this call by, so the session-status-content row can say `⟳ operation`
    -- while a long one runs (docs/TOOL-PROGRESS.md). Drawn, never used as a policy fact.
    if args.action == "await" then args.tool = "operation" end
    local ok, raw = pcall(host.operation, args.action or "status", json.encode(args))
    if not ok then return {error=tostring(raw)} end
    local answer = json.decode(raw)
    -- A command that just SETTLED may have removed a file this run wrote: the record is where the
    -- card's lines come from (announce_gone above). One flag read per recorded file per poll, and only
    -- after a settle, so the display costs a reader nothing until there is something to show.
    if type(answer) == "table" and answer.settled == true then announce_gone(ctx) end
    -- Item #43: list and await answer IDS AND STATE by default; an output BODY is returned only when it
    -- was asked for, and then bounded. A run that lists four operations should not pay for four logs,
    -- and the one number a caller needs to decide what to do next (is it settled? how many bytes? where
    -- is the log?) is in the record either way.
    local action = tostring(args.action or "")
    if (action == "list" or action == "await" or action == "wait") and type(answer) == "table" then
      local wanted = args.output == true or args.include_output == true
      local cap = math.max(1024, math.min(tonumber(args.max_bytes) or 4096, 65536))
      local records = answer
      local single = answer.operation_id ~= nil or answer.state ~= nil
      if single then records = { answer } end
      if type(records) == "table" then
        for _, record in ipairs(records) do
          if type(record) == "table" then
            local had = false
            for _, key in ipairs({ "stdout", "stderr" }) do
              local value = record[key]
              if type(value) == "string" and value ~= "" then
                had = true
                if not wanted then
                  record[key .. "_omitted"] = #value
                  record[key] = nil
                elseif #value > cap then
                  record[key] = value:sub(1, cap)
                  record[key .. "_truncated"] = #value
                end
              end
            end
            if had and not wanted then
              record.output_omitted = true
              record.output_hint = "add output=true (max_bytes=" .. cap
                .. ") to this call, or read one stream: operation action=\"read\" id=... stream=stdout"
            end
          end
        end
      end
    end
    return answer
  end
  if name == "node_update" then
    -- Distance update (lua/core/remote_update.lua, docs/REMOTE-UPDATE.md). Master only, and the peer
    -- re-checks the same authority on its own side; this branch adds the local half only - the record
    -- of what was asked, and the one follow-up wake that brings the outcome back to THIS session.
    if not is_master(role) then return {error="forbidden_for_role:"..role} end
    local remote = dofile("lua/core/remote_update.lua")
    local action = tostring(args.action or "request")
    local selector = tostring(args.node or "")
    if selector == "" then return {error="node_required", effect="none", allowed_actions=remote.ACTIONS} end
    if action == "check" then return remote.inspect(nodeslib.remote_call, selector, args) end
    if action == "status" then
      return remote.status(nodeslib.remote_call, selector, { id = args.id, session = ctx.session_id })
    end
    if action ~= "request" then return {error="unknown_update_action", action=action, allowed_actions=remote.ACTIONS} end
    local reply = remote.request(nodeslib.remote_call, selector, {
      commit = args.commit, rendezvous = args.rendezvous == true,
      reason = args.reason, session = ctx.session_id,
    })
    if reply.ok == true and reply.record and ctx.session_id then
      local scheduled = remote.schedule_followup({ user_id = user_id, session_id = ctx.session_id }, selector, reply,
        args.follow_up_seconds)
      reply.follow_up = scheduled and scheduled.wake or nil
      if not scheduled then
        reply.follow_up_error = "no wake was scheduled; read the outcome with action=\"status\" and id=" .. tostring(reply.record)
      end
    end
    return reply
  end
  if name == "time" then
    return platform.local_clock()
  end
  if name=="tool_result" then
    if not is_master(role) then return {error="forbidden_for_role:"..role} end
    return tool_output.read(args.sha256,args.offset,args.limit)
  end
  -- The self-loop controls (docs/SELF-LOOP.md). Notes and wakes are scoped to the calling session by
  -- selfloop itself (owner and session are re-checked there from ctx, never from the arguments).
  if name == "wake" or name == "wake_list" or name == "wake_cancel" then
    local selfloop = dofile("lua/core/selfloop.lua")
    if name == "wake" then return selfloop.schedule(args, ctx) end
    if name == "wake_list" then return selfloop.list(args, ctx) end
    return selfloop.cancel(args, ctx)
  end
  if name == "notes_read" or name == "notes_write" or name == "notes_append" or name == "notes_compact" then
    local selfloop = dofile("lua/core/selfloop.lua")
    if name == "notes_read" then return selfloop.notes_read(args, ctx) end
    if name == "notes_write" then return selfloop.notes_write(args, ctx) end
    if name == "notes_append" then return selfloop.notes_append(args, ctx) end
    return selfloop.notes_compact(args, ctx)
  end
  -- The done gate (docs/DONE-GATE.md). Master/admin only: the acceptance checks for a request are the
  -- operator's business, and the gate can run commands.
  if name == "done_criteria" then
    if not is_master(role) then return { error = "forbidden_for_role:" .. tostring(role) } end
    -- Item 1 (change/done-gate-trial): the call is counted on the RUN that made it, at the one door
    -- every path goes through - a direct call and a script's inner call share this dispatcher, so the
    -- count cannot depend on which shape the model chose. The mark is a boolean on the gate state the
    -- run already carries (agent.lua puts it on the dispatch ctx); the tool body never reads it.
    if type(ctx) == "table" and type(ctx.gate) == "table" then ctx.gate.done_criteria_called = true end
    return dofile("lua/core/done_gate.lua").tool(args, ctx)
  end

  -- A guest's memory is its own: it writes and reads only `user:<id>`, never `global` (which a
  -- master's recall and runs read) and never another scope. The model picks `scope`; the role decides.
  local guest_scope = not is_master(role) and ("user:" .. tostring(user_id)) or nil
  if name == "remember" then
    if not args.content or args.content == "" then return { error = "content_required" } end
    -- With `id`, this replaces that entry in place. A stale or unknown id refuses rather than
    -- inserting a second copy of a fact the model believes it is correcting.
    local id, refusal = memory.remember(args.content, guest_scope or args.scope or "global", args.tags or {}, args.id)
    if not id then return { error = refusal or "memory_not_found" } end
    local replaced = (args.id ~= nil and args.id ~= "") or nil
    return { ok = true, id = id, replaced = replaced }
  elseif name == "recall" then
    -- `recall()` with no words is the natural first move of a model getting its bearings (17/11, session
    -- 6d9f9d9c: schema_required:arguments.query failed the whole first script): it gets the newest facts.
    if tostring(args.query or ""):find("%S") == nil then
      return memory.memories(guest_scope or args.scope, args.limit or 10)
    end
    if guest_scope then return memory.recall(args.query or "", args.limit or 10, guest_scope, true) end
    return memory.recall(args.query or "", args.limit or 10, args.scope)
  elseif name == "skill" then
    local skills = dofile("lua/core/skills.lua")
    if args.query~=nil then
      if args.name~=nil then return {error='skill_forms_are_exclusive'} end
      local workspace=ctx.session_id and memory.session_workspace and memory.session_workspace(ctx.session_id) or nil
      return skills.search(args,{user=ctx.user_id or user_id,role=role,session=ctx.session_id or '',
        cwd=session_cwd(memory,ctx),workspace=workspace,profile=ctx.subagent and ctx.subagent.allowed or nil})
    end
    if args.limit~=nil or args.offset~=nil or args.snapshot~=nil then return {error='skill_query_required'} end
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
    return memory.memories(guest_scope or args.scope, args.limit or 50)
  elseif name == "forget" then
    if not args.id or args.id == "" then return { error = "id_required" } end
    -- Deleting is reading's sibling: an id is not an authorization (session isolation, finding 10). The
    -- scope the fact lives in decides, and a guest may only delete what it could have read - its own
    -- `user:<id>`. An id that names no live row answers the same way a wrong one does.
    -- NOT a collapsed conditional: "a and f() or true" is true whenever f() returns false, so the
    -- refusal could never fire - the one line this whole finding rested on (item 1, round 2).
    local allowed, why = true, nil
    if memory.may_delete then allowed, why = memory.may_delete(args.id, guest_scope) end
    if not allowed then
      return { error = why or "forget_forbidden_scope", effect = "none", id = args.id,
        note = "this memory is not in a scope you may delete from; a scoped caller deletes only its own facts" }
    end
    return { id = args.id, forgotten = memory.forget(args.id) and true or false }
  elseif name == 'run' or name == 'codemode' then
    if not is_master(role) then return {error='forbidden_for_role:'..role} end
    -- One pathway (docs/AGENT-SEAT.md, principle 2): a run call becomes the codemode call a fenced
    -- run block forms, and everything after this line is the same code for both transports.
    if name == 'run' then
      local call,refused=dofile('lua/core/raw_code.lua').native_run(args)
      if not call then return refused end
      args=call
    end
    local catalog=routed_catalog() or M.all(role)
    local execution=M.discovery_execution(memory,ctx)
    return dofile('lua/core/codemode.lua').run(memory,args,role,ctx,catalog,function()
      return ctx.subagent and M.all_for(ctx.subagent.allowed or {},role,ctx,memory) or M.all(role,ctx,memory)
    end,function(target,parameters,fragment)
      local old,nested=ctx.tool_arguments_json,ctx.codemode_nested;ctx.tool_arguments_json=fragment;ctx.codemode_nested=true
      local ok,value=pcall(M.dispatch,memory,target,parameters,role,ctx);ctx.tool_arguments_json=old;ctx.codemode_nested=nested
      if not ok then error(value) end;return value
    end,execution)
  elseif name == "capabilities" then
    local list,execution={},{}
    local describe,workspace=M.discovery_execution(memory,ctx)
    for _,item in ipairs(routed_catalog() or M.all(role)) do
      local tool=item['function'].name;list[#list+1]=tool;execution[tool]=describe(tool)
    end
    return {role=role,capabilities=list,execution=execution,workspace=workspace,
      note='Permitted catalogue, not an execution guarantee. Inspect workspace status before invocation; native permissions, arguments, profile and effect checks remain authoritative.'}
  elseif name == "subagent" then
    -- One Lua facade for the model and for the HTTP control route; the owner is
    -- derived from `ctx` (server side), never from the arguments the model sent.
    local result=dofile("lua/core/subagents.lua").control(args, ctx)
    if args.action=='list' and type(result.subagents)=='table' then
      local source=result.subagents
      local offset=math.max(0,math.floor(tonumber(args.offset) or 0))
      local limit=math.min(50,math.max(1,math.floor(tonumber(args.limit) or 12)))
      local page={subagents={},total=#source,offset=offset}
      for i=offset+1,math.min(#source,offset+limit) do
        local task=source[i]
        page.subagents[#page.subagents+1]={subagent_id=task.subagent_id,session_id=task.session_id,
          parent_session_id=task.parent_session_id,profile=task.profile,model=task.model,reasoning=task.reasoning,
          state=task.state,settled=task.settled,execution_node=task.execution_node,
          error=task.error and tool_output.slice(tostring(task.error),1,512),
          prompt=tool_output.slice(tostring(task.prompt or ''),1,512),
          evidence={action='status',id=task.subagent_id}}
      end
      page.next_offset=offset+#page.subagents<#source and offset+#page.subagents or nil
      page.note='Bounded list; status/result and exact session pages retain original evidence.'
      return page
    end
    return result
  elseif name == "bash" then
    if not args.command or args.command == "" then return { error = "command_required" } end
    local timeout = args.timeout_seconds
    if timeout ~= nil and (type(timeout) ~= "number" or timeout % 1 ~= 0 or timeout < 1 or timeout > 86400) then
      return { error = "invalid_timeout_seconds" }
    end
    -- The bytes the command reads. Refused by name above the bound, never clipped: a command given half its
    -- input is a command that hangs or writes the wrong thing, and the caller has to know which happened.
    local stdin = args.stdin
    if stdin ~= nil then
      if type(stdin) ~= "string" then return { error = "invalid_stdin", effect = "none" } end
      if #stdin > STDIN_MAX_BYTES then
        return { error = "stdin_too_large", bytes = #stdin, max_bytes = STDIN_MAX_BYTES, effect = "none" }
      end
    end
    -- An explicit `args.cwd` still wins; a session's worktree is the default, and "" keeps the
    -- node's own cwd.
    local cwd = args.cwd
    local cwd_from_session = false
    if cwd == nil or cwd == "" then cwd = session_cwd(memory, ctx); cwd_from_session = true end
    -- A directory the session recorded that is GONE is refused here, before anything runs: a shell in the
    -- node's checkout is the defect this guard exists for (24/11).
    if cwd_from_session then
      local gone = session_cwd_refusal(cwd)
      if gone then return gone end
    end
    -- A common `git commit` path gets a bounded, opt-in pre-commit review. The first
    -- attempt with unread leads returns them without executing the command. A repeated
    -- attempt on the same patch is allowed so a false positive cannot trap the agent;
    -- the final answer still reports unresolved leads. This is not a universal hook:
    -- commits hidden inside scripts or other tools are outside this interception.
    if patch_audit.enabled() and not ctx.subagent and ctx.commit_audits
        and args.command:match("%f[%w]git%s+commit%f[%W]") then
      local audit=patch_audit.git_audit(cwd,ctx.reviewed_paths,
        {session_id=ctx.session_id,run_id=ctx.run_id})
      if audit.error then return {error="graph_patch_audit_failed",audit=audit} end
      if (audit.lead_count or 0)>0 then
        local fingerprint=audit.patch_fingerprint or "unknown_patch"
        if not ctx.commit_audits[fingerprint] then
          ctx.commit_audits[fingerprint]=true
          return {error="graph_patch_review_required",audit=audit,
            note="commit not executed; inspect the cited callers or retry to acknowledge a false positive"}
        end
      end
    end
    if ctx.parallel_start then
      -- Start independent shell calls through the existing supervised operation manager. The
      -- model chose this call group; policy, session cwd and the commit review still run here.
      -- The `operation` start is this same bash call, not a second one: `same_call`.
      return M.dispatch(memory, "operation", { action = "start", command = args.command,
        cwd = cwd, timeout_seconds = timeout, stdin = stdin,
        -- Low CPU priority is for work nobody is waiting for (18/11 round 2, finding 9): the code-mode
        -- pending layer says whether this call is backgrounded, and a call the script is actively
        -- awaiting keeps the node's own priority.
        background = ctx.background_operation == true }, role, ctx, launch_cwd(memory,ctx,requested_cwd), true)
    end
    local provenance = launch_cwd(memory,ctx,requested_cwd)
    -- The name the reader knows this call by, for the session-status-content row while the command
    -- runs (docs/TOOL-PROGRESS.md). A label the host draws; it is not a policy fact.
    provenance.tool = "bash"
    -- The files this command changes, for the READER (Victor 20/11). The snapshot is taken before the
    -- command runs and compared after it, and only when a listener asks for it: the model's result is
    -- read before this point and is not touched by it. A read-only command takes no snapshot at all.
    -- THE CALLER ON ANOTHER NODE ASKS TOO (chat-view-round-2, item 2). A peer's command changed files on
    -- the peer, and this node drew nothing at all: the watcher only ran for a caller with a local view
    -- (`ctx.emit`/`ctx.watch_changes`), which a peer call does not have. A caller that asked for the
    -- change text (`ctx.record_change`, the same word a write/edit uses) gets the LIST here - the paths
    -- and their line counts, never the texts: a file's whole content is not what crossing a wire for a
    -- display costs, and the count is what the row says.
    local for_caller = ctx and ctx.peer_call == true and ctx.record_change == true
    local watched = nil
    if (ctx and type(ctx.emit) == "function" and ctx.watch_changes) or for_caller then
      watched = bash_changes.before(cwd,
        ctx.read_only_command and ctx.read_only_command(args.command) or nil)
    end
    local result = run(args.command, timeout, cwd, provenance, stdin)
    -- The phase breakdown is AGGREGATE EVIDENCE, not context: it leaves the answer a caller receives
    -- (lua/core/bash_result.lua) and the agent records it on this call's tool span from here
    -- (lua/core/agent.lua, tool_output.execution_timing), so the numbers are neither lost nor spent on
    -- every shell line. Keyed by the operation, so a stale one can never be attached to another call.
    if type(result) == "table" and type(result.timing) == "table" and ctx then
      ctx.execution_timing = { operation_id = result.operation_id, timing = result.timing }
    end
    -- After the command: what it changed. Emitted as its own event, so the model's result above stays
    -- exactly what the tool returned, and a reader who is not watching changes pays nothing.
    local shell_changed, shell_refused = nil, nil
    if watched ~= nil then
      shell_changed, shell_refused = bash_changes.changed(watched)
      if ctx and type(ctx.emit) == "function" and ctx.watch_changes
          and (#shell_changed > 0 or #shell_refused > 0) then
        ctx.emit({ type = "bash_changes", command = args.command, files = shell_changed, refused = shell_refused })
      end
      if for_caller and (#shell_changed > 0 or #shell_refused > 0) then
        -- The answer the caller receives: which files, and how much of each. An allow-list of five
        -- names and no text at all - this crosses a wire for a display row, not for a file.
        local summary = {}
        for _, item in ipairs(shell_changed) do
          local added, removed = changeset.line_delta(item.before_text or "", item.after_text or "")
          summary[#summary + 1] = { path = item.path, added = added, removed = removed,
            created = (item.before_text or "") == "", deleted = item.deleted == true }
        end
        for _, item in ipairs(shell_refused) do
          summary[#summary + 1] = { path = item.path, refused = tostring(item.why or "unreadable") }
        end
        if type(result) == "table" then result.changes = summary end
      end
    end
    -- A file this RUN wrote and a command then removed, outside a work tree (where the snapshot above
    -- has nothing to compare): the run's own record still holds the text, so the card is a Delete with
    -- its real lines. PROBED, never parsed from the command line - only a path this run recorded is
    -- looked at, and only when the host can SAY the path is gone: a read that answers nil is also what a
    -- binary file answers, and guessing there would draw a deletion that never happened. A git tree has
    -- already reported it above, so a path in that list is not probed twice.
    if ctx then
      local reported = {}
      for _, item in ipairs(shell_changed or {}) do reported[item.path] = true end
      for _, item in ipairs(shell_refused or {}) do reported[item.path] = true end
      announce_gone(ctx, reported)
    end
    -- The adopted-tree guidance is *policy*, and policy depends on what this caller may use:
    -- a profile with `bash` but not `operation` cannot read or cancel the operation it has just
    -- been handed, so telling it to would be the same dead end the old refusal was. The host
    -- returns the facts; this decides what to say about them.
    if type(result) == "table" and result.promoted == true then
      local allowed = ctx.subagent and ctx.subagent.allowed or nil
      local id = tostring(result.operation_id or "")
      if allowed == nil or allowed["operation"] == true then
        result.note = "The shell command completed with exit code " .. tostring(result.command_code or result.process_exit_code) ..
          ". Its command result is complete; descendants remain supervised as operation " .. id ..
          " under the original timeout and may produce more output. Do not await just to confirm shell exit. " ..
          "Read or await wait_for=settled only if the task depends on background work. Cancel only when you intend to terminate it. Do not rerun the command."
      else
        result.note = "The shell command completed with exit code " .. tostring(result.command_code or result.process_exit_code) ..
          ". Descendants remain supervised as operation " .. id .. " under the original timeout and may produce more output. " ..
          "This profile does not allow the `operation` tool, so background work cannot be inspected or canceled here. " ..
          "The shell result is complete; do not rerun it."
      end
    end
    return result
  elseif name == "read" then
    -- A well-known spelling for one argument becomes the declared one BEFORE the path is resolved, so
    -- `file_path` resolves, fences and records exactly as `path` does (lua/core/file_tools.lua, ALIASES).
    local named, conflict = file_tools.accept_names("read", args)
    if conflict then return conflict end
    args = named
    args.path = resolve_path(memory, ctx, args.path)
    -- The scope is what lets a later edit refuse an anchor it can prove came from a partial page
    -- (file_tools.page_key): the session is the unit that was served the bytes.
    local read = file_tools.read(args,function(entry) return memory.store_image(entry) end,nil,
      ctx and ctx.session_id)
    -- A caller on ANOTHER node can ask for the picture's bytes (lua/core/remote_image.lua): a reference
    -- whose path is a file on this machine is useless there, and refusing it was the whole answer until
    -- now (mission run-block-images-reach-model, item 3). Below the cap and only for this built-in read's
    -- own picture; the bytes travel INSTEAD of the reference.
    if args.image_bytes == true then
      return dofile('lua/core/remote_image.lua').offer(read, memory.load_image)
    end
    return read
  elseif name == 'capture_inspect' then
    args.path=resolve_path(memory,ctx,args.path)
    return dofile('lua/core/capture_view.lua').inspect(args)
  elseif name == "diagnose" then
    return diagnose.run(args.steps,function(tool,options)
      return M.dispatch(memory,tool,options,role,ctx)
    end)
  elseif name == "write" then
    local named, conflict = file_tools.accept_names("write", args)
    if conflict then return on_this_node(conflict) end
    args = named
    if not args.path then return on_this_node({ error = "path_required" }) end
    if type(args.content)~="string" then return on_this_node({error="content_required"}) end
    local path = resolve_path(memory, ctx, args.path)
    local before = host.read_file and host.read_file(path)
    -- nil is "missing" only if the file is really missing. An existing file that is not readable as
    -- text (binary, invalid UTF-8) has no "before" this store can hold: record it as not undoable,
    -- never as an empty file that undo would then write back over the original.
    if before == nil then
      before = (host.path_kind and host.path_kind(path) == "file") and false or ""
    end
    local verified
    local ok = host.write_file and host.write_file(path, args.content or "")
    if ok then
      local compared = M.written_body(path, args.content or "")
      if compared and compared.error then return on_this_node(compared) end
      verified = compared
    end
    local notification=ok and graph_hint(memory,ctx,path) or nil
    -- Record what changed while the previous text is still in hand: this is what the diff
    -- topic shows and what its undo replays. A failed write records nothing.
    if ok and ctx and ctx.changes then
      changeset.record(ctx.changes, path, before, args.content or "")
    end
    local written = { ok = ok and true or false, path = path, error=not ok and "write_failed" or nil,
      graph_index=notification }
    -- A body too large to compare is named on the answer, so "ok" is not read as "the bytes were checked".
    if verified and verified.unverified then written.body_unverified = verified.why end
    -- The caller on another node records this change in its own session (see the edit branch).
    if ok and ctx and ctx.peer_call and ctx.record_change == true then
      written.change = change_for_wire({ path = path, before = before, after = args.content or "" })
    end
    -- What the READER sees of it (lua/core/diff_view.lua): the same two texts, unchanged by the call.
    if ok then announce_change(ctx, "write", path, before, args.content or "") end
    -- The name of the node this ran on (mission write-names-its-node), on the way out for every caller.
    return on_this_node(written)
  elseif name == "edit" then
    local named, conflict = file_tools.accept_names("edit", args)
    if conflict then return on_this_node(conflict) end
    args = named
    args.path = resolve_path(memory, ctx, args.path)
    -- A caller on another node sends the page record of ITS session (see remote_pages), and asks for the
    -- two texts back when it will record the change in that session - the run that made a change is the
    -- session that owns its undo.
    local want_change = (ctx and ctx.peer_call and ctx.record_change == true) and true or false
    -- The callback is the one place that holds both sides of an applied edit, so it keeps the record
    -- (when this caller has one) AND the two texts the reader's card needs. It runs only after the file
    -- was written (file_tools.apply), so a failed edit announces nothing.
    local applied_texts={}
    local result=file_tools.edit(args,function(path,before,after)
      if ctx.changes then changeset.record(ctx.changes,path,before,after) end
      applied_texts[#applied_texts+1]={path=path,before=before,after=after}
    end,nil,ctx and ctx.session_id,remote_pages(ctx),want_change)
    if result.applied then result.graph_index=graph_hint(memory,ctx,result.path) end
    if result.applied then
      for _,item in ipairs(applied_texts) do announce_change(ctx,"edit",item.path,item.before,item.after) end
    end
    if result.change then result.change = change_for_wire(result.change) end
    return on_this_node(result)
  elseif name == "ls" then
    -- Native listing: `ls -la` does not exist on Windows, and the description
    -- promises portability.
    local listed = resolve_path(memory, ctx, args.path) or "."
    if host.list_dir then
      local ok, result = pcall(host.list_dir, listed)
      if ok and result then return json.decode(result) end
    end
    if platform.os() == "windows" then
      return run("dir /b " .. shell_quote(listed))
    end
    return run("ls -la -- " .. shell_quote(listed))
  elseif name == "grep" then
    local allowed={pattern=true,path=true,ignore_case=true,limit=true,max_depth=true,extensions=true,
      context=true,node=true}
    for key in pairs(args) do if not allowed[key] then return {error='unsupported_search_option',option=key} end end
    if type(args.pattern)~='string' then return {error='pattern_required'} end
    if args.path~=nil and type(args.path)~='string' then return {error='invalid_search_path'} end
    if args.ignore_case~=nil and type(args.ignore_case)~='boolean' then return {error='invalid_ignore_case'} end
    for key,bounds in pairs({limit={1,500},max_depth={0,64},context={0,10}}) do
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
    local ok,result=pcall(host.grep,args.pattern,resolve_path(memory,ctx,args.path) or '.',json.encode(args))
    if not ok then return {error=tostring(result)} end
    return json.decode(result)
  elseif name == "graph" then
    -- Off by default (docs/GRAPH.md): refused by name, before the module is loaded and before any store,
    -- index or component call could exist. `searchTools` will not find it either - it reads the catalogue.
    if not graph_offered() then return { error = "graph_dormant", effect = "none",
      next = 'The code graph is OFF by default on this node (docs/GRAPH.md). Read with read/grep, or switch it on: WA_GRAPH_COMPONENT=1, or "graph": true in the features section of policy.json.' } end
    local graph = dofile("lua/core/graph.lua")
    local action = args.action or "explain"
    local root, root_err
    if action~="audit_report" and action~="audit_assess" and action~="audit_feedback" then
      root,root_err=patch_audit.workspace_root(memory,ctx,args.cwd)
      if root_err then return {error=root_err} end
    end
    if action == "audit" then
      if args.source=="git" then
        if ctx.subagent then return {error="git_audit_forbidden_for_subagent"} end
        return patch_audit.git_audit(root,ctx.reviewed_paths,
          {session_id=ctx.session_id,run_id=ctx.run_id})
      end
      return patch_audit.run(ctx.changes, ctx.reviewed_paths,
        {session_id=ctx.session_id,run_id=ctx.run_id,root=root})
    elseif action == "audit_report" then
      return patch_audit.report(args.hours)
    elseif action == "audit_assess" then
      return patch_audit.assess(args,ctx)
    elseif action == "audit_feedback" then
      return patch_audit.feedback(args.run_id,args.outcome,args.commit,ctx)
    end
    if not graph.available() then return { error = "graph_unavailable" } end
    local result, err, diagnostic
    if action == "search_symbols" then result, err, diagnostic = graph.search_symbols(args.name,
      { root=root, limit = args.limit, prefer_implementations = args.prefer_implementations })
    elseif action == "symbol_source" then result, err, diagnostic = graph.symbol_source({
      path=args.path,name=args.name,line=args.line,kind=args.kind},
      {root=root,source_version=args.source_version,byte_offset=args.byte_offset,max_bytes=args.max_bytes})
    elseif action == "overview" then result, err, diagnostic = graph.overview({root=root,aspects=args.aspects,limit=args.limit,max_bytes=args.max_bytes})
    elseif action == "impact" then
      local patch, patch_err
      local source=args.source or "git"
      if source=="native" then patch,patch_err=patch_audit.native_changes(ctx.changes)
      else patch,patch_err=patch_audit.git_changes(root) end
      if not patch then return {error=patch_err or "impact_patch_unavailable",source=source} end
      result,err,diagnostic=graph.impact(patch,{root=root,direction=args.direction,depth=args.depth,limit=args.limit,
        offset=args.offset,cursor=args.cursor,max_bytes=args.max_bytes})
      if result then result.source=source; result.patch_fingerprint=patch.fingerprint end
    elseif action == "explain" then result, err, diagnostic = graph.explain(args.name,{root=root})
    elseif action == "query" then result, err, diagnostic = graph.query(args.name, { root=root,limit = args.limit })
    elseif action == "path" then result, err, diagnostic = graph.path(args.from, args.to,{root=root})
    elseif action == "caps" then result, err, diagnostic = graph.caps({root=root})
    elseif action == "stats" then result, err, diagnostic = graph.stats({root=root})
    elseif action == "index" then result, err, diagnostic = graph.index({ root=root,force = args.force })
    else return { error = "unknown_graph_action:" .. tostring(action) } end
    if not result then
      if diagnostic and diagnostic.error then return diagnostic end
      if err=='graph_refresh_required' then return {error=err,refresh_required=true,indexed=false,
        next='Use read/grep now, or explicitly run graph action=index for this cwd; reads never rebuild.'} end
      return {error=err or 'graph_error'}
    end
    return result
  elseif name == "client" then
    local ok, raw = pcall(host.client, args.action or "", json.encode(args))
    if not ok then return { error = tostring(raw) } end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return { result = raw } end
    return decoded
  elseif name == "shell" then
    -- Nothing was dispatched, so nothing can be uncertain: the run must not lose its
    -- client to a mistyped call. Lua marks its own pre-dispatch refusals the same way
    -- the node marks `client_not_connected`.
    if not args.command or args.command == "" then return { error = "command_required", effect = "none" } end
    local ok, raw = pcall(host.client, "shell", json.encode(args))
    if not ok then return { error = tostring(raw) } end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return { result = raw } end
    return decoded
  elseif name == "spell_save" then
    return spellslib.save(args)
  elseif name == "spell_run" then
    return spellslib.run(args.name, args.params)
  elseif name == "spell_compose" then
    return spellslib.compose(args)
  elseif name == "spell_list" then
    return spellslib.list()
  elseif name == "spell_get" then
    return spellslib.get(args.name) or { error = "unknown_spell" }
  elseif name == "spell_forget" then
    return spellslib.remove(args.name)
  elseif name == "spell_export" then
    return spellslib.export_to_file(args.name, args.params, args.binary, args.path)
  elseif name == "sessions" then
    local owner = user_id
    if args.all_owners == true then
      if not is_master(role) then return { error = "forbidden_for_role:" .. tostring(role) } end
      owner = nil
    end
    local path = type(args.path) == "string" and args.path ~= "" and args.path or nil
    return { sessions = memory.list_sessions(owner, args.limit or 30, { path = path }),
      filter = { all_owners = owner == nil, path = path } }
  elseif name == "session" then
    local session = memory.session(args.session_id)
    if not session then return { error = "unknown_session" } end
    if session.user_id ~= user_id and not is_master(role) then return { error = "forbidden" } end
    return dofile('lua/core/session_view.lua').get(memory,args.session_id,args)
  elseif name == "search_messages" then
    local owner
    if not is_master(role) then owner=user_id end
    return dofile('lua/core/history_search.lua').search(memory,args,owner)
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
  elseif name == "session_worktree" then
    local id = args.session_id or ctx.session_id
    if not id or id == "" then return { error = "session_id_required" } end
    local record = memory.session(id)
    if not record then return {error="unknown_session"} end
    if record.user_id ~= user_id then return {error="forbidden"} end
    local workspace = memory.session_workspace(id)
    local action = args.action or "status"
    if action == "status" then
      -- One line first: what is bound and what to do next. The struct alone answered neither, which is
      -- why a model called status three times in a row until the guard ended the turn (18/11).
      return { status_line = workspaces.status_line(memory, id),
        session_id = id, worktree = memory.session_worktree(id), workspace = workspace,
        recovery = workspaces.recovery_hint(memory, id) }
    elseif action=='release' then
      local released,why,detail=workspaces.release(memory,id,user_id)
      if not released then return {error=why,detail=detail,session_id=id} end
      return {ok=true,session_id=id,workspace=released,branch_retained=true}
    elseif action == "allocate" or action == "recover" then
      local source_id = record.fork_parent_id
      if not source_id or source_id == "" then source_id = record.parent_session_id end
      if not source_id or source_id == "" then source_id = id end
      local allocated, detail = workspaces.ensure(memory, id, source_id, {root_recovery=source_id==id})
      if not allocated then return {error=workspaces.refusal_code(detail),detail=detail,
        workspace=memory.session_workspace(id),recovery=workspaces.recovery_hint(memory,id)} end
      return {ok=true,session_id=id,workspace=allocated}
    elseif action == "set" then
      if workspace and workspace.required then return {error="workspace_managed",state=workspace.state} end
      if type(args.path) ~= "string" or args.path == "" then return { error = "path_required" } end
      -- The directory must exist: a typo that silently pointed every tool at a missing tree
      -- would look like the whole project vanished, which is worse than a refusal. `host.list_dir`
      -- reports failure as `{error=...}`, not nil, so the JSON has to be read rather than trusted
      -- for truthiness - a bare pcall check accepted every path.
      if host.list_dir then
        local ok, raw = pcall(host.list_dir, args.path)
        local decoded = ok and json.decode(raw) or nil
        if type(decoded) ~= "table" or decoded.error then
          return { error = "worktree_not_a_directory", path = args.path }
        end
      end
      return { ok = true, session_id = id, worktree = memory.set_session_worktree(id, args.path) }
    elseif action == "clear" then
      if workspace and workspace.required then return {error="workspace_managed",state=workspace.state} end
      return { ok = true, session_id = id, worktree = memory.set_session_worktree(id, "") }
    end
    return { error = "unknown_action", action = action }
  elseif name == "fleetview" then
    -- One read-only call for the whole fabric (docs/FLEET-OPS.md). It has no write path at all: the
    -- module it calls cannot act, so no argument can make this tool change anything.
    local fleetview = dofile('lua/core/fleetview.lua')
    local lessons
    if args.lessons ~= false then
      local ok, recalled = pcall(function() return dofile('lua/core/lessons.lua').ensure() end)
      if ok and type(recalled) == 'table' then lessons = recalled end
    end
    -- WHOSE VIEW THIS IS (session isolation, item 1 round 4): the caller's own memory module, role and
    -- session go in. The module's node-scope grant needs a store to write its audit line to and a role to
    -- check; a hard-coded 'master' with no store was neither audited nor refused, so the read answered as
    -- a sessionless caller and showed a fraction of the node's work as if it were all of it.
    local view = fleetview.view({ lessons = lessons, memory = memory, role = role,
      user_id = user_id, session = ctx.session_id })
    return view
  elseif name == "lessons" then
    local store = dofile('lua/core/lessons.lua')
    local action = tostring(args.action or 'recall')
    if action == 'add' then
      local added = store.add({ id = args.id, symptom = args.symptom, cause = args.cause, fix = args.fix,
        rule = args.rule, tags = args.tags, source = args.source })
      if not added.ok then return { error = added.error, effect = 'none' } end
      return added
    elseif action == 'list' then
      return { lessons = store.list(args.limit), stats = store.stats(), note = store.NOTE }
    elseif action == 'stats' then
      return { ok = true, stats = store.stats() }
    end
    local recalled = store.recall(args.query, args.limit)
    if recalled.error then return { error = recalled.error, effect = 'none', note = recalled.note } end
    return recalled
  elseif name == "build" then
    -- The relation between the running binary and the tree (lua/core/build_status.lua): three facts
    -- and the verdict between them, so a reader never has to infer that a green row graded another
    -- commit bytes.
    return dofile("lua/core/build_status.lua").status()
  elseif name == "nodes" then
    -- ANSWERS FROM WHAT THE NODE KNOWS, IN UNDER A SECOND (23/11). The default list started one
    -- `wa nodes probe` child per peer and WAITED out its 20 s deadline: measured on avell, three calls in
    -- a row took 20.4 s, 20.4 s and 0.25 s, and a turn cannot call the model until this returns (session
    -- daf51bb3: 83 s, four of nine rounds spent finding where WhatsApp runs). The probes are still
    -- started - that is how an answer arrives - but this call waits at most ANSWER_S for them and says
    -- how old each answer is; a child that has not settled is left running (never cancelled) and
    -- publishes for the next call.
    -- Half a second, not a second: an answer already on disk is read with no wait at all, and a probe
    -- that has not answered inside half a second is reported `probe_pending` (the next call joins it).
    -- Measured: 0.9 s of wait plus the fan-out's own overhead read as 1.02 s, which is over the second a
    -- turn's first model call needs.
    local ANSWER_S = 0.5
    local list = {}
    for _, node in ipairs(nodeslib.list({ wait_s = ANSWER_S, keep_running = true })) do
      local entry = {
        name = node.name, role = node.role, online = node.online,
        local_node = node.local_node, capabilities = node.capabilities,
        capabilities_reason = node.capabilities_reason,
        endpoints = node.endpoints, node_id = node.node_id,
      }
      if node.capabilities_at then entry.capabilities_at = node.capabilities_at end
      if node.capabilities_age_s then entry.capabilities_age_s = node.capabilities_age_s end
      -- Whether this node may call the peer at all: read from the peer's registry binding (cached),
      -- so a refusal is visible before a call is spent on it.
      if not node.local_node then
        local ok, status = pcall(nodeslib.operator_status, node)
        if ok and type(status) == "table" then for key, value in pairs(status) do entry[key] = value end
        else entry.operator_of_peer = "unknown"; entry.operator_basis = "lookup_failed" end
      end
      list[#list + 1] = entry
    end
    return { nodes = list,
      note = "operator_of_peer: true = this node is pinned in the peer's accepted binding; false = the peer will refuse it (unknown_caller); unknown = no binding on record or the lookup failed. Registry view, cached 60 s. "
        .. "capabilities_age_s: how old the peer's capabilities answer is (capabilities_at is when it was produced); capabilities_reason probe_pending means a probe is running and had not answered when this list was drawn - ask again in a second and it is there." }
  elseif name == "remote" then
    if type(args) == "table" and (args.capability == "batch" or args.calls ~= nil) then return remote_batch(memory, args, role, ctx) end
    local call, refusal = M.remote_arguments(args, function() return M.catalog(role) end)
    if not call then return refusal end
    if call.capability == "remote" then return { error = "remote_cannot_recurse" } end
    -- A script may now change a peer as well as read it: the peer's own binding/role checks and this
    -- node's per-call permission and workspace checks are the gate, exactly as for an ordinary call
    -- (31/10, the operator asked code mode to do everything it can). The `calls` batch below stays
    -- read-only on the wire: it is one signed round trip of 1-8 reads, enforced again on the peer.
    local node = nodeslib.find(call.node)
    if not node then
      return { error = "unknown_node:" .. tostring(call.node), online_nodes = online_nodes(),
        note = "No peer is named " .. tostring(call.node) .. ". Use one of online_nodes (or a node_id from the nodes tool)." }
    end
    -- What the peer must know about this SESSION, not about the answer: the page of a file it was
    -- served there, and that it wants the before/after text of a change back. Both travel in the signed
    -- body (nodes.lua M.remote_call options) and never in `args`, which is the model's own text.
    local target = node.name or node.node_id
    -- MIXED FLEET (mission tool-args-honest-and-same-on-peers, follow-up): a peer that predates a field
    -- IGNORES it - the silent drop this mission closed on this node, one hop out. Before the call leaves,
    -- a field this node added is confirmed against the peer's OWN catalogue; unconfirmed is refused HERE,
    -- with nothing sent. `node` is not in the list: it is a routing word for this call and never travels.
    if not node.local_node then
      for _, field in ipairs(PEER_FIELD_SUPPORT[call.capability] or {}) do
        if type(call.args) == 'table' and call.args[field] ~= nil then
          local federation = dofile('lua/core/federation.lua')
          local declared, version = federation.declares(target, call.capability, field)
          if declared ~= true then
            local version_text = (type(version) == 'string' and version ~= '' and version ~= 'unknown')
              and (' (version ' .. version .. ')') or ' (version unknown)'
            return { error = 'peer_field_unsupported', effect = 'none', capability = tostring(call.capability),
              field = field, peer = tostring(target), peer_version = version,
              message = 'peer ' .. tostring(target) .. ' runs a build without ' .. field .. version_text
                .. ', so nothing was sent.',
              fix = 'send the call without ' .. field .. ', or update that peer to a build whose catalogue'
                .. ' declares it; a field a peer does not declare is never sent to be dropped.' }
          end
        end
      end
    end
    local options
    if not node.local_node and (call.capability == "edit" or call.capability == "write") then
      options = { record_change = (ctx and ctx.changes) ~= nil }
      if call.capability == "edit" and ctx and ctx.session_id then
        -- Keyed by the path AS IT WAS WRITTEN, which is the same string a read of that file used. `false`
        -- says this session was served nothing for it at that path: a fact this process holds because it
        -- keeps the session's record. With NO session id there is no such record to speak from, so the
        -- field is left out and the peer falls back to its own record for this caller, exactly as before
        -- - an absent record is not "nothing was read" (unknown is not yes).
        local snapshot = file_tools.page_snapshot(ctx.session_id, call.args.path, target)
        options.read_pages = { record = snapshot or false }
      end
    end
    local result
    if node.local_node then
      -- A call addressed to THIS node is this node's own tool call, so it runs under this session -
      -- for the file capabilities only, whose handlers take nothing else from the context. Without
      -- this, a self-addressed `edit` was the one edit on this machine with no fence and no record.
      local own = (call.capability == "read" or call.capability == "write" or call.capability == "edit")
      result=M.dispatch(memory, call.capability, call.args, role, own and ctx or nil)
    else
      -- Fail fast when the registry already says the peer will refuse this node: a cached `false`
      -- is re-read once, fresh, before it refuses, so a binding granted a moment ago is not denied.
      local ok, status = pcall(nodeslib.operator_status, node)
      if ok and type(status) == "table" and status.operator_of_peer == false then
        ok, status = pcall(nodeslib.operator_status, node, { fresh = true })
      end
      -- Same second door as the batch path: with the mesh on, the pins no longer answer alone — the
      -- target does, through the roster it verified. A peer that refuses still answers; a peer whose
      -- roster does not cover this call answers `mesh_denied`, which is the honest word for it.
      if ok and type(status) == "table" and status.operator_of_peer == false and not nodeslib.mesh_enabled() then
        result = nodeslib.refusal("node", "unknown_caller", nil, node)
        result.error = "not_peer_operator"
        result.verified = nil
        result.source = "rendezvous /lookup of " .. tostring(node.name) .. "'s binding (nothing was sent to the peer)"
        result.note = nil
        result.peer_binding, result.peer_operators, result.operator_basis = status.peer_binding, status.peer_operators, status.operator_basis
      else
        -- A read asks the peer for the picture's bytes as well: a peer that does not know the field
        -- answers exactly what it answered before, and the refusal below is unchanged (an old node keeps
        -- working; nothing is assumed about the peer's build).
        local sent = call.capability == "read" and dofile('lua/core/remote_image.lua').request(call.args) or call.args
        result=nodeslib.remote_call(call.node, call.capability, peer_args_with_cwd(memory, ctx, call.capability, sent), options)
      end
      if type(result) == "table" and REMOTE_REFUSALS[result.error] then
        result.online_nodes = online_nodes()
        result.next = REMOTE_REFUSALS[result.error]
      end
    end
    -- A file this call changed on ANOTHER node (Victor 22/11: every create/edit has to be visible). The
    -- peer's answer carries no text this node could draw - an edit's digests address the PEER's store -
    -- so the card is one honest row naming the path and the node, never nothing. A `local_node` peer
    -- needs no row: the dispatch above runs here and its own branch already emits the card.
    if not node.local_node and (call.capability == "write" or call.capability == "edit")
        and type(result) == "table" and ctx and type(ctx.emit) == "function" and ctx.watch_changes then
      local target = result.path or (type(call.args) == "table" and call.args.path) or "?"
      local ok = not result.error and result.ok ~= false
      -- The peer's answer carries the two texts when the call asked for them (mission
      -- remote-edit-first-class sends `change` on the wire): then the reader gets the SAME card a local
      -- write draws, from the peer's own before/after. A peer that sent no texts, or refused the call,
      -- gives the one honest row - never nothing. An allow-list: only these five fields travel.
      local wire = result.change
      if type(wire) ~= "table" or wire.recorded == false
          or type(wire.before) ~= "string" or type(wire.after) ~= "string" then
        wire = nil
      end
      deliver(ctx, { type = "remote_change", capability = call.capability, node = node.name,
        path = tostring(target), ok = ok, error = result.error,
        before_text = wire and wire.before or nil, after_text = wire and wire.after or nil })
    end
    -- THE FILES A PEER'S COMMAND CHANGED (chat-view-round-2, item 2). The peer names them (paths and line
    -- counts, never texts) when the call asked for the change (`record_change`); each is a row of its own,
    -- in the same place a local `bash_changes` card goes, so a change made by running a command on another
    -- machine stops being invisible. A peer that sent no list draws nothing new: unknown is not "nothing
    -- changed".
    if not node.local_node and call.capability == "bash" and type(result) == "table"
        and type(result.changes) == "table" and type(ctx) == "table"
        and type(ctx.emit) == "function" and ctx.watch_changes then
      for _, item in ipairs(result.changes) do
        if type(item) == "table" and type(item.path) == "string" then
          deliver(ctx, { type = "remote_change", capability = "bash", node = node.name,
            path = item.path, ok = item.refused == nil, error = item.refused,
            added = tonumber(item.added), removed = tonumber(item.removed),
            created = item.created == true, deleted = item.deleted == true })
        end
      end
      result.changes = nil
    end
    -- A picture the peer sent (lua/core/remote_image.lua): verified against the digest it named, stored
    -- HERE, and handed on as this node's own reference - the same content-addressed store and the same
    -- provider route a local read uses. A picture that fails a check is a named refusal.
    --
    -- The adopt comes FIRST and the reference is attached AFTER the wrong-machine check below, because a
    -- reference this node just wrote is a file that exists HERE: the check exists to refuse a path on the
    -- wrong machine, and naming an adopted picture "on the wrong machine" would refuse the very transfer
    -- this branch is here to accept (measured: the refusal fired on a successful adoption).
    local adopted
    if type(result) == "table" and result.image_data ~= nil then
      local reference, problem = dofile('lua/core/remote_image.lua').adopt(memory, result)
      if not reference then return problem end
      adopted = reference
    end
    if carries_local_images(result) and not adopted then
      return {error="remote_image_transport_unsupported",capability=call.capability,
        note="The image was not returned as text or as a path on the wrong machine."}
    end
    if adopted then result._images = { adopted } end
    -- The caller's own half of a file call on a peer (mission remote-edit-first-class): record the page
    -- THIS session was served there, and record the change in THIS session, with the node it happened
    -- on, so undo puts the peer's file back. A call addressed to this node needed neither - its own
    -- handlers already did both under this session.
    if type(result) == "table" and not node.local_node then
      if call.capability == "read" then
        -- An answer that does not say what it served records nothing and says why (file_tools): a page
        -- nobody can read must never widen what a later edit there may quote.
        file_tools.record_peer_page(ctx and ctx.session_id, target, call.args.path, result)
      elseif call.capability == "edit" or call.capability == "write" then
        local change = result.change
        -- The two texts are for the record, not for the model's view: the call asked to change one file,
        -- not to be shown the whole of it twice.
        result.change = nil
        if ctx and ctx.changes and not result.error then
          if type(change) == "table" then
            -- Written out, not as "intact and X or Y": with a nil middle the `or` always wins, and the
            -- entry was recorded as unrecordable every time (measured by this mission's own test before it
            -- was believed). A peer that could not send the texts says why; then `before` is false, which
            -- is the store's word for "the file existed and its text could not be captured".
            local before, reason = change.before, change.reason
            if change.recorded == false then
              before, reason = false, (change.reason or "change_not_recorded")
            end
            changeset.record(ctx.changes, change.path or call.args.path, before,
              change.after or "", target, reason)
          else
            -- An older peer sends no texts. One honest row that cannot be undone, never a crash, and
            -- its reason is what the diff topic and the undo route report.
            changeset.record(ctx.changes, call.args.path, false, "", target, "peer_sent_no_change_text")
          end
        end
      end
    end
    -- Say what was repaired, so the model learns the shape instead of relying on the repair.
    if call.hoisted and type(result) == "table" then
      result.normalized = "remote: moved " .. table.concat(call.hoisted, ", ")
        .. " to the top level. Canonical shape: " .. REMOTE_EXAMPLE
    end
    return result
  end

  -- Fall back to a WASM plugin (admin only; guests never see their schemas).
  if not is_master(role) then return { error = "unknown_tool:" .. tostring(name) } end
  local ok, result = pcall(host.invoke, name, json.encode(args))
  if not ok then return { error = tostring(result) } end
  local decoded = json.decode(result)
  if type(decoded) ~= "table" then return { result = result } end
  return decoded
end

-- Launch only shell calls the model returned in the same assistant response. The system
-- guideline tells it to group independent actions; writes and commands with dependencies must
-- remain in separate responses. Every command still passes through normal bash validation and
-- patch review before the operation manager starts it. At most eight can be active in one batch.
-- Does dispatching `name` change something outside this run?
--
-- The steering fence exists because steering cannot undo an effect that has already happened, so
-- a call needs stopping only when it has one. A read-only allowlist, not an effectful one: a tool
-- this file has never heard of (a plugin's) keeps the fence, which is the safe direction.
local READ_ONLY = {
  read = true, capture_inspect=true, grep = true, ls = true, tool_result = true, skill = true,
  graph = true, diagnose = true, capabilities = true, tool_search=true, web_search=true,web_read=true,nodes = true,
  fleetview = true,
  recall = true, memories = true, sessions = true, session = true,
  search_messages = true,
  notes_read = true, wake_list = true,
  spell_list = true, spell_get = true,
  -- The WhatsApp reads (and a send's status) cannot undo an executed effect, so they need no fence.
  mcp_whatsapp_contacts = true, mcp_whatsapp_search = true, mcp_whatsapp_read = true,
  mcp_whatsapp_reactions = true, mcp_whatsapp_media = true, mcp_whatsapp_send_status = true,
  email_send_status = true,
  email_search = true, email_read = true, email_media = true,
}

function M.has_effect(name, args)
  if type(name)~='string' then return true end
  -- A retired batch name answers one sentence and touches nothing, so it needs no steering fence: an
  -- effect fence exists to stop something that cannot be undone, and a refusal is already undone.
  if retired_lib.NAMES[name] then return false end
  -- The one WhatsApp surface knows its own effects: `mcp_whatsapp_read` is a read on a node whose
  -- account it may ask a peer for, and the generic `mcp_` rule below would look it up in a registry it
  -- is no longer part of. One of them is two calls: a send queues a message (an effect) and a resume with
  -- a job id only waits on the queue (a read), so the args decide which - see `lua/core/whatsapp.lua`.
  local whatsapp_effect = whatsapp_lib.effect(name, args)
  if whatsapp_effect then return whatsapp_effect ~= 'read' end
  if name:sub(1,4)=='mcp_' then return not mcp.is_read(name) end;if name:sub(1,5)=='peer_' then return not dofile('lua/core/federation.lua').is_read(name) end;return READ_ONLY[name] ~= true end

function M.start_parallel_bash(calls, memory, role, ctx)
  -- A hook layer that must see every call cannot be skipped by the parallel path: while hooks are
  -- configured, bash calls run one at a time through `dispatch`, where PreToolUse and PostToolUse fire
  -- (docs/HOOKS.md, "what a hook cannot see"). With no configured hooks this is one cached lookup and
  -- the batching behaviour is unchanged. The shipped guard is the exception in the other direction: it
  -- is not a reason to give up batching (each command still reaches it in `dispatch`), but a batch that
  -- contains a command it refuses is not launched as a batch - the serial path refuses it with the
  -- usual verdict.
  if hookslib.configured() then return nil end
  for _, call in ipairs(type(calls) == 'table' and calls or {}) do
    local fn = type(call) == 'table' and call['function'] or nil
    if type(fn) == 'table' then
      local ok, call_args = pcall(json.decode, fn.arguments or '')
      if ok and type(call_args) == 'table' and hookslib.guard_refuses(fn.name, call_args) then return nil end
    end
  end
  if not is_master(role) or (ctx and ctx.subagent
      and (not ctx.subagent.allowed or not ctx.subagent.allowed.operation))
      or type(calls) ~= "table" or #calls < 2 then return nil end
  local pending, count = {}, 0
  for _, call in ipairs(calls) do
    local fn = type(call) == "table" and call["function"] or nil
    -- The args decide an effect for one tool (`mcp_whatsapp_send` resumes with a job id and only
    -- waits), so the batch gate reads them before it asks: a resume may ride with a batch of reads.
    local args_ok, call_args = pcall(json.decode, type(fn) == "table" and fn.arguments or "")
    if not args_ok or type(call_args) ~= "table" then call_args = nil end
    if type(fn) ~= "table" or (fn.name ~= "bash" and M.has_effect(fn.name, call_args)) then return nil end
    if fn.name == "bash" and type(call.id) == "string" and call.id ~= "" then
      local args = call_args
      if args and type(args.command) == "string" and args.command ~= "" then
        pending[#pending + 1] = { id = call.id, args = args }
        count = count + 1
      end
    end
  end
  if count == 0 or count > 8 then return nil end

  local started = {}
  for _, item in ipairs(pending) do
    local parallel_ctx = {}
    for key, value in pairs(ctx or {}) do parallel_ctx[key] = value end
    parallel_ctx.parallel_start = true
    local result
    if ctx and ctx.steering_admit and not ctx.steering_admit() then
      result={error='superseded_by_steering',executed=false,effect='none'}
    else
      result = M.dispatch(memory, "bash", item.args, role, parallel_ctx)
    end
    if type(result) == "table" and type(result.operation_id) == "string" then
      started[item.id] = { operation_id = result.operation_id }
    else
      -- A refusal is a result, not permission to execute the call a second time.
      started[item.id] = { result = result }
    end
  end
  return started
end

function M.await_parallel_bash(operation_id, role, ctx)
  -- Reading back the batch this tool started is the same call's plumbing, not a new one.
  local state = M.dispatch(nil, "operation", { action = "await", id = operation_id, tool = "bash" }, role, ctx, nil, true)
  if type(state) ~= "table" then return { error = "parallel_operation_await_failed" } end
  if state.error == "await_interrupted" then
    M.dispatch(nil, "operation", { action = "cancel", id = operation_id }, role, ctx, nil, true)
    for _ = 1, 10 do
      state = M.dispatch(nil, "operation", { action = "wait", id = operation_id, wait_ms = 500 }, role, ctx, nil, true)
      if type(state) == "table" and state.settled == true then break end
    end
    if type(state) ~= "table" or state.settled ~= true then
      return {operation_id=operation_id,error="run_cancelled",cleanup="unknown",output_complete=false}
    end
    state.error = state.error or "run_cancelled"
  end
  -- The same page the pending module reads at, from one pair of constants (item 4): a direct bash
  -- answer and a handle over the same operation must clip at the same byte.
  local pages = dofile("lua/core/codemode_pending.lua")
  local stdout = M.dispatch(nil, "operation", { action = "read", id = operation_id,
    stream = "stdout", offset = 0, limit = pages.STDOUT_PAGE_BYTES }, role, ctx, nil, true)
  local stderr = M.dispatch(nil, "operation", { action = "read", id = operation_id,
    stream = "stderr", offset = 0, limit = pages.STDERR_PAGE_BYTES }, role, ctx, nil, true)
  local code = tonumber(state.process_exit_code) or -1
  -- The phase breakdown of a PARALLEL command is aggregate evidence like a direct one's: the answer a
  -- caller receives no longer carries it (mission slim-tool-results, lua/core/bash_result.lua), so it
  -- travels to this call's tool span through the context (lua/core/agent.lua).
  if type(state.timing) == "table" and type(ctx) == "table" then
    ctx.execution_timing = { operation_id = operation_id, timing = state.timing }
  end
  return { operation_id = operation_id, code = code, ok = code == 0,
    stdout = type(stdout) == "table" and stdout.content or "",
    stderr = type(stderr) == "table" and stderr.content or "",
    output_complete = state.output_complete == true,
    stdout_bytes = type(stdout) == "table" and stdout.available_bytes or nil,
    stderr_bytes = type(stderr) == "table" and stderr.available_bytes or nil,
    stdout_path = state.stdout_path, stderr_path = state.stderr_path,
    stderr_truncated = type(stderr) == "table" and
      (tonumber(stderr.available_bytes) or 0) > pages.STDERR_PAGE_BYTES or false,
    stdout_truncated = type(stdout) == "table" and
      (tonumber(stdout.available_bytes) or 0) > pages.STDOUT_PAGE_BYTES or false,
    error = state.error, timing = state.timing, parallel = true }
end

-- The schema of the tool a refusal is about, read only when a refusal is rendered: it is what turns
-- "the arguments were wrong" into "this tool takes path (string, required)". It reads the two tables
-- this module already holds - never `M.catalog`, which asks the connectors and the peers: a refusal must
-- not make a network call to explain itself, and a peer that is down would turn one refusal into two.
-- The ONE lookup the argument validator and the peer bash path use (mission
-- tool-args-honest-and-same-on-peers): a tool's declared parameters, by name and role.
--
-- The two hand-written lists are scanned first - no host call, no catalogue - which covers every tool this
-- file declares, the WhatsApp surface (appended to M.admin at load, lua/core/tools.lua) and `tool_result` /
-- `route_task`. A name that is not there is a connector, a peer's exported tool or a wasm plugin, and those
-- are looked up in the catalogue: built at most once per role every CATALOG_TTL seconds, because
-- `M.catalog` costs 11-18 ms and a call that is not one of them must not pay for it.
local function parameters_of(name,role)
 local lists = { M.shared or {} }
 if is_master(role or "guest") then lists[#lists+1] = M.admin or {} end
 for _,list in ipairs(lists) do
  for _,item in ipairs(list) do
   local fn=item["function"]
   if fn and fn.name==name then return fn.parameters end
  end
 end
 return nil
end

local catalog_parameters, CATALOG_TTL = {}, 30
function M.parameters(name, role)
  local declared = parameters_of(name, role)
  if declared then return declared end
  if type(name) ~= 'string' or name == '' then return nil end
  local key = tostring(role or 'guest')
  local now = tonumber(host.now()) or 0
  local entry = catalog_parameters[key]
  if not entry or now - entry.at >= CATALOG_TTL then
    entry = { at = now, by_name = {} }
    local ok, list = pcall(M.catalog, role)
    if ok and type(list) == 'table' then
      for _, item in ipairs(list) do
        local fn = item['function'] or {}
        if type(fn.name) == 'string' and type(fn.parameters) == 'table' then entry.by_name[fn.name] = fn.parameters end
      end
    end
    catalog_parameters[key] = entry
  end
  return entry.by_name[name]
end


-- Hook points around one tool call (docs/HOOKS.md). This wrapper is the one funnel every tool call
-- passes - the model's, a subagent's, a probe's, and one made *inside* another call: code mode's
-- `await tools.bash(...)`, `tool_call {name=...}`, a `remote {capability:"batch"}` entry that runs
-- here (`remote_batch` dispatches it through this file). A nested dispatch is a hook
-- boundary of its own, so `PreToolUse` cannot be bypassed by calling a tool a second way (11/11: the
-- engine fired only for the outermost call, so a script - the way this node is normally worked -
-- reached any tool and no hook ever saw it). It is inert with no hooks configured: `hooks.active` is
-- a cached lookup and the two `fire` calls answer an empty verdict without reading a file or starting
-- a process.
local function hook_ctx(ctx)
  return { session_id = ctx.session_id, run_id = ctx.run_id or ctx.steering_run_id, node_id = ctx.node_id,
    user_id = ctx.user_id, role = ctx.role or ctx.subagent and "subagent" or nil, cwd = ctx.cwd,
    subagent = ctx.subagent }
end

-- The payload carries the arguments a hook may rewrite and a bounded, redacted view of a result.
-- Text the node would not put in a transcript does not go to a hook either, and a huge tool result is
-- clipped rather than copied - a hook that needs the whole file can read it.
local function hook_result_view(output)
  local ok, flat = pcall(json.encode, output or {})
  if not ok or type(flat) ~= "string" then return nil, nil end
  local encoded = flat
  if redact.value then
    local redacted_ok, redacted = pcall(redact.value, output, { tool = "hook" })
    if redacted_ok and redacted then
      local encoded_ok, value = pcall(json.encode, redacted)
      if encoded_ok and type(value) == "string" then encoded = value end
    end
  end
  local bytes = #encoded
  if bytes > 8000 then
    return { truncated = true, bytes = bytes, view = encoded:sub(1, 8000) }, bytes
  end
  local decoded_ok, decoded = pcall(json.decode, encoded)
  return decoded_ok and type(decoded) == "table" and decoded or { view = encoded }, bytes
end

-- A hook that itself runs a tool is running *inside* the engine: that dispatch does not fire the
-- engine again, or one hook would re-enter itself for as long as its own call lasts. The count is
-- also why there is no recursion loop to bound elsewhere - it never grows past the one live firing.
local hook_depth = 0
local function hook_fire(event, payload, ctx)
  hook_depth = hook_depth + 1
  local ok, verdict = pcall(hookslib.fire, event, payload, ctx)
  hook_depth = hook_depth - 1
  if not ok then error(verdict) end
  return verdict
end

local dispatch = M.dispatch
-- `same_call` means this dispatch is the tool *continuing* the call it was handed, not a second
-- logical call: `bash` starting its own supervised operation, a history read forwarded to the peer
-- that holds it, the operation read that collects a batch's output. Those do not fire again - a deny
-- answered for the plumbing of a call that already ran is the "deny after the effect" this wrapper
-- exists to prevent. Every other nested dispatch is a boundary, and it is an argument rather than
-- ambient state on `ctx`, so a nested *different* call cannot inherit a suppression it was never
-- granted.
function M.dispatch(memory,name,args,role,ctx,cwd_provenance,same_call)
  ctx=ctx or {}
  -- Every return of this wrapper is a refusal a model may read, so all of them pass the one renderer.
  local function refuse(value)
    if type(value)~="table" or value.error==nil then return value end
    return refusal.finalize(value,{tool=name,role=role,args=args,input=ctx.tool_arguments_json,
      parameters=parameters_of(name,role),site="the tool dispatcher"})
  end
  local generation=ctx.resource_effect_generation or 0
  local boundary = not same_call and hook_depth == 0 and hookslib.active()
  local call_args = args
  local pre
  if boundary then
    pre = hook_fire('PreToolUse', { tool_name = name, tool_input = args or {},
      tool_call_id = ctx.tool_call_id, cwd = ctx.cwd or platform.cwd() }, hook_ctx(ctx))
    if pre.blocked then
      return refuse({ error = 'hook_denied', denied_by = pre.blocked_by, permission = pre.permission,
        reason = pre.reason, effect = 'none', hook_system_messages = pre.system_messages,
        note = 'A configured hook refused this call: ' .. tostring(pre.reason) })
    end
    if next(pre.updated_input or {}) ~= nil then
      local merged = {}
      for key, value in pairs(args or {}) do merged[key] = value end
      for key, value in pairs(pre.updated_input) do merged[key] = value end
      call_args = merged
    end
  end
  -- The canonical checkout is one shared resource (lua/core/canonical_guard.lua): a session that does not
  -- hold the landing lease may not write into it. Refused HERE, before the tool runs, because a check after
  -- the write is a report about damage, not a boundary. Reads stay allowed.
  local protected = canonical_guard.guard(name, call_args, ctx)
  if protected then return refuse(protected) end
  local ok,result=pcall(dispatch,memory,name,call_args,role,ctx,cwd_provenance)
  -- Uncertainty is for unknown *effects*, not for refusals. A result the node marked
  -- `effect:"none"` never reached the client, so it cannot have changed anything, and
  -- branding the run's claims for it would take the client away from the run that had
  -- simply mistyped something.
  local no_effect = type(result)=="table" and result.effect=="none"
  if (ctx.resource_effect_generation or 0)>generation and not no_effect and (not ok or type(result)~="table" or result.error
      or result.ok==false or result.cancelled or result.cleanup=="unknown"
      or (result.code and result.code~=0) or result.state=="running" or result.state=="unknown") then
    local marked=resources.uncertain(ctx)
    if not marked.ok then error("resource_uncertainty_record_failed: "..json.encode(marked)) end
  end
  if boundary then
    -- The post-event payload costs a JSON encode of the whole result, so it is built only for the
    -- events that have somewhere to go: configured hooks, or the shipped guard's own verdict. With no
    -- configured hooks the guard is the entire post-processing and this path stays as cheap as it was.
    local configured = hookslib.configured()
    local failed = (not ok) or (type(result) ~= "table") or result.error ~= nil or result.ok == false
      or result.cancelled == true or (result.code and result.code ~= 0) or result.state == "unknown"
    local post
    if configured then
      local payload = { tool_name = name, tool_input = call_args or {}, tool_call_id = ctx.tool_call_id,
        cwd = ctx.cwd or platform.cwd(), ok = not failed, effect = type(result) == "table" and result.effect or nil }
      if failed then
        payload.error = not ok and tostring(result) or (type(result) == "table" and result.error) or "tool_failed"
      else
        payload.tool_response, payload.tool_response_bytes = hook_result_view(result)
      end
      post = hook_fire(failed and 'PostToolUseFailure' or 'PostToolUse', payload, hook_ctx(ctx))
    end
    local extra = {}
    if pre and pre.additional_context then extra[#extra + 1] = pre.additional_context end
    if post and post.additional_context then extra[#extra + 1] = post.additional_context end
    local messages = {}
    for _, text in ipairs((pre and pre.system_messages) or {}) do messages[#messages + 1] = text end
    for _, text in ipairs((post and post.system_messages) or {}) do messages[#messages + 1] = text end
    if type(result) == "table" then
      if #extra > 0 then result.hook_context = table.concat(extra, "\n") end
      if #messages > 0 then result.hook_system_messages = messages end
    end
  end
  -- The one boundary every refusal crosses: the code in `error` is never touched, and a message, the
  -- offending input and a fix are added where they are missing (lua/core/refusal.lua).
  if ok then result=refuse(result) end
  if not ok then error(result) end
  return result
end

-- Every answer carries one status (lua/core/status.lua): stamped here, around the whole dispatcher, so
-- every return path - refusals, hooks, effects, scripts - gets the same signal without each site saying it.
do
  local status = dofile("lua/core/status.lua")
  local bash_result = dofile("lua/core/bash_result.lua")
  local inner = M.dispatch
  -- A command's answer is slimmed HERE, at the one door every call passes last: after the hooks, after
  -- the refusal renderer and after the status stamp, so every other caller of this layer sees exactly
  -- what it saw before and only the answer a script receives changes. The record keeps every field -
  -- `operation {action="status", id=<operation_id>}` answers it (lua/core/bash_result.lua, mission
  -- slim-tool-results).
  M.dispatch = function(memory, name, args, role, ctx, cwd_provenance, same_call)
    return bash_result.slim_for(name, args,
      status.stamp(inner(memory, name, args, role, ctx, cwd_provenance, same_call)))
  end
end

return M
