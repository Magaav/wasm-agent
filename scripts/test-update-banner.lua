-- `lua/core/update_banner.lua`: the compare logic, the release feed, the cache TTL and the bus fact.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-update-banner.lua wa --db <scratch>/t.db
--
-- No network: every case is a fixture file, an injected fetch, or a pure function. What this pins is
-- the part that would otherwise be an opinion - that "behind" is proven (the installed release is in
-- the published window, local ancestry says so, or a prebuilt install is older than the window), that
-- a tree the feed does not mention stays `unknown` instead of being called behind, that the banner
-- line is the one the window and the CLI print, that fifteen minutes is one request per process set
-- even across a failed request, and that the cache never stores a verdict (so the banner disappears
-- the moment the node runs the release).
local banner = dofile("lua/core/update_banner.lua")
local updater = dofile("lua/core/update.lua")
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

-- ---- identities -------------------------------------------------------------

eq(banner.parse_release_tag("node-abc123456789"), "abc123456789", "a node-<sha12> tag names a commit")
eq(banner.parse_release_tag("node-ABC123456789"), "abc123456789", "the tag's hex is normalised to lower case")
eq(banner.parse_release_tag("v0.2.0"), nil, "a version tag is not this node's binary release")
eq(banner.parse_release_tag("wa-android-a7bbcda92b76"), nil, "an Android bundle is not a desktop node release")
eq(banner.parse_release_tag("node-abc123"), nil, "a short tag is refused, not padded")
eq(banner.parse_release_tag("node-abc1234567890"), nil, "a long tag is refused")
eq(banner.parse_release_tag(nil), nil, "no tag is nil")

eq((banner.parse_commit("abc1234") or {}).short, "abc1234", "the build record's 7-hex id parses")
eq((banner.parse_commit("abcdef1234567890abcdef1234567890abcdef12") or {}).short, "abcdef123456",
   "the prebuilt record's 40-hex id names its 12-hex release")
eq(banner.parse_commit("unknown"), nil, "an unrecorded commit is not a commit")
eq(banner.parse_commit("abc12"), nil, "fewer than seven hex is no evidence")
eq(banner.parse_commit("abc123g"), nil, "a non-hex character is not a commit")

ok(banner.same_commit("aaaaaaa", "aaaaaaabbbbb"), "a 7-hex id matches the 12-hex release it prefixes")
ok(banner.same_commit("aaaaaaabbbbb", "aaaaaaa"), "the comparison is symmetric")
ok(not banner.same_commit("aaaaaaa", "bbbbbbbbbbbb"), "different commits do not match")
ok(not banner.same_commit("aaa", "aaabbbbbbbbb"), "a three-character prefix is no match")
ok(not banner.same_commit("", "aaaaaaaaaaaa"), "an empty id matches nothing")

local build = banner.identity({ commit = "aaaaaaa", source_provenance = "clean-built-by-deploy" })
eq(build and build.sha12, "aaaaaaa", "a build install's identity is its commit")
eq(build and build.prebuilt, false, "a build install is not a published binary")
local prebuilt = banner.identity({ commit = "abcdef1234567890abcdef1234567890abcdef12",
  binary_source = "prebuilt-release", binary_release = "node-abcdef123456" })
eq(prebuilt and prebuilt.sha12, "abcdef123456", "a prebuilt install's identity is its release name")
eq(prebuilt and prebuilt.prebuilt, true, "a prebuilt install is a published binary")
eq(banner.identity({ commit = "unknown" }), nil, "a record that names no commit has no identity")
eq(banner.identity(nil), nil, "no record means no identity")

-- The reader must agree with the deploy's own reader (`update.lua` keeps `installed.txt` single).
local scratch = host.getenv("WASM_AGENT_HOME") or (dofile("lua/core/platform.lua").cwd() .. "/.git/wa-update-banner-test")
local scratch_sh = scratch:gsub("\\", "/")
pcall(host.exec, "rm -rf '" .. scratch_sh .. "' && mkdir -p '" .. scratch_sh .. "/install' '" .. scratch_sh .. "/cache'", "")
local install = scratch .. "/install"
local RECORD = "commit=aaaaaaa\nbranch=main\ndirty=0\nsource_provenance=clean-built-by-deploy\nvia=deploy.sh\n"
host.write_file(install .. "/installed.txt", RECORD)
ok(host.read_file(install .. "/installed.txt") ~= nil, "the install record fixture is written")
local theirs = updater.installed_record(install)
eq(theirs.commit, "aaaaaaa", "update.lua reads the fixture record")
eq(banner.identity(theirs).sha12, banner.identity(updater.installed_record(install)).sha12,
   "this module and update.lua agree about what is installed")

