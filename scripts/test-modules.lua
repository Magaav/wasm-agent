-- The module route, asked the way the HTTP binding asks it.
--
-- The property this file exists for: the route lists what is on disk and nothing else, so a module
-- that is deleted stops being listed, stops being mounted and stops being served with no edit to
-- any file. `scripts/test-modules-removal.sh` deletes the directory and asserts that end to end,
-- running this harness against the tree with the module present and again with it gone; this file
-- is what pins the route's behaviour under every ask - off, on, granted, and an ask naming
-- something that is not there - without touching disk.
--
-- The ask is the environment, as it is for a node, so the harness drives it the way an operator
-- does: `host.getenv` is overridden for the duration of one case, the technique
-- scripts/test-observability.lua uses to cover several configurations in one process.
--
--   WASM_AGENT_MODULES_DIR=<tree>/modules WASM_AGENT_LUA_ROOT=<tree> \
--     WA_SCRIPT=<tree>/scripts/test-modules.lua wa --db <scratch.db>
--
-- It names no module: the module it exercises is the first one the listing reports, and a tree that
-- carries none is a case of its own - so this file can be read, copied and run in any tree, which
-- is also why the removal proof can assert that no file outside a module's directory names it.
local json = dofile("lua/vendor/json.lua")
local modules = dofile("lua/core/modules.lua")

local native_getenv = host.getenv
local overrides = {}
host.getenv = function(name)
  if overrides[name] ~= nil then return overrides[name] end
  return native_getenv(name)
end

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error("module route: " .. label .. " (after " .. checks .. " checks)", 2) end
end

-- One request through the entry point the dispatch table calls.
local function request(op, id, path)
  local text = wa_modules(op, id or "", path or "", "")
  ok(type(text) == "string", "the route answers a string, got " .. type(text))
  local decoded_ok, answer = pcall(json.decode, text)
  ok(decoded_ok and type(answer) == "table", "the answer is JSON: " .. tostring(text))
  ok(type(answer.status) == "number" and type(answer.content_type) == "string"
     and type(answer.body) == "string", "the answer carries status, content_type and body")
  return answer
end

local function listing()
  local answer = request("list")
  ok(answer.status == 200, "a listing is a 200: " .. tostring(answer.body))
  return json.decode(answer.body)
end

local function find(list, id)
  for _, item in ipairs(list.modules or {}) do
    if item.id == id then return item end
  end
  return nil
end

-- One case: the ask for the duration of `body`, with the real environment restored afterwards even
-- when the case fails - a harness that leaves an override behind poisons every later check.
local function with_ask(ask, capabilities, body)
  overrides.WASM_AGENT_MODULES = ask or ""
  overrides.WASM_AGENT_MODULE_CAPABILITIES = capabilities or ""
  local ran, problem = pcall(body)
  overrides.WASM_AGENT_MODULES = nil
  overrides.WASM_AGENT_MODULE_CAPABILITIES = nil
  overrides.WASM_AGENT_MODULES_DIR = nil
  if not ran then error(problem, 0) end
end

local base = listing()
ok(base.exists == true, "the modules directory must exist for this harness: " .. tostring(base.dir))
ok(base.route == "/modules", "the listing says which route it came from")
local subject = base.modules[1]
local absent = "no-such-module-in-this-tree"

