-- The module system: a module is one directory under `modules/`, and nothing else.
--
-- Adding a module creates `modules/<id>/` with a `module.json` in it; removing one deletes that
-- directory. Neither needs an edit anywhere else, and that is not a convention this file merely
-- trusts: discovery is `host.list_dir` on the modules directory, so what is on disk is what is
-- listed, and `scripts/test-modules-removal.sh` deletes the directory and then asserts that no
-- file outside it names the module at all. There is no registry to keep in step, which is the
-- whole point - a registry is the thing that leaves references behind when a directory goes.
--
-- The route is `wa_modules(op, id, path, session)`, in the positional shape the Rust dispatch
-- table calls a Lua handler with (`wa_skills`, `wa_session`, ...). It answers with a
-- `{status, content_type, body}` envelope so the HTTP side decides nothing; the one line that
-- binding still needs, and what a page fetches, are in docs/MODULES.md.
local json = dofile("lua/vendor/json.lua")

local M = {}

local MANIFEST = "module.json"
-- The module system's own page lives beside the modules, not in one of them. It carries no
-- manifest, which is exactly what keeps it out of the listing: a directory is a module only
-- when it holds a `module.json`, so the host page, an abandoned directory, or a stray file can
-- never become a phantom module.
local HOST_DIR = "host"

-- What this host grants a module. A manifest declares what it needs; everything not granted here
-- is refused *out loud* - the listing carries the refusal, the host page renders it beside the
-- mounted panel, and the page's frame is sandboxed without same-origin, so a module that asks
-- for `network` is visibly refused rather than quietly broken somewhere later.
--
-- `WASM_AGENT_MODULE_CAPABILITIES` adds grants. It exists so the refusal can be falsified:
-- grant the capability and the badge has to disappear.
local GRANTED = { panel = true }

local TYPES = {
  html = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  md = "text/markdown; charset=utf-8",
  svg = "image/svg+xml",
  txt = "text/plain; charset=utf-8",
}

-- An unset variable is absent, not empty: `host.getenv` pushes nothing for one, so a caller that
-- compares it directly sees nil and a `..` on it raises. Every read of the environment here goes
-- through this.
local function env(name)
  local value = host.getenv(name)
  if type(value) ~= "string" then return "" end
  return value
end

local function list_of(value)
  local items = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "string" and item ~= "" then items[#items + 1] = item end
    end
  end
  return items
end

local function tokens(value)
  local set = {}
  for token in (value .. ","):gmatch("([^,%s]+)") do set[token] = true end
  return set
end

local function sorted(set)
  local names = {}
  for name in pairs(set) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function norm(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""))
end

-- `host.list_dir` answers one JSON value - failure included, as `{error=...}` rather than nil - so
-- it is read and decoded, never truth-tested. Nil means "not a directory we can read", which the
-- caller decides about: for this route it is an empty listing, never an error, because a node with
-- no modules is a node in a normal state.
local function entries_of(directory)
  local raw = host.list_dir(directory)
  if type(raw) ~= "string" then return nil end
  local decoded_ok, listing = pcall(json.decode, raw)
  if not decoded_ok or type(listing) ~= "table" or listing.error then return nil end
  if type(listing.entries) ~= "table" then return nil end
  return listing.entries
end

-- Where modules are read from, in order: an explicit override (a test, or a candidate node), the
-- checkout the interpreter reads its Lua from, this node's own home - which is how a module
-- reaches an installed node without rebuilding it - and finally the working directory. A
-- missing directory is not an error: a node with no modules lists none and mounts none.
function M.root()
  local explicit = env("WASM_AGENT_MODULES_DIR")
  if explicit ~= "" then return norm(explicit) end
  local checkout = env("WASM_AGENT_LUA_ROOT")
  if checkout ~= "" then return norm(checkout) .. "/modules" end
  local paths = host.paths()
  local home = type(paths) == "table" and paths.config or nil
  if type(home) == "string" and home ~= "" then return norm(home) .. "/modules" end
  return "modules"