-- ---- the published side -----------------------------------------------------

local FEED_BODY = '[' ..
  '{"tag_name":"node-cccccccccccc","name":"node-cccccccccccc","html_url":"https://example.invalid/c",' ..
  '"published_at":"2026-11-06T10:00:00Z","draft":false,"prerelease":true,"body":"SECRET notes text"},' ..
  '{"tag_name":"v0.2.0","name":"wasm-agent 0.2.0","html_url":"https://example.invalid/v020"},' ..
  '{"tag_name":"wa-android-a7bbcda92b76","name":"android","html_url":"https://example.invalid/a"},' ..
  '{"tag_name":"node-aaaaaaabbbbb","name":"node-aaaaaaabbbbb","html_url":"https://example.invalid/ab"},' ..
  '{"tag_name":"node-dddddddddddd","name":"draft","draft":true},' ..
  '{"tag_name":"nightly","name":"nightly"}' ..
  ']'

local feed, feed_error = banner.parse_feed(FEED_BODY)
ok(feed ~= nil, "the release list parses")
eq(feed_error, nil, "a parse that succeeded reports no error")
eq(feed and #feed, 2, "only the two node-<sha12> releases are this node's: versions, Android and drafts are skipped")
eq(feed and feed[1].sha12, "cccccccccccc", "the newest published release is first, as GitHub returns it")
eq(feed and feed[2].sha12, "aaaaaaabbbbb", "the older release keeps its place")
eq(feed and feed[1].prerelease, nil, "the feed's own notes are not carried into the fact")
ok(not tostring(json.encode(feed)):find("SECRET", 1, true), "release note text is never stored")
eq((select(2, banner.parse_feed("not json"))), "feed_invalid", "a body that is not JSON is named")
eq((select(2, banner.parse_feed("[]"))), "no_node_release", "a feed with no node release says so")
eq((banner.parse_feed('{"tag_name":"node-cccccccccccc"}') or {})[1].sha12, "cccccccccccc",
   "a single release object is accepted for a fixture")

eq(banner.parse_remote("git@github.com:Magaav/wasm-agent.git"), "Magaav/wasm-agent", "an ssh remote names the repo")
eq(banner.parse_remote("https://github.com/Magaav/wasm-agent"), "Magaav/wasm-agent", "an https remote names the repo")
eq(banner.parse_remote("https://github.com/Magaav/wasm-agent.git"), "Magaav/wasm-agent", "a .git suffix is stripped")
eq(banner.parse_remote("/local/mirror/wasm-agent"), nil, "a local mirror names no GitHub repo")
eq(banner.parse_remote(""), nil, "an empty remote names nothing")

-- ---- the comparison ---------------------------------------------------------

local LATEST = { tag = "node-cccccccccccc", sha12 = "cccccccccccc", url = "https://example.invalid/c" }
local OLDER = { tag = "node-aaaaaaabbbbb", sha12 = "aaaaaaabbbbb" }

local function compare(installed, list, order, prebuilt)
  return banner.compare(installed, list, { order = order, prebuilt = prebuilt })
end
eq((compare(banner.identity({ commit = "cccccccccccc" }), { LATEST, OLDER })), "equal",
   "an install at the newest release is current")
eq((compare(build, { LATEST })), "unknown", "a tree commit the feed does not mention is not called behind")
eq((compare(build, { LATEST }, function() return "older" end)), "older", "local ancestry can prove it is behind")
eq((compare(build, { LATEST }, function() return "newer" end)), "newer", "local ancestry can prove it is ahead")
eq((compare(build, { LATEST, OLDER })), "older", "a later entry in the published window is an older release")
eq((compare(prebuilt, { LATEST, OLDER }, nil, true)), "older",
   "a prebuilt install whose release fell out of the window is behind every release in it")
eq((compare(build, { LATEST }, function() return nil end)), "unknown", "an unanswerable ancestry stays unknown")
eq((compare(nil, { LATEST })), "unknown", "no identity is unknown")
eq((select(2, compare(nil, { LATEST }))), "unknown_installed_commit", "and says which fact is missing")
eq((select(2, compare(build, {}))), "feed_unavailable", "no feed is unknown, never current")

-- ---- the line ---------------------------------------------------------------

local behind = banner.verdict(build, { LATEST, OLDER }, "older", "installed_release_in_window", { repo = "o/r" })
eq(behind.state, "behind", "older is behind")
eq(behind.line, "Update available (cccccccccccc): run wa update or /update",
   "the line is the one the CLI footer and the window print")
eq(banner.verdict(build, { LATEST }, "equal", "same_commit", {}).line, nil, "current prints no line")
eq(banner.verdict(build, { LATEST }, "newer", "local_ancestry", {}).line, nil, "ahead prints no line")
eq(banner.verdict(build, nil, "unknown", "feed_unavailable", {}).line, nil, "unknown prints no line")

-- ---- the surfaces that show it -----------------------------------------------
-- The module is only half the feature: the CLI footer, the session-start line and the window route
-- are read out of their own files, so a revert of one of them fails here instead of silently leaving a
-- cache nothing reads.
local cli = host.read_file("lua/core/cli_view.lua") or ""
local chat = host.read_file("lua/core/chat.lua") or ""
local server = host.read_file("lua/core/server.lua") or ""
ok(cli:find("update_note", 1, true) ~= nil, "the CLI view keeps an update note for its footer")
ok(cli:find("if self.update_note and self.update_note ~= \"\" then", 1, true) ~= nil,
   "the footer draws the note")
ok(chat:find("banner.check({ refresh = true })", 1, true) ~= nil, "the chat asks at session start")
ok(chat:find("view.update_note = seen.line", 1, true) ~= nil, "and puts the line in the footer")
ok(chat:find("print(redact.text(seen.line))", 1, true) ~= nil, "and prints it once, outside the transcript")
ok(server:find("update_banner.status", 1, true) ~= nil, "the /update check route answers with the banner")
ok(server:find("pcall(update_banner.tick)", 1, true) ~= nil, "the served node refreshes it on the housekeeping tick")
ok(server:find('host.getenv("WA_SCRIPT") == nil', 1, true) ~= nil,
   "and a WA_SCRIPT test run never touches the real node's state")

-- ---- the whole check, against fixtures --------------------------------------

local cache = scratch .. "/cache/update-check.json"
local fixture = scratch .. "/feed.json"
host.write_file(fixture, FEED_BODY)
host.write_file(install .. "/installed.txt", RECORD)

local calls = 0
local function fetch_counts(options)
  calls = calls + 1
  return FEED_BODY
end
local function base(extra)
  local o = { install = install, tree = "", record = nil, cache_path = cache,
    repo = "Magaav/wasm-agent", fetch = fetch_counts, order = function() return nil end }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local first = banner.check(base({ now = 1000 }))
eq(first.state, "behind", "the check answers behind from the fixture")
eq(first.line, "Update available (cccccccccccc): run wa update or /update", "with the banner line")
eq(calls, 1, "the first check makes exactly one request")
eq(first.cached, false, "the first check is not a cache hit")
eq(first.attempted, true, "and it did ask")
local cached_text = host.read_file(cache) or ""
ok(cached_text ~= "", "the check writes its cache under <state>/update-check.json")
local cached_fact = json.decode(cached_text)
eq(cached_fact.latest.tag, "node-cccccccccccc", "the cache holds the feed's newest release")
eq(cached_fact.order[1], "cccccccccccc", "and the published window, newest first")
eq(cached_fact.state, nil, "the cache holds no verdict: the installed side is read every time")
ok(not cached_text:find("SECRET", 1, true), "no release note text reaches the cache")

local within = banner.check(base({ now = 1000 + 60 * 1000 }))
eq(within.state, "behind", "a check inside the window answers the same")
eq(within.cached, true, "a check inside the window is a cache hit")
eq(calls, 1, "and costs no second request")

local edge = banner.check(base({ now = 1000 + banner.CACHE_MS - 1 }))
eq(edge.cached, true, "one millisecond before the window is still a hit")
eq(calls, 1, "still one request")

local past = banner.check(base({ now = 1000 + banner.CACHE_MS }))
eq(past.cached, false, "the window expires exactly at CACHE_MS")
eq(calls, 2, "and the next check is the second request")

-- The indicator clears because installed == latest, read fresh from the record and the cache.
host.write_file(install .. "/installed.txt", "commit=cccccccccccc\nbinary_source=prebuilt-release\nbinary_release=node-cccccccccccc\n")
banner.reset()
eq(banner.status(base({ now = 1000 + banner.CACHE_MS + 1000 })).state, "current",
   "after the swap the same cache answers current, with no request")
eq(calls, 2, "and no request was made to notice it")
local after_swap = banner.status(base({ now = 1000 + banner.CACHE_MS + 1000 }))
eq(after_swap.line, nil, "the banner is gone once the node runs that version")
-- And the reverse: a rebuilt record makes the same cache say behind again, still without a request.
host.write_file(install .. "/installed.txt", RECORD)
eq(banner.status(base({ now = 1000 + banner.CACHE_MS + 2000 })).state, "behind",
   "a stale record against the same cache is behind again")

-- A tree the feed does not mention, and local ancestry says it is ahead.
banner.reset()
host.write_file(install .. "/installed.txt", "commit=ddddddd\nsource_provenance=clean-built-by-deploy\n")
local ahead = banner.check(base({ now = 1000 + banner.CACHE_MS + 3000, order = function() return "newer" end }))
eq(ahead.state, "ahead", "a tree ahead of the newest release is ahead")
eq(ahead.line, nil, "and is not told to update")
host.write_file(install .. "/installed.txt", "commit=unknown\n")
eq(banner.status(base({ now = 1000 + banner.CACHE_MS + 4000 })).state, "unknown",
   "an install that names no commit is unknown, not behind")
host.write_file(install .. "/installed.txt", RECORD)

-- ---- offline, a broken feed, and the claim ----------------------------------

banner.reset()
local offline_calls = 0
local offline = banner.check({ install = install, tree = "", cache_path = scratch .. "/none.json",
  repo = "o/r", offline = "1", now = 2000,
  fetch = function() offline_calls = offline_calls + 1; return FEED_BODY end })
eq(offline.state, "unknown", "offline with no cache is unknown")
eq(offline.reason, "feed_unavailable", "and the reason is the feed it does not have")
eq(offline_calls, 0, "offline makes no request")
eq(offline.line, nil, "offline prints no line")

-- A known update survives going offline: the cached feed still answers, with no request.
banner.reset()
local offline_cached = banner.check({ install = install, tree = "", cache_path = cache, repo = "Magaav/wasm-agent",
  offline = "1", now = 1000 + banner.CACHE_MS + 5000,
  fetch = function() offline_calls = offline_calls + 1; return FEED_BODY end })
eq(offline_cached.state, "behind", "a cached release still shows while offline")
eq(offline_calls, 0, "and offline still makes no request")

-- A failing feed claims the window before it tries: one request per fifteen minutes, not one per tick.
local broken_cache = scratch .. "/cache/broken.json"
local broken_calls = 0
local function broken() broken_calls = broken_calls + 1; return nil, "feed_status_500" end
banner.reset()
local broken_first = banner.check({ install = install, tree = "", cache_path = broken_cache, repo = "o/r",
  now = 3000, fetch = broken })
eq(broken_first.state, "unknown", "a failed feed is unknown")
eq(broken_first.error, "feed_status_500", "and names the failure")
eq(broken_calls, 1, "the failed attempt is one request")
local broken_again = banner.check({ install = install, tree = "", cache_path = broken_cache, repo = "o/r",
  now = 3000 + 60 * 1000, fetch = broken })
eq(broken_again.state, "unknown", "a second check inside the window is still unknown")
eq(broken_calls, 1, "and costs no second request, because the window was claimed first")
eq(tonumber((json.decode(host.read_file(broken_cache) or "{}") or {}).checked_at), 3000,
   "the claim is on disk before the request")

-- ---- the bus ----------------------------------------------------------------

local published, topic, payload_text
local bus_opts = base({ now = 1000 + 2 * banner.CACHE_MS,
  publish = function(t, text) published = (published or 0) + 1; topic = t; payload_text = text; return true end })
banner.reset()
local bus_verdict = banner.check(bus_opts)
eq(published, 1, "one refresh publishes one fact")
eq(topic, "kernel.update.available", "on the topic the job names")
local payload = json.decode(payload_text or "{}")
eq(payload.state, bus_verdict.state, "the fact carries the state")
eq(payload.latest, "cccccccccccc", "and the release's commit, not a sentence")
eq(payload.message, nil, "and never a rendered message")
eq(bus_verdict.published, true, "the verdict says the fact was published")

local absent = banner.check({ install = install, tree = "", cache_path = scratch .. "/bus-none.json",
  repo = "o/r", now = 9000, fetch = function() return FEED_BODY end })
eq(absent.bus, "bus_unavailable", "no bus reachable from Lua is named, not failed")
eq(absent.published, false, "and the check still answers")

-- ---- the served node's tick ------------------------------------------------

banner.reset()
local tick_calls = 0
local function ticked() tick_calls = tick_calls + 1; return FEED_BODY end
local tick_opts = { install = install, tree = "", cache_path = scratch .. "/tick.json", repo = "o/r",
  fetch = ticked }
banner.tick(tick_opts)
banner.tick(tick_opts)
eq(tick_calls, 1, "two ticks in a row are one request (the memo covers the housekeeping interval)")
banner.reset()
banner.tick(tick_opts)
eq(tick_calls, 1, "even after a reset the cache window holds: still one request")
banner.reset()
banner.tick({ install = install, tree = "", cache_path = scratch .. "/tick2.json", repo = "o/r",
  now = 60 * banner.CACHE_MS, fetch = ticked })
eq(tick_calls, 2, "a distinct cache path is a distinct window")

-- ---- the CLI footer really draws it ---------------------------------------
-- Not a source grep: the view is built, its screen row is set, and the text it hands the host's footer
-- is read back. The note goes first (it is the one thing on the row with an action) and the session
-- numbers survive after it; with no note the row is what it always was.
local cli_view = dofile("lua/core/cli_view.lua")
local footer_text, footer_right
local original_editor_footer = host.editor_footer
host.editor_footer = function(text, right) footer_text, footer_right = text, right return true end
local view = cli_view.new({ live = true, stdout = true, limit = 120, out = function() end })
view.screen = { top = 1, bottom = 10, status = 15, input_top = 16, input = 19, footer = 21 }
view.editor, view.editor_ready, view.model = true, true, "test-model"
view.last_summary = "3 runs"
view.update_note = "Update available (cccccccccccc): run wa update or /update"
view:footer_draw()
ok(footer_text ~= nil and footer_text:find("Update available (cccccccccccc)", 1, true) ~= nil,
   "the footer row carries the update note")
ok(footer_text ~= nil and footer_text:find("3 runs", 1, true) ~= nil,
   "and keeps the session numbers after it")
ok(footer_right == "test-model", "the right side of the footer is still the model")
view.update_note = nil
view:footer_draw()
eq(footer_text, "3 runs", "without a note the footer is the numbers alone")
view.last_summary = nil
view:footer_draw()
ok(footer_text ~= nil and footer_text:find("/ for commands", 1, true) ~= nil,
   "with nothing to say it is the hint row it always was")
if original_editor_footer == nil then host.editor_footer = nil else host.editor_footer = original_editor_footer end

-- A cache written for a different repository is not a fact about this node.
local other_repo_cache = scratch .. "/cache/other-repo.json"
host.write_file(other_repo_cache, json.encode({ schema = 1, checked_at = 7000, repo = "other/repo",
  latest = { tag = "node-eeeeeeeeeeee", sha12 = "eeeeeeeeeeee" }, order = { "eeeeeeeeeeee" } }))
banner.reset()
local repo_calls = 0
local repo_check = banner.check({ install = install, tree = "", cache_path = other_repo_cache, repo = "Magaav/wasm-agent",
  now = 7100, fetch = function() repo_calls = repo_calls + 1; return FEED_BODY end })
eq(repo_calls, 1, "a cache for another repository is not reused")
eq(repo_check.latest and repo_check.latest.sha12, "cccccccccccc", "the answer is this repository's release")

-- ---- the default locations --------------------------------------------------

if host.getenv("WA_UPDATE_CHECK_CACHE") == nil or host.getenv("WA_UPDATE_CHECK_CACHE") == "" then
  eq(banner.cache_path("/scratch/state"), "/scratch/state/update-check.json",
     "the cache lives under <state>/update-check.json")
  ok(banner.state_dir():find("%.wasm%-agent$") ~= nil or banner.state_dir():find("wasm%-agent$") ~= nil,
     "the state directory is the node's own config directory")
end
if host.getenv("WA_NODE_RELEASE_REPO") == nil or host.getenv("WA_NODE_RELEASE_REPO") == "" then
  eq(banner.repo(""), "Magaav/wasm-agent", "with no tree and no override the canonical repo is the feed")
end
eq(banner.feed_url("o/r"), "https://api.github.com/repos/o/r/releases?per_page=5",
   "the public API with the job's page size")
eq(banner.per_page(), 5, "the published window is five releases unless the operator widens it")
eq(banner.TOPIC, "kernel.update.available", "the topic constant")
eq(banner.CACHE_MS, 15 * 60 * 1000, "fifteen minutes")

-- The fixture file (no injected fetch) is the same path a test or an operator points the check at.
banner.reset()
local from_fixture = banner.check({ install = install, tree = "", cache_path = scratch .. "/cache/fixture.json",
  fixture = fixture, repo = "o/r", now = 500 })
eq(from_fixture.state, "behind", "the fixture file answers without a request")

if failed == 0 then
  pcall(host.exec, "rm -rf '" .. scratch_sh .. "'", "")
  print("update banner ok (" .. checks .. " checks)")
  return
end
print("update banner: " .. failed .. " failed of " .. checks .. " checks (fixtures kept in " .. scratch .. ")")
os.exit(1)
