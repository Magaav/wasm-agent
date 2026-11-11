-- `lua/core/update_banner.lua`: the compare logic, the release feed, the cache TTL and the bus fact.
--
--   WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-update-banner.lua wa --db <scratch>/t.db
--
-- Its scratch is its own (`mktemp -d`, marked, removed only while the marker is this run's) and never a
-- path from the environment (measured 11/11: this file used WASM_AGENT_HOME, which inside `wa` is the
-- operator's home, and deleted it).
--
-- No network: every case is a fixture file, an injected fetch, or a pure function. What this pins is
-- the part that would otherwise be an opinion - that "behind" is proven on the right channel (a tree
-- against origin/main, a release against the newest entry with this machine's assets), that a newer
-- aarch64-only release is never offered to x86_64, that a tree the feed does not mention is not called
-- behind, that the banner line is the one the window and the CLI print, that fifteen minutes is one
-- request per process set even across a failed request, that the same world gives the same line across
-- repeated reads and window rollovers, and that the cache never stores a verdict (so the banner
-- disappears the moment the node runs the new commit).
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
local function shell(command)
  local ok, raw = pcall(host.exec, command, "", 30)
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil end
  return tostring(decoded.stdout or ""):gsub("%s+$", "")
end
-- Never a path from the environment: `WASM_AGENT_HOME` answers "where is the node's home", not "where
-- may a test write". This run creates its own directory and marks it, and cleanup deletes only a
-- directory that still carries the marker it wrote.
local scratch = shell("mktemp -d 2>/dev/null || mktemp -d -t wa-update-banner")
assert(scratch and scratch ~= "", "update banner: could not create a scratch directory; refusing to run without its own")
local scratch_sh = scratch:gsub("\\", "/")
local marker = scratch_sh .. "/.wa-test-scratch"
local token = tostring(host.uuid and host.uuid() or (host.now and host.now() or ""))
assert(host.write_file(marker, "test-update-banner " .. token .. "\n"), "update banner: could not mark its own scratch")
local function cleanup()
  local read_ok, text = pcall(host.read_file, marker)
  if not read_ok or type(text) ~= "string" or not text:find(token, 1, true) then return false end
  if not dofile("lua/core/path_guard.lua").command("rm -rf '" .. scratch_sh .. "'") then return false end
  pcall(host.exec, "rm -rf '" .. scratch_sh .. "'", "", 30)
  return true
end
assert(shell("mkdir -p '" .. scratch_sh .. "/install' '" .. scratch_sh .. "/cache'") ~= nil, "update banner: could not prepare its scratch")
local install = scratch .. "/install"
local RECORD = "commit=aaaaaaa\nbranch=main\ndirty=0\nsource_provenance=clean-built-by-deploy\nvia=deploy.sh\n"
host.write_file(install .. "/installed.txt", RECORD)
ok(host.read_file(install .. "/installed.txt") ~= nil, "the install record fixture is written")
local theirs = updater.installed_record(install)
eq(theirs.commit, "aaaaaaa", "update.lua reads the fixture record")
eq(banner.identity(theirs).sha12, banner.identity(updater.installed_record(install)).sha12,
   "this module and update.lua agree about what is installed")

-- ---- the published side -----------------------------------------------------

-- The machine the fixtures are for: the tests must state a target, because the banner's whole job is
-- to ask whether a release carries an asset this machine can run. An x86_64 asset on the second
-- release and only an aarch64 one on the first is the operator's `work` feed, reduced to two entries.
local TARGET = "x86_64-unknown-linux-gnu"
local function asset_json(sha, triple)
  triple = triple or TARGET
  return '"assets":[' ..
    '{"name":"node-' .. sha .. '.manifest"},' ..
    '{"name":"wa-' .. triple .. '-' .. sha .. '"},' ..
    '{"name":"wa-sentinel-' .. triple .. '-' .. sha .. '"}]'
end

local FEED_BODY = '[' ..
  '{"tag_name":"node-cccccccccccc","name":"node-cccccccccccc","html_url":"https://example.invalid/c",' ..
  '"published_at":"2026-11-06T10:00:00Z","draft":false,"prerelease":true,"body":"SECRET notes text",' ..
  asset_json("cccccccccccc") .. '},' ..
  '{"tag_name":"v0.2.0","name":"wasm-agent 0.2.0","html_url":"https://example.invalid/v020"},' ..
  '{"tag_name":"wa-android-a7bbcda92b76","name":"android","html_url":"https://example.invalid/a"},' ..
  '{"tag_name":"node-aaaaaaabbbbb","name":"node-aaaaaaabbbbb","html_url":"https://example.invalid/ab",' ..
  asset_json("aaaaaaabbbbb") .. '},' ..
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

local function release(sha)
  local assets = { ["node-" .. sha .. ".manifest"] = true,
    ["wa-" .. TARGET .. "-" .. sha] = true, ["wa-sentinel-" .. TARGET .. "-" .. sha] = true }
  return { tag = "node-" .. sha, sha12 = sha, assets = assets }
end
local LATEST = release("cccccccccccc")
LATEST.url = "https://example.invalid/c"
local OLDER = release("aaaaaaabbbbb")

local function compare(installed, list, order, prebuilt)
  return banner.compare(installed, list, { order = order, prebuilt = prebuilt, target = TARGET })
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

-- ---- installability: the asset must be for this machine ----------------------
-- The operator's feed (`work`, 10/11): the newest release is aarch64-only, the next one has an
-- x86_64 asset. The banner may name the second or nothing; it may never name the first.
local AARCH64_ONLY = { tag = "node-4147192f2725", sha12 = "4147192f2725", assets = {
  ["node-4147192f2725.manifest"] = true,
  ["wa-aarch64-unknown-linux-gnu-4147192f2725"] = true,
  ["wa-sentinel-aarch64-unknown-linux-gnu-4147192f2725"] = true } }
local X86 = OLDER

eq(banner.target({ os = "linux", arch = "x86_64" }), TARGET, "x86_64 Linux names the gnu triple")
eq(banner.target({ os = "linux", arch = "aarch64" }), "aarch64-unknown-linux-gnu", "aarch64 Linux names its triple")
eq(banner.target({ os = "windows", arch = "x86_64" }), nil, "a non-Linux host has no prebuilt channel")
ok(not banner.installable(AARCH64_ONLY, TARGET), "an aarch64-only release is not installable on x86_64")
ok(banner.installable(LATEST, TARGET), "a release with this target's manifest, node and sentinel is")
eq((banner.newest_installable({ AARCH64_ONLY, X86 }, TARGET) or {}).sha12, "aaaaaaabbbbb",
  "the newest installable release skips the aarch64-only entry")

local older_prebuilt = banner.identity({ commit = "9999999999999999999999999999999999999999",
  binary_source = "prebuilt-release", binary_release = "node-111111111111" })
local newer_installable, newer_reason = banner.compare(older_prebuilt, { AARCH64_ONLY, X86 },
  { target = TARGET, order = function() return "older" end })
eq(newer_installable, "older", "a newer installable release is behind, even behind a skipped one")
eq(newer_reason, "local_ancestry", "and the reason is the ancestry that proved it")
local no_asset, no_asset_reason = banner.compare(older_prebuilt, { AARCH64_ONLY },
  { target = TARGET, order = function() return "older" end })
eq(no_asset, "unknown", "a newer release with no asset for this arch is never called behind")
eq(no_asset_reason, "no_installable_asset", "and the reason names the missing asset")
eq((banner.compare(banner.identity({ commit = "4147192f2725" }), { AARCH64_ONLY }, { target = TARGET })),
  "equal", "the same version is current even when it has no asset for this machine")
local no_asset_line = banner.verdict(older_prebuilt, { AARCH64_ONLY }, no_asset, no_asset_reason,
  { target = TARGET, channel = "release" })
eq(no_asset_line.line, nil, "and it draws no line at all")
ok(tostring(no_asset_line.message):find("nothing this machine can install", 1, true) ~= nil,
  "the verdict still says why, for /update and the JSON")

-- ---- the buildable-tree channel ---------------------------------------------
-- A tree install updates by building origin/main, so the release feed must not be consulted at all.
-- This is the `work` regression: installed 090858da, origin/main ahead, newest release aarch64-only.
local tree_identity = banner.identity({ commit = "090858da", branch = "main", via = "deploy.sh" })
local tree_calls = 0
local tree_verdict = banner.check({
  install = install, tree = "/fixture/tree", tree_main = "73b63548cba1",
  record = { commit = "090858da", branch = "main", via = "deploy.sh" },
  cache_path = scratch .. "/cache/tree.json", target = TARGET, now = 6000,
  order = function(installed, latest)
    if latest.sha12 == "73b63548cba1" then return "older" end
    return nil
  end,
  fetch = function() tree_calls = tree_calls + 1; return FEED_BODY end,
})
eq(tree_verdict.channel, "tree", "a runtime tree takes the build channel")
eq(tree_verdict.state, "behind", "and is behind origin/main")
eq(tree_verdict.line, "Update available (73b63548cba1): run wa update or /update",
  "the line names origin/main, never the aarch64 release")
eq(tree_verdict.latest and tree_verdict.latest.sha12, "73b63548cba1", "and that is the latest fact")
eq(tree_calls, 0, "the release feed is not even requested on a tree install")

local tree_current = banner.check({
  install = install, tree = "/fixture/tree", tree_main = "73b63548cba1",
  record = { commit = "73b63548", via = "deploy.sh" }, cache_path = scratch .. "/cache/tree2.json",
  now = 6100, target = TARGET,
})
eq(tree_current.state, "current", "the same tree commit is current, with no line")
eq(tree_current.line, nil, "nothing is drawn")
local tree_dirty = banner.check({
  install = install, tree = "/fixture/tree", tree_main = "", tree_reason = "tree_dirty",
  record = { commit = "090858da", via = "deploy.sh" }, cache_path = scratch .. "/cache/tree3.json",
  now = 6200, target = TARGET,
})
eq(tree_dirty.state, "unknown", "a dirty tree is not offered")
eq(tree_dirty.line, nil, "a tree wa update would refuse draws no line")
eq(tree_dirty.reason, "tree_dirty", "and the reason is the refusal")

-- ---- stability: the same world gives the same line, every time ----------------
-- The report was a banner that appeared and disappeared. The verdict must depend only on the
-- record, the tree's origin/main and the cached feed - never on how many times it was asked, nor
-- on the fifteen-minute window rolling over with an unchanged feed.
local stable_cache = scratch .. "/cache/stable.json"
local function stable_base(extra)
  local o = { install = install, tree = "", cache_path = stable_cache, repo = "Magaav/wasm-agent",
    target = TARGET, fetch = function() return FEED_BODY end, order = function() return nil end }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end
banner.reset()
local stable_opts = stable_base({ now = 10 * banner.CACHE_MS, cache_path = stable_cache,
  order = function() return "older" end })
local first = banner.check(stable_opts)
eq(first.state, "behind", "the stable fixture starts behind")
for i = 1, 5 do
  local again = banner.status(stable_base({ now = 10 * banner.CACHE_MS + i * 1000, cache_path = stable_cache,
    order = function() return "older" end }))
  eq(again.state, first.state, "repeat " .. i .. " keeps the same state")
  eq(again.line, first.line, "repeat " .. i .. " keeps the same line")
end
for i = 1, 3 do
  banner.reset()
  local later = banner.check(stable_base({ now = 10 * banner.CACHE_MS + i * banner.CACHE_MS,
    cache_path = stable_cache, order = function() return "older" end }))
  eq(later.state, first.state, "window " .. i .. " keeps the same state")
  eq(later.line, first.line, "window " .. i .. " keeps the same line")
end
-- The same property with the aarch64-only release first: the banner still names the x86_64 release
-- and does not alternate between the two as the cache is reread.
local asset_cache = scratch .. "/cache/assets.json"
local asset_feed = '[' ..
  '{"tag_name":"node-4147192f2725","assets":[' ..
    '{"name":"node-4147192f2725.manifest"},{"name":"wa-aarch64-unknown-linux-gnu-4147192f2725"},' ..
    '{"name":"wa-sentinel-aarch64-unknown-linux-gnu-4147192f2725"}]},' ..
  '{"tag_name":"node-aaaaaaabbbbb",' .. asset_json("aaaaaaabbbbb") .. '}]'
banner.reset()
local asset_first = banner.check({ install = install, tree = "", record = { commit = "9999999",
  binary_source = "prebuilt-release", binary_release = "node-999999999999" },
  cache_path = asset_cache, repo = "o/r",
  target = TARGET, now = 20000, fetch = function() return asset_feed end,
  order = function() return "older" end })
eq(asset_first.latest and asset_first.latest.sha12, "aaaaaaabbbbb", "the first answer names the x86_64 release")
for i = 1, 5 do
  local again = banner.status({ install = install, tree = "", record = { commit = "9999999",
    binary_source = "prebuilt-release", binary_release = "node-999999999999" },
    cache_path = asset_cache, repo = "o/r",
    target = TARGET, now = 20000 + i * 1000, order = function() return "older" end })
  eq(again.latest and again.latest.sha12, "aaaaaaabbbbb", "reread " .. i .. " never flips to the aarch64 release")
  eq(again.line, asset_first.line, "reread " .. i .. " keeps the same line")
end

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
ok(cli:find("session_notice", 1, true) ~= nil, "the CLI view keeps the notice for session-status-content")
ok(cli:find("function METHODS:session_draw()", 1, true) ~= nil,
   "and has one place that draws that line")
ok(cli:find("region_bottom", 1, true) ~= nil, "the line is reserved out of the output region")
ok(chat:find("banner.check({ refresh = true })", 1, true) ~= nil, "the chat asks at session start")
ok(chat:find("view.session_notice = seen.line", 1, true) ~= nil, "and puts the line in session-status-content")
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
    repo = "Magaav/wasm-agent", target = TARGET, fetch = fetch_counts, order = function() return nil end }
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
  repo = "o/r", target = TARGET, offline = "1", now = 2000,
  fetch = function() offline_calls = offline_calls + 1; return FEED_BODY end })
