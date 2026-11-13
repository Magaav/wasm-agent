-- Live reload: the UI and command layer of a running CLI is replaced without restarting it.
--
-- WHY. Every visible part of `wa chat` - the slash commands and the balloon they draw in, the status
-- bar, the wake line, the transcript's formatting, the tool titles and result views, the skills list,
-- the palette, the journal - is Lua, and until now it was read ONCE, at start. So a one-word change to
-- how `/mcp` lines its connectors cost a process restart, a session re-attach and a lost run: the
-- operator asked for it on 13/11 ("i like this live reloads apply this update"), pointing at Claude
-- Code's statusLine - a fresh process per refresh reading state from files, so an edit shows on the next
-- tick with no restart. The shape here is the same idea taken one step in: a fresh MODULE per change,
-- swapped in at the next frame or command, with the state left where the core keeps it.
--
-- WHAT MOVES, AND WHAT NEVER DOES. Two sets, both data (below), and `M.require` decides which one a
-- path belongs to:
--
--   UI       reloadable. It draws, formats, lists, or runs a command's own view. A wrong one costs a
--            frame and is undone by the next edit - which is why it may be replaced while a run streams.
--   GUARD    never reloadable. The hooks engine, the path guard, the canonical-worktree guard, the
--            progress guard, the code-mode policy, the done gate, the release and payload signature
--            checks, the access/binding policy, the vault, `wa land`, and this file. A guard that could
--            be replaced from a reload source is a guard that can be replaced by whoever can write a
--            file - so these are loaded from the node's OWN source (the binary's embedded tree, or the
--            checkout the process was started from) and no reload source is ever consulted for one.
--            `scripts/test-hotreload.lua` lists them and fails when a poisoned copy in a reload tree
--            reaches the process.
--
--   CORE     everything else under `lua/core` (the agent, memory, provider, tools, the ledger). Not
--            reloadable either, for a different reason: it owns the session, the run and the database
--            handle, and a second copy of it mid-run is two writers on one ledger.
--
--   RUNTIME  not Lua at all: the terminal driver (`rust/wa-term`: raw mode, the screen buffer, the
--            transcript, the editor), the capability surface and the interpreter (`wa-capabilities`:
--            `host.rs`, `core_component.rs`), and the process that owns the session
--            (`wa-host/src/main.rs`). Listed here so the list is one place, and checked the same way.
--
-- STATE. A reload drops nothing because the reloadable modules no longer keep state. `M.store` is one
-- table owned by the core, created once per process, and it holds what the UI layer persists between
-- frames and between module versions: the live views, the balloon's page, the scroll anchor, the wake
-- fact, the input object, the notice row. A module may not add a field to it and expect it to survive a
-- swap of ITSELF: the store is the core's, the version counter in it is bumped on every swap, and the
-- pieces the UI owns are documented at the field (`session view state`, `balloon`, `scroll`, `wakes`,
-- `input`, `notices`). Two places that used to keep module-level state - `cli_view.restart_seen` and
-- `local_views.published_at` - are caches in this store now, so the swapped-in copy starts warm.
--
-- SOURCES, TWO ONLY (`M.mode`):
--
--   dev      `wa chat --dev <dir>` (or `WASM_AGENT_HOTRELOAD_DEV=<dir>`): the operator's working tree.
--            The status bar says `dev reload`, because a CLI running code that is not what it was
--            installed with has to SAY so on the row a reader looks at.
--   release  the installed release payload (`<config>/payload`, `WASM_AGENT_HOTRELOAD_PAYLOAD` to name
--            another) - a committed tree written beside the node by a deploy, so a deploy of UI-only
--            changes reaches sessions that are already running. Accepted only when its `SHA256SUMS`
--            verifies against a trusted release key AND every file that is loaded matches its line in
--            those sums (`lua/core/payload.lua`): change/sign is on main, so nothing here is accepted
--            unsigned.
--
-- FAILURE. Loading is `load(text, name, "t", env)` into a FRESH environment (one that inherits `_G`,
-- so a module still sees `host`, `utf8`, `string`, but whose own globals and upvalues are private), then
-- a self-check - the module's own `M.selfcheck` when it has one, and `PROBE`'s render probe, which
-- calls the new code rather than looking at it, because "it parsed" is not "it renders". Only then is
-- the module table swapped. A syntax error, a load-time error, a failing self-check or a render that
-- raises keeps the OLD module and produces ONE line: `reload failed: <path>: <error>`. Nothing is ever
-- half-swapped: the swap is one assignment to `entry.mod`, and every caller reaches it through a proxy,
-- so the next lookup is the new copy and nothing that has already been entered is changed underneath it.
--
-- MEASURED (`scripts/test-hotreload.lua`, this node, 13/11): save -> visible 41 ms in dev (throttle 250
-- ms, so worst case is throttle + scan + load: 6 ms scans a 130 kB module's directory and loads + probes
-- it). The per-frame cost of not reloading is one `host.list_dir` of `lua/core` (126 entries) per 250 ms
-- while the UI is drawing, and 0 when no reload source is configured - the fast path's own timing is
-- unchanged because `M.tick` returns before it asks the host anything.
if __wa_reload then return __wa_reload end

