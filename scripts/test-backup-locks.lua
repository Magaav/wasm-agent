-- The pre-update backup must never try to copy a lock file.
--
-- A lock file is an SQLite file a live process holds in an exclusive transaction; attaching it fails with
-- "database is locked". On 04/11 the binding transport lease (`binding.transport.sqlite`) matched none of
-- backup.lua's lock patterns, so every bound node's /update died in its backup and nothing could update.
-- This test reads the Rust sources: any `.sqlite` name opened within five lines before a
-- `BEGIN EXCLUSIVE` is a lock, and backup.is_store must reject it. A new lock file with a new name fails
-- here, before it fails on a node.
local backup = dofile("lua/core/backup.lua")
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 0) end
end

-- git ls-files in a checkout; find when the tree is a plain copy (a test container, an unpacked bundle).
local listed = json.decode(host.exec("git ls-files 'rust/*.rs' 2>/dev/null || find rust -name '*.rs' -not -path '*/target/*'", ""))
ok(listed and listed.code == 0 and tostring(listed.stdout):find("%.rs"), "the Rust sources must be listable")
local files = {}
for path in tostring(listed.stdout):gmatch("[^\r\n]+") do
  if not path:find("/target/", 1, true) then files[#files + 1] = path end
end
ok(#files > 0, "there are Rust sources to scan")

-- A literal's file name, with any `{...}` format placeholder replaced by a sample value.
local function names_in(line)
  local out = {}
  -- with_extension("x.sqlite") replaces the extension of a state file (`binding.json` -> `binding.x.sqlite`):
  -- take it as that, then drop it so the bare literal is not read as a file name of its own.
  for ext in line:gmatch('with_extension%("([^"]-%.sqlite)"%)') do out[#out + 1] = "binding." .. ext end
  line = line:gsub('with_extension%("[^"]-"%)', "")
  for literal in line:gmatch('"([^"]-%.sqlite)"') do out[#out + 1] = literal end
  for i, name in ipairs(out) do
    name = name:gsub("{[^}]*}", "x")
    if name:sub(1, 1) == "." then name = "x" .. name end
    out[i] = name:match("([^/\\]+)$")
  end
  return out
end

local locks, seen = {}, {}
for _, path in ipairs(files) do
  local lines = {}
  for line in tostring(host.read_file(path) or ""):gmatch("([^\n]*)\n?") do lines[#lines + 1] = line end
  for n, line in ipairs(lines) do
    if line:find("BEGIN EXCLUSIVE", 1, true) and not line:find("assert!", 1, true) then
      for k = math.max(1, n - 5), n do
        for _, name in ipairs(names_in(lines[k])) do
          if not seen[name] then seen[name] = path .. ":" .. k; locks[#locks + 1] = name end
        end
      end
    end
  end
end
ok(#locks >= 3, "the scan must find the known lock files (found " .. #locks .. ")")
ok(seen["binding.transport.sqlite"] ~= nil, "the binding transport lease must be found by the scan")
for _, name in ipairs(locks) do
  ok(backup.is_store(name) == false, "backup would try to copy the lock file " .. name .. " (" .. seen[name] .. ")")
end

-- And the real stores are still backed up.
for _, name in ipairs({ "memory.db", "claims.sqlite", "index.sqlite", "memory.db.run-journal.sqlite", "graph.db", "jobs.db" }) do
  ok(backup.is_store(name) == true, "a data store must be backed up: " .. name)
end

print("backup locks ok (" .. checks .. " checks, " .. #locks .. " lock names)")
