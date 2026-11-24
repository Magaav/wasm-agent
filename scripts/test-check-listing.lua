-- `wa update --check` REFRESHES THE LIST AND NAMES THE RELEASE THE INSTALLER WOULD TAKE (Fable, 24/11).
--
-- WHAT WAS MEASURED, run for real on this node:
--   release list: 5 entries, read 2026-11-21 01:42Z, newest node-e4e40405d89b
--   this node (fe108a8c): no published binary for fe108a8c on x86_64-unknown-linux-gnu
-- The list was three days old when a person asked, and the second line is true by NAME and false in
-- effect: `scripts/deploy.sh` then looks for a release built from the same compiled inputs
-- (`wa_node_release_digest_search`) and downloads node-9a0c589adfa0 for this very commit.
--
-- So the answer now (1) refreshes the list first, bounded, and says `read just now` - or names the
-- failure with the old list's own date - and (2) runs that same lookup and names the release it finds,
-- with the installer's own fallback sentence when the lookup cannot run.
--
-- This row drives `lua/core/update_banner.lua` through the SAME two functions `wa update --check` calls
-- (`M.refresh` then `M.listing`), with the seams those functions offer: a fixture feed instead of a
-- request, and a `covering` answer instead of a digest walk. The real walk is the installer's own code
-- (`scripts/test-deploy-node-binaries.sh` exercises it); what is proved here is the wiring, the dates and
-- the words.
--
--   WA_SCRIPT=scripts/test-check-listing.lua wa --db /tmp/wa-check-listing.db
-- Prints `check listing ok`.
local json = dofile("lua/vendor/json.lua")

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-check-listing")
if why_home then print("REFUSED test-check-listing: " .. why_home); os.exit(2) end

local banner = dofile("lua/core/update_banner.lua")
local home = host.paths().home
local work = home .. "/check-listing"
if type(host.mkdir) == "function" then pcall(host.mkdir, work) end
local function write(path, text) host.write_file(path, text) end
local function read(path) local ok, text = pcall(host.read_file, path); return ok and text or nil end

local checks, failed = 0, 0
local function ok(name) checks = checks + 1; print("  ok   " .. name) end
local function bad(name, detail)
  checks = checks + 1; failed = failed + 1
  print("  FAIL " .. name .. (detail and (" (" .. tostring(detail) .. ")") or ""))
end

local TARGET = "ccccccccdddd0000000000000000000000000000"
local INSTALLED = "eeeeeeeeffff0000000000000000000000000000"
local COVER = "node-9a0c589adfa0"
local function entry(tag, assets)
  return { tag_name = tag, name = tag, html_url = "https://example.invalid/" .. tag,
    published_at = "2026-11-24T10:00:00Z",
    assets = (function() local list = {} for name in pairs(assets or {}) do list[#list + 1] = { name = name } end return list end)() }
end
local function feed_file(name, entries)
  local path = work .. "/" .. name
  write(path, json.encode(entries))
  return path
end
local triple = banner.target({}) or "x86_64-unknown-linux-gnu"
local WITH_ASSETS = { ["node-111111112222.manifest"] = true,
  ["wa-" .. triple .. "-111111112222"] = true, ["wa-sentinel-" .. triple .. "-111111112222"] = true }
local FEED = feed_file("feed.json", { entry("node-111111112222", WITH_ASSETS) })

-- ---- 1. a refresh that works: the list is read NOW, and the answer says so ---------------------------------
local cache = work .. "/update-check.json"
write(cache, json.encode({ schema = banner.SCHEMA, checked_at = 1795225343870, last_ok_at = 1795225343870,
  repo = "fixture/fixture", transport = "fixture",
  window = { { tag = "node-111111112222", sha12 = "111111112222", assets = WITH_ASSETS } } }))
local refreshed = banner.refresh({ fixture = FEED, cache_path = cache, repo = "fixture/fixture",
  now = 1795600000000 })
if refreshed.ok == true then ok("refresh: a reachable list is read and cached") else bad("refresh failed", refreshed.reason) end
local listing = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED, target = TARGET,
  tree = "/nonexistent-for-this-row", read = refreshed.ok and "just now" or nil,
  refresh_failed = (not refreshed.ok) and refreshed.reason or nil,
  covering = function() return { state = "covering", tag = COVER, source_commit = "9a0c589adfa0" } end })
local first = listing.lines[1] or ""
if first:find("read just now", 1, true) then ok("the list line says 'read just now' after a refresh: " .. first)
else bad("the list line does not say 'read just now'", first) end

-- ---- 2. a refresh that fails: the OLD date is shown, the failure is named ----------------------------------
local broken = banner.refresh({ fixture = work .. "/no-such-feed.json", cache_path = cache,
  repo = "fixture/fixture", now = 1795600000000 })
if broken.ok == false and tostring(broken.reason) ~= "" then ok("refresh: a failing feed is refused by name (" .. tostring(broken.reason) .. ")")
else bad("a failing refresh was not refused by name") end
local old = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED, target = TARGET,
  tree = "/nonexistent-for-this-row",
  refresh_failed = tostring(broken.reason),
  covering = function() return { state = "none", tag = nil } end })
