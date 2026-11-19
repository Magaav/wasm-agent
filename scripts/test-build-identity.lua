
-- The build's identity: one name for these bytes, composed in RUST and only READ here.
--
-- The finding (Victor, 18/11): `lua/core/chat.lua` passed `version = "0.1.0"` to the welcome box, so
-- every node said v0.1.0 whatever it was running - a release, a dev build, a dirty tree, a pinned node
-- all read the same. Round 3 made the composer single: `rust/wa-host/src/build_info.rs`
-- (`install_label`) decides release/pin/commit, filters the pin ledger to THIS node and parses a pin
-- block regardless of line order. `lua/core/build_identity.lua` reads `host.build_identity()` and hands
-- the fields on - it no longer reads `~/.wasm-agent/installed.txt`, which the installer never writes.
--
-- These assertions are about that reader: what it passes through, what it says when the binary can name
-- nothing, and that it never invents a version. The composer's own rules - a pin for another node, a
-- cleared record in either line order, the last record winning - are Rust's, in
-- `rust/wa-host/src/build_info.rs`'s tests; the end-to-end pin filter is `scripts/test.sh`.
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

-- The reader passes the binary's label through unchanged: the composer owns the words.
eq(identity.identity({ native = { label = "e5ba9089", commit = "e5ba908921e8aa11bbcc", dirty = "false",
  known = true } }).label, "e5ba9089", "a dev/plain build is its own commit")
eq(identity.identity({ native = { label = "e5ba9089+dirty", commit = "e5ba908921e8", dirty = "true",
  known = true } }).label, "e5ba9089+dirty",
  "a dirty build says so: the tree, not the commit, is what was compiled")
eq(identity.identity({ native = { label = "node-e5ba908921e8", commit = "e5ba908921e8", dirty = "false",
  known = true } }).label, "node-e5ba908921e8", "a release install shows the release it was installed as")
eq(identity.identity({ native = { label = "fc6a9d80 (pinned)", commit = "fc6a9d8034f4aa", dirty = "false",
  known = true } }).label, "fc6a9d80 (pinned)", "a pinned node shows its pin")

-- `source` is the label's SHAPE read back, for a caller that wants to say where the name came from. It
-- decides nothing: the label is already the composer's answer.
eq(identity.identity({ native = { label = "fc6a9d80 (pinned)", known = true } }).source, "pin",
  "a label ending (pinned) reads as a pin")
eq(identity.identity({ native = { label = "node-e5ba908921e8", known = true } }).source, "release",
  "and a node- name reads as a release")
eq(identity.identity({ native = { label = "e5ba9089", known = true } }).source, "build",
  "anything else the composer wrote is the bytes' own build")

-- UNKNOWN: never a made-up number. An older binary answers nothing.
eq(identity.identity({ native = false }).label, "unknown build",
  "a binary that cannot name itself says unknown, never a version")
eq(identity.identity({ native = { label = "unknown build", commit = "unknown", dirty = "unknown",
  known = false } }).label, "unknown build", "and an identity that knows nothing says the same")
eq(identity.identity({ native = { label = "unknown build", known = false } }).source, "unknown",
  "and its source says unknown rather than build")

-- It no longer reads an install record of its own: `record` is not an input any more, and the path it
-- used to open (`~/.wasm-agent/installed.txt`) is not one this module may reintroduce.
local source = host.read_file("lua/core/build_identity.lua") or ""
ok(source ~= "", "the module's source is readable, so these two checks are not vacuous")
local text_reads_record, mentions = false, 0
for line in source:gmatch("[^\n]+") do
  if not line:match("^%s*%-%-") then
    if line:find("installed.txt", 1, true) then text_reads_record = true end
    if line:find("pins.lua", 1, true) then text_reads_record = true end
  end
  if line:find("installed.txt", 1, true) then mentions = mentions + 1 end
end
ok(not text_reads_record,
  "no CODE line in the module reads installed.txt or the pin ledger: the Rust composer owns both")
ok(source:find("NEVER WRITES", 1, true) ~= nil and mentions == 1,
  "and the one mention of installed.txt is the comment saying the installer never writes it there ("
  .. mentions .. ")")

-- The crate's version is never the identity: this is the exact string the old banner printed.
for _, case in ipairs({
  { native = { label = "e5ba9089", known = true } },
  { native = false },
}) do
  local label = identity.identity(case).label
  ok(label ~= "0.1.0" and not label:find("0.1.0", 1, true),
    "the crate version is never the label: " .. tostring(label))
end

-- The welcome box prints it, through the one function: the call site passes the label, and the banner
-- only paints what it is given (so the assertion is about the sentence a reader sees).
local text = cli_view.banner({ live = false, limit = 120,
  version = identity.label({ native = { label = "e5ba9089", known = true } }) })
ok(text:find("ve5ba9089", 1, true) ~= nil, "the welcome box carries the build's own name")
ok(text:find("v0.1.0", 1, true) == nil, "and never the hard-coded version it used to")

if failed == 0 then print("build identity ok (" .. checks .. " checks)") else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)
