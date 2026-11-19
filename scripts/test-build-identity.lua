
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

-- IT DOES NOT COMPOSE A NAME OF ITS OWN. The composer is Rust, so the module must pass the binary's
-- answer through - whatever the native fields say, the label is the binary's, never assembled here. An
-- assertion on the module's SOURCE would pass on any edit that moves a comment, so this is behaviour:
-- a label the composer could not have produced still comes back unchanged, and a known=false answer
-- still reports unknown even when a label is present, because a binary that says it does not know is
-- not a binary whose label may be trusted.
eq(identity.identity({ native = { label = "not-a-commit-shape", known = true } }).label,
  "not-a-commit-shape", "the module hands the binary's label through, it does not reshape it")
-- A binary that says it does not know is reported as NOT known, and classified unknown. Its label is
-- still handed through unchanged - it is the composer's answer, and this module never rewrites one - so
-- the fact is carried by known/source rather than by a string this module would have invented.
local unsure = identity.identity({ native = { label = "e5ba9089", known = false } })
eq(unsure.known, false, "a binary that says it does not know is reported as not known")
eq(unsure.source, "unknown", "and it is classified unknown, not as a build")
eq(unsure.label, "e5ba9089", "while the binary's own label is still handed through, never rewritten")

-- The crate's version is never the identity: this is the exact string the old banner printed.
for _, case in ipairs({
  { native = { label = "e5ba9089", known = true } },
  { native = false },
}) do
  local label = identity.identity(case).label
  ok(label ~= "0.1.0" and not label:find("0.1.0", 1, true),
    "the crate version is never the label: " .. tostring(label))
  -- And the crate version itself is never INVENTED: the field fell back to the literal 0.1.0, which is
  -- the same invented number one field over. A binary that states no version reports "".
  local crate = identity.identity(case).crate_version
  ok(crate ~= "0.1.0", "the crate version is never invented: " .. tostring(crate))
end
-- The version a binary DOES state is passed through, so the check above is not vacuous.
eq(identity.identity({ native = { label = "e5ba9089", known = true, version = "0.2.1" } }).crate_version,
  "0.2.1", "a stated crate version is carried")

-- The welcome box prints it, through the one function: the call site passes the label, and the banner
-- only paints what it is given (so the assertion is about the sentence a reader sees).
local text = cli_view.banner({ live = false, limit = 120,
  version = identity.label({ native = { label = "e5ba9089", known = true } }) })
ok(text:find("ve5ba9089", 1, true) ~= nil, "the welcome box carries the build's own name")
ok(text:find("v0.1.0", 1, true) == nil, "and never the hard-coded version it used to")

if failed == 0 then print("build identity ok (" .. checks .. " checks)") else print("FAILED " .. failed .. "/" .. checks) end
os.exit(failed == 0 and 0 or 1)
