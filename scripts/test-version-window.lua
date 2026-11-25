-- `lua/core/release.lua` and `lua/core/update_banner.lua`: the newest version/build is found without
-- depending on how many were published after it - and the normal answer costs the same one request it did.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-version-window.lua wa --db <scratch>
--
-- No network: a stub transport pages an honest feed and records every URL asked, so the REQUEST COUNT is a
-- fact each case states.
local release = dofile("lua/core/release.lua")
local json = dofile("lua/vendor/json.lua")
local banner = dofile("lua/core/update_banner.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function build(tag, prerelease)
  return { tag_name = tag, name = tag, draft = false, prerelease = prerelease == true,
    published_at = "2026-11-24T00:00:00Z", html_url = "https://github.com/x/y/releases/tag/" .. tag, assets = {} }
end
local function node_build(i)
  return build("node-" .. string.format("%012x", 0x200000 + i), false)
end

-- transport(feed, latest): /releases/latest answers `latest` (a JSON body, or nil for 404); the list is
-- sliced by the per_page and page the URL asks for. Every URL is recorded.
local function transport(feed, latest)
  local asked = {}
  local get = function(url)
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
  return get, asked
end

-- ---- W3: a STABLE node asks Latest once and stops ------------------------------------------------
local feed = {}
for i = 0, 24 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
local get, asked = transport(feed, json.encode(build("v0.1.2", false)))
local found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2", "a stable node reads the release marked Latest (" .. tostring(found and found.tag) .. ")")
ok(#asked == 1, "and pays exactly one request for it (" .. tostring(#asked) .. ")")
print("stable-latest: requests = " .. tostring(#asked) .. ", tag = " .. tostring(found and found.tag))

-- ---- W3: a PRE-RELEASE node must not stop at Latest (Latest is never a pre-release) -----------------
local prefeed = { build("v0.1.3-rc.1", true), node_build(0), build("v0.1.2", false) }
get, asked = transport(prefeed, json.encode(build("v0.1.2", false)))
found = release.fetch({ get = get, installed = "v0.1.1-rc.4", prerelease = true })
ok(found ~= nil and found.tag == "v0.1.3-rc.1",
  "a newer pre-release beside an older Latest is taken (got " .. tostring(found and found.tag) .. ")")
ok(#asked == 2, "after reading Latest and the first page - and no more (" .. tostring(#asked) .. ")")
print("prerelease-beside-latest: requests = " .. tostring(#asked) .. ", tag = " .. tostring(found and found.tag))

-- ---- W3: Latest in hand, and NOTHING newer on the page - it must not be discarded ----------------------
-- 120 builds and no version at all beyond Latest: the pre-release channel reads one page and answers with
-- what it already had. Before this fix it read five pages and returned nil, discarding v0.1.2.
local noisy = {}
for i = 0, 119 do noisy[#noisy + 1] = node_build(i) end
get, asked = transport(noisy, json.encode(build("v0.1.2", false)))
found = release.fetch({ get = get, installed = "v0.1.1-rc.4", prerelease = true })
ok(found ~= nil and found.tag == "v0.1.2",
  "a pre-release node whose page holds no version answers with Latest (got " .. tostring(found and found.tag) .. ")")
ok(#asked == 2, "in exactly two requests: Latest and one page (" .. tostring(#asked) .. ")")
print("prerelease-latest-no-newer: requests = " .. tostring(#asked) .. ", tag = " .. tostring(found and found.tag) .. ", entries read = 120")


-- ---- the measured window shapes, with the Latest that today's repo really has: a node BUILD ----------
feed = {}
for i = 0, 24 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed, json.encode(node_build(999)))
found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2", "25 builds newer, Latest is a build: the version is found (" .. tostring(found and found.tag) .. ")")
ok(#asked == 2, "after Latest and one 100-entry page (" .. tostring(#asked) .. " URL(s))")
ok(asked[2]:match("per_page=100") ~= nil, "and the widened page asks for 100 entries")
print("25-builds-newer: entries read = 26, requests = " .. tostring(#asked) .. ", per_page = 100")
feed = {}
for i = 0, 69 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed, json.encode(node_build(999)))
found = release.fetch({ get = get, installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2", "70 builds newer: the version is found (" .. tostring(found and found.tag) .. ")")
print("70-builds-newer: entries read = 71, requests = " .. tostring(#asked))

-- a node build offered as Latest is never taken for a version, and never returned at all
local only_build = function(url)
  if url:match("/releases/latest$") then return json.encode(node_build(999)) end
  return nil, "feed_status_404"
end
ok(release.fetch({ get = only_build, installed = "v0.1.1" }) == nil, "a build offered as Latest is never returned as a version")

-- ---- the bound is real: a version on page 3, and the count when there is none ----------------------
feed = {}
for i = 0, 249 do feed[#feed + 1] = node_build(i) end
feed[#feed + 1] = build("v0.1.2", false)
get, asked = transport(feed, json.encode(node_build(999)))
found = release.fetch({ get = get, installed = "v0.1.1" })
local list_pages = 0
for _, url in ipairs(asked) do if url:match("/releases%?") then list_pages = list_pages + 1 end end
ok(found ~= nil and found.tag == "v0.1.2", "251 entries in: the version on page 3 is found")
ok(list_pages == 3, "after exactly three list requests (" .. tostring(list_pages) .. ")")
print("page-3-version: entries read = 251, list requests = " .. tostring(list_pages))
feed = {}
for i = 0, 599 do feed[#feed + 1] = node_build(i) end
get, asked = transport(feed, nil)
local missing, reason = release.fetch({ get = get, installed = "v0.1.1" })
ok(missing == nil and reason == "no_version_in_500_entries",
  "600 builds and no version: the code names the 500 entries read (got " .. tostring(reason) .. ")")
local verdict = release.verdict("v0.1.1", nil, reason)
ok(verdict.state == "unknown", "and the state is unknown, not current")
ok(verdict.message == "could not find a version in the newest 500 releases",
  "the sentence says could not find a version in the newest 500 releases (got " .. tostring(verdict.message) .. ")")
print("no-version: entries read = 500, message = " .. tostring(verdict.message))

-- an explicit feed (a mirror) is one request, exactly as named, with no paging behind it
get, asked = transport({ build("v0.1.2", false) })
found = release.fetch({ get = get, url = "https://mirror.example/releases.json", installed = "v0.1.1" })
ok(found ~= nil and found.tag == "v0.1.2" and #asked == 1 and asked[1] == "https://mirror.example/releases.json",
  "an explicit feed is one request to that URL (" .. tostring(#asked) .. ")")

-- ---- W2: the banner keeps today's first request and widens only when it holds no build ---------------
local function banner_ask(feed_list, latest_json)
  local asked = {}
  local request = function(url)
    asked[#asked + 1] = url
    if url:match("/releases/latest$") then
      if latest_json == nil then return nil, "feed_status_404" end
      return latest_json
    end
    local per_page = tonumber(url:match("per_page=(%d+)")) or 30
    local page = tonumber(url:match("[?&]page=(%d+)")) or 1
    local slice = {}
    for i = (page - 1) * per_page + 1, math.min(#feed_list, page * per_page) do slice[#slice + 1] = feed_list[i] end
    return json.encode(slice)
  end
  return request, asked
end
-- the normal case: builds are the newest entries, so ONE small request answers
local builds = {}
for i = 0, 24 do builds[#builds + 1] = node_build(i) end
local request, basked = banner_ask(builds, nil)
local list = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list ~= nil and #list == 20, "the banner reads its first page of 20 (" .. tostring(list and #list) .. ")")
ok(#basked == 1, "and asks exactly once in the normal case (" .. tostring(#basked) .. ")")
ok(basked[1]:match("per_page=20") ~= nil and basked[1]:match("/releases/latest") == nil,
  "at per_page=20 and never at /releases/latest")
print("banner-normal: entries read = 20, requests = " .. tostring(#basked) .. ", per_page = 20, latest = 0")
-- no build in the first page (all version tags): widen to 100-entry pages and find the build
local versions = {}
for i = 0, 24 do versions[#versions + 1] = build("v0.0." .. i, true) end
versions[#versions + 1] = node_build(7)
request, basked = banner_ask(versions, nil)
list = banner.fetch({ request = request }, "Magaav/wasm-agent")
local widened = 0
for _, url in ipairs(basked) do if url:match("per_page=100") then widened = widened + 1 end end
ok(list ~= nil and list[#list].tag == "node-" .. string.format("%012x", 0x200007),
  "a first page with no build widens to the 100-entry pages and finds it")
ok(widened == 1, "after exactly one widened page (" .. tostring(widened) .. "); requests = " .. tostring(#basked))
print("banner-widen: entries read = 25 version tags + 1 build, requests = " .. tostring(#basked) .. ", widened pages = " .. tostring(widened))
-- seventy version tags then a build: two widened pages at 100/page is still one
local many = {}
for i = 0, 69 do many[#many + 1] = build("v0.0." .. i, true) end
many[#many + 1] = node_build(7)
request, basked = banner_ask(many, nil)
list = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list ~= nil, "70 version tags then a build: the banner finds it (requests = " .. tostring(#basked) .. ")")
print("banner-70-non-built: requests = " .. tostring(#basked))
-- nothing anywhere: the code names the count
request, basked = banner_ask({}, nil)
list, reason = banner.fetch({ request = request }, "Magaav/wasm-agent")
ok(list == nil and reason == "no_build_in_0_entries", "an empty feed names the count it read (got " .. tostring(reason) .. ")")
print("banner-none: reason = " .. tostring(reason))

if failed > 0 then print("version window FAILED (" .. checks .. " checks, " .. failed .. " failed)") return 1 end
print("version window ok (" .. checks .. " checks)")
return 0