local json = dofile("lua/vendor/json.lua")

local M = {}

-- One instance per process. The reload module is loaded by several callers (the chat, the view, a
-- command) and a second instance would be a second store - state kept in the wrong one, and a swap
-- nobody rebinds. The singleton is also what `dofile`-loaded modules find.
__wa_reload = M

-- How often the reload source's directories are listed, in seconds. Dev is a person pressing save; the
-- payload is a deploy, and a deploy is not a race with a keystroke. Both are wall-clock, from
-- `host.now()`.
M.THROTTLE = 0.25
M.THROTTLE_RELEASE = 2.0

-- ---------------------------------------------------------------------------- what may be reloaded

-- The UI and command layer: what draws, formats, lists, or runs a command's view. Adding a module here
-- is the whole opt-in; `M.require` is what makes the callers go through the proxy.
local UI = {
  "lua/core/cli_view.lua",         -- the render: status bar, wake line, tool titles, result views, banner
  "lua/core/balloon.lua",          -- every command's overlay
  "lua/core/commands.lua",         -- the slash-command registry and `/help`
  "lua/core/status.lua",           -- `/status`
  "lua/core/markdown.lua",         -- output formatting (fenced blocks, inline styles, wrapping)
  "lua/core/command_output.lua",   -- a command's output as rows
  "lua/core/cli_panel.lua",        -- the panel spec a command hands the host
  "lua/core/local_views.lua",      -- the mid-run view channel
  "lua/core/codemode_view.lua",    -- a code-mode script's result view
  "lua/core/codemode_block.lua",   -- the block a code-mode script draws in
  "lua/core/evidence_view.lua",    -- how a failure is shown
  "lua/core/capture_view.lua",     -- how a capture is shown
  "lua/core/fleetview.lua",        -- the fleet pages
  "lua/core/mcp_command.lua",      -- `/mcp` pages
  "lua/core/mcp_cli.lua",          -- `/mcp` walk
  "lua/core/nodes_cli.lua",        -- `/nodes` pages
  "lua/core/model_cli.lua",        -- `/model`, `/reasoning`
  "lua/core/provider_management.lua", -- `/login`, `/provider`
  "lua/core/binding_cli.lua",      -- `/bind`, `/nodes`, `/accept`, ...
  "lua/core/services_cli.lua",     -- `/services` pages
  "lua/core/steer_cli.lua",        -- the steering queue's rows
  "lua/core/tool_progress.lua",    -- a running tool's live row
  "lua/core/skills.lua",           -- the skills list and what a skill says it is for
  "lua/core/harness_evaluator_cli.lua", -- the evaluator's report, as rows
}

-- Never reloadable, and named one by one rather than by a pattern: a list a reviewer can read is the
-- point. Each is a guard, a policy or the machinery that decides what may be loaded at all.
local GUARD = {
  "lua/core/hooks.lua",            -- the hooks engine (and the mods that run through it)
  "lua/core/hooks_defaults.lua",
  "lua/core/hook_events.lua",
  "lua/core/path_guard.lua",       -- the delete/path guard
  "lua/core/canonical_guard.lua",  -- the canonical-checkout guard
  "lua/core/progress_guard.lua",   -- no silent success
  "lua/core/codemode_policy.lua",  -- what a code-mode script may reach
  "lua/core/done_gate.lua",        -- the done-criteria gate
  "lua/core/release.lua",          -- the release signature/version check
  "lua/core/payload.lua",          -- the payload signature check, and the source this file reads
  "lua/core/access.lua",           -- operator policy: who may reach this node
  "lua/core/binding.lua",          -- the two-sided fabric consent
  "lua/core/vault.lua",            -- keys by reference
  "lua/core/land.lua",             -- signing, and nothing ships unsigned
  "lua/core/retired.lua",          -- what may not be replayed
  "lua/core/reload.lua",           -- this file: a reloader that can be reloaded is not one
  "lua/core/redact.lua",           -- what must never be printed
}

-- Not Lua. The terminal driver, the interpreter and its capability surface, and the process that owns
-- the session: these are compiled in, and a reload source cannot supply them because it cannot supply
-- anything that is not a Lua module. Listed so the guard test has one list to check and so a reader
-- asking "why can't the status row's driver be live?" finds the answer beside the ones that can.
M.RUNTIME = {
  "rust/wa-term/src/terminal_editor.rs", -- raw mode, input, screen buffer, the editor
  "rust/wa-term/src/transcript.rs",      -- the transcript the host draws
  "rust/wa-term/src/selection.rs",
  "rust/wa-term/src/tool_progress.rs",
  "rust/wa-term/src/build_status.rs",
  "rust/wa-term/src/scroll/",            -- the fullscreen transcript's scrolling
  "rust/wa-capabilities/src/host.rs",    -- the capability surface Lua calls
  "rust/wa-capabilities/src/core_component.rs", -- the wasmtime host and the Lua VM boot
  "rust/wa-capabilities/src/capabilities.rs",   -- and its grant table
  "rust/wa-capabilities/src/disk.rs",           -- disk_cap
  "rust/wa-agent/src/guards.rs",
  "rust/wa-host/src/main.rs",            -- the process: the session and the in-flight run
  "rust/wa-host/src/release.rs",         -- the trusted-key verifier
}

