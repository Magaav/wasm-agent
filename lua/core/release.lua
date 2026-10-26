-- Is there a newer published release than the one this node runs?
--
-- One GET, one comparison, no installation. The node cannot replace itself - the stop is the last
-- command a run executes - so this answers a question and `update.lua` decides what to do about the
-- answer. What it deliberately does NOT do: install, download a bundle, or clear the "behind" state
-- because the caller looked hopeful.
--
-- `unknown` is a real answer, and it is never rendered as `current`: an unreachable feed, a feed that
-- does not parse, or an install whose record names no release all say `unknown` with the reason. A
-- node that says "up to date" because it could not ask is the silent success this file exists to
-- avoid.
--
-- The comparison is on tags (`v0.2.0`), because that is the only version identity the published side
-- and the installed side can agree on without a second request: the install record carries the commit
-- it was built from and, since this change, the release tag it was installed as. An install from
-- before that change has a commit and no tag, so it answers `unknown` - once, until its next deploy.
local M = {}

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

-- GitHub's own "newest non-draft release" endpoint. It is one request, it needs no token for a
-- public repository, and its body names the tag. `WA_RELEASE_FEED` overrides it (a mirror, or `off`).
M.DEFAULT_FEED = "https://api.github.com/repos/Magaav/wasm-agent/releases/latest"

-- Ten minutes. The UI asks on load and after an update; a check that costs a request every time the
-- window reloads is a request per reload for an answer that changes a few times a week.
M.CACHE_MS = 10 * 60 * 1000

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function slashes(path)
  return (tostring(path or ""):gsub("\\", "/"))
end

local function getenv(name)
  if not (host.getenv) then return nil end
  local ok, value = pcall(host.getenv, name)
  if not ok or value == nil then return nil end
  return value
end

local function read(path)
  if not path or path == "" then return nil end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= "string" then return nil end
  return text
end

-- ---- versions ---------------------------------------------------------------

