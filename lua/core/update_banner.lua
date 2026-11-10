-- "Update available (<short sha>): run wa update or /update" - the banner Claude Code and pi show.
--
-- This is NOT `lua/core/release.lua`. That module compares release *tags* (`v0.2.0`); this one
-- answers the question the sentence asks: can this machine install something newer, and what is it?
--
-- TWO CHANNELS, because `wa update` has two:
--
--   * **tree** (`runtime-worktree.txt` names a checkout): the update is a build of the tree's
--     `origin/main`. The banner names that commit, and never a release. No feed is read at all.
--   * **release** (no tree): the update is a published `node-<sha12>` release, but only one that
--     carries the manifest, node and sentinel assets for THIS machine's target triple. An
--     aarch64-only release is not an update for x86_64, however new it is.
--
-- Five facts shape the whole module:
--
--   1. **Installed** is `installed.txt` (`commit=`, `binary_source=`, `binary_release=`), read through
--      `lua/core/update.lua`'s own reader so a check and a deploy cannot disagree about what landed.
--   2. **Latest** is the tree's `origin/main` on the tree channel, or the first `node-<twelve hex>`
--      release in the feed with this target's three assets on the release channel. A version tag
--      (`v0.2.0`), an Android bundle (`wa-android-<commit>`) and a release with no asset for this
--      machine are not candidates. The list is newest-first as GitHub returns it.
--   3. **No fetch.** The check never runs `git fetch` and never merges. On the release channel local
--      git answers whether the installed commit is an ancestor of the release commit; on the tree
--      channel it answers the same question against `origin/main`. An unanswerable question is
--      `unknown`, never a guess.
--   4. **One network call per fifteen minutes, shared by every process - on the release channel.**
--      The cache `<state>/update-check.json` holds the published window (including the asset names,
--      never the verdict): the state is recomputed on every read from that window and the *current*
--      installed record, so the banner disappears the moment the node runs the new commit, without
--      waiting for the next call. The tree channel reads no cache and makes no request. The slot is
--      claimed (written) before the request, so a crash or a timeout cannot become a retry loop.
--   5. **A failed check is silent and visible in the state.** `unknown` with a named reason is an
--      answer; "up to date" is only ever `current`, and only when the commits are equal.
--
-- Publishing the result on the bus (`kernel.update.available`) is attempted when the host offers a
-- publish capability. This host does not yet expose the bus to Lua (docs/BUS.md: it is a component
-- WIT interface, `rust/wa-bus`), so today the cached file is the whole surface - the attempt is a
-- `pcall` on `host.bus_publish` and its absence is `bus_unavailable`, not a failure of the check.
local M = {}

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
-- The one reader of the install record and of the runtime tree. `update.lua` does not load this
-- module, so the dependency is one-way.
local update = dofile("lua/core/update.lua")

-- Schema 2 added the release's asset names (the window, not just the newest tag): a `node-<sha12>`
-- release can exist for one architecture only, and a schema-1 cache cannot say whether this machine
-- can install it. An old cache is refused rather than guessed at, which costs one immediate refresh.
M.SCHEMA = 2
M.TOPIC = "kernel.update.available"
M.CACHE_MS = 15 * 60 * 1000
-- Reads of the cache during one process are memoised for this long: the CLI polls nothing, and a
-- served node asks on its housekeeping tick, so the only cost of a shorter value is file reads.
M.READ_MEMO_MS = 60 * 1000
M.DEFAULT_REPO = "Magaav/wasm-agent"
M.DEFAULT_PER_PAGE = 5
-- The target triples the prebuilt channel names its assets with (`scripts/lib/node-binaries.sh`).
-- `host.platform().arch` is Rust's `std::env::consts::ARCH`; the aliases are there because the
-- kernel, a bootstrap and a test all spell the same machine differently. A platform this table does
-- not name has no prebuilt channel; a tree install still updates by building.
M.TARGETS = {
  x86_64 = "x86_64-unknown-linux-gnu", amd64 = "x86_64-unknown-linux-gnu",
  aarch64 = "aarch64-unknown-linux-gnu", arm64 = "aarch64-unknown-linux-gnu",
}
-- "Update available (abc123456789): run wa update or /update" - one wording, used by the CLI footer,
-- the session-start line and the window, so the three surfaces cannot drift (docs/RELEASE-UPDATE.md).
M.LINE = "Update available (%s): run wa update or /update"

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function slashes(path)
  return (tostring(path or ""):gsub("\\", "/"))
end

local function getenv(name)
  if not host.getenv then return nil end
  local ok, value = pcall(host.getenv, name)
  if not ok or value == nil then return nil end
  return tostring(value)
end

local function read(path)
  if not path or path == "" then return nil end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= "string" then return nil end
  return text
end

local function write(path, text)
  if not path or path == "" then return false end
  local ok = pcall(host.write_file, path, text)
  return ok and true or false
end

local function quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function shell(command)
  if not host.exec then return nil end
  local ok, raw = pcall(host.exec, command, "")
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function available(command)
  local result = shell("command -v " .. command .. " >/dev/null 2>&1")
  return result ~= nil and tonumber(result.code) == 0
end

-- ---- identities -------------------------------------------------------------

