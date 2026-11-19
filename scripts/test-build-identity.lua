
-- The build's identity: one name for these bytes, and the four answers this node can give.
--
-- The finding (Victor, 18/11): `lua/core/chat.lua` passed `version = "0.1.0"` to the welcome box, so
-- every node said v0.1.0 whatever it was running - a release, a dev build, a dirty tree, a pinned node
-- all read the same. This asserts the one function that now supplies it, and that nothing invents a
-- version when it cannot name one.
--
-- No binary, no home and no pin store: every input is injected, which is the whole reason
-- build_identity.identity takes them.
local identity = dofile("lua/core/build_identity.lua")
local cli_view = dofile("lua/core/cli_view.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label); failed = failed + 1 end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

-- A build installed from a checkout: it prints its commit.
eq(identity.identity({ native = { label = "e5ba9089", commit = "e5ba908921e8aa11bbcc", dirty = "false" },
  record = {}, pin = nil }).label, "e5ba9089",
  "a dev/plain build is its own commit")

-- A RELEASE install: node-<sha12> is the name it was installed as, and the record is the install's.
local released = identity.identity({ native = { label = "e5ba9089", commit = "e5ba908921e8", dirty = "false" },
  record = { binary_release = "node-e5ba908921e8", commit = "e5ba908921e8" }, pin = nil })
eq(released.label, "node-e5ba908921e8", "a release install shows the release it was installed as")
eq(released.source, "release", "and says that is where the name came from")

-- A DIRTY tree: the commit is not what was built, and the label says so rather than claiming the commit.
eq(identity.identity({ native = { label = "e5ba9089+dirty", commit = "e5ba908921e8", dirty = "true" },
  record = {}, pin = nil }).label, "e5ba9089+dirty",
  "a dirty build says so: the tree, not the commit, is what was compiled")

-- A PINNED node: the most specific fact wins, whoever installed it.
eq(identity.identity({ native = { label = "e5ba9089", commit = "e5ba908921e8", dirty = "false" },
  record = { binary_release = "node-e5ba908921e8" }, pin = "fc6a9d8034f4aa" }).label,
  "fc6a9d80 (pinned)", "a pinned node shows its pin, not the release it came from")

-- UNKNOWN: never a made-up number. An older binary answers nothing, and no record means no evidence.
eq(identity.identity({ native = false, record = {}, pin = false }).label, "unknown build",
  "a binary that cannot name itself says unknown, never a version")
eq(identity.identity({ native = { label = "unknown build", commit = "unknown", dirty = "unknown" },
  record = {}, pin = nil }).label, "unknown build", "and an identity that knows nothing says the same")

-- An older binary WITH an install record: the record is the only evidence, and it is used as such.
eq(identity.identity({ native = false, record = { commit = "e5ba908921e8aa11" }, pin = false }).label, "e5ba9089",
  "an older binary falls back to the record the installer wrote from it")

-- The crate's version is never the identity: this is the exact string the old banner printed.
for _, case in ipairs({
  { native = { label = "e5ba9089" }, record = {}, pin = nil },
  { native = false, record = {}, pin = false },
}) do
  local label = identity.identity(case).label
  ok(label ~= "0.1.0" and not label:find("0.1.0", 1, true),
    "the crate version is never the label: " .. tostring(label))
end

-- The welcome box prints it, through the one function: the call site passes the label, and the banner
-- only paints what it is given (so the assertion is about the sentence a reader sees).
local text = cli_view.banner({ live = false, limit = 120,
  version = identity.label({ native = { label = "e5ba9089" }, record = {}, pin = nil }) })
ok(text:find("ve5ba9089", 1, true) ~= nil, "the welcome box carries the build's own name")
ok(text:find("v0.1.0", 1, true) == nil, "and never the hard-coded version it used to")

if failed == 0 then print("build identity ok (" .. checks .. " checks)") else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)