eq(offline.state, "unknown", "offline with no cache is unknown")
eq(offline.reason, "feed_unavailable", "and the reason is the feed it does not have")
eq(offline_calls, 0, "offline makes no request")
eq(offline.line, nil, "offline prints no line")

-- A known update survives going offline: the cached feed still answers, with no request.
banner.reset()
local offline_cached = banner.check({ install = install, tree = "", cache_path = cache, repo = "Magaav/wasm-agent",
  target = TARGET, offline = "1", now = 1000 + banner.CACHE_MS + 5000,
  fetch = function() offline_calls = offline_calls + 1; return FEED_BODY end })
eq(offline_cached.state, "behind", "a cached release still shows while offline")
eq(offline_calls, 0, "and offline still makes no request")

-- A failing feed claims the window before it tries: one request per fifteen minutes, not one per tick.
local broken_cache = scratch .. "/cache/broken.json"
local broken_calls = 0
local function broken() broken_calls = broken_calls + 1; return nil, "feed_status_500" end
banner.reset()
local broken_first = banner.check({ install = install, tree = "", cache_path = broken_cache, repo = "o/r",
  target = TARGET, now = 3000, fetch = broken })
eq(broken_first.state, "unknown", "a failed feed is unknown")
eq(broken_first.error, "feed_status_500", "and names the failure")
eq(broken_calls, 1, "the failed attempt is one request")
local broken_again = banner.check({ install = install, tree = "", cache_path = broken_cache, repo = "o/r",
  target = TARGET, now = 3000 + 60 * 1000, fetch = broken })
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
  repo = "o/r", target = TARGET, now = 9000, fetch = function() return FEED_BODY end })
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

