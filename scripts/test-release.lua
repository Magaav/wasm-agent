-- `lua/core/release.lua`: version precedence, the published body, the verdict, and the cache.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-release.lua wa --db <scratch>
--
-- No network: every case is a fixture file, a table, or the pure comparison. What this pins is the
-- part that would otherwise be an opinion - that a prerelease sorts below its release, that an
-- install with no recorded tag answers `unknown` rather than "up to date", and that an unreachable
-- feed never becomes `current`.
local release = dofile("lua/core/release.lua")
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

-- ---- version precedence -----------------------------------------------------

ok(release.parse_version("v0.2.0") ~= nil, "v0.2.0 parses")
ok(release.parse_version("0.1.0-alpha.12") ~= nil, "a prerelease parses")
ok(release.parse_version("1.0.0-rc.1+build.7") ~= nil, "build metadata is accepted and ignored")
ok(release.parse_version("nightly") == nil, "a non-version is nil")
ok(release.parse_version("1.2") == nil, "a two-part version is nil, not a guess")

eq(release.compare("0.1.0", "0.2.0"), -1, "older core sorts first")
eq(release.compare("0.2.0", "0.2.0"), 0, "equal versions compare equal")
eq(release.compare("v0.2.0", "0.2.0"), 0, "the tag prefix does not change the answer")
eq(release.compare("0.1.0-alpha.12", "0.1.0"), -1, "a prerelease sorts below its release")
eq(release.compare("0.1.0-alpha.2", "0.1.0-alpha.10"), -1, "prerelease numbers compare numerically")
eq(release.compare("0.1.0-alpha", "0.1.0-alpha.1"), -1, "a shorter prerelease sorts first")
eq(release.compare("1.0.0-rc.1", "1.0.0-beta.2"), 1, "prerelease identifiers compare as text")
eq(release.compare("1.0.0+a", "1.0.0+b"), 0, "build metadata is not precedence")
eq(release.compare("garbage", "1.0.0"), nil, "an uncomparable pair is nil, not zero")

eq(release.newer("0.2.0", "0.1.0"), true, "0.2.0 is newer than 0.1.0")
eq(release.newer("0.1.0", "0.2.0"), false, "0.1.0 is not newer than 0.2.0")
eq(release.newer("nope", "0.2.0"), nil, "an unparseable candidate is not newer")

-- ---- the published body -----------------------------------------------------

local BODY = [[{
  "tag_name": "v0.2.0",
  "name": "wasm-agent 0.2.0",
  "html_url": "https://github.com/Magaav/wasm-agent/releases/tag/v0.2.0",
  "published_at": "2026-10-26T18:00:00Z",
  "prerelease": false,
  "body": "First major release.\n\n- a node can see it is behind."
}]]

local parsed, parse_error = release.parse_release(BODY)
ok(parsed ~= nil, "a release body parses")
eq(parsed and parsed.version, "0.2.0", "the version comes from the tag, without the v")
eq(parsed and parsed.tag, "v0.2.0", "the tag is kept as published")
eq(parsed and parsed.url, "https://github.com/Magaav/wasm-agent/releases/tag/v0.2.0", "the release url is kept")
eq(parsed and parsed.published_at, "2026-10-26T18:00:00Z", "the publish time is kept")
ok(parsed and parsed.notes:find("behind", 1, true) ~= nil, "the notes are kept for the banner")
eq((release.parse_release("{}")), nil, "a body with no tag is refused")
eq((release.parse_release('{"tag_name": "nightly"}')), nil, "a tag that is not a version is refused")
eq((release.parse_release("not json")), nil, "a body that is not json is refused")
eq(parse_error, nil, "a parse that succeeded reports no error")

local long = release.parse_release('{"tag_name":"v1.0.0","body":"' .. string.rep("word ", 200) .. '"}')
ok(long ~= nil and #long.notes <= 404, "long notes are bounded")

-- ---- the verdict ------------------------------------------------------------

local behind = release.verdict("0.1.0", parsed)
eq(behind.state, "behind", "an older install is behind")
eq(behind.latest, "0.2.0", "the verdict names the latest release")
ok(behind.message:find("v0.1.0", 1, true) ~= nil, "the verdict names the installed version")
eq(release.verdict("0.2.0", parsed).state, "current", "an equal install is current")
eq(release.verdict("0.3.0", parsed).state, "current", "a newer install is not called behind")
eq(release.verdict(nil, parsed).state, "unknown", "an install with no recorded tag is unknown")
eq(release.verdict(nil, parsed).reason, "no_recorded_release", "and says why")
eq(release.verdict("0.1.0", nil, "feed_status_404").state, "unknown", "an unreachable feed is unknown, never current")
eq(release.verdict("garbage", parsed).state, "unknown", "an uncomparable install is unknown")
ok(release.verdict(nil, nil, "checks_disabled").message:find("checks_disabled", 1, true) ~= nil,
   "the unknown message carries the reason")

-- ---- the installed side -----------------------------------------------------

eq(release.installed({ release = "v0.2.0" }), "0.2.0", "the install record's release is the version")
eq(release.installed({ version = "0.2.0" }), "0.2.0", "a version key is accepted too")
eq(release.installed({ commit = "7568f452" }), nil, "a commit is not a version")
eq(release.installed({ release = "garbage" }), nil, "a bad record value is nil, not a version")
eq(release.installed(nil), nil, "no record is nil")

-- ---- the cache --------------------------------------------------------------

local home = host.getenv("WASM_AGENT_HOME") or "."
local fixture = home .. "/release-fixture.json"
local cache = home .. "/release-cache.json"
pcall(host.write_file, fixture, BODY)
pcall(host.remove_file, cache)

local first = release.check({ installed = "0.1.0", fixture = fixture, cache_path = cache, now = 1000 })
eq(first.state, "behind", "the check answers from the fixture")
eq(first.cached, false, "the first check is not a cache hit")
-- Read through the host, never `io.open`: a handle left open on Windows blocks the next atomic
-- replacement (os error 5), and the test would be the thing that broke the behaviour it checks.
ok(host.read_file(cache) ~= nil, "the check writes its cache")

local second = release.check({ installed = "0.1.0", fixture = fixture, cache_path = cache, now = 1000 + 60 * 1000 })
eq(second.cached, true, "a check inside the window is a cache hit")
eq(second.state, "behind", "and answers the same")

local stale = release.check({ installed = "0.1.0", fixture = fixture, cache_path = cache, now = 1000 + release.CACHE_MS + 1 })
eq(stale.cached, false, "a check past the window asks again")

-- A corrupt cache must not become a version nobody published.
pcall(host.write_file, cache, json.encode({ at = 5000, release = { version = "garbage" } }))
local corrupt = release.check({ installed = "0.1.0", fixture = fixture, cache_path = cache, now = 6000 })
eq(corrupt.state, "behind", "a corrupt cache falls back to the feed")
ok(corrupt.latest == "0.2.0", "and reports the published version")

local offline = release.check({ installed = "0.1.0", offline = 1, cache_path = home .. "/no-such-cache.json", now = 9000 })
eq(offline.state, "unknown", "offline is unknown")
eq(offline.reason, "checks_disabled", "and says the check was disabled")

local missing = release.check({ installed = "0.1.0", fixture = home .. "/absent.json", cache_path = home .. "/absent-cache.json", now = 9100 })
eq(missing.state, "unknown", "a missing fixture is unknown")
eq(missing.reason, "feed_unreachable", "and says the feed was unreachable")

if failed > 0 then print("release: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("release ok (" .. checks .. " checks)")
