-- The installed release payload, and the gate a reload from it has to pass first.
--
-- WHY THIS FILE EXISTS, AND WHY IT IS A GUARD. `lua/core/reload.lua` has two sources, and only one of
-- them is a person at a keyboard: the operator's checkout under `--dev`, and - on a deployed node, with
-- no flag - the payload the node was installed with. A payload is a directory of Lua on disk, so
-- "reload only from the payload" without a check is "run whatever is in that directory", written by
-- whoever can write a file there. That is the one thing a self-updating agent must never do, so the
-- payload is accepted only when its `SHA256SUMS` carries a signature by a key this node already trusts
-- and every file that is loaded matches its line in those sums.
--
-- The verifier is not reimplemented here. `change/sign` is on main, and the node ships one trusted-key
-- verifier - `rust/wa-host/src/release.rs`, the same code `scripts/install.sh`, `scripts/upgrade.sh` and
-- the publisher use, which reads the keys embedded in the binary, `<home>/release-keys.txt` and
-- `WA_RELEASE_KEYS`. It is asked as `wa release verify --sums <payload> --quiet`, by the node's OWN
-- binary (`host.runtime_info().binary_path`), so the keys and the code are the running install's and not
-- whatever a shell would find on `PATH`.
--
-- Not reloadable, and named in `reload.lua`'s GUARD list: a signature check that a reload source could
-- replace is not a check. `scripts/test-hotreload.lua` proves a poisoned copy in a reload tree never
-- reaches the process.
--
-- THE PAYLOAD'S SHAPE (written by `scripts/hotreload-payload.sh`, installed beside the node):
--
--   <config>/payload/SHA256SUMS       `<sha256>  lua/core/cli_view.lua`, one line per file
--   <config>/payload/SHA256SUMS.sig   the release signature (ed25519, wa-vault's release-signing key)
--   <config>/payload/lua/...          the committed tree's Lua
--
-- `<config>` is `host.paths().config` (`~/.wasm-agent`), which is the one root everything the node
-- creates lives under.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.SUMS = "SHA256SUMS"
M.SIGNATURE = "SHA256SUMS.sig"

-- The payload this node was installed with, or nil. `WASM_AGENT_HOTRELOAD_PAYLOAD` names another (a
-- candidate, an operator's copy); otherwise it is the one directory a deploy writes.
function M.installed()
  local declared = host.getenv("WASM_AGENT_HOTRELOAD_PAYLOAD")
  local dir = (type(declared) == "string" and declared ~= "") and declared or nil
  if not dir then
    local ok, paths = pcall(host.paths)
    local config = ok and type(paths) == "table" and paths.config or nil
    if type(config) ~= "string" or config == "" then return nil end
    dir = config:gsub("/+$", "") .. "/payload"
  end
  local ok, kind = pcall(host.path_kind, dir)
  if not ok or kind ~= "dir" then return nil end
  return dir
end

-- One argument of a shell command, quoted for the shell `host.exec` uses. POSIX single quotes take
-- everything literally (and `'` is closed-reopened); cmd.exe has no such thing, so a Windows argument is
-- double-quoted with the quotes doubled. A path with a space in it is the case that matters on both.
local function quote(text)
  text = tostring(text or "")
  local ok, platform = pcall(host.platform)
  local os_name = ok and type(platform) == "table" and tostring(platform.os or "") or ""
  if os_name:lower():match("^win") then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- The `sha256  path` lines of a sums file, as {path -> digest}. A line that is neither shape is skipped
-- rather than guessed at: the verifier already refused a malformed sums file, so this is only ever
-- reading one it accepted.
local function parse_sums(text)
  local sums, count = {}, 0
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local digest, name = line:match("^(%x+)%s+%*?(.-)%s*$")
    if digest and name and #digest == 64 then
      sums[name:gsub("^%./", "")] = digest:lower()
      count = count + 1
    end
  end
  return sums, count
end

local cached = { dir = nil, stamp = nil, ok = nil, error = nil, sums = nil, count = 0 }

-- Forget what was verified. A caller that has just written a payload (a test, an operator) says so
-- instead of waiting for the stamp to change.
function M.reset()
  cached = { dir = nil, stamp = nil, ok = nil, error = nil, sums = nil, count = 0 }
end

local function binary()
  local ok, raw = pcall(host.runtime_info)
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, info = pcall(json.decode, raw)
  if not decoded_ok or type(info) ~= "table" then return nil end
  local path = info.binary_path
  if type(path) ~= "string" or path == "" then return nil end
  return path
end

-- Ask this node's own binary to verify the payload's signature.
-- Answers "" when the payload verifies, or the refusal to report.
local function verify(dir)
  local sums = dir:gsub("/+$", "") .. "/" .. M.SUMS
  local present = host.read_file(sums)
  if type(present) ~= "string" or present == "" then
    return "payload_unsigned: " .. dir .. " has no " .. M.SUMS
  end
  local signature = host.read_file(dir:gsub("/+$", "") .. "/" .. M.SIGNATURE)
  if type(signature) ~= "string" or signature == "" then
    return "payload_unsigned: " .. dir .. " has no " .. M.SIGNATURE
  end
  local exe = binary()
  if not exe then return "payload_unverified: this process cannot name its own binary (host.runtime_info)" end
  local command = quote(exe) .. " release verify --sums " .. quote(dir) .. " --quiet"
  local ok, raw = pcall(host.exec, command, "", 30)
  if not ok or type(raw) ~= "string" then return "payload_unverified: the verifier could not run" end
  local decoded_ok, answer = pcall(json.decode, raw)
  if not decoded_ok or type(answer) ~= "table" then return "payload_unverified: unreadable answer from " .. command end
  if tonumber(answer.code) == 0 then return "" end
  local detail = tostring(answer.stderr or ""):gsub("%s+$", "")
  if detail == "" then detail = tostring(answer.stdout or ""):gsub("%s+$", "") end
  if detail == "" then detail = "exit " .. tostring(answer.code) end
  return "payload_signature_invalid: " .. detail
end

-- Is this payload accepted? Cached on the DIGEST OF ITS SUMS FILE - so a signature check costs one file
-- read per tick, and a deploy (which rewrites `SHA256SUMS` and `SHA256SUMS.sig` together) is what makes
-- it run again. Answers true, or false and the ONE line to show.
function M.ensure(dir, force)
  dir = tostring(dir or M.installed() or "")
  if dir == "" then return false, "payload_missing: this node has no payload directory" end
  local text = host.read_file(dir:gsub("/+$", "") .. "/" .. M.SUMS)
  if type(text) ~= "string" or text == "" then
    return false, "payload_unsigned: " .. dir .. " has no " .. M.SUMS
  end
  local stamp = host.sha256(text)
  if not force and cached.dir == dir and cached.stamp == stamp and cached.ok ~= nil then
    return cached.ok, cached.error
  end
  local problem = verify(dir)
  cached = { dir = dir, stamp = stamp, ok = problem == "", error = problem, sums = nil, count = 0 }
  if problem ~= "" then return false, problem end
  local sums, count = parse_sums(text)
  cached.sums, cached.count = sums, count
  if count == 0 then
    cached.ok, cached.error = false, "payload_unsigned: " .. dir .. "/" .. M.SUMS .. " names no files"
    return false, cached.error
  end
  return true
end

-- Is THIS file the one the signed sums vouch for? In release mode every module a reload loads goes
-- through here, so editing one file inside a payload - signed yesterday, modified now - is a refusal
-- that names the file instead of a load.
function M.file_ok(dir, path, text)
  dir = tostring(dir or M.installed() or "")
  local ok, problem = M.ensure(dir)
  if not ok then return false, problem end
  local sums = cached.sums
  if type(sums) ~= "table" then
    local read, sums_text = pcall(host.read_file, dir:gsub("/+$", "") .. "/" .. M.SUMS)
    if not read or type(sums_text) ~= "string" then return false, "payload_unverified: " .. dir .. "/" .. M.SUMS .. " is unreadable" end
    sums = parse_sums(sums_text)
    cached.sums = sums
  end
  local want = sums[path]
  if not want then return false, "payload_file_unlisted: " .. path .. " is not named by " .. dir .. "/" .. M.SUMS end
  local have = host.sha256(tostring(text or ""))
  if have ~= want then return false, "payload_file_mismatch: " .. path .. " is " .. have .. ", the signed sums name " .. want end
  return true
end

-- For a report (`/reload`): what was verified, and how many files it vouches for.
function M.state()
  return { dir = cached.dir, ok = cached.ok, error = cached.error, files = cached.count or 0, at = cached.at }
end

return M