-- `v0.2.0`, `0.1.0-alpha.12`, `1.0.0-rc.1+build`. Returns nil for anything else, because a version
-- this does not understand must not be compared by accident.
function M.parse_version(text)
  local source = trim(text):gsub("^[vV]", "")
  if source == "" then return nil end
  local major, minor, patch, rest = source:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
  if not major then return nil end
  local core = { tonumber(major), tonumber(minor), tonumber(patch) }
  local pre = nil
  -- Build metadata (`+sha`) is explicitly not part of precedence.
  local tail = (rest or ""):gsub("%+.*$", "")
  if tail ~= "" then
    if tail:sub(1, 1) ~= "-" then return nil end
    pre = {}
    for part in tail:sub(2):gmatch("[^.]+") do pre[#pre + 1] = part end
    if #pre == 0 then return nil end
  end
  return { core = core, pre = pre }
end

local function compare_identifier(left, right)
  local ln = tonumber(left)
  local rn = tonumber(right)
  if ln and rn then
    if ln == rn then return 0 end
    return ln < rn and -1 or 1
  end
  -- A numeric identifier always has lower precedence than an alphanumeric one.
  if ln then return -1 end
  if rn then return 1 end
  if left == right then return 0 end
  return left < right and -1 or 1
end

-- Semantic-version precedence: the numeric core first, then a prerelease sorts BELOW its release, and
-- the identifiers of two prereleases compare left to right. Returns -1, 0, 1, or nil when either side
-- is not a version.
function M.compare(left, right)
  local a = M.parse_version(left)
  local b = M.parse_version(right)
  if not a or not b then return nil end
  for index = 1, 3 do
    if a.core[index] ~= b.core[index] then
      return a.core[index] < b.core[index] and -1 or 1
    end
  end
  if not a.pre and not b.pre then return 0 end
  if not a.pre then return 1 end
  if not b.pre then return -1 end
  local count = math.max(#a.pre, #b.pre)
  for index = 1, count do
    local x, y = a.pre[index], b.pre[index]
    if x == nil then return -1 end
    if y == nil then return 1 end
    local verdict = compare_identifier(x, y)
    if verdict ~= 0 then return verdict end
  end
  return 0
end

-- True only when `candidate` is strictly newer. An uncomparable pair is `nil` plus the reason, never
-- a hopeful `true`.
function M.newer(candidate, installed)
  local verdict = M.compare(candidate, installed)
  if not verdict then return nil, "uncomparable_versions" end
  return verdict > 0
end

-- ---- the published side -----------------------------------------------------

-- The body of `/releases/latest`. Kept separate from the request so a fixture can be a file.
function M.parse_release(text)
  local ok, body = pcall(json.decode, tostring(text or ""))
  if not ok or type(body) ~= "table" then return nil, "feed_invalid" end
  local tag = trim(body.tag_name)
  if tag == "" then return nil, "feed_invalid" end
  local version = tag:gsub("^[vV]", "")
  if not M.parse_version(version) then return nil, "feed_invalid" end
  local notes = trim(body.body):gsub("\r", "")
  if #notes > 400 then notes = notes:sub(1, 400):gsub("%s*[^%s]*$", "") .. "..." end
  return {
    tag = tag,
    version = version,
    name = trim(body.name),
    url = trim(body.html_url),
    published_at = trim(body.published_at),
    prerelease = body.prerelease == true,
    notes = notes,
  }
end

function M.feed_url()
  local configured = trim(getenv("WA_RELEASE_FEED"))
  if configured == "off" then return nil end
  if configured ~= "" then return configured end
  return M.DEFAULT_FEED
end

-- Returns release, error. `options.fixture` is a file holding the endpoint's body and `options.url`
-- an explicit feed, so the tests never touch the network; the same names as environment overrides
-- (`WA_RELEASE_FIXTURE`, `WA_RELEASE_FEED`) exist for a node. `WA_OFFLINE` / `WA_SKIP_UPDATE_CHECK`
-- are the operator's off switches.
function M.fetch(options)
  options = options or {}
  local fixture = trim(options.fixture ~= nil and options.fixture or getenv("WA_RELEASE_FIXTURE"))
  if fixture ~= "" then
    local text = read(fixture)
    if not text then return nil, "feed_unreachable" end
    return M.parse_release(text)
  end
  local offline = trim(options.offline ~= nil and tostring(options.offline) or getenv("WA_OFFLINE"))
  if offline == "1" or offline == "true" or trim(getenv("WA_SKIP_UPDATE_CHECK")) == "1" then
    return nil, "checks_disabled"
  end
  local url = options.url or M.feed_url()
  if not url then return nil, "checks_disabled" end
  if not host.http then return nil, "http_unavailable" end
  local headers = json.encode({
    ["Accept"] = "application/vnd.github+json",
    ["User-Agent"] = "wasm-agent release check",
  })
  local ok, raw = pcall(host.http, "GET", url, headers, "")
  if not ok or type(raw) ~= "string" then return nil, "feed_unreachable" end
  local decoded_ok, response = pcall(json.decode, raw)
  if not decoded_ok or type(response) ~= "table" then return nil, "feed_unreachable" end
  if tonumber(response.status) ~= 200 then
    return nil, "feed_status_" .. tostring(response.status or "unknown")
  end
  return M.parse_release(response.body)
end

-- ---- the installed side -----------------------------------------------------

-- `installed.txt` is the install's own record (`commit=`, and now `release=`). `record` is that file
-- parsed; `version` is accepted too so a test or a future record shape needs no change here.
function M.installed(record)
  if type(record) ~= "table" then return nil end
  local named = trim(record.release ~= nil and record.release or record.version)
  if named == "" then return nil end
  named = named:gsub("^[vV]", "")
  if not M.parse_version(named) then return nil end
  return named
end

-- ---- the answer -------------------------------------------------------------

function M.verdict(installed, release, reason)
  local verdict = { installed = installed, reason = reason }
  if not release then
    verdict.state = "unknown"
    verdict.message = "cannot tell whether this node is behind the latest release: " ..
      tostring(reason or "feed_unavailable")
    return verdict
  end
  verdict.latest = release.version
  verdict.tag = release.tag
  verdict.url = release.url
  verdict.published_at = release.published_at
  verdict.notes = release.notes
  if not installed then
    verdict.state = "unknown"
    verdict.reason = "no_recorded_release"
    verdict.message = "this install records no release tag, so it cannot be compared to " ..
      tostring(release.tag) .. "; the next deploy records one"
    return verdict
  end
  local comparison = M.compare(installed, release.version)
  if not comparison then
    verdict.state = "unknown"
    verdict.reason = "uncomparable_versions"
    verdict.message = "cannot compare installed " .. installed .. " with " .. release.version
    return verdict
  end
  if comparison < 0 then
    verdict.state = "behind"
    verdict.message = "installed v" .. installed .. " is behind the latest release " .. release.tag
    return verdict
  end
  verdict.state = "current"
  verdict.message = "installed v" .. installed .. " is the latest release"
  return verdict
end

function M.cache_path()
  return slashes(paths.config()) .. "/release-cache.json"
end

local function read_cache(path)
  local text = read(path)
  if not text then return nil end
  local ok, cached = pcall(json.decode, text)
  if not ok or type(cached) ~= "table" then return nil end
  return cached
end

-- The whole check. `options.installed` is the release tag the install recorded (nil when it recorded
-- none); `options.now` and `options.fresh` exist so a test never depends on the clock or the network.
function M.check(options)
  options = options or {}
  local now = tonumber(options.now) or (host.monotonic_ms and host.monotonic_ms()) or os.time() * 1000
  local path = options.cache_path or M.cache_path()
  local cached = (not options.fresh) and read_cache(path) or nil
  local release, reason, from_cache
  if cached and tonumber(cached.at) and (now - tonumber(cached.at)) < M.CACHE_MS then
    -- The cached value is the parsed release, and it is re-validated on the way out: a hand-edited or
    -- half-written cache answers `unknown` rather than a version nobody published.
    local held = cached.release
    if type(held) == "table" and trim(held.version) ~= "" and M.parse_version(held.version) then
      release, from_cache = held, true
    end
  end
  if not release then
    if options.cache_only then
      -- A deploy request must not pay a network call, so it reads what a previous check left behind
      -- and says `not_checked` when nothing did. That is a fact, not a failure.
      local verdict = M.verdict(options.installed, nil, "not_checked")
      verdict.checked_at = now
      return verdict
    end
    release, reason = M.fetch(options)
    if release then
      pcall(host.write_file, path, json.encode({ at = now, release = release }))
    end
  end
  local verdict = M.verdict(options.installed, release, reason)
  verdict.cached = from_cache and true or false
  verdict.checked_at = now
  return verdict
end

return M