end

function M.granted()
  local granted = {}
  for name in pairs(GRANTED) do granted[name] = true end
  for name in pairs(tokens(env("WASM_AGENT_MODULE_CAPABILITIES"))) do granted[name] = true end
  return granted
end

-- Modules are off unless asked for, and the ask is data rather than a file: an id in
-- `WASM_AGENT_MODULES`, or `"enabled": true` inside the module's own manifest. Both live with
-- whoever asked - the operator, or the module itself - so deleting the directory leaves nothing
-- behind and an ask that names a module which is gone is simply an ask about nothing, not an
-- error. That is what makes removal need no edit to the ask, and it is asserted.
local function asked_for()
  return tokens(env("WASM_AGENT_MODULES"))
end

local function read_manifest(directory)
  local text = host.read_file(directory .. "/" .. MANIFEST)
  if type(text) ~= "string" then return nil, "no " .. MANIFEST end
  local decoded_ok, manifest = pcall(json.decode, text)
  if not decoded_ok or type(manifest) ~= "table" then return nil, MANIFEST .. " is not valid JSON" end
  return manifest
end

local function entry_present(directory, entry)
  if entry == "" then return false end
  for _, item in ipairs(entries_of(directory) or {}) do
    if item.name == entry and item.kind == "file" then return true end
  end
  return false
end

