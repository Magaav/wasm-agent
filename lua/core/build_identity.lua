
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