-- `node-<twelve hex>` is a binary release of one commit (`scripts/lib/node-binaries.sh`). Anything
-- else - `v0.2.0`, `wa-android-a7bbcda92b76`, `nightly` - is not this node's release and is skipped.
function M.parse_release_tag(tag)
  local sha = tostring(tag or ""):match("^node%-(%x+)$")
  if sha and #sha == 12 then return sha:lower() end
  return nil
end

-- A commit as the record writes it: the build path records `git rev-parse --short` (7-8 hex), the
-- prebuilt path records the full 40. Both are accepted; nothing is padded, and a value that is not
-- hex is not a commit.
function M.parse_commit(text)
  local value = trim(text):lower()
  if #value < 7 or #value > 40 or value:find("[^0-9a-f]") then return nil end
  return { commit = value, short = #value > 12 and value:sub(1, 12) or value }
end

-- Prefix equality: the build record's short id is a prefix of the 12-hex release name, and the
-- prebuilt record's full id has the 12-hex name as its prefix. Seven hex is the shortest id the
-- record writes, so the comparison requires seven on both sides - a three-character "match" would be
-- no evidence at all.
function M.same_commit(left, right)
  local a, b = trim(left):lower(), trim(right):lower()
  if a == "" or b == "" then return false end
  if #a < 7 or #b < 7 then return false end
  return a:sub(1, #b) == b or b:sub(1, #a) == a
end

-- The install record, normalised into the two identities this module compares: the release name it
-- was installed as (a prebuilt install has it verbatim) and the commit it was built from.
function M.identity(record)
  if type(record) ~= "table" then return nil end
  local release = M.parse_release_tag(record.binary_release)
  local commit = M.parse_commit(record.commit)
  if not release and not commit then return nil end
  return {
    sha12 = release or (commit and commit.short) or nil,
    commit = commit and commit.commit or nil,
    release = release and ("node-" .. release) or nil,
    prebuilt = tostring(record.binary_source or ""):match("^prebuilt") ~= nil,
    source = trim(record.binary_source),
  }
end

-- ---- the published side -----------------------------------------------------

-- The body of `GET /repos/<owner>/<repo>/releases?per_page=5`: a list, newest first. A single object
-- is accepted too so a fixture can be one release. Drafts are skipped; pre-releases are not, because
-- a node-<sha12> release is the binary of a commit whether GitHub calls it a pre-release or not.
function M.parse_feed(text)
  local ok, body = pcall(json.decode, tostring(text or ""))
  if not ok or type(body) ~= "table" then return nil, "feed_invalid" end
  if body[1] == nil then body = { body } end
  local list = {}
  for _, entry in ipairs(body) do
    if type(entry) == "table" and entry.draft ~= true then
      local sha = M.parse_release_tag(entry.tag_name)
      if sha then
        -- The asset names are the installability fact: a release with only
        -- `wa-aarch64-unknown-linux-gnu-<sha>` cannot be installed on an x86_64 node. Names only -
        -- no download URL, no size, no release notes, so the cache stays a fact about the feed.
        local assets = {}
        for _, asset in ipairs(type(entry.assets) == "table" and entry.assets or {}) do
          local name = trim(type(asset) == "table" and asset.name or "")
          if name ~= "" then assets[name] = true end
        end
        list[#list + 1] = {
          tag = trim(entry.tag_name),
          sha12 = sha,
          name = trim(entry.name),
          url = trim(entry.html_url),
          published_at = trim(entry.published_at),
          assets = assets,
        }
      end
    end
  end
  if #list == 0 then return nil, "no_node_release" end
  return list
end

-- ---- what this machine can install ------------------------------------------

-- The triples this host can run. `WA_NODE_TARGET` wins (a cross-built node, a test naming a triple);
-- otherwise `host.platform()` is the one source of os and arch. A non-Linux host has no prebuilt
-- channel at all: an install there is a build from a tree, if the node has one.
function M.target(options)
  local o = options or {}
  local explicit = trim(o.target ~= nil and tostring(o.target) or getenv("WA_NODE_TARGET"))
  if explicit ~= "" then return explicit end
  local info = platform.info()
  local os_name = trim(o.os ~= nil and tostring(o.os) or (info.os or ""))
  local arch = trim(o.arch ~= nil and tostring(o.arch) or (info.arch or ""))
  if os_name ~= "linux" then return nil end
  return M.TARGETS[arch:lower()]
end

-- A release is installable here when it carries the three files the prebuilt path verifies for this
-- target: the manifest that pins the release's identity, the node and the supervisor. A release with
-- only the aarch64 row is not installable on x86_64, however new it is.
function M.installable(entry, target)
  if type(entry) ~= "table" or type(entry.assets) ~= "table" then return false end
  if not target or target == "" or not entry.sha12 then return false end
  return entry.assets["node-" .. entry.sha12 .. ".manifest"] == true
    and entry.assets["wa-" .. target .. "-" .. entry.sha12] == true
    and entry.assets["wa-sentinel-" .. target .. "-" .. entry.sha12] == true
end

-- The newest release this machine can install, or nil. The feed is newest-first, so the first
-- installable entry is the answer; entries without an asset for this target are skipped, not treated
-- as a reason to tell the reader about a download that would fail.
function M.newest_installable(feed, target)
  for _, entry in ipairs(type(feed) == "table" and feed or {}) do
    if M.installable(entry, target) then return entry end
  end
  return nil
end

-- `git@github.com:owner/repo.git`, `https://github.com/owner/repo`, or a local mirror path: only the
-- first two name a GitHub repository, and the same fallback as `wa_node_release_repo` (the origin's
-- slug, else the canonical repository) keeps the shell lib and this module reading one release.
function M.parse_remote(url)
  local text = trim(url)
  local slug = text:match("github%.com[:/]+([%w%-_.]+/[%w%-_.]+)")
  if slug then
    slug = slug:gsub("%.git$", "")
    if slug:match("^[%w%-_.]+/[%w%-_.]+$") then return slug end
  end
  return nil
end

function M.repo(tree)
  local configured = trim(getenv("WA_NODE_RELEASE_REPO"))
  if configured ~= "" then return configured end
  if tree and tree ~= "" and host.exec then
    local result = shell("git -C " .. quote(slashes(tree)) .. " config --get remote.origin.url 2>/dev/null")
    if result and tonumber(result.code) == 0 then
      local slug = M.parse_remote(result.stdout)
      if slug then return slug end
    end
  end
  return M.DEFAULT_REPO
end

function M.per_page()
  local configured = tonumber(trim(getenv("WA_UPDATE_CHECK_PER_PAGE")))
  if configured and configured >= 1 and configured <= 100 then return math.floor(configured) end
  return M.DEFAULT_PER_PAGE
end

function M.feed_url(repo)
  local configured = trim(getenv("WA_UPDATE_CHECK_FEED"))
  if configured == "off" then return nil end
  if configured ~= "" then return configured end
  return "https://api.github.com/repos/" .. tostring(repo) .. "/releases?per_page=" .. M.per_page()
end

function M.disabled(options)
  local o = options or {}
  local offline = trim(tostring(o.offline ~= nil and o.offline or getenv("WA_OFFLINE")))
  if offline == "1" or offline == "true" then return true, "checks_disabled" end
  local skip = trim(getenv("WA_SKIP_UPDATE_CHECK"))
  if skip == "1" or skip == "true" then return true, "checks_disabled" end
  local enabled = trim(getenv("WA_UPDATE_CHECK"))
  if enabled == "0" or enabled == "off" or enabled == "false" then return true, "checks_disabled" end
  return false
end

local function http_get(url)
  if not host.http then return nil, "http_unavailable" end
  local headers = json.encode({
    ["Accept"] = "application/vnd.github+json",
    ["User-Agent"] = "wasm-agent update check",
  })
  local ok, raw = pcall(host.http, "GET", url, headers, "")
  if not ok or type(raw) ~= "string" then return nil, "feed_unreachable" end
  local decoded_ok, response = pcall(json.decode, raw)
  if not decoded_ok or type(response) ~= "table" then return nil, "feed_unreachable" end
  if tonumber(response.status) ~= 200 then
    return nil, "feed_status_" .. tostring(response.status or "unknown")
  end
  if type(response.body) ~= "string" or trim(response.body) == "" then return nil, "feed_empty" end
  return response.body
end

local function gh_get(repo)
  local result = shell("gh api " .. quote("repos/" .. tostring(repo) .. "/releases?per_page=" .. M.per_page()) .. " 2>/dev/null")
  if not result or tonumber(result.code) ~= 0 or type(result.stdout) ~= "string" or trim(result.stdout) == "" then
    return nil, "feed_unreachable"
  end
  return result.stdout
end

local function curl_get(url)
  local command = "curl -sS -f --max-time 20 -H " .. quote("Accept: application/vnd.github+json") ..
    " -H " .. quote("User-Agent: wasm-agent update check") .. " " .. quote(url) .. " 2>/dev/null"
  local result = shell(command)
  if not result or tonumber(result.code) ~= 0 or type(result.stdout) ~= "string" or trim(result.stdout) == "" then
    return nil, "feed_unreachable"
  end
  return result.stdout
end

-- One request, from the first transport that can make it. `host.http` is primary because it is the
-- node's own bounded network capability and needs neither `gh` nor `curl` on the machine; the two
-- shell forms are the fallbacks the release recipe names (`docs/COMPONENTS.md`, prebuilt binaries).
-- `WA_UPDATE_CHECK_TRANSPORT=gh|curl|http` pins one.
function M.fetch(options, repo)
  local o = options or {}
  local fixture = trim(o.fixture ~= nil and tostring(o.fixture) or getenv("WA_UPDATE_CHECK_FIXTURE"))
  if fixture ~= "" then
    local text = read(fixture)
    if not text then return nil, "feed_unreachable", "fixture" end
    local list, reason = M.parse_feed(text)
    return list, reason, "fixture"
  end
  if type(o.fetch) == "function" then
    local body, reason = o.fetch(o)
    if not body then return nil, reason or "feed_unreachable", "injected" end
    local list, parse_reason = M.parse_feed(body)
    return list, parse_reason, "injected"
  end
  local url = o.url or M.feed_url(repo)
  if not url then return nil, "checks_disabled", nil end
  local order = { "http", "gh", "curl" }
  local configured = trim(o.transport ~= nil and tostring(o.transport) or getenv("WA_UPDATE_CHECK_TRANSPORT"))
  if configured ~= "" then order = { configured } end
  -- A configured URL is not a GitHub API path, so `gh` (which takes one) cannot serve it.
  if trim(getenv("WA_UPDATE_CHECK_FEED")) ~= "" then
    local narrowed = {}
    for _, name in ipairs(order) do if name ~= "gh" then narrowed[#narrowed + 1] = name end end
    order = narrowed
  end
  for _, name in ipairs(order) do
    local body, reason, present
    if name == "http" then
      present = host.http ~= nil
      if present then body, reason = http_get(url) else reason = "http_unavailable" end
    elseif name == "gh" then
      present = available("gh")
      if present then body, reason = gh_get(repo) else reason = "gh_unavailable" end
    elseif name == "curl" then
      present = available("curl")
      if present then body, reason = curl_get(url) else reason = "curl_unavailable" end
    end
    if body then
      local list, parse_reason = M.parse_feed(body)
      return list, parse_reason, name
    end
    -- A transport that is present and failed IS the answer: falling through would be a second
    -- request in the same window, which the fifteen-minute rule exists to prevent.
    if present then return nil, reason or "feed_unreachable", name end
  end
  return nil, "feed_unreachable", nil
end

-- ---- the comparison ---------------------------------------------------------

-- Four answers, and only one of them is "up to date":
--   older   -> behind   (the installed commit is a published release and the feed moved past it, or
--                        local git proves the release commit is a descendant of the installed one)
--   equal   -> current
--   newer   -> ahead    (local git proves the installed commit is a descendant of the release)
--   unknown -> unknown  (no record, no feed, or a commit the feed does not mention and local git
--                        cannot order - a tree whose unpublished commits may be ahead or behind)
--
-- The comparison is against a release **this machine can install** (`o.installable`, or the first
-- feed entry whose assets name this target). A newer aarch64-only release is not a reason to tell an
-- x86_64 node to update, and a prebuilt install that is actually ahead of the feed is not "behind"
-- just because its release fell out of the five-entry window - local ancestry answers that first.
-- The third return value is the release compared against, so a caller does not have to recompute it.
function M.compare(identity, feed, options)
  local o = options or {}
  if not identity or not identity.sha12 then return "unknown", "unknown_installed_commit" end
  if type(feed) ~= "table" or #feed == 0 then return "unknown", "feed_unavailable" end
  local target = o.target
  if target == nil then target = M.target(o) end
  local latest = o.installable or M.newest_installable(feed, target)
  if not latest then
    -- Nothing in the window can be installed here. "Ahead" and "current" remain provable against the
    -- newest published entry; anything else is not the update banner's claim to make.
    local newest = feed[1]
    if M.same_commit(identity.sha12, newest.sha12) then return "equal", "same_commit" end
    if type(o.order) == "function" then
      local verdict = o.order(identity, newest)
      if verdict == "newer" then return "newer", "local_ancestry" end
      if verdict == "equal" then return "equal", "local_ancestry" end
    end
    return "unknown", "no_installable_asset"
  end
  if M.same_commit(identity.sha12, latest.sha12) then return "equal", "same_commit", latest end
  -- Local ancestry first: it is the only fact that can tell an older prebuilt install from one that
  -- is newer than the release its own release name no longer appears beside.
  if type(o.order) == "function" then
    local verdict = o.order(identity, latest)
    if verdict == "older" or verdict == "newer" or verdict == "equal" then
      return verdict, "local_ancestry", latest
    end
  end
  for index = 2, #feed do
    if M.same_commit(identity.sha12, feed[index].sha12) then
      return "older", "installed_release_in_window", latest
    end
  end
  -- A prebuilt install names a published release; if that release is not among the newest ones, every
  -- one of those is newer than it.
  if identity.prebuilt then return "older", "installed_release_older_than_window", latest end
  -- A tree install: the unanswerable case is a commit the feed does not carry. Local ancestry (no
  -- network) turns it into a fact when both objects are on disk; otherwise it stays unknown rather
  -- than guessing "behind" at the tree that is actually ahead of the last release.
  return "unknown", "installed_not_in_release_feed", latest
end

local STATE = { older = "behind", equal = "current", newer = "ahead", unknown = "unknown" }

function M.verdict(identity, feed, comparison, reason, meta)
  meta = meta or {}
  local latest = meta.latest or (type(feed) == "table" and feed[1] or nil)
  local verdict = {
    schema = M.SCHEMA,
    state = STATE[comparison] or "unknown",
    reason = reason,
    -- `tree` is origin/main of a buildable checkout; `release` is a published binary with an asset
    -- for this machine. The channel is part of the fact: "behind" means something different in each.
    channel = meta.channel,
    target = meta.target,
    repo = meta.repo,
    installed = identity and {
      commit = identity.commit,
      sha12 = identity.sha12,
      release = identity.release,
      prebuilt = identity.prebuilt and true or false,
    } or nil,
    checked_at = meta.checked_at,
    age_ms = meta.age_ms,
    cached = meta.cached and true or false,
    transport = meta.transport,
    error = meta.error,
  }
  if latest then verdict.latest = latest end
  if type(feed) == "table" and #feed > 0 then verdict.window = #feed end
  local installed = tostring((identity and identity.sha12) or "?")
  if verdict.state == "behind" and latest and latest.sha12 then
    verdict.line = string.format(M.LINE, latest.sha12)
    verdict.message = "installed " .. installed .. " is behind " ..
      (meta.channel == "tree" and "origin/main " or "the newest installable release ") .. tostring(latest.tag or latest.sha12)
  elseif verdict.state == "current" then
    verdict.message = "installed " .. installed ..
      (meta.channel == "tree" and " is origin/main" or " is the newest installable release")
  elseif verdict.state == "ahead" then
    verdict.message = "installed " .. installed ..
      (meta.channel == "tree" and " is ahead of origin/main " or " is newer than the newest installable release ") ..
      tostring(latest and (latest.tag or latest.sha12) or "?")
  elseif reason == "no_installable_asset" then
    verdict.message = "no published release carries a " .. tostring(meta.target or "this machine") ..
      " binary, so there is nothing this machine can install"
  elseif reason == "tree_dirty" then
    verdict.message = "the runtime tree has uncommitted changes, so wa update would refuse; nothing is offered"
  elseif reason == "tree_origin_unknown" then
    verdict.message = "the runtime tree names no origin/main, so it is unknown what a build would install"
  else
    verdict.message = "cannot tell whether this node is behind: " .. tostring(reason or "feed_unavailable")
  end
  return verdict
end

-- ---- the cache --------------------------------------------------------------

-- `<state>/update-check.json`: the feed as it was last seen, and when it was last asked for. It holds
-- no verdict on purpose - the installed side changes when a deploy lands, and a cached verdict would
-- keep saying "update available" about the release the node now runs.
function M.state_dir()
  return slashes(paths.config())
end

function M.cache_path(state_dir)
  local configured = trim(getenv("WA_UPDATE_CHECK_CACHE"))
  if configured ~= "" then return configured end
  return slashes(state_dir or M.state_dir()) .. "/update-check.json"
end

local function read_cache(path)
  local text = read(path)
  if not text then return nil end
  local ok, cached = pcall(json.decode, text)
  if not ok or type(cached) ~= "table" then return nil end
  if tonumber(cached.schema) ~= M.SCHEMA then return nil end
  local latest = type(cached.latest) == "table" and cached.latest
    or (type(cached.window) == "table" and cached.window[1] or nil)
  if type(latest) ~= "table" or not M.parse_release_tag(latest.tag) then
    -- A feed with no usable latest is no feed: the verdict then says `unknown` rather than comparing
    -- against a version nobody published (the release cache's rule, applied here).
    if cached.checked_at ~= nil then return { checked_at = tonumber(cached.checked_at), last_ok_at = tonumber(cached.last_ok_at), error = cached.error } end
    return nil
  end
  return cached
end

local function order_of(feed)
  local order = {}
  for _, entry in ipairs(feed) do order[#order + 1] = entry.sha12 end
  return order
end

-- The cached feed, rebuilt into the list shape the comparison takes. There is no request here.
local function feed_from_cache(cached)
  if not cached then return nil end
  -- Schema 2 stores the whole published window, asset names included, because choosing the newest
  -- release this machine can install needs the assets of *every* window entry, not only the newest
  -- tag. The entries are facts about the feed; the verdict is still recomputed from the record.
  if type(cached.window) == "table" then
    local feed = {}
    for _, entry in ipairs(cached.window) do
      if type(entry) == "table" then
        local sha = M.parse_release_tag(entry.tag)
        if sha then
          feed[#feed + 1] = {
            tag = trim(entry.tag), sha12 = sha, name = trim(entry.name),
            url = trim(entry.url), published_at = trim(entry.published_at),
            assets = type(entry.assets) == "table" and entry.assets or {},
          }
        end
      end
    end
    if #feed > 0 then return feed end
  end
  -- A hand-written fixture from before schema 2. It carries no asset names, so no entry in it can be
  -- proven installable here; the shape survives only so an old fixture still parses.
  if type(cached.latest) ~= "table" then return nil end
  local latest = cached.latest
  local sha = M.parse_release_tag(latest.tag)
  if not sha then return nil end
  local feed = { { tag = latest.tag, sha12 = sha, name = latest.name, url = latest.url, published_at = latest.published_at } }
  for _, entry in ipairs(type(cached.order) == "table" and cached.order or {}) do
    local other = trim(entry):lower()
    if #other == 12 and other ~= sha then
      feed[#feed + 1] = { tag = "node-" .. other, sha12 = other }
    end
  end
  return feed
end

local function write_cache(path, value)
  if not path then return end
  write(path, json.encode(value))
end

-- The claim written before a request: `checked_at` now, and the last good feed kept. If this process
-- dies mid-request the window is still spent, which is the point - a crash must not become a retry.
local function claim(cached, repo, now)
  return {
    schema = M.SCHEMA,
    checked_at = now,
    last_ok_at = cached and tonumber(cached.last_ok_at) or nil,
    repo = repo,
    latest = cached and cached.latest or nil,
    order = cached and cached.order or nil,
    window = cached and cached.window or nil,
    transport = cached and cached.transport or nil,
    error = nil,
    pending = true,
  }
end

-- ---- local ancestry, no network ---------------------------------------------

-- "Is the installed commit an ancestor of the release commit?" answered from the objects already in
-- the runtime tree. `nil` when the tree is unknown or the release commit is not there: an unanswerable
-- question is not an answer.
function M.order_by_ancestry(tree, identity, latest)
  if not tree or tree == "" or not identity or not identity.commit or not latest then return nil end
  local path = slashes(tree)
  local function ancestor(left, right)
    local result = shell("git -C " .. quote(path) .. " merge-base --is-ancestor " .. left .. " " .. right .. " 2>/dev/null")
    return result ~= nil and tonumber(result.code) == 0
  end
  local installed, release = trim(identity.commit):lower(), trim(latest.sha12):lower()
  if installed == "" or release == "" then return nil end
  if M.same_commit(installed, release) then return "equal" end
  if ancestor(installed, release) then return "older" end
  if ancestor(release, installed) then return "newer" end
  return nil
end

-- ---- the buildable-tree channel --------------------------------------------

-- The commit `wa update` would build: the tree's local `origin/main` (then `main`), and no fetch -
-- the banner is not allowed to make one. A dirty tree is refused by `update.lua` before it queues,
-- so it is not an install this banner may offer either. Returns `sha12, ref` or `nil, reason`.
function M.tree_target(tree)
  if not tree or tree == "" then return nil, "tree_unavailable" end
  local path = slashes(tree)
  local status = shell("git -C " .. quote(path) .. " status --porcelain 2>/dev/null")
  if not status or tonumber(status.code) ~= 0 then return nil, "tree_unreadable" end
  if trim(status.stdout) ~= "" then return nil, "tree_dirty" end
  for _, ref in ipairs({ "refs/remotes/origin/main", "refs/heads/main" }) do
    local result = shell("git -C " .. quote(path) .. " rev-parse --short=12 " .. ref .. " 2>/dev/null")
    if result and tonumber(result.code) == 0 then
      local sha = trim(result.stdout):lower()
      if #sha >= 7 and not sha:find("[^0-9a-f]") then return sha, ref end
    end
  end
  return nil, "tree_origin_unknown"
end

-- The tree's answer is the same four-valued comparison, with `origin/main` as the candidate. Local
-- ancestry is the only fact needed; there is no release and no asset because the install is a build.
function M.tree_compare(identity, target, order)
  if not identity or not identity.commit or not target then return "unknown", "tree_origin_unknown" end
  if M.same_commit(identity.commit, target) then return "equal", "same_commit" end
  local verdict = type(order) == "function" and order(identity, { sha12 = target }) or nil
  if verdict == "older" or verdict == "newer" or verdict == "equal" then return verdict, "local_ancestry" end
  return "unknown", "tree_origin_unknown"
end

-- ---- the bus ----------------------------------------------------------------

-- One fact per completed refresh: identity and time only, never a sentence, never the feed's notes.
-- Returns false plus the reason when this host has no bus reachable from Lua (today: all of them).
function M.publish(verdict, options)
  local o = options or {}
  local publish = o.publish
  if publish == nil and host and host.bus_publish then publish = host.bus_publish end
  if type(publish) ~= "function" then return false, "bus_unavailable" end
  local fact = {
    schema = "wa.update.available",
    schema_version = 1,
    state = verdict.state,
    repo = verdict.repo,
    installed = verdict.installed and verdict.installed.sha12 or nil,
    latest = verdict.latest and verdict.latest.sha12 or nil,
    tag = verdict.latest and verdict.latest.tag or nil,
    checked_at = verdict.checked_at,
  }
  local ok, result = pcall(publish, M.TOPIC, json.encode(fact))
  if not ok then return false, tostring(result) end
  if result == false or result == nil then return false, "bus_refused" end
  return true
end

-- ---- the whole check --------------------------------------------------------

-- `options`: `install`, `tree`, `record`, `now`, `refresh` (false = cache only), `fixture`, `fetch`,
-- `url`, `repo`, `offline`, `cache_path`, `state_dir`, `publish`, `order`. The names exist so a test
-- can point the whole path - record, cache, feed - at fixtures, and never at this machine's node.
function M.check(options)
  local o = options or {}
  local now = tonumber(o.now) or math.floor((host.now and host.now() or os.time()) * 1000)
  local install = o.install or update.install_dir()
  local tree = o.tree
  if tree == nil then tree = update.runtime_tree(install) end
  local record = o.record or update.installed_record(install)
  local identity = M.identity(record)
  local repo = o.repo or M.repo(tree)
  local target = M.target(o)

  -- A node with a buildable tree updates by building it: `wa update` fetches origin and deploys the
  -- tree's main. The release feed is not consulted at all on that path, which is what keeps an
  -- aarch64-only release from being advertised to an x86_64 node. `o.tree_main` lets a test name the
  -- ref without a git fixture; a real check reads it (and the dirty flag) locally.
  local tree_main, tree_ref, tree_reason
  if o.tree_main ~= nil then
    tree_main = trim(o.tree_main):lower()
    if tree_main == "" then tree_main = nil end
    tree_ref = "injected"
    tree_reason = o.tree_reason
  elseif tree and tree ~= "" then
    local sha, ref_or_reason = M.tree_target(tree)
    tree_main = sha
    if sha then tree_ref = ref_or_reason else tree_reason = ref_or_reason end
  end
  if tree_main and (#tree_main < 7 or tree_main:find("[^0-9a-f]")) then
    tree_main, tree_reason = nil, "tree_origin_unknown"
  end
  if tree and tree ~= "" and (tree_main ~= nil or tree_reason ~= nil) then
    local order = o.order
    if order == nil then
      order = function(installed, latest) return M.order_by_ancestry(tree, installed, latest) end
    end
    local comparison, compare_reason
    local latest
    if tree_main then
      latest = { tag = "origin/main", name = "origin/main", sha12 = tree_main }
      comparison, compare_reason = M.tree_compare(identity, tree_main, order)
    else
      comparison, compare_reason = "unknown", tree_reason or "tree_origin_unknown"
    end
    local verdict = M.verdict(identity, nil, comparison, compare_reason, {
      repo = repo, checked_at = now, cached = false, channel = "tree", target = target,
      latest = latest, error = tree_reason,
    })
    verdict.tree, verdict.fresh, verdict.attempted = tree, false, false
    verdict.tree_ref = tree_ref
    return verdict
  end

  local path = o.cache_path or M.cache_path(o.state_dir)
  local cached = read_cache(path)
  -- A cache written for another repository (a mirror switched, an origin changed) names releases this
  -- node does not run; it is not a fact about this node, so it is not used.
  if cached and cached.repo and cached.repo ~= repo then cached = nil end
  local feed = feed_from_cache(cached)
  local age = cached and tonumber(cached.checked_at) and (now - tonumber(cached.checked_at)) or nil
  local fresh = age ~= nil and age >= 0 and age < M.CACHE_MS
  local disabled, disabled_reason = M.disabled(o)
  local reason = cached and cached.error or nil
  local attempted, transport = false, cached and cached.transport or nil

  if not fresh and o.refresh ~= false and not disabled then
    -- The window is spent before the request: a crash or a timeout must not retry sooner.
    write_cache(path, claim(cached, repo, now))
    attempted = true
    local fetched, fetch_reason, used = M.fetch(o, repo)
    if fetched then
      feed, reason, transport = fetched, nil, used
      write_cache(path, {
        schema = M.SCHEMA, checked_at = now, last_ok_at = now, repo = repo,
        transport = used, latest = fetched[1], order = order_of(fetched), window = fetched,
      })
    else
      reason = fetch_reason
      -- The last good feed is kept: a transient failure must not erase a known update, and the next
      -- attempt is `CACHE_MS` away.
      write_cache(path, {
        schema = M.SCHEMA, checked_at = now,
        last_ok_at = cached and tonumber(cached.last_ok_at) or nil,
        repo = repo, transport = transport,
        latest = cached and cached.latest or nil, order = cached and cached.order or nil,
        window = cached and cached.window or nil, error = reason,
      })
    end
  elseif fresh then
    reason = cached and cached.error or nil
  elseif o.refresh == false then
    reason = reason or "not_checked"
  end
  if disabled then reason = disabled_reason end

  local order = o.order
  if order == nil then
    order = function(installed, latest) return M.order_by_ancestry(tree, installed, latest) end
  end
  local comparison, compare_reason, installable = M.compare(identity, feed,
    { target = target, order = order, installable = o.installable })
  local verdict = M.verdict(identity, feed, comparison, compare_reason, {
    repo = repo, checked_at = now, age_ms = age, cached = fresh, transport = transport, error = reason,
    channel = "release", target = target,
    -- The comparison's own choice when it made one; the newest tag otherwise, so a caller still sees
    -- what the feed held even when nothing in it can be installed here.
    latest = installable or (type(feed) == "table" and feed[1] or nil),
  })
  verdict.tree = tree
  verdict.fresh = fresh
  verdict.attempted = attempted
  if attempted then
    -- One publish per completed refresh. The bus is a fact fan-out, so a refused or absent bus is
    -- reported in the verdict and never retried here.
    local published, bus_reason = M.publish(verdict, o)
    verdict.published, verdict.bus = published, bus_reason
  end
  return verdict
end

-- ---- session-status-content -----------------------------------------------------
--
-- The CLI's **session-status-content** area: ONE line directly above the session status bar,
-- reserved for transient session notices (docs/RELEASE-UPDATE.md). This module decides what that
-- line says, because two facts share it and only one of them is the update notice:
--
--   * a sandbox rebuild REPLACES the notice while it is in flight. The deploy writes
--     `<data>/build-status.json` (the same file `rust/wa-term/src/build_status.rs` reads and draws,
--     with a progress bar, when the native editor owns the screen), so the two renderers cannot
--     disagree about whether a build is running. A finished build shows its result for a moment and
--     hands the line back; a **failed** one shows the failure and then hands the line back too - a
--     failed build leaves the update available, so the notice is still true and is never lost;
--   * otherwise the notice is the line, in the CLI view's warning yellow.
--
-- Empty is no line at all: the row stays with the chat, so there is never a blank gap above the
-- status bar. The windows below are the twin of the constants in `build_status.rs` and the tests pin
-- them against it, the same way `M.LINE` is pinned against the window's sentence.
M.BUILDING_FOR = 120      -- seconds; `build_status::FRESH`
M.INSTALLED_FOR = 30      -- `build_status::INSTALLED_FOR`
M.FAILED_FOR = 60         -- `build_status::FAILED_FOR`
-- The loader's prefix, the same words `build_status.rs` uses: `⟳ building wasm-agent ...`.
M.BUILDING_LINE = "\226\159\179 building wasm-agent"
M.REBUILT_LINE = "\226\156\147 wasm-agent rebuilt%s \226\128\148 restarting into the new build"
M.FAILED_LINE = "\226\156\151 wasm-agent build failed%s"

-- `125` -> `2m05s`, `45` -> `45s`, `3720` -> `1h02m`: `elapsed` in build_status.rs, to the second.
local function elapsed(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
  return s .. "s"
end

-- Where the deploy records its progress: `<data>/build-status.json`, overridable so a test (or an
-- operator) can point it at a fixture and never at this machine's node.
function M.build_path(options)
  local o = options or {}
  local configured = trim(o.path)
  if configured == "" then configured = trim(getenv("WA_BUILD_STATUS")) end
  if configured ~= "" then return configured end
  return slashes(paths.data()) .. "/build-status.json"
end

-- The build's status, or nil. Re-read at most once a second (the deploy writes it many times a
-- second while it compiles) - the same rule `build_status::current` applies on the Rust side.
local build_memo = { at = nil, path = nil, status = nil }
function M.build_status(options)
  local o = options or {}
  local path = o.path or M.build_path(o)
  local now = math.floor((host.now and host.now() or os.time()) * 1000)
  if build_memo.path == path and build_memo.at and (now - build_memo.at) < 1000 and not o.refresh then
    return build_memo.status
  end
  local text = read(path)
  local status = nil
  if text then
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" then status = decoded end
  end
  build_memo.path, build_memo.at, build_memo.status = path, now, status
  return status
end

-- Forget the memo: a caller that just wrote the file (a test, the deploy's own tail) asks again now.
function M.reset_build() build_memo.at, build_memo.path, build_memo.status = nil, nil, nil end

-- The loader's line: what the build says it is doing, and for how long. The bar is the Rust
-- renderer's; this one is the same sentence without it, because a line that also has to survive
-- `clip` at 40 columns should not spend 16 of them on a bar.
function M.building_text(build, now)
  local phase, crate = trim(build.phase), trim(build.crate)
  local what = ""
  if phase == "compiling" then
    local done, total = tonumber(build.done), tonumber(build.total)
    local count = ""
    if total and total > 0 then count = math.min(math.max(done or 0, 0), total) .. "/" .. total .. " " end
    what = count .. "compiling" .. (crate ~= "" and (" " .. crate) or "")
  elseif phase ~= "" then
    what = phase
  end
  local started = tonumber(build.started_at)
  local clock = started and (" \194\183 " .. elapsed((tonumber(now) or 0) - started)) or ""
  if what == "" then return M.BUILDING_LINE .. clock end
  return M.BUILDING_LINE .. " \194\183 " .. what .. clock
end

-- The build's own line, or nil when there is no fresh build to show: `building`, `installed` (a
-- result, briefly) and `failed` (the failure, briefly - then the notice has the line back).
function M.build_line(build, now)
  if type(build) ~= "table" then return nil end
  local at = tonumber(build.at)
  if not at or not tonumber(now) then return nil end
  local age = tonumber(now) - at
  local state = trim(build.state)
  if state == "building" and age < M.BUILDING_FOR then
    return { kind = "building", text = M.building_text(build, now) }
  end
  if state == "installed" and age < M.INSTALLED_FOR then
    local took = trim(build.crate)
    return { kind = "installed", text = string.format(M.REBUILT_LINE, took ~= "" and (" (" .. took .. ")") or "") }
  end
  if state == "failed" and age < M.FAILED_FOR then
    local phase = trim(build.phase)
    return { kind = "failed", text = string.format(M.FAILED_LINE, phase ~= "" and (" (" .. phase .. ")") or "") }
  end
  return nil
end

-- What the session-status-content line says now: `{ text, kind }`, or nil when there is no line.
-- `options`: `notice` (the standing sentence), `build` (a status table; false = never read the
-- file), `path`, `now` (unix seconds), `refresh`.
function M.session_content(options)
  local o = options or {}
  local now = tonumber(o.now) or (host.now and host.now() or os.time())
  local build = o.build
  if build == nil then build = M.build_status(o) end
  local fact = M.build_line(build, now)
  if fact then return fact end
  local notice = trim(o.notice)
  if notice == "" then return nil end
  return { kind = "notice", text = notice }
end

-- Cache only: what the window asks for on load. The served node's housekeeping tick keeps the cache
-- fresh, so a page load never costs a request (docs/RELEASE-UPDATE.md names the measurement that made
-- a network call in a request path unacceptable).
function M.status(options)
  local o = {}
  for key, value in pairs(options or {}) do o[key] = value end
  o.refresh = false
  return M.check(o)
end

-- The served node's periodic check. `READ_MEMO_MS` keeps the housekeeping tick (every 20s) from
-- re-reading the cache file, and `CACHE_MS` keeps it from making more than one request per window.
local memo = { at = nil, verdict = nil }

function M.tick(options)
  local o = options or {}
  local now = tonumber(o.now) or math.floor((host.now and host.now() or os.time()) * 1000)
  if memo.at and memo.verdict and (now - memo.at) < M.READ_MEMO_MS and o.now == nil then
    return memo.verdict
  end
  local verdict = M.check(o)
  memo.at, memo.verdict = now, verdict
  return verdict
end

-- Forget the in-process memo. A test (or a caller that just installed a release) uses it; nothing in
-- a node needs to.
function M.reset()
  memo.at, memo.verdict = nil, nil
end

return M