if subject then
  ok(subject.entry ~= "", "a module must name an entry point: " .. subject.id)
  ok(subject.tag ~= "", "a module must name its tag, which is how it is recovered: " .. subject.id)
  ok(subject.attach.surface ~= "", "a module must say what it attaches to: " .. subject.id)

  -- 1. Off unless asked for: present in the listing, mounted nowhere, and its files refused. An
  --    experiment nobody enabled is not on the screen *and* is not fetchable.
  with_ask("", "", function()
    local off = listing()
    ok(off.available == #base.modules, "a module is listed whether or not it is enabled")
    ok(#off.mounted == 0, "nothing is mounted when nothing was asked for")
    local mine = find(off, subject.id)
    ok(mine ~= nil, "the module is still discoverable while it is off")
    ok(mine.enabled == false and mine.mounted == false, "an unasked module is neither enabled nor mounted")
    ok(mine.entry_url == subject.id .. "/" .. subject.entry,
       "the entry is a sibling of the host page, which is where the module directory is")
    local denied = request("file", subject.id, subject.entry)
    ok(denied.status == 403, "the files of an unasked module are refused, not served: " .. tostring(denied.body))
    ok(json.decode(denied.body).error == "module_not_enabled", "the refusal names why it refused")
  end)

  -- 2. Asked for: listed as mounted, and its entry served byte for byte from disk.
  with_ask(subject.id, "", function()
    local on = listing()
    ok(#on.mounted == 1 and on.mounted[1] == subject.id, "the asked module is the mounted one")
    local mine = find(on, subject.id)
    ok(mine.enabled == true and mine.mounted == true, "the asked module is enabled and mounted")
    local served = request("file", subject.id, subject.entry)
    ok(served.status == 200, "the entry is served: " .. tostring(served.body))
    local disk = host.read_file(modules.root() .. "/" .. subject.id .. "/" .. subject.entry)
    ok(served.body == disk, "the route serves the file on disk, byte for byte")
    if subject.entry:match("%.html$") then
      ok(served.content_type:match("^text/html") ~= nil, "html is served as html: " .. served.content_type)
    end
    local by_entry = request("file", subject.id, "")
    ok(by_entry.status == 200 and by_entry.body == disk, "an empty path means the module's entry point")

    -- A module is served its own files and nothing next to it.
    for _, escape in ipairs({ "../" .. subject.id .. "/" .. subject.entry, "..\\host\\index.html",
                              "/etc/hosts", "C:/Windows/win.ini" }) do
      local refused = request("file", subject.id, escape)
      ok(refused.status == 400 and json.decode(refused.body).error == "bad_path",
         "a module cannot be walked out of: " .. escape .. " -> " .. tostring(refused.body))
    end
    local missing = request("file", subject.id, "not-a-file-in-this-module.txt")
    ok(missing.status == 404 and json.decode(missing.body).error == "file_not_found",
       "a missing file is a 404, not an empty 200")
  end)

  -- 3. A declared capability this host does not grant is refused in the listing itself. That is what
  --    the host page renders as a badge beside the panel: a refusal is visible, not silent.
  ok(#subject.capabilities > 0, "the worked example declares a capability so a refusal can be seen")
  with_ask(subject.id, "", function()
    local on = listing()
    local granted = {}
    for _, name in ipairs(on.granted) do granted[name] = true end
    local mine = find(on, subject.id)
    ok(#mine.refused > 0, "a declared capability this host does not grant is refused in the listing")
    for _, capability in ipairs(mine.capabilities) do
      local refused = false
      for _, name in ipairs(mine.refused) do if name == capability then refused = true end end
      ok(refused ~= (granted[capability] == true),
         "the refusal is exactly what is not granted: " .. capability)
    end
  end)

  -- 4. The falsifier for the badge: grant what the module declares, and the refusal has to go. A
  --    badge that stays whatever the grant is would be decoration, and check 3 would pass anyway.
  with_ask(subject.id, table.concat(subject.capabilities, ","), function()
    local on = listing()
    local mine = find(on, subject.id)
    ok(#mine.refused == 0, "a granted capability is not refused: " .. json.encode(mine.refused))
    ok(#on.mounted == 1, "granting a capability does not change what is mounted")
  end)
else
  print("module route: no module in " .. base.dir .. " - the mount, refusal and file-serving checks did NOT run")
end

-- 5. A directory that holds no module directory holds no modules, and an empty tree is not an
--    error: this is the state a tree is in after a module is deleted, and a page that showed an
--    error there would be lying about a node that is behaving correctly. The directory used is the
--    tree root - real, and not one this module system owns - so the check also says modules are
--    found under `modules/` and nowhere else.
with_ask(subject and subject.id or absent, "", function()
  overrides.WASM_AGENT_MODULES_DIR = modules.root() .. "/.."
  local empty = listing()
  ok(empty.exists == true and empty.available == 0, "a directory with no manifest holds no modules")
  ok(#empty.mounted == 0 and #empty.issues == 0, "asking for a module that is not there is not an error")
  ok(json.encode(empty):find(subject and subject.id or absent, 1, true) == nil,
     "an ask that names a module nothing matches leaves no trace of the id in the listing")
  overrides.WASM_AGENT_MODULES_DIR = modules.root() .. "/not-a-directory"
  local nowhere = listing()
  ok(nowhere.exists == false and nowhere.available == 0 and #nowhere.issues == 0,
     "a missing modules directory is an empty listing, not a failure")
end)

-- 6. The page's own two fetches, which the route answers with no ask at all: the page itself, and
--    its listing where a page expects to find it. Both live under the module system's own empty id -
--    there is deliberately no second name for them, because a page reachable at two depths resolves
--    `<id>/<entry>` differently at each.
local page = request("file", "", "index.html")
ok(page.status == 200 and page.content_type:match("^text/html") ~= nil, "the host page is served")
ok(page.body:find("waHostReady", 1, true) ~= nil, "the host page is the one that mounts modules")
local index = request("file", "", "index.json")
ok(index.status == 200, "the listing is served beside the page")
ok(index.body == request("list").body, "the page's listing is the route's listing for this tree")
ok(request("file", "", "not-a-page.html").status == 404, "the module system serves its page and its listing only")
ok(request("file", absent, "index.html").status == 404, "the page is not reachable under a name that is not a module")

-- 7. What the route refuses, so a caller cannot mistake a bad request for an empty answer.
local registered = request("list", absent, "")
ok(registered.status == 200, "a listing is a listing whatever id is passed in")
local unknown = request("file", absent, "index.html")
ok(unknown.status == 404 and json.decode(unknown.body).error == "module_not_found",
   "an unknown module is a 404: " .. tostring(unknown.body))
local nonsense = request("frobnicate", "", "")
ok(nonsense.status == 400 and json.decode(nonsense.body).error == "unknown_op",
   "an unknown operation is a 400: " .. tostring(nonsense.body))

-- The environment is back exactly as it was: every case above went through the override.
ok(host.getenv("WASM_AGENT_MODULES") == native_getenv("WASM_AGENT_MODULES"),
   "the harness restored the environment")

print("module route ok (" .. checks .. " checks, " .. #base.modules .. " module(s) in " .. base.dir .. ")")
