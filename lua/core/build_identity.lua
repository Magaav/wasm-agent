
-- **One name for the build this process is running**, and the only place it is composed.
--
-- The welcome box said `v0.1.0` because `lua/core/chat.lua` handed `cli_view.banner` a literal,
-- and every node said it whatever it had been built from (Victor, 18/11). A version is not an identity:
-- two nodes on `0.1.0` can differ by a hundred commits, and the whole 18/11 rollback was about a node
-- whose record named a commit its bytes did not contain. So the identity is the COMMIT, and it comes
-- from the binary's own compiled-in build info (`--build-info`, `rust/wa-host/build.rs`), never from
-- a record that says what somebody meant to install.
--
-- Four facts, one answer, in this order of authority:
--
--   pin        an operator held this node somewhere on purpose - `fc6a9d80 (pinned)`. Reported
--              FIRST because it is the most specific thing true of this node, and the one a reader
--              must not have to go looking for.
--   release    the node was installed from a published `node-<sha12>` release: its name, from
--              `installed.txt`'s `binary_release`, which `scripts/lib/install-record.sh` writes
--              from the binary's own label.
--   build      the bytes' own label (`e5ba9089`, `e5ba9089+dirty` when built from a dirty tree).
--   unknown    `unknown build` - NEVER a made-up number. A binary older than `host.build_identity`
--              cannot name its commit, and saying so is the answer; `0.1.0` was the lie.
--
-- `crate_version` is carried beside it because some scripts still ask for a version number
-- (`scripts/release-linux.sh` writes it into a release record). It is never used as the identity: the
-- surfaces that name the build - the welcome box, `wa --version`, /health and the update banner's
-- installed side - all print `label`, and they print the SAME one because they all ask here.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- The one line every surface prints when the bytes cannot name themselves.
M.UNKNOWN = "unknown build"

local function decode(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, value = pcall(json.decode, raw)
  return ok and type(value) == "table" and value or nil
end

local function read(path)
  if not (host and host.read_file) then return nil end
  local ok, text = pcall(host.read_file, path)
  return ok and type(text) == "string" and text or nil
end

-- `installed.txt@: the install's own record, one key=value per line, and the one reader of it -
-- so the label an operator sees and the record a deploy writes cannot drift apart.
local function installed()
  local home = (host.paths and host.paths().home) or ""
  if home == "" then return {} end
  local text = read((home:gsub("\\", "/")) .. "/.wasm-agent/installed.txt")
  local record = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then record[key:gsub("^%s+", ""):gsub("%s+$", "")] = value:gsub("^%s+", ""):gsub("%s+$", "") end
  end
  return record
end

-- The pin in force for this node, if any: the pin store's own rule, read and never re-decided here
-- (`lua/core/pins.lua` owns it). A declared pin record names a commit; the LABEL shows it as
-- `<short> (pinned)` so a reader who has never heard of a pin still sees the node is held.
local function pinned()
  local ok, pins = pcall(dofile, "lua/core/pins.lua")
  if not ok or type(pins) ~= "table" or type(pins.active) ~= "function" then return nil end
  -- The node answers to its NAME and to its id, and a pin written under either has to be found: the
  -- same pair `lua/core/update.lua` asks with, resolved the same way, so a pin that gates a deploy
  -- gates the label too.
  local name_ok, nodes = pcall(dofile, "lua/core/nodes.lua")
  local local_name, local_id = "", ""
  if name_ok and type(nodes) == "table" then
    local named, value = pcall(nodes.node_name)
    if named then local_name = tostring(value or "") end
    local id_ok, identity = pcall(nodes.identity)
    if id_ok and type(identity) == "table" then local_id = tostring(identity.node_id or "") end
  end
  local read_ok, record = pcall(pins.active, local_name, local_id)
  if not read_ok or type(record) ~= "table" then return nil end
  local commit = tostring(record.commit or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if commit == "" or commit == "unknown" then return nil end
  return commit
end

-- The binary's own answer, or nil when this host predates the capability.
function M.native()
  if not (host and host.build_identity) then return nil end
  local ok, raw = pcall(host.build_identity)
  return ok and decode(raw) or nil
end

--- The build's identity, resolved once and remembered: `{ label, commit, dirty, source, known }`.
--
-- @opts@ is for a test and nothing else: `native` is the binary's own answer, `record` the install
-- record, `pin` the pinned commit. Every one is injectable so the four cases this module exists for -
-- release, dev build, dirty build, pinned node - are asserted without a binary, a home or a pin store.
function M.identity(opts)
  local o = opts or {}
  if o.native == nil and o.record == nil and o.pin == nil and M._cached then return M._cached end
  -- `false` is "explicitly none", which `nil` cannot say: `{ native = nil }` IS `{}` in Lua, so a
  -- test asking for a binary that cannot name itself would silently have got the real one. Every input
  -- therefore also takes `false`.
  local native = o.native
  if native == nil then native = M.native() elseif native == false then native = nil end
  local record = o.record
  if record == nil then record = installed() end
  local pin = o.pin
  if pin == nil then pin = pinned() elseif pin == false then pin = nil end
  local dirty = tostring((native or {}).dirty or "")
  local built = tostring((native or {}).label or "")
  -- A binary that predates the capability says nothing; the record's build_info= is then the only
  -- evidence, and it says the same thing by another route (the binary answered when it was installed).
  local base = built
  if base == "" or base == M.UNKNOWN then
    base = tostring(record.commit or "")
    if base == "" or base == "unknown" then base = M.UNKNOWN else base = base:sub(1, 8) end
  end
  local release = tostring(record.binary_release or record.release or "")
  local label, source
  if pin and pin ~= "" then
    label, source = pin:sub(1, 8) .. " (pinned)", "pin"
  elseif release ~= "" then
    label, source = release, "release"
  else
    label, source = base, (base == M.UNKNOWN and "unknown" or "build")
  end
  local identity = {
    label = label,
    commit = tostring((native or {}).commit or (record.commit or M.UNKNOWN)),
    dirty = dirty, source = source,
    known = base ~= M.UNKNOWN,
    -- The crate's version, for the scripts that want a number. Never the label.
    crate_version = tostring((native or {}).version or "0.1.0"),
  }
  if o.native == nil and o.record == nil and o.pin == nil then M._cached = identity end
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