-- ---- session-status-content: one line, two producers ---------------------------
-- The line directly above the session status bar holds the update notice, and a rebuild REPLACES it
-- while it runs. The windows are the twin of the Rust renderer's constants, so the tests read that
-- file rather than restating them: a drift here would be a build that hides the notice for a
-- different length of time depending on which renderer drew it.
local rust = host.read_file("rust/wa-term/src/build_status.rs") or ""
local cli_view = dofile("lua/core/cli_view.lua")
local function rust_const(name)
  return tonumber((rust:match("const " .. name .. ": f64 = ([%d%.]+)")))
end
eq(rust_const("FRESH"), banner.BUILDING_FOR, "the loader's freshness window is build_status::FRESH")
eq(rust_const("INSTALLED_FOR"), banner.INSTALLED_FOR, "the success result's window is INSTALLED_FOR")
eq(rust_const("FAILED_FOR"), banner.FAILED_FOR, "the failure's window is FAILED_FOR")
ok(rust:find("building wasm-agent", 1, true) ~= nil, "the loader's words are the Rust renderer's")
ok(rust:find("wasm-agent rebuilt", 1, true) ~= nil, "so is the rebuilt line")
ok(rust:find("wasm-agent build failed", 1, true) ~= nil, "and the failed one")
eq(cli_view.PALETTE.warning, "ffc107", "the notice is the view's warning yellow (#ffc107)")
eq(string.format("%d;%d;%d", tonumber("ff", 16), tonumber("c1", 16), tonumber("07", 16)), "255;193;7",
   "which is the truecolor triple the Rust renderer must use")
