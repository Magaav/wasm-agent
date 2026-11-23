
-- **The build's name, read from the binary that is running - never composed here.**
--
-- The welcome box said `v0.1.0` because `lua/core/chat.lua` handed `cli_view.banner` a literal,
-- and every node said it whatever it had been built from (Victor, 18/11). A version is not an identity:
-- two nodes on `0.1.0` can differ by a hundred commits, and the whole 18/11 rollback was about a node
-- whose record named a commit its bytes did not contain.
--
-- ONE COMPOSER, AND IT IS RUST (`rust/wa-host/src/build_info.rs`, `install_label`). It alone decides
-- whether the name is the release the node was installed from, the pin an operator holds it at, or the
-- bytes' own commit label - and it alone parses the pin ledger, where it also filters to THIS node (a
-- fleet-wide ledger marks the node a record names, not whoever reads the file). This module used to
-- recompose that decision in Lua from `~/.wasm-agent/installed.txt`, WHICH THE INSTALLER NEVER WRITES
-- (the record lives in the install directory), so its copy was always empty and the two composers could
-- disagree. It now only reads `host.build_identity()` and hands the fields on.
--
-- Four facts, one answer, decided in Rust:
--
--   pin        an operator held this node somewhere on purpose - `fc6a9d80 (pinned)`.
--   release    the node was installed from a published `node-<sha12>` release.
--   build      the bytes' own label (`e5ba9089`, `e5ba9089+dirty` from a dirty tree).
--   unknown    `unknown build` - NEVER a made-up number, for a binary older than the capability.
--
-- `crate_version` is carried beside the label for the scripts that want a number; it is never the
-- identity. `source` is the label's SHAPE read back for a caller that wants to say where the name came
-- from - it decides nothing, and the surfaces print `label`.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- The one line every surface prints when the bytes cannot name themselves.
M.UNKNOWN = "unknown build"

-- THE PRODUCT VERSION, in one place (Victor, 22/11: the welcome line reads
-- `✻ Welcome to wasm-agent! v0.1.0 · v<sha>`).
--
-- It is a LITERAL and not a derivation, on purpose. The published tags are `v0.1.0-alpha.N`, the crate
-- carries `0.1.0`, and every one of those is a build number; the product version is a product decision
-- that Victor took (0.1.0 - "v1.0 is wrong", 22/11 - and it agrees with the crates and the tags) and
-- THE RELEASE OWNS IT: when a release names itself, this is the ONE line it changes, and nothing else in the
-- tree spells the number. `label()` above stays what it is - the build's own name - and the two are never
-- conflated: this says what the product IS, the label says which bytes are running.
--
-- READERS, so the number is written once and nowhere else:
--   * the BINARY embeds it at build time (`rust/wa-host/build.rs` and `rust/wa-capabilities/build.rs` both
--     extract this line) - that is how a shell script or `wa --version` knows it without a checkout;
--   * `wa release cut` reads it, computes the next one, and writes this line in the commit that publishes the
--     release (`M.tree_version` / `M.next_version`, lua/core/land.lua);
--   * `M.product_version()` below is the surface reader: the BINARY's answer first (an installed node has no
--     tree), this constant when the binary is older than the field.
M.PRODUCT_VERSION = "0.1.0"

local function decode(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, value = pcall(json.decode, raw)
  return ok and type(value) == "table" and value or nil
end

local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The binary's own answer, or nil when this host predates the capability.
function M.native()
  if not (host and host.build_identity) then return nil end
  local ok, raw = pcall(host.build_identity)
  return ok and decode(raw) or nil
end

--- The PRODUCT version (`0.1.0`), the number a person reads, or `unknown`.
--
-- It is not the identity (`M.label()` is: a version cannot tell two nodes apart - Victor, 18/11). It is the
-- other half of the same line, and it comes from ONE owner: the tree's `VERSION` file, embedded in the binary
-- at build time and read back through `host.build_identity()`. A binary older than that field answers
-- `unknown`, which is the honest answer - never a made-up number and never the crate's own.
function M.product_version(opts)
  local o = opts or {}
  local native = o.native
  if native == nil then native = M.native() elseif native == false then native = nil end
  local text = trim((native or {}).product_version)
  if text ~= "" then return text end
  -- A binary older than the field: the tree's constant is the answer, because it is the LAST RELEASED
  -- version (the release writes it) and a dev build between releases shows exactly that, with its own sha
  -- beside it. Never a made-up number.
  return M.PRODUCT_VERSION
end

--- Which of the four shapes a label is, read back from the string.
--
-- Presentation only: `install_label` already DECIDED, and this only says which case its answer belongs
-- to so a caller can word a sentence about it. A pin always ends ` (pinned)` and a release always
-- starts `node-`, both written by the composer, so neither is a guess.
local function classify(label, known)
  if not known then return "unknown" end
  -- " (pinned)" is NINE cells: a space and eight characters. It was written as eight and a label the
  -- composer produced read as a plain build.
  if label:sub(-9) == " (pinned)" then return "pin" end
  if label:sub(1, 5) == "node-" then return "release" end
  return "build"
end

--- The build's identity: `{ label, commit, dirty, source, known, crate_version }`.
--
-- @opts@ is for a test and nothing else: `native` replaces the binary's own answer, so every case this
-- module can report is asserted without a binary or a home. `false` means "explicitly none", which
-- `nil` cannot say (`{ native = nil }` IS `{}` in Lua).
function M.identity(opts)
  local o = opts or {}
  if o.native == nil and M._cached then return M._cached end
  local native = o.native
  if native == nil then native = M.native() elseif native == false then native = nil end
  local label = trim((native or {}).label)
  if label == "" then label = M.UNKNOWN end
  local known = (native or {}).known and label ~= M.UNKNOWN
  local identity = {
    label = label,
    commit = trim((native or {}).commit) ~= "" and trim((native or {}).commit) or "unknown",
    dirty = trim((native or {}).dirty) ~= "" and trim((native or {}).dirty) or "unknown",
    known = known and true or false,
    source = classify(label, known),
    -- The crate's version, for a script that wants a number, or "" when the binary did not state one.
    -- It used to fall back to the literal 0.1.0 - the invented version this module exists to stop - so a
    -- binary that predates the capability made every caller read the crate's number as the node's.
    crate_version = trim((native or {}).version),
  }
  if o.native == nil then M._cached = identity end
  return identity
end

--- The one line: what the welcome box, `wa --version` and /health all print.
function M.label(opts)
  return M.identity(opts).label
end

-- A test (and a reload) must be able to forget a resolved answer, or the next assertion reads the
-- previous fixture.
function M.reset()
  M._cached = nil
end

return M
