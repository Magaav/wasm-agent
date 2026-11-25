-- A CUT LEAVES A NODE THAT FINISHES THE MIGRATION ITSELF (slice (b), requirement 5).
--
-- The shell half renames a legacy path aside and then renames a link through `current` onto it; a cut between
-- the two leaves the path absent on purpose. This row pins the half that must make that survivable: on the next
-- start, wa puts back every link the pointer names that is missing or dangling, and never replaces a real file or
-- directory (that is today's layout, and it is also evidence of a migration that has not started).
--
-- It writes nothing outside its own scratch directory under /tmp (never the node's data dir, never a ledger: it
-- opens no database at all) and refuses the operator's home like every other row.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end

local function sh(cmd) return host.exec(cmd, "", 60) end
-- host.path_kind is the surface this host has (file_exists does not exist here: the first run of the row said so).
local function exists(p) local ok, kind = pcall(host.path_kind, p); return ok and kind ~= "missing" end
local n = 0
local function check(what, cond)
  if not cond then error("FAIL test-version-repair: " .. what) end
  n = n + 1
end

local base = os.getenv("TMPDIR") or "/tmp"
if base:find("%.wasm%-agent") then base = "/tmp" end
-- A fixed name, not one derived from host.exec: that call answers a JSON envelope (measured - the first run of
-- this row built a scratch path out of the envelope and every mkdir landed in a name nobody looked at).
local root = base .. "/wa-version-repair"
sh("rm -rf '" .. root .. "' && mkdir -p '" .. root .. "/install' '" .. root .. "/share/versions/aaaaaaaaaaaa/lua-core' " ..
   "'" .. root .. "/share/versions/aaaaaaaaaaaa/scripts' '" .. root .. "/share/versions/aaaaaaaaaaaa/ui'")
local share = root .. "/share"
local install = root .. "/install"
local version = share .. "/versions/aaaaaaaaaaaa"
sh("printf 'id=aaaaaaaaaaaa\\ncommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' > '" .. version .. "/version.txt'")
sh("printf 'wa' > '" .. version .. "/wa' && printf 'sentinel' > '" .. version .. "/wa-sentinel'")
sh("printf 'init' > '" .. version .. "/lua-core/init.lua' && printf 'deploy' > '" .. version .. "/scripts/deploy.sh'")
sh("printf 'ui' > '" .. version .. "/ui/index.html'")
sh("ln -sfn versions/aaaaaaaaaaaa '" .. share .. "/current'")

local repair = dofile("lua/core/version_repair.lua")

-- 1. No pointer: nothing to repair, nothing written (every node before this slice installs).
local none = repair.repair({ share = root .. "/share-none", install = install, quiet = true })
check("no current -> no_current, and no repair", none.reason == "no_current" and (none.repaired or 0) == 0)
check("no current -> nothing was created", not exists(root .. "/share-none/current"))

-- 2. A half-done migration: the install has NOTHING where the pointer names something -> every member is linked.
local result = repair.repair({ share = share, install = install, quiet = true })
check("every missing link is put back (got " .. tostring(result.repaired) .. ")", (result.repaired or 0) == 5)
for _, name in ipairs({ "wa", "wa-sentinel", "lua-core", "scripts" }) do
  check(name .. " resolves through current",
    exists(install .. "/" .. name) and
    tostring(host.canonical_path(install .. "/" .. name)) == tostring(host.canonical_path(version .. "/" .. name)))
end
check("the share root's ui resolves through current",
  tostring(host.canonical_path(share .. "/ui")) == tostring(host.canonical_path(version .. "/ui")))

-- 3. A REAL directory is never replaced: today's layout, and evidence of a migration that has not started.
sh("rm -rf '" .. install .. "/scripts' && mkdir -p '" .. install .. "/scripts' && printf 'mine' > '" .. install .. "/scripts/deploy.sh'")
local before = host.canonical_path(install .. "/scripts")
local again = repair.repair({ share = share, install = install, quiet = true })
check("a real directory is left alone", tostring(host.canonical_path(install .. "/scripts")) == tostring(before))
check("its content is untouched", tostring(host.read_file(install .. "/scripts/deploy.sh")) == "mine")
check("the run still reports the healthy paths as skipped", (again.skipped or 0) >= 4)

-- 4. Idempotent: a second repair on a healthy install repairs nothing.
local third = repair.repair({ share = share, install = install, quiet = true })
check("a healthy install repairs nothing", (third.repaired or 0) == 0)

sh("rm -rf '" .. root .. "'")
print("version repair ok (" .. n .. " checks)")