ok(rust:find("255;193;7", 1, true) ~= nil, "and build_status::NOTICE is that triple")

local NOTICE_LINE = "Update available (cccccccccccc): run wa update or /update"
local BUILDING = { state = "building", phase = "compiling", done = 143, total = 412, crate = "serde_json",
  started_at = 1000, at = 1123 }
eq(banner.session_content({ notice = NOTICE_LINE, build = false, now = 100 }).kind, "notice",
   "with no build the line is the notice")
eq(banner.session_content({ notice = NOTICE_LINE, build = false, now = 100 }).text, NOTICE_LINE,
   "and the sentence is the one the module publishes")
eq(banner.session_content({ notice = "", build = false, now = 100 }), nil, "with neither there is no line")
eq(banner.session_content({ notice = "  ", build = false, now = 100 }), nil, "whitespace is no line")
local building_line = banner.session_content({ notice = NOTICE_LINE, build = BUILDING, now = 1125 })
eq(building_line.kind, "building", "a build in flight replaces the notice")
eq(building_line.text, banner.BUILDING_LINE .. " \194\183 143/412 compiling serde_json \194\183 2m05s",
   "the loader names the phase, the crates and the clock")
ok(not building_line.text:find("Update available", 1, true), "and the notice is not in it")
eq(banner.session_content({ notice = NOTICE_LINE, build = BUILDING, now = 1123 + banner.BUILDING_FOR + 1 }).kind,
   "notice", "a build that died without saying so gives the line back")