local second = old.lines[1] or ""
if second:find("read 2026%-") or second:find("read 2026-", 1, true) then ok("the list line keeps the OLD date when the refresh failed: " .. second)
else bad("the list line lost the old date", second) end
if second:find("the refresh just now failed", 1, true) then ok("and it names the failure")
else bad("the list line does not name the refresh failure", second) end

-- ---- 3. the lookup finds a covering release: the answer NAMES it ----------------------------------------
local named = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED, target = TARGET,
  tree = "/nonexistent-for-this-row", order = function() return "newer" end,
  covering = function() return { state = "covering", tag = COVER, source_commit = "9a0c589adfa0" } end })
local behind = ""
for _, line in ipairs(named.lines or {}) do if line:find("behind by", 1, true) then behind = line end end
local want_named = "no binary is published under " .. TARGET:sub(1, 12) .. "'s own name; the installer downloads " ..
  COVER .. ", built from the same inputs"
if behind == "behind by (" .. TARGET:sub(1, 12) .. "): " .. want_named then ok("a covering release is NAMED: " .. behind)
else bad("the covering release was not named", behind) end

-- ---- 4. the lookup cannot run: the installer's own fallback sentence, never a claim ----------------------
local fallback = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED, target = TARGET,
  tree = "/nonexistent-for-this-row", order = function() return "newer" end,
  covering = function() return { state = "unavailable", reason = "no_target" } end })
local line4 = ""
for _, line in ipairs(fallback.lines or {}) do if line:find("behind by", 1, true) then line4 = line end end
local want_fallback = "no binary is published under " .. TARGET:sub(1, 12) ..
  "'s own name; the installer also accepts one built from the same inputs and looks for it at install time"
if line4 == "behind by (" .. TARGET:sub(1, 12) .. "): " .. want_fallback then ok("a lookup that cannot run says what the installer will still do")
else bad("the fallback sentence is wrong", line4) end

-- ---- 5. a published commit still reads as published ------------------------------------------------------
local published = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED,
  target = "1111111122220000000000000000000000000000", tree = "/nonexistent-for-this-row",
  covering = function() return { state = "covering", tag = COVER } end })
local line5 = ""
for _, line in ipairs(published.lines or {}) do if line:find("behind by", 1, true) then line5 = line end end
if line5:find("published binary for 111111112222 on " .. triple, 1, true) then ok("a published commit still reads as published")
else bad("the published case changed", line5) end

-- ---- 6. a commit the list does not name: the installer's answer is ADDED, and no claim is made about the
--         commit's own name ------------------------------------------------------------------------------
local unnamed = banner.listing({ cache_path = cache, repo = "fixture/fixture", installed = INSTALLED, target = TARGET,
  tree = "/nonexistent-for-this-row",
  covering = function() return { state = "covering", tag = COVER, source_commit = "9a0c589adfa0" } end })
local line6 = ""
for _, line in ipairs(unnamed.lines or {}) do if line:find("behind by", 1, true) then line6 = line end end
if line6:find("the release list cannot say whether", 1, true) and line6:find("the installer accepts " .. COVER, 1, true) then
  ok("a commit the list does not name keeps its honest first half and ADDS the installer's release")
else bad("the unnamed-commit line is wrong", line6) end
if line6:find("no binary is published under", 1, true) then
  bad("a commit the list does not name was CLAIMED unpublished", line6)
else ok("and it does not claim the commit is unpublished") end

if failed == 0 then print("check listing ok (" .. checks .. " checks)") os.exit(0) end
print("check listing FAILED (" .. checks .. " checks, " .. failed .. " failed)")
os.exit(1)
