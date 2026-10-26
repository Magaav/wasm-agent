-- The `/update` route's two modes, on a fixture install: a read-only release check, and the deploy
-- request that must not pay for one.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-release.lua wa --db <scratch>
--
-- What this pins: `check` answers without a sentinel, without synchronizing the tree, without a
-- backup, and without writing a request - the properties that make it safe to call from a window
-- reload. And that the deploy path still reports the cached release state, so "/update queued" and
-- "you are two versions behind" are one answer rather than two commands.
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

local home = host.getenv("WASM_AGENT_HOME") or "."
local install = home .. "/install"
local requests = home .. "/sentinel"
local fixture = home .. "/feed.json"
pcall(host.exec, "mkdir -p '" .. install .. "' '" .. requests .. "'", "")
pcall(host.write_file, install .. "/installed.txt",
  "commit=abc1234\nbranch=main\ndirty=0\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nrelease=0.1.0\n")
pcall(host.write_file, fixture, '{"tag_name":"v0.2.0","name":"0.2.0","html_url":"https://example.invalid/r","published_at":"2026-10-26T18:00:00Z","body":"notes"}')

-- ---- the read-only check ----------------------------------------------------

local checked = updater.run({ check = true, install = install, sentinel_dir = requests, fresh = true, feed_fixture = fixture })
eq(checked.ok, true, "the check answers")
eq(checked.status, "release_check", "and says it was a check")
eq(checked.release and checked.release.state, "behind", "and that this install is behind")
eq(checked.release and checked.release.latest, "0.2.0", "naming the published release")
ok(checked.release and checked.release.message:find("0.1.0", 1, true) ~= nil, "and the installed one")
ok(checked.queued == nil, "a check never claims to have queued anything")
ok(checked.request == nil, "and names no request")
local ok_list, listed = pcall(json.decode, host.exec("ls '" .. requests .. "' 2>/dev/null | wc -l", ""))
ok(ok_list and tonumber(listed.code) == 0, "the request box can be listed")
ok(ok_list and tonumber((tostring(listed.stdout or ""):match("%d+") or "-1")) == 0, "a check wrote nothing into the request box")

-- The check must not need a sentinel: this fixture has none, and the answer is still the answer.
local no_sentinel = updater.run({ check = true, install = install, sentinel_dir = requests, fresh = true, feed_fixture = fixture })
eq(no_sentinel.status, "release_check", "a check does not require a sentinel")

-- ---- the deploy path reads the cache, and does not fetch --------------------

-- The cached answer the check just left behind is what the deploy path reports: the same window, the
-- same version, with no second request.
local deploy = updater.run({ install = install, sentinel_dir = requests, reason = "test", skip_source_sync = true, skip_backup = true })
ok(deploy.release ~= nil, "the deploy report carries a release verdict")
eq(deploy.release and deploy.release.state, "behind", "read from the cache")
ok(deploy.release and deploy.release.checked_at ~= nil, "and says when it was checked")
eq(deploy.status, "no_watcher", "the deploy is refused for the missing watcher, not for the release")

-- A node that has never checked reports `not_checked` rather than pretending: the deploy path must
-- never turn a missing answer into "current".
local cold = updater.run({ check = true, install = install, sentinel_dir = requests, offline = 1, fresh = true })
eq(cold.release and cold.release.state, "unknown", "an offline check is unknown")
ok(cold.release and cold.release.reason == "checks_disabled", "and names the reason")

if failed > 0 then print("update release: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("update release ok (" .. checks .. " checks)")