eq(banner.session_content({ notice = NOTICE_LINE,
  build = { state = "installed", crate = "312s", at = 95 }, now = 100 }).kind, "installed",
   "a finished build shows its result")
eq(banner.session_content({ notice = NOTICE_LINE,
  build = { state = "installed", crate = "312s", at = 95 }, now = 95 + banner.INSTALLED_FOR + 1 }).kind,
   "notice", "for a moment only")
eq(banner.session_content({ notice = NOTICE_LINE,
  build = { state = "failed", phase = "exit 101", at = 95 }, now = 99 }).kind, "failed",
   "a failed build is visible first")
eq(banner.session_content({ notice = NOTICE_LINE,
  build = { state = "failed", phase = "exit 101", at = 95 }, now = 95 + banner.FAILED_FOR + 1 }).kind,
   "notice", "and then the notice comes back: the update is still available")

-- The file the deploy writes is the same file the CLI reads, and a missing or broken one is simply
-- no build (never an error on the status line).
local build_fixture = scratch .. "/build-status.json"
host.write_file(build_fixture, json.encode(BUILDING))
banner.reset_build()
local read_back = banner.build_status({ path = build_fixture })
eq(type(read_back), "table", "the deploy's build-status.json is read")
eq(banner.session_content({ notice = NOTICE_LINE, now = 1125, path = build_fixture }).kind, "building",
   "and it decides the line")
host.write_file(build_fixture, "not json")
banner.reset_build()
eq(banner.build_status({ path = build_fixture, refresh = true }), nil, "a broken file is no build")
eq(banner.session_content({ notice = NOTICE_LINE, now = 1125, path = scratch .. "/nope.json" }).kind, "notice",
   "as is one that is not there")
banner.reset_build()