-- What the listing says about one module. A manifest that claims an id other than its directory's
-- name is an issue rather than a second identity: the directory is the module, so mounting it
-- under a name nobody can find would make "which directory do I delete?" a question again.
local function describe(root, name, manifest, asked, granted, issues)
  local directory = root .. "/" .. name
  local entry = type(manifest.entry) == "string" and manifest.entry or ""
  local attach = type(manifest.attach) == "table" and manifest.attach or {}
  local declared = list_of(manifest.capabilities)
  local refused = {}
  for _, capability in ipairs(declared) do
    if not granted[capability] then refused[#refused + 1] = capability end
  end
  local enabled = asked[name] == true or manifest.enabled == true
  local mounted = enabled and entry ~= "" and entry_present(directory, entry)
  if enabled and entry ~= "" and not mounted then
    issues[#issues + 1] = name .. ": entry '" .. entry .. "' is missing from the module directory"
  end
  return {
    id = name,
    name = type(manifest.name) == "string" and manifest.name or name,
    version = type(manifest.version) == "string" and manifest.version or "",
    tag = type(manifest.tag) == "string" and manifest.tag or "",
    description = type(manifest.description) == "string" and manifest.description or "",
    attach = { surface = attach.surface or "", slot = attach.slot or "" },
    entry = entry,
    -- Relative to the host page, which sits beside the module directories in both places it is
    -- served from: `modules/host/` in a node, the root of a static tree.
    entry_url = entry ~= "" and ("../" .. name .. "/" .. entry) or "",
    capabilities = declared,
    refused = refused,
    enabled = enabled,
    mounted = mounted,
  }
end

-- The listing, computed by reading the directory. `exists` distinguishes "no modules directory"
-- from "a directory with nothing in it"; neither is an error, because both are normal states of a
-- node that has no modules - and an error there would light up a page that is behaving correctly.
function M.scan()
  local root = M.root()
  local entries = entries_of(root)
  local modules, issues = {}, {}
  if not entries then return modules, issues, { dir = root, exists = false } end
  local asked, granted = asked_for(), M.granted()
  for _, item in ipairs(entries) do
    if item.kind == "dir" and item.name ~= HOST_DIR then
      local manifest, problem = read_manifest(root .. "/" .. item.name)
      if not manifest then
        if problem ~= "no " .. MANIFEST then issues[#issues + 1] = item.name .. ": " .. problem end
      elseif type(manifest.id) == "string" and manifest.id ~= "" and manifest.id ~= item.name then
        issues[#issues + 1] = item.name .. ": manifest id '" .. manifest.id .. "' names a different directory"
      else
        modules[#modules + 1] = describe(root, item.name, manifest, asked, granted, issues)
      end
    end
  end
  table.sort(modules, function(a, b) return a.id < b.id end)
  return modules, issues, { dir = root, exists = true }
end

function M.listing()
  local modules, issues, where = M.scan()
  local mounted = {}
  for _, module in ipairs(modules) do
    if module.mounted then mounted[#mounted + 1] = module.id end
  end
  return {
    ok = #issues == 0,
    route = "/modules",
    dir = where.dir,
    exists = where.exists,
    granted = sorted(M.granted()),
    available = #modules,
    mounted = mounted,
    issues = issues,
    modules = modules,
  }
end

local function reply(status, content_type, body)
  return json.encode({ status = status, content_type = content_type, body = body })
end

local function problem(status, error, extra)
  local body = { ok = false, error = error }
  for key, value in pairs(extra or {}) do body[key] = value end
  return reply(status, "application/json; charset=utf-8", json.encode(body))
end

local function file(relative, absolute)
  local text = host.read_file(absolute)
  -- Binary files read as nil here: host.read_file is UTF-8 text only. A module that needs to
  -- serve a picture needs a bytes-capable host call, not a different route.
  if type(text) ~= "string" then return problem(404, "file_not_found", { path = relative }) end
  local extension = (relative:match("%.([%w]+)$") or ""):lower()
  return reply(200, TYPES[extension] or "application/octet-stream", text)
end

-- A module is served its own files and nothing else: the id is looked up in the listing rather
-- than joined onto a path (so a request can only reach a directory that is a module), and the
-- relative path is refused if it can leave the directory - a parent step, a leading slash, or a
-- Windows separator or drive colon.
local function inside(path)
  if path == "" then return false end
  if path:sub(1, 1) == "/" then return false end
  if path:find("..", 1, true) then return false end
  if path:find("\\", 1, true) then return false end
  if path:find(":", 1, true) then return false end
  return true
end

function M.serve(id, path)
  local root = M.root()
  id, path = id or "", path or ""
  if id == "" or id == HOST_DIR then
    -- The module system's own page, and its listing where a page expects to find it. `index.json`
    -- is not a file on disk: it is this listing, so the page never carries a copy of what is on
    -- disk, which is what would survive a deletion and lie.
    if path == "" or path == "index.html" then
      return file(HOST_DIR .. "/index.html", root .. "/" .. HOST_DIR .. "/index.html")
    end
    if path == "index.json" then
      return reply(200, "application/json; charset=utf-8", json.encode(M.listing()))
    end
    return problem(404, "not_found", { id = id, path = path })
  end
  local found
  for _, module in ipairs((M.scan())) do
    if module.id == id then found = module end
  end
  if not found then return problem(404, "module_not_found", { id = id }) end
  -- Off unless asked for goes for the files too, not only for the screen: an experiment nobody
  -- enabled is not fetchable either.
  if not found.enabled then return problem(403, "module_not_enabled", { id = id }) end
  if path == "" then path = found.entry end
  if not inside(path) then return problem(400, "bad_path", { id = id, path = path }) end
  return file(id .. "/" .. path, root .. "/" .. id .. "/" .. path)
end

-- The route. `op` is the operation, because a positional handler is what the dispatch table
-- calls; `session` is accepted and deliberately unused - a listing reads the disk and grants
-- nothing, and a route that gated on the session would need every reader named before a page
-- could be opened. What the binding does with the session is a decision for the Rust line, and
-- docs/MODULES.md says so.
function M.route(op, id, path, session)
  op = (op or ""):lower()
  if op == "" or op == "list" then
    return reply(200, "application/json; charset=utf-8", json.encode(M.listing()))
  end
  if op == "file" then return M.serve(id, path) end
  return problem(400, "unknown_op", { op = op })
end

function wa_modules(op, id, path, session)
  return M.route(op, id, path, session)
end

return M