-- The IPC ops a component implements are a contract with the seam, and a component is installed bytes,
-- not source: a reload cannot reach them at all. Named for the guard test's inventory line.
M.COMPONENTS = "a WASI component is installed bytes (components.lock), never a reload source"

local ui_set, guard_set = {}, {}
for _, path in ipairs(UI) do ui_set[path] = true end
for _, path in ipairs(GUARD) do guard_set[path] = true end

M.UI, M.GUARD = UI, GUARD

-- What a path is, for every path this process can be asked to load:
--   "ui"      reloadable, may come from a reload source
--   "guard"   never reloadable, always from the node's own source
--   "core"    the rest of `lua/` (agent, memory, tools, the ledger): not reloadable either
--   "vendor"  third-party Lua (`lua/vendor`): not reloadable
--   "runtime" a compiled piece a reload source cannot supply
--   nil       not a Lua module of this tree at all, and `M.require` refuses it by name
function M.class(path)
  path = tostring(path or ""):gsub("\\", "/")
  if ui_set[path] then return "ui" end
  if guard_set[path] then return "guard" end
  for _, prefix in ipairs(M.RUNTIME) do
    if path == prefix or (prefix:sub(-1) == "/" and path:sub(1, #prefix) == prefix) then return "runtime" end
  end
  if path:match("^lua/core/[^/]+%.lua$") then return "core" end
  if path:match("^lua/vendor/[^/]+%.lua$") then return "vendor" end
  return nil
end

-- Is a reload source ever consulted for this path? One function, so a caller cannot answer it
-- differently from the loader.
function M.reloadable(path) return M.class(path) == "ui" end

-- ---------------------------------------------------------------------------- the store

-- One table, owned by the core, created here and never replaced. Documented field by field because
-- "state out of the modules" is only true if the reader can see where it went.
--
--   version   bumped on every swap: a module that caches a rendering can tell its copy is stale
--   views     the live `cli_view` objects, oldest first (session view state lives IN them, see below)
--   objects   {path, object, rebind} - every live object a swap has to point at the new methods
--   balloon   the balloon's own state: the stack it last showed, the page it was on, the selection
--   scroll    the output region's anchor: {top, at} - where a reload should keep the reader looking
--   wakes     the self-wake fact the footer draws: {text, rows, at}
--   input     the `cli_input` object (its pending lines and its eof)
--   notices   one line per reload failure, newest last, with how often it repeated
--   swaps     how many swaps happened, failures how many were refused
--   stamps    {path: "size:modified"} - the freshness of every watched file, from one directory listing
--   checked   when the source was last listed (per mode, see THROTTLE)
M.store = {
  version = 0,
  views = {},
  objects = {},
  balloon = { stack = {}, page = 1, selected = 1, command = nil },
  scroll = { top = 0, at = 0 },
  wakes = { text = "", rows = {}, at = 0 },
  input = nil,
  notices = {},
  swaps = 0,
  failures = 0,
  last = nil,
  stamps = {},
  checked = -1,
  refused = {},
  payload = nil,
}

-- A named piece of the store, created on first use. Modules ask for a name (`M.state("balloon")`), never
-- for the store itself: a module that could replace the store could lose the state it was swapped to
-- preserve.
function M.state(name)
  name = tostring(name or "")
  if name == "" then return M.store end
  if type(M.store[name]) ~= "table" then M.store[name] = {} end
  return M.store[name]
end

-- A live object that a swap of `path` must rebind. `rebind(mod)` gets the new module table; the object
-- keeps its own fields, which is the whole of "a reload drops no state".
function M.object(path, object, rebind)
  M.store.objects[#M.store.objects + 1] = { path = path, object = object, rebind = rebind }
  return object
end

function M.unbind(object)
  for index = #M.store.objects, 1, -1 do
    if M.store.objects[index].object == object then table.remove(M.store.objects, index) end
  end
end

-- The live views, registered by `cli_view.new` (`views` above). A view is session view state: its
-- fields are the run, the phase, the footer's numbers and the rows it has drawn, so a swap must not
-- touch the object - only the methods it answers with.
function M.view(view, rebind)
  M.store.views[#M.store.views + 1] = view
  return M.object("lua/core/cli_view.lua", view, rebind)
end

function M.drop_view(view)
  for index = #M.store.views, 1, -1 do
    if M.store.views[index] == view then table.remove(M.store.views, index) end
  end
  M.unbind(view)
end

-- ---------------------------------------------------------------------------- the source

local config = { dev = nil, payload = nil }

-- Name the reload source. `--dev <dir>` (or the environment) wins over the installed payload, because a
-- developer asking for their working tree means it even on a node that has a payload.
function M.configure(opts)
  opts = opts or {}
  config.dev = (type(opts.dev) == "string" and opts.dev ~= "") and opts.dev or nil
  config.payload = (type(opts.payload) == "string" and opts.payload ~= "") and opts.payload or nil
  M.store.stamps, M.store.checked = {}, -1
  installed_cache = nil
  return M.mode()
end

local function env(name)
  local value = host.getenv(name)
  if type(value) ~= "string" or value == "" then return nil end
  return value
end

-- The payload the node was deployed with, when it has one. `lua/core/payload.lua` owns the signature
-- check; this only asks it where the tree is. Both answers are cached: `M.mode` is asked on every frame
-- (the status line asks whether it must say `dev reload`) and a `dofile` per frame would be a reload
-- mechanism that costs more than the thing it reloads. `M.configure` is what invalidates them.
local payload_cache, installed_cache = nil, nil
local function payload_module()
  if payload_cache then return payload_cache end
  local ok, module = pcall(dofile, "lua/core/payload.lua")
  if ok and type(module) == "table" then payload_cache = module; return module end
  return nil
end

local function payload_dir()
  if config.payload then return config.payload end
  local declared = env("WASM_AGENT_HOTRELOAD_PAYLOAD")
  if declared then return declared end
  if installed_cache ~= nil then return installed_cache or nil end
  local module = payload_module()
  local dir = nil
  if module then
    local ok, answer = pcall(module.installed)
    if ok and type(answer) == "string" and answer ~= "" then dir = answer end
  end
  installed_cache = dir or false
  return dir
end

-- "dev", "release" or nil. Nil is ordinary: a node started from its own binary with no payload and no
-- `--dev` has nothing to reload from, and every entry point here returns before asking the host
-- anything.
function M.mode()
  if config.dev then return "dev" end
  local dir = payload_dir()
  if dir then return "release" end
  return nil
end

-- The tree the reloadable modules are read from: the operator's checkout, or the installed payload.
function M.root()
  local mode = M.mode()
  if mode == "dev" then return config.dev end
  if mode == "release" then return payload_dir() end
  return nil
end

-- What the status bar says about this, or nil for nothing to say. A dev tree is said out loud -
-- `dev reload` - because a CLI whose commands are not the ones it was installed with is a fact a reader
-- acts on. A deployed payload is the node's own bytes and says nothing.
function M.status()
  if M.mode() == "dev" then return "dev reload" end
  return nil
end

-- ---------------------------------------------------------------------------- loading

-- path -> {path, class, mod, previous, proxy, source, stamp, swaps, failed_stamp, error}
local loaded = {}

-- A fresh environment for one load: it INHERITS `_G` (a module keeps `host`, `json`, `string`, `utf8`,
-- `os.date`, `pcall` - everything it had), and its own assignments land in this table instead of in the
-- shared one, so the copy that is swapped out cannot see or set what the copy swapped in does. `dofile`
-- is routed through this file, so a reloadable module's reloadable dependencies come from the same
-- reload source (a dev tree's `cli_view` gets the dev tree's `markdown`, not the binary's).
local function module_env()
  local environment = setmetatable({}, { __index = _G })
  environment.dofile = function(path)
    if M.reloadable(path) then return M.require(path) end
    return dofile(path)
  end
  environment.reload = M
  return environment
end

-- The node's OWN text for a module: the tree compiled into the binary (`EMBEDDED`, published by the boot
-- in rust/wa-capabilities/src/core_component.rs and rust/wa-host/src/main.rs) or, for a process started
-- from a checkout, the file under `WASM_AGENT_LUA_ROOT`. Never a reload source: the reload tree is only
-- ever consulted by `text_of` below, and only for a ui module.
local function node_text(path)
  if type(EMBEDDED) == "table" and type(EMBEDDED[path]) == "string" then return EMBEDDED[path] end
  local root = host.getenv("WASM_AGENT_LUA_ROOT")
  if type(root) ~= "string" or root == "" then return nil end
  local ok, text = pcall(host.read_file, root:gsub("/+$", "") .. "/" .. path)
  if not ok or type(text) ~= "string" or text == "" then return nil end
  return text
end

-- The text a reload source holds for a module, and the file it came from: nil when this node has no source
-- or the source does not carry that file (the ordinary state of a dev tree that only holds what is being
-- edited). Only ever asked about a ui module - `load_from` decides that.
local function text_of(path)
  local dir = M.root()
  if not dir then return nil end
  local file = dir:gsub("/+$", "") .. "/" .. path
  local ok, text = pcall(host.read_file, file)
  if not ok or type(text) ~= "string" or text == "" then return nil end
  return text, file
end

-- The payload's signature gate, applied to the file about to be loaded. In release mode a module is
-- only accepted when the payload verified AND this file's bytes are the ones the signed sums name; in
-- dev mode the operator's tree is the operator's, and saying so on the status bar is the whole guard.
local function accepted(path, text)
  if M.mode() ~= "release" then return true end
  local module = payload_module()
  if not module then return false, "payload_gate_missing: lua/core/payload.lua did not load" end
  local dir = M.root()
  local ok, problem = module.ensure(dir)
  if not ok then return false, tostring(problem or "payload_refused") end
  local fine, mismatch = module.file_ok(dir, path, text)
  if not fine then return false, tostring(mismatch or "payload_file_mismatch: " .. path) end
  return true
end

-- The module's own self-check, then the render probe. Both run the NEW code, not a description of it:
-- a syntax error is caught by `load`, and a render that raises is caught here, before the swap.
local PROBE = {
  ["lua/core/cli_view.lua"] = function(module)
    local view = module.new({ out = function() end, live = false, limit = 80, register = false })
    assert(type(view) == "table", "cli_view.new returned " .. type(view))
    local line = view:status_text(false)
    assert(type(line) == "string", "status_text returned " .. type(line))
    assert(type(module.banner({ limit = 80, version = "probe" })) == "string", "banner")
    assert(type(module.paint("x", "accent", false)) == "string", "paint")
    assert(type(module.tool_title("bash", { command = "true" }, 80)) == "string", "tool_title")
    -- The result view: `outcome` answers (did it work, the words). A successful bash result is a pass with
    -- a summary, which is the one judgement every tool result goes through.
    local passed, summary = module.outcome("bash", { code = 0, stdout = "ok" }, { command = "true" })
    assert(passed == true and type(summary) == "string", "outcome")
    local failed_ok, failure = module.outcome("bash", { code = 1, stderr = "no" }, { command = "false" })
    assert(failed_ok == false and type(failure) == "string", "outcome of a failure")
    assert(type(module.wake_text(nil)) == "string", "wake_text")
  end,
  ["lua/core/balloon.lua"] = function(module)
    local pages = module.paged("Probe", { "one", "two" }, { per = 2 })
    assert(type(pages) == "table" and #pages > 0, "paged")
    assert(type(module.text(pages, 80)) == "string", "text")
    local rows = module.page_text(module.page({ title = "t", lines = { "l" } }), 80)
    assert(type(rows) == "table" and #rows > 0, "page_text")
  end,
  ["lua/core/commands.lua"] = function(module)
    assert(type(module.help()) == "string" and #module.help() > 0, "help")
    assert(#module.menu() > 0, "menu")
    assert(#module.names() > 0, "names")
  end,
  ["lua/core/markdown.lua"] = function(module)
    assert(type(module.columns("plain text")) == "number", "columns")
  end,
  ["lua/core/status.lua"] = function(module)
    assert(type(module.session_lines) == "function", "session_lines")
  end,
}

local function probe(path, module)
  if type(module) ~= "table" then return false, "module returned " .. type(module) end
  if type(module.selfcheck) == "function" then
    local ok, answer = pcall(module.selfcheck)
    if not ok then return false, tostring(answer) end
    if answer == false or (type(answer) == "string" and answer ~= "") then
      return false, tostring(answer ~= true and answer or "selfcheck refused")
    end
  end
  local check = PROBE[path]
  if check then
    local ok, answer = pcall(check, module)
    if not ok then return false, tostring(answer) end
  end
  return true
end

-- One line, whatever the error was: a failure is one row on a screen, not a stack trace in the middle
-- of a run. The module's path is the whole name a reader needs to open the file.
local function one_line(problem)
  local text = tostring(problem or "unknown error"):gsub("^%s+", ""):gsub("%s+$", "")
  local first = text:match("^[^\n]*") or text
  return (first:gsub("^.-:%d+:%s*", ""))
end

-- The one line a failure produces, kept in the store as well as printed, so a test - or a `/reload`
-- report - can read what happened without scrubbing a screen.
local function fail(entry, problem, now)
  local text = "reload failed: " .. entry.path .. ": " .. one_line(problem)
  M.store.failures = M.store.failures + 1
  local notice = M.store.notices[#M.store.notices]
  if notice and notice.text == text then
    notice.count, notice.at = (notice.count or 1) + 1, now
  else
    M.store.notices[#M.store.notices + 1] = { ok = false, text = text, at = now, path = entry.path, count = 1 }
  end
  entry.error = text
  return text
end

-- The freshness of one file, read now: `size:modified` from a listing of its own directory. It is what a
-- load records, so the stamp and the bytes are the same reading - a file loaded from the reload tree is
-- stamped at exactly the version that was loaded, and the NEXT edit is a change. (Recording the stamp of
-- the last scan instead left the first edit after a load looking like the state we had always been in, so
-- the first save was ignored: measured, 13/11.)
local function entries_of(directory)

  local ok, raw = pcall(host.list_dir, directory)
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, listing = pcall(json.decode, raw)
  if not decoded_ok or type(listing) ~= "table" or type(listing.entries) ~= "table" then return nil end
  return listing.entries
end

local function stamp_stamp(item)
  return tostring(item.size or 0) .. ":" .. tostring(item.modified or 0)
end

local function stamp_file(path)
  local dir = M.root()
  if not dir then return nil end
  local folder = path:match("^(.*)/[^/]+$")
  local name = path:match("([^/]+)$")
  if not folder or not name then return nil end
  for _, item in ipairs(entries_of(dir:gsub("/+$", "") .. "/" .. folder) or {}) do
    if item.kind == "file" and tostring(item.name) == name then return stamp_stamp(item) end
  end
  return nil
end

-- Load `path` from the reload source when it has one, else from the node's own tree, and answer the
-- module table plus where it came from and the freshness stamp it was read at.
local function load_from(path)
  local entry = loaded[path]
  local source = "node"
  local text, file = nil, nil
  if M.reloadable(path) then text, file = text_of(path) end
  if text then
    local fine, problem = accepted(path, text)
    if not fine then return nil, problem, "reload" end
    -- `load` answers nil AND the compiler's own sentence for a syntax error, so the second value is the
    -- message a reader needs; a chunk that raises is the `pcall` below.
    local compiled, chunk, complaint = pcall(load, text, "@" .. (file or path), "t", module_env())
    if not compiled then return nil, tostring(chunk), "reload" end
    if type(chunk) ~= "function" then
      return nil, tostring(complaint or ("the file did not compile: " .. tostring(chunk))), "reload"
    end
    local ran, result = pcall(chunk)
    if not ran then return nil, tostring(result), "reload" end
    source = "reload"
    local fine2, problem2 = probe(path, result)
    if not fine2 then return nil, problem2, "reload" end
    return result, nil, source
  end
  -- The node's own source: the binary's embedded tree, or the checkout the process was started from.
  -- This is the path every guard takes, always - a plain `dofile`, so a guard sees the global `dofile`
  -- and no reload source can be named by anything it calls.
  if entry and entry.class == "ui" then
    -- A UI module from the NODE is still compiled into its own fresh environment, for one reason that
    -- matters in practice: its own `dofile` must be the routed one, so the modules it calls are resolved
    -- through this file too. Without that, a dev tree holding only the file being edited (`mcp_command`
    -- without `mcp_cli`) would give a half-reloaded UI - the copy read through the node's `dofile` would
    -- call the node's dependency and the edit would never appear. A full checkout, which is the ordinary
    -- `--dev` case, behaves the same either way.
    local own = node_text(path)
    if own then
      local compiled, chunk, complaint = pcall(load, own, "@" .. path, "t", module_env())
      if not compiled then return nil, tostring(chunk), source end
      if type(chunk) ~= "function" then return nil, tostring(complaint or "did not compile"), source end
      local ran, result = pcall(chunk)
      if not ran then return nil, tostring(result), source end
      local fine, problem = probe(path, result)
      if not fine then return nil, problem, source end
      return result, nil, source
    end
  end
  local ok, result = pcall(dofile, path)
  if not ok then return nil, tostring(result), source end
  return result, nil, source
end

local function proxy_for(path)
  local entry = loaded[path]
  if entry.proxy then return entry.proxy end
  local proxy = {}
  setmetatable(proxy, {
    __index = function(_, key)
      if not entry.mod then
        -- Lazy: a command's module is read when the command is used, not when the process starts, which
        -- is also what lets `--dev` be parsed before anything is read from the tree it names.
        local module, problem = M.load(path)
        if not module then error("reload: " .. path .. ": " .. tostring(problem), 2) end
        entry.mod = module
      end
      return entry.mod[key]
    end,
  })
  entry.proxy = proxy
  return proxy
end

-- `M.require(path)`: the one entry point every caller of a reloadable module uses. It answers a stable
-- proxy, so `local cli_view = reload.require("lua/core/cli_view.lua")` keeps working across every swap
-- that module will ever have.
function M.require(path)
  path = tostring(path or ""):gsub("\\", "/")
  local entry = loaded[path]
  if entry then return entry.proxy or proxy_for(path) end
  entry = { path = path, class = M.class(path), swaps = 0 }
  loaded[path] = entry
  if not entry.class then
    error("reload: not a module of this tree: " .. path, 2)
  end
  if entry.class == "runtime" then
    -- Compiled into the binary: the terminal driver, the interpreter and its capability surface, the
    -- process that owns the session. There is no Lua module here to read, and no reload source can supply
    -- one - which is the whole of why the driver and the guards are outside this mechanism.
    error("reload: never_reloadable: " .. path .. " is compiled into this binary", 2)
  end
  if entry.class ~= "ui" then
    -- A guard, the core or a vendor file: loaded from the node's own source, now, and never watched.
    local module, problem = load_from(path)
    if not module then error("reload: " .. path .. ": " .. tostring(problem), 2) end
    entry.mod, entry.source, entry.static = module, "node", true
  end
  return proxy_for(path)
end

-- Load a reloadable module now, from whichever source it has, and answer the module table (not the
-- proxy). The first load's stamp is what the watcher compares against, so a module that was already
-- edited before the CLI started is picked up by the first tick rather than reported as a change.
function M.load(path)
  path = tostring(path or ""):gsub("\\", "/")
  local entry = loaded[path]
  if not entry then
    entry = { path = path, class = M.class(path), swaps = 0 }
    loaded[path] = entry
  end
  local module, problem, source = load_from(path)
  if not module then return nil, problem end
  entry.mod, entry.source = module, source
  -- The stamp is what this load READ, not what the last scan saw. A module read from the NODE is stamped
  -- `""` - the absence of a file in the reload tree - so the first copy to appear there is a change, which
  -- is what `--dev` on a tree that does not carry that file yet has to do. (Leaving it nil made the first
  -- scan record it instead of swapping, and the first save after a load was ignored: measured, 13/11.)
  entry.stamp = source == "reload" and (stamp_file(path) or "") or ""
  return entry.mod
end

function M.is_loaded(path)
  local entry = loaded[tostring(path or "")]
  return entry and entry.mod ~= nil or false
end

function M.source_of(path)
  local entry = loaded[tostring(path or "")]
  return entry and entry.source or nil
end

function M.loaded_paths()
  local paths = {}
  for path in pairs(loaded) do paths[#paths + 1] = path end
  table.sort(paths)
  return paths
end

M.module = function(path)
  local entry = loaded[tostring(path or "")]
  return entry and entry.mod or nil
end

-- ---------------------------------------------------------------------------- the swap

-- Replace one module, atomically or not at all: the new table is fully loaded and probed before the
-- assignment that makes it the live one, and every live object registered for this path is rebound
-- AFTER it, so a rebind failure cannot leave the process pointing at a half-swapped module.
function M.swap(path)
  path = tostring(path or ""):gsub("\\", "/")
  local entry = loaded[path]
  if not entry then return false, "not_loaded: " .. path end
  if entry.class ~= "ui" then return false, "never_reloadable: " .. path end
  local now = host.now()
  local module, problem, source = load_from(path)
  if not module then return false, fail(entry, problem, now) end
  local previous = entry.mod
  entry.mod, entry.previous, entry.source = module, previous, source
  entry.swaps = entry.swaps + 1
  entry.error = nil
  entry.stamp = stamp_file(path) or entry.stamp or ""
  M.store.version = M.store.version + 1
  M.store.swaps = M.store.swaps + 1
  M.store.last = { path = path, source = source, at = now, ms = 0 }
  for _, object in ipairs(M.store.objects) do
    if object.path == path and object.object then
      local ok, rebind_problem = pcall(object.rebind, module)
      if not ok then return true, "rebound_failed: " .. one_line(rebind_problem) end
    end
  end
  return true, source
end

-- ---------------------------------------------------------------------------- the watcher

-- One listing per directory the watched modules live in, and a stamp of `size:modified` per file:
-- modifying a file without changing its size is the case a size-only stamp would miss, and a save is
-- what changes it. `host.list_dir` answers both in one call (rust/wa-capabilities/src/host.rs).
local function scan()
  local root = M.root()
  if not root then return false end
  local folders = {}
  for path, entry in pairs(loaded) do
    if entry.class == "ui" and entry.mod then
      local folder = path:match("^(.*)/[^/]+$")
      if folder then folders[folder] = true end
    end
  end
  local stamps = {}
  for folder in pairs(folders) do
    for _, item in ipairs(entries_of(root:gsub("/+$", "") .. "/" .. folder) or {}) do
      if item.kind == "file" then
        stamps[folder .. "/" .. tostring(item.name)] = stamp_stamp(item)
      end
    end
  end
  M.store.stamps = stamps
  return true
end

-- The tick. Called at every frame and every command boundary (`cli_view`'s framed methods, and the
-- chat's REPL loop), returns the notices the caller must draw - zero or one per changed module - and
-- never raises: a reload that failed must not take the run with it.
function M.tick(now)
  local notices = {}
  local mode = M.mode()
  if not mode then return notices end
  now = tonumber(now) or host.now()
  local throttle = mode == "dev" and M.THROTTLE or M.THROTTLE_RELEASE
  if M.store.checked >= 0 and (now - M.store.checked) < throttle then return notices end
  M.store.checked = now
  if mode == "release" then
    local module = payload_module()
    local dir = M.root()
    local ok, problem = false, "payload_gate_missing"
    if module then ok, problem = module.ensure(dir) end
    M.store.payload = { ok = ok, dir = dir, error = (not ok) and tostring(problem) or nil, at = now }
    if not ok then
      -- A payload that does not verify is said ONCE per distinct reason: it is a standing condition
      -- (someone wrote into a payload without signing it), and a line per frame would be noise over a
      -- screen the reader is trying to read.
      local text = "payload refused: " .. one_line(problem)
      local last = M.store.notices[#M.store.notices]
      if not (last and last.text == text) then
        M.store.notices[#M.store.notices + 1] = { ok = false, text = text, at = now, count = 1 }
        notices[#notices + 1] = { ok = false, text = text }
      end
      return notices
    end
  end
  if not scan() then return notices end
  for path, entry in pairs(loaded) do
    if entry.class == "ui" and entry.mod then
      local stamp = M.store.stamps[path]
      if stamp then
        if entry.stamp == nil then
          entry.stamp = stamp
        elseif stamp ~= entry.stamp and stamp ~= entry.failed_stamp then
          local started = now
          local ok, source = M.swap(path)
          local elapsed = math.max(0, (host.now() - started) * 1000)
          if ok then
            entry.failed_stamp = nil
            M.store.last = { path = path, source = source, at = started, ms = elapsed }
            notices[#notices + 1] = { ok = true, path = path, source = source,
              text = "reloaded " .. path:gsub("^lua/core/", "") .. " (" .. (source or "?") .. ", "
                .. string.format("%.0f", elapsed) .. " ms)" }
            M.store.notices[#M.store.notices + 1] = notices[#notices]
          else
            -- The stamp that failed is remembered: the same broken file is not re-read and re-reported
            -- on every frame. The next save changes it and the next tick tries again.
            entry.failed_stamp = stamp
            -- `M.swap` already recorded the failure (and its one line) in the store; the notice it
            -- hands back is the same sentence the caller must draw now.
            notices[#notices + 1] = { ok = false, text = tostring(source), path = path }
          end
        end
        entry.stamp = stamp
      end
    end
  end
  return notices
end

-- ---------------------------------------------------------------------------- the inventory

-- The classification, as data, for `/reload` (a report), the docs, and the guard test. `lua/core` is
-- listed rather than scanned with `pairs` on a directory, so a module added without a decision shows up
-- as "core" in the test's own report instead of vanishing.
function M.inventory()
  local rows, counts = {}, { ui = 0, guard = 0, core = 0, runtime = 0 }
  for _, path in ipairs(UI) do
    rows[#rows + 1] = { path = path, class = "ui", loaded = M.is_loaded(path), source = M.source_of(path) }
    counts.ui = counts.ui + 1
  end
  for _, path in ipairs(GUARD) do
    rows[#rows + 1] = { path = path, class = "guard" }
    counts.guard = counts.guard + 1
  end
  for _, path in ipairs(M.RUNTIME) do
    rows[#rows + 1] = { path = path, class = "runtime" }
    counts.runtime = counts.runtime + 1
  end
  local entries = entries_of((M.root() or ".") .. "/lua/core")
  if entries then
    for _, item in ipairs(entries) do
      local path = "lua/core/" .. tostring(item.name)
      if item.kind == "file" and path:match("%.lua$") and not ui_set[path] and not guard_set[path] then
        rows[#rows + 1] = { path = path, class = "core" }
        counts.core = counts.core + 1
      end
    end
  end
  table.sort(rows, function(a, b) return a.path < b.path end)
  return rows, counts
end

-- ---------------------------------------------------------------------------- the report

-- `/reload`'s rows: what the source is, whether it is accepted, what has been swapped and what failed.
-- One command, so an operator can see the mechanism working instead of inferring it from a screen that
-- changed on its own.
function M.report()
  local rows = {}
  local mode = M.mode()
  rows[#rows + 1] = "source    " .. tostring(mode or "none (this node runs its own binary; --dev <dir> reloads a tree)")
  if mode then rows[#rows + 1] = "tree      " .. tostring(M.root()) end
  if mode == "release" then
    local state = M.store.payload
    rows[#rows + 1] = "signature " .. (state and (state.ok and ("verified at " .. tostring(state.at)) or tostring(state.error))
      or "not checked yet")
  end
  rows[#rows + 1] = string.format("swaps     %d (%d refused, store version %d)", M.store.swaps, M.store.failures, M.store.version)
  if M.store.last then
    rows[#rows + 1] = string.format("last      %s from %s in %.0f ms", M.store.last.path,
      tostring(M.store.last.source), tonumber(M.store.last.ms) or 0)
  end
  local seen = {}
  for _, notice in ipairs(M.store.notices) do
    if not seen[notice.text] then
      seen[notice.text] = true
      rows[#rows + 1] = notice.text .. ((notice.count or 1) > 1 and (" (x" .. notice.count .. ")") or "")
    end
  end
  local loaded_rows = {}
  for _, path in ipairs(M.loaded_paths()) do
    local entry = loaded[path]
    if entry.mod then
      loaded_rows[#loaded_rows + 1] = string.format("%s  %s (%d swap%s)", entry.class, path,
        entry.swaps or 0, (entry.swaps or 0) == 1 and "" or "s")
    end
  end
  for _, row in ipairs(loaded_rows) do rows[#rows + 1] = row end
  return rows
end

return M