-- ---- the CLI's session-status-content area really draws it ---------------------
-- Not a source grep: the view is built, its screen rows are set, and what it writes is read back.
-- The area is ONE line directly above the session status bar; the notice is yellow; the status bar
-- keeps its own content (the notice no longer prefixes it); a build REPLACES the notice on that same
-- line and hands it back when it is over; an empty area takes no line at all.
local NOTICE_LINE = "Update available (cccccccccccc): run wa update or /update"
local writes = {}
local clock = 100
-- A 21-row framed console without the native editor: `cli_view.screen_rows(21)`.
local function framed(extra)
  writes = {}
  local options = { live = true, limit = 120, now = function() return clock end,
    rows = function() return 21 end, out = function(text) writes[#writes + 1] = text end }
  for key, value in pairs(extra or {}) do options[key] = value end
  local view = cli_view.new(options)
  view.screen = { top = 1, bottom = 19, status = 20, content = 19, input = 21 }
  -- What `screen_on` records for the region it laid out (the test sets the table itself).
  view.region_row = 19
  view.last_summary = "3 runs"
  return view
end
local function drawn(mark) return table.concat(writes, "", mark or 1) end
-- The text a reader sees: the escape sequences are the layout, not the content.
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end

-- (a) no notice, no build: no line at all, and the output region keeps the row.
local quiet = framed()
quiet:session_draw()
eq(drawn(), "", "no notice draws no line at all (no blank gap above the status bar)")
eq(quiet:region_bottom(), 19, "and the output region keeps the row")
eq(quiet:region_bottom(), quiet.screen.bottom, "which is the height's own last output row")

-- (b) a notice: its own yellow line, one row above the status bar, and the bar unchanged.
local shown = framed()
shown.session_notice = NOTICE_LINE
shown:session_draw()
local out = drawn()
ok(out:find("\27[19;1H", 1, true) ~= nil, "the notice is drawn on row 19: directly above the status bar on 20")
ok(out:find(cli_view.paint(NOTICE_LINE, "warning", true), 1, true) ~= nil,
   "in the warning yellow, the same sentence")
ok(out:find("\27[20;1H", 1, true) == nil, "and not on the status bar's own row")
eq(shown:region_bottom(), 18, "the line is reserved: output ends one row higher while it shows")

-- The status bar itself is unchanged: the editor's footer row gets the session numbers alone, with
-- no notice prefixed to them (that is the whole point of the change).
local footer_text, footer_right
local original_editor_footer = host.editor_footer
host.editor_footer = function(text, right) footer_text, footer_right = text, right return true end
local bar = framed()
bar.editor, bar.editor_ready, bar.stdout, bar.model = true, true, true, "test-model"
bar.screen = { top = 1, bottom = 10, status = 15, content = 14, input_top = 16, input = 19, footer = 21 }
bar.session_notice = NOTICE_LINE
bar:footer_draw()
eq(footer_text, "3 runs", "the status bar carries its own content only, left-aligned as before")
eq(footer_right, "test-model", "and its right side is still the model")
ok(drawn():find("\27[15;1H", 1, true) ~= nil,
   "the notice is drawn on the status row's own row (idle: there is no status bar, so the line takes it)")
ok(drawn():find(cli_view.paint(NOTICE_LINE, "warning", true), 1, true) ~= nil, "with the notice, in yellow, on it")
bar.session_notice = nil
bar:footer_draw()
eq(footer_text, "3 runs", "with no notice the bar is what it always was")
if original_editor_footer == nil then host.editor_footer = nil else host.editor_footer = original_editor_footer end

-- (c) a build in flight REPLACES the notice on the same line.
local building = { state = "building", phase = "compiling", done = 1, total = 4, crate = "serde", started_at = 90, at = 95 }
local built = framed({ session_status = function()
  return banner.session_content({ notice = NOTICE_LINE, build = building, now = clock })
end })
built.session_notice = NOTICE_LINE
built:session_draw()
out = drawn()
ok(out:find(cli_view.paint(banner.BUILDING_LINE .. " \194\183 1/4 compiling serde \194\183 10s", "borderAccent", true), 1, true) ~= nil,
   "the loader is the line while the build runs")
ok(out:find("Update available", 1, true) == nil, "and the update notice is gone from it")
ok(out:find("\27[19;1H", 1, true) ~= nil, "on the same row it always uses")

-- (d) a failed build: the failure is visible first, and then the notice comes back on that line, so
-- the notice is never the thing that gets lost.
clock = 96
local failing = framed({ session_status = function() return banner.session_content({ notice = NOTICE_LINE,
  build = { state = "failed", phase = "exit 101", at = 95 }, now = clock }) end })
failing.session_notice = NOTICE_LINE
failing:session_draw()
out = drawn()
ok(out:find(cli_view.paint(banner.FAILED_LINE:format(" (exit 101)"), "error", true), 1, true) ~= nil,
   "a failed build says so, in the error colour")
ok(out:find("Update available", 1, true) == nil, "and replaces the notice while it does")
clock = 95 + banner.FAILED_FOR + 1
local back = framed({ session_status = function() return banner.session_content({ notice = NOTICE_LINE,
  build = { state = "failed", phase = "exit 101", at = 95 }, now = clock }) end })
back.session_notice = NOTICE_LINE
back:session_draw()
ok(drawn():find(cli_view.paint(NOTICE_LINE, "warning", true), 1, true) ~= nil,
   "once the failure is no longer fresh the notice is back, in yellow, on the same row")
-- A build that died without saying so hands the line back too.
clock = 95 + banner.BUILDING_FOR + 1
local died = framed({ session_status = function() return banner.session_content({ notice = NOTICE_LINE,
  build = { state = "building", phase = "compiling", at = 95 }, now = clock }) end })
died.session_notice = NOTICE_LINE
died:session_draw()
ok(drawn():find(cli_view.paint(NOTICE_LINE, "warning", true), 1, true) ~= nil,
   "a stale 'building' is not a line: the notice is")

-- (e) width 40: exactly 40 columns, an ellipsis at the end, one row.
local narrow = framed({ limit = 40 })
narrow.session_notice = NOTICE_LINE
local narrow_text = narrow:session_line()
eq(cli_view.visible_columns(narrow_text), 40, "a 40-column terminal gets exactly 40 columns")
ok(visible(narrow_text):find("\226\128\166$") ~= nil, "truncated with an ellipsis")
ok(narrow_text:find("\n", 1, true) == nil, "and never wrapped")
narrow:region_bottom()
eq(narrow:region_bottom(), 18, "the reserved row is the same at any width")

-- A captured transcript (no terminal): the same text, once, as plain lines - no cursor movement and
-- no colour. This is also the NO_COLOR path: `wants_live` is false, so `paint` paints nothing.
local captured = {}
local capture_view = cli_view.new({ live = false, limit = 120, out = function(text) captured[#captured + 1] = text end })
capture_view.session_notice = NOTICE_LINE
capture_view:paint()
capture_view:paint()
local log = table.concat(captured)
eq((select(2, log:gsub("Update available", ""))), 1, "a captured transcript prints the notice once, as text")
ok(log:find("\27[", 1, true) == nil, "with no escape sequences in it")

-- The evidence that the whole file list is wired: the CLI keeps the sentence for the new area, and
-- the chat puts it there.
ok(cli:find("session_notice", 1, true) ~= nil, "the CLI view keeps the notice for session-status-content")
ok(chat:find("view.session_notice = seen.line", 1, true) ~= nil, "and the chat puts the line there")

-- A cache written for a different repository is not a fact about this node.
local other_repo_cache = scratch .. "/cache/other-repo.json"
host.write_file(other_repo_cache, json.encode({ schema = 1, checked_at = 7000, repo = "other/repo",
  latest = { tag = "node-eeeeeeeeeeee", sha12 = "eeeeeeeeeeee" }, order = { "eeeeeeeeeeee" } }))
banner.reset()
local repo_calls = 0
local repo_check = banner.check({ install = install, tree = "", cache_path = other_repo_cache, repo = "Magaav/wasm-agent",
  target = TARGET, now = 7100, fetch = function() repo_calls = repo_calls + 1; return FEED_BODY end })
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
  fixture = fixture, repo = "o/r", target = TARGET, now = 500 })
eq(from_fixture.state, "behind", "the fixture file answers without a request")

if failed == 0 then
  cleanup()
  print("update banner ok (" .. checks .. " checks)")
  return
end
print("update banner: " .. failed .. " failed of " .. checks .. " checks (fixtures kept in " .. scratch .. ")")
os.exit(1)
