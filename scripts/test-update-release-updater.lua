-- The release-install update path picks the UPDATER THAT CAME WITH THE BUNDLE.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-release-updater.lua wa --db <scratch>
--
-- What this pins (11/11): a node installed from a published bundle carries `scripts/install.sh` beside its
-- binary - the same one-command front door that installed it, verified with the bundle's own files.sha256.
-- `/update` must run THAT, not re-clone the repository into `<home>/wasm-agent-bootstrap` and run whatever
-- `main` says today: the updater a node runs is the updater of the release it is running.
--
-- The four facts: presence is detected from the file (no version negotiation), `--check` is read-only and
-- answers behind/current from the core's own words, a core that refuses is reported as
-- release_check_failed with its output, and an install from before the updater existed reports no
-- updater at all (so the clone path stays reachable for it - the caller's decision, not a guess here).
local update = dofile("lua/core/update.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

local home = host.getenv("WASM_AGENT_HOME") or "."
local install = home .. "/install"
local record = { via = "linux-bootstrap", release = "v0.1.0-alpha.13", commit = "0123456789abcdef0123456789abcdef01234567" }
local facts = { install = install, installed_commit = "0123456789abcdef0123456789abcdef01234567" }
local function shell_ok(cmd) local r = host.exec(cmd, ""); return r and tonumber(r.code) == 0 end

host.exec("mkdir -p '" .. install .. "/scripts' '" .. install .. "/ui'", "")

-- ---- before the updater: nothing is claimed -------------------------------------------------------
ok(update.installed_updater(install) == nil, "an install without scripts/install.sh reports no updater")
ok(update.installed_updater(nil) == nil, "and no install at all reports no updater")
ok(update.installed_updater("") == nil, "an empty install path reports no updater")

-- ---- the front door is there: it is the updater ------------------------------------------------
host.write_file(install .. "/scripts/install.sh", table.concat({
  "#!/bin/sh",
  "# fixture front door: prints what the core would print, so the parse is what is under test",
  "for a in \"$@\"; do case \"$a\" in --check) check=1 ;; esac; done",
  "if [ -n \"${check:-}\" ]; then",
  "  echo 'bootstrap: install /fixture: behind (installed 01234567)'",
  "  echo 'bootstrap: check only: would install v0.1.0-alpha.15 into /fixture'",
  "  exit 0",
  "fi",
  "echo 'bootstrap: installed'",
  "exit 0",
}, "\n") .. "\n")
shell_ok("chmod 755 '" .. install .. "/scripts/install.sh'")
ok(update.installed_updater(install) == install .. "/scripts/install.sh", "the installed front door is found beside the binary")

local checked = update.run_release({ check = true }, facts, record)
ok(checked.ok == true, "a read-only check answers")
ok(checked.status == "behind", "and says the node is behind (got " .. tostring(checked.status) .. ")")
ok(checked.channel == "release-bundle", "the channel is named")
ok(checked.updater == "installed", "and the path is the installed updater, not a clone (got " .. tostring(checked.updater) .. ")")
ok(checked.target_release == "v0.1.0-alpha.15", "the target release comes from the core's own words (got " .. tostring(checked.target_release) .. ")")
ok(checked.queued == nil, "a check never claims to have queued anything")

-- ---- current: the same shape, one word different ------------------------------------------------
host.write_file(install .. "/scripts/install.sh", "#!/bin/sh\nprintf '%s\\n' 'bootstrap: install /fixture: current (installed 01234567)' 'bootstrap: check only: would install v0.1.0-alpha.13 into /fixture'\nexit 0\n")
shell_ok("chmod 755 '" .. install .. "/scripts/install.sh'")
local current = update.run_release({ check = true }, facts, record)
ok(current.ok == true and current.status == "current", "a current node is reported current (got " .. tostring(current.status) .. ")")

-- ---- a core that refuses is reported with its own output, and installs nothing -------------------
host.write_file(install .. "/scripts/install.sh", "#!/bin/sh\necho 'bootstrap: index_unreachable: https://example.invalid/index.json'\nexit 1\n")
shell_ok("chmod 755 '" .. install .. "/scripts/install.sh'")
local refused = update.run_release({ check = true }, facts, record)
ok(refused.ok == false, "a refusing core is not a success")
ok(refused.status == "release_check_failed", "and is named release_check_failed (got " .. tostring(refused.status) .. ")")
ok(type(refused.observed) == "string" and refused.observed:find("index_unreachable", 1, true) ~= nil,
  "with the core's own words as the observation")

if failed > 0 then print("update release updater: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("update release updater ok (" .. checks .. " checks)")
