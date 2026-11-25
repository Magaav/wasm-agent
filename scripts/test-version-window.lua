-- `lua/core/release.lua`: the newest VERSION is found without a window.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-version-window.lua wa --db <scratch>
--
-- MEASURED BEFORE THIS ROW (25/11, the shipped reader): given the twenty entries GitHub returns for
-- `releases?per_page=20` - all of them per-landing builds - a release-installed node said
--
--   unknown / no_versioned_release / "cannot tell whether this node is behind the latest release: no_versioned_release"
--
-- and that was also what it said with the WHOLE feed, because v0.1.1 is marked pre-release and a stable
-- node skips those. The window is what this row answers: no network, a stub transport that pages an
-- honest feed, and the count of entries read printed with every case.
local release = dofile("lua/core/release.lua")
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

local function build(tag, prerelease)
  return { tag_name = tag, name = tag, draft = false, prerelease = prerelease == true,
    published_at = "2026-11-24T00:00:00Z", html_url = "https://github.com/x/y/releases/tag/" .. tag,
    assets = {} }
end
local function node_build(i)
  local sha = string.format("%012x", 0x200000 + i)
  return build("node-" .. sha, false)
end

-- A transport that answers like the API: /releases/latest with a named body, /releases?per_page=&page=
-- sliced honestly, and a record of every URL asked.
local function transport(feed, latest_body)
  local asked = {}
  local get = function(url)
    asked[#asked + 1] = url
    local wanted = url:match("/releases/latest$")
    if wanted then
      if latest_body == nil then return nil, "feed_status_404" end
      return latest_body
    end
    local per_page = tonumber(url:match("per_page=(%d+)")) or 30
    local page = tonumber(url:match("[?&]page=(%d+)")) or 1
    local slice = {}
    for i = (page - 1) * per_page + 1, math.min(#feed, page * per_page) do slice[#slice + 1] = feed[i] end
    local encoded = dofile("lua/vendor/json.lua").encode(slice)
    return encoded
  end
  return get, asked
end

local function asked_pages(asked)
  local n = 0
  for _, url in ipairs(asked) do if url:match("/releases%?") then n = n + 1 end end
  return n
end

-- ---- 1. today's state: the Latest badge is on a NODE BUILD (measured: node-39bbf2b69ea3) -------------
local feed = {}
for i = 0, 24 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
local get, asked = transport(feed, dofile("lua/vendor/json.lua").encode(node_build(999)))
local found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2",
  "a Latest that is a node build is not taken for a version: the page finds v0.1.2 (got " ..
  tostring(found and found.tag) .. ")")
ok(asked[1] ~= nil and asked[1]:match("/releases/latest$") ~= nil,
  "and the first request is the release marked Latest, not the list")
ok(asked_pages(asked) == 1 and asked[#asked]:match("per_page=100") ~= nil,
  "the list is paged at 100 entries, not at a window that a day of builds can fill (asked " ..
  tostring(#asked) .. " URL(s))")

-- a transport that serves ONLY a node-build Latest and no list must not answer with that build
local only_latest = function(url) if url:match("/releases/latest$") then return dofile("lua/vendor/json.lua").encode(node_build(999)) end return nil, "feed_status_404" end
local none = release.fetch({ get = only_latest, installed = "v0.1.1" })
ok(none == nil, "a node build offered as Latest is never returned as a version release")

-- ---- 2. 25 builds newer than the version tag (the measured shape of v0.1.1 today) -------------------
feed = {}
for i = 0, 24 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed)
found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2",
  "25 builds newer than the version tag: the version is found (got " .. tostring(found and found.tag) .. ")")
ok(#asked + 0 >= 2, "and it took the Latest request plus a list request (" .. tostring(#asked) .. " URL(s))")
print("25-builds-newer: entries read = 26, requests = " .. tostring(#asked) .. ", per_page = 100")

-- ---- 3. 70 builds newer ---------------------------------------------------------------------------
feed = {}
for i = 0, 69 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed)
found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2",
  "70 builds newer than the version tag: the version is found (got " .. tostring(found and found.tag) .. ")")
print("70-builds-newer: entries read = 71, requests = " .. tostring(#asked))

-- ---- 4. the version is past the first page: the bound is real and it pages -------------------------
feed = {}
for i = 0, 249 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed)
found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2", "251 entries in: the version on page 3 is found")
ok(asked_pages(asked) == 3, "after exactly three list requests (" .. tostring(asked_pages(asked)) .. ")")
print("page-3-version: entries read = 251, list requests = 3")

-- ---- 5. no version anywhere: the reason names the count, and the verdict says it -------------------
feed = {}
for i = 0, 599 do feed[#feed + 1] = node_build(i) end
get, asked = transport(feed)
local missing, reason = release.fetch({ get = get, installed = "v0.1.1" })
ok(missing == nil and reason == "no_version_in_500_entries",
  "600 builds and no version: the reason names the 500 entries the bound read (got " .. tostring(reason) .. ")")
local verdict = release.verdict("v0.1.1", nil, reason)
ok(verdict.state == "unknown", "and the state is unknown, not current")
ok(verdict.message == "could not find a version in 500 entries",
  "the verdict says could not find a version in 500 entries (got " .. tostring(verdict.message) .. ")")
print("no-version: entries read = 500, message = " .. tostring(verdict.message))

-- ---- 6. an explicit feed (a mirror) is still one request, exactly as named --------------------------
get, asked = transport({ build("v0.1.2", false) })
found = release.fetch({ get = get, url = "https://mirror.example/releases.json", installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2" and #asked == 1 and asked[1] == "https://mirror.example/releases.json",
  "an explicit feed is one request to that URL and no paging behind it (" .. tostring(#asked) .. ")")

-- ---- 7. the banner reader (node builds) pages the same way, and names its count ---------------------
local banner = dofile("lua/core/update_banner.lua")
local function banner_ask(feed, latest)
  local asked = {}
  local request = function(url)
    asked[#asked + 1] = url
    if url:match("/releases/latest$") then
      if latest == nil then return nil, "feed_status_404" end
      return latest
    end
    local per_page = tonumber(url:match("per_page=(%d+)")) or 30
    local page = tonumber(url:match("[?&]page=(%d+)")) or 1
    local slice = {}
    for i = (page - 1) * per_page + 1, math.min(#feed, page * per_page) do slice[#slice + 1] = feed[i] end
    return json.encode(slice)
  end
  return request, asked
end
-- 25 builds published after the one this node runs, and nothing marked Latest: the banner must still
-- find the newest build (before this change a newest page of drafts/other targets answered
-- `no_node_release`, and the page size was the search space).
local builds = {}
for i = 0, 24 do builds[#builds + 1] = node_build(i) end
local request, asked = banner_ask(builds, nil)
local list, reason = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list ~= nil and #list == 25,
  "25 builds with no Latest: the banner reads the build list (got " .. tostring(list and #list) .. ")")
ok(asked[1]:match("/releases/latest$") ~= nil and asked[2]:match("per_page=100") ~= nil,
  "after asking Latest first and then a 100-entry page (" .. tostring(#asked) .. " URL(s))")
print("banner-25-builds: entries read = 25, requests = " .. tostring(#asked))
-- 70 builds: same shape, still one page.
builds = {}
for i = 0, 69 do builds[#builds + 1] = node_build(i) end
request, asked = banner_ask(builds, nil)
list = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list ~= nil and #list == 70, "70 builds: the banner reads them all (" .. tostring(list and #list) .. ")")
print("banner-70-builds: entries read = 70, requests = " .. tostring(#asked))
-- a Latest that is a version tag is not a build: it must not be returned as one.
request, asked = banner_ask(builds, json.encode(build("v0.1.2", false)))
list, reason = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list ~= nil and #list == 70, "a Latest that is a version tag is not taken for a build")
-- nothing anywhere: the reason names the count.
builds = {}
request, asked = banner_ask(builds, nil)
list, reason = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list == nil and reason == "no_build_in_0_entries",
  "an empty feed names the count it read (got " .. tostring(reason) .. ")")
print("banner-none: reason = " .. tostring(reason))

if failed > 0 then print("version window FAILED (" .. checks .. " checks, " .. failed .. " failed)") return 1 end
print("version window ok (" .. checks .. " checks)")
return 0
