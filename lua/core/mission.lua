-- wa mission launch|start|resume|status|stop - the mission loop, in the CLI.
--
-- The behaviour is scripts/mission.sh's, and deliberately so: that script encodes measured failures that
-- cost whole rounds (docs/MISSIONS.md), and a second implementation that "improves" on them re-learns
-- them. What changes is where it lives and who else can call it: one module, on the agent-control API
-- (lua/core/agent_control.lua), so a mission is a child like any other and Fleet View sees it.
--
-- THE RULES, kept because each one came from a lost run:
--   * liveness is the NODE'S run, never a launcher's pid. A CLI that exited rc=1 while the node kept
--     writing looks "finished" to a pid check, and the next launch made two writers in one worktree;
--   * one answer permits a start: no launcher standing, and the node says the mission's run is released.
--     Every other answer - alive, held, stale, starting, unknown - refuses BY NAME with the command that
--     clears it. There is no --force, and unknown is never yes;
--   * one fresh session per launch (wa chat --once), never a resume; the done file carries the rc, so a
--     launch that finished and one that died cannot read the same;
--   * the session id is read where the CLI prints it - STDERR, "wa: session <id> ok" - and only a
--     36-character [0-9a-f-] line is accepted. The id goes into run.lock and from there into SQL, so the
--     shape check is the guard against a stray line becoming a query.
--
-- PROCESSES. A launch is a detached setsid child of THIS process, recorded by pid in launch.pid before it
-- can write anything; stop signals that pid only - never a pattern (21/11: a pkill -f pattern killed an
-- orchestrator watcher). Nothing here kills what it did not start.
local json = dofile("lua/vendor/json.lua")
local M = {}

M.DEFAULT_START_WAIT_SECONDS = 600

-- The missions root. MISSION_ROOT (the fixture's name; scripts/test-mission.sh exports it) wins over
-- MISSIONS_DIR, and the default is the operator's own ~/Work/missions.
function M.root(env)
  local read = env or host.getenv
  return read("MISSION_ROOT") or read("MISSIONS_DIR") or (read("HOME") .. "/Work/missions")
end

function M.dir(name, root) return (root or M.root()) .. "/" .. tostring(name) end

-- A mission name is a directory name and a branch suffix: one word, no path separators, no traversal.
function M.check_name(name)
  if name == nil or name == "" then return nil, "name_required" end
  local word = tostring(name)
  if not word:match("^[A-Za-z0-9]") then return nil, "name_must_start_with_a_letter_or_digit" end
  if word:find("[/\\]") or word:find("..", 1, true) or word:find(" ") then return nil, "name_must_be_one_word" end
  return word
end

-- "wa: session <id> ok" - and nothing else - is a session id.
function M.session_id_ok(value)
  if type(value) ~= "string" or #value ~= 36 then return false end
  return value:match("^[0-9a-f%-]+$") ~= nil
end

function M.read_file(path)
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= "string" then return nil end
  return text
end

function M.write_file(path, text)
  local ok, err = pcall(host.write_file, path, text)
  if not ok then return nil, tostring(err) end
  return true
end

-- A path exists when it can be read as a file OR is a directory: a mission directory is a directory, and
-- reading it as a file fails for a reason that has nothing to do with whether it is there.
function M.exists(path)
  if M.read_file(path) ~= nil then return true end
  local ok, raw = pcall(host.exec, "test -d " .. string.format("%q", path), "", 20)
  if not ok or type(raw) ~= "string" then return false end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return false end
  return tonumber(decoded.code) == 0
end

-- The node has no mkdir capability; a mission directory is created the one way there is, by name, with
-- its own exit status read back.
function M.ensure_dir(path)
  local ok, raw = pcall(host.exec, "mkdir -p " .. string.format("%q", path), "", 30)
  if not ok or type(raw) ~= "string" then return nil, "cannot_create_directory" end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" or tonumber(decoded.code) ~= 0 then
    return nil, "cannot_create_directory: " .. tostring(path)
  end
  return true
end

-- One KEY=value out of an env/lock file, quotes stripped, newest line wins.
function M.field(text, key)
  if not text then return nil end
  local value = nil
  for line in text:gmatch("[^\r\n]+") do
    local found = line:match("^" .. key .. "='(.*)'$")
    if found then value = found end
  end
  return value
end

function M.worktree_of(dir)
  local wt = M.field(M.read_file(dir .. "/env"), "WT")
  if wt and wt ~= "" then return wt end
  return dir .. "/wt"
end

-- This node's short name. HOSTNAME is not exported by every shell (measured: empty under a bare env, and
-- an empty NODE makes the runner refuse every launch as "wrong node"), so the host is asked directly and
-- an unreadable answer stays empty - the runner then refuses by name instead of pretending.
function M.node_name()
  local ok, raw = pcall(host.exec, "hostname -s 2>/dev/null || uname -n", "", 20)
  if not ok or type(raw) ~= "string" then return "" end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return "" end
  return (tostring(decoded.stdout or ""):gsub("%s+$", ""))
end

function M.marker_of(name, worktree) return "mission " .. tostring(name) .. " in " .. tostring(worktree) end

-- The session this mission recorded: the id the CLI printed, checked for shape. out.log is read too
-- because a stub (and an older launch) writes it there.
function M.recorded_session(dir)
  for _, suffix in ipairs({ "/err.log", "/out.log" }) do
    local text = M.read_file(dir .. suffix)
    if text then
      local found = text:match("wa: session ([^ ]+) ")
      if found and M.session_id_ok(found) then return found end
    end
  end
  return nil
end

function M.lock_field(dir, key)
  local value = M.field(M.read_file(dir .. "/run.lock"), key)
  if value == "" then return nil end
  return value
end

function M.git(repository, arguments, cwd)
  local ok, raw = pcall(host.exec, "git -C " .. string.format("%q", repository) .. " " .. arguments, cwd or "", 120)
  if not ok or type(raw) ~= "string" then return nil, "git_unavailable" end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil, "git_answer_unreadable" end
  if tonumber(decoded.code) ~= 0 then return nil, tostring(decoded.stderr or ""):sub(1, 400) end
  return tostring(decoded.stdout or "")
end

-- A launch is standing when the runner this file names is still alive. Signal 0 only: the kernel says
-- whether the pid exists, and nothing here signals a process it did not start.
function M.launch_standing(dir)
  local pid = M.read_file(dir .. "/launch.pid")
  local value = tonumber((pid or ""):match("%d+"))
  if not value or value <= 0 then return nil end
  return value
end

--------------------------------------------------------------------------- the runner
-- One static file per mission, never rewritten per launch. It exports the toolchain and this mission's own
-- build dir, takes run.lock BEFORE the node is asked for a session, binds the session id the CLI prints,
-- runs the CLI, and writes done with its rc. The lock is NOT released here: the CLI's exit is not the
-- run's end, and a shell that released it would claim something it cannot see.
--
-- Three guards on a process that can spawn wa children, because a fork storm cost a node on 20/11:
--   * a DEPTH GUARD - a runner started from inside a runner exits 94 by name;
--   * a TIMEOUT that signals only the CLI pid it started (never a pattern);
--   * RLIMIT_NPROC, fd and core limits, raised where that is safe and never below what a build needs.
M.RUNNER = [==[
#!/usr/bin/env bash
# generated by wa mission launch - re-launch to regenerate; do not edit.
set -uo pipefail
# DEPTH GUARD: a runner started from inside a runner is a fork storm, and it stops here by name.
[ -n "${WA_MISSION_CHILD:-}" ] && { echo 'mission: runner inside a runner (depth guard)' >&2; exit 94; }
export WA_MISSION_CHILD=1
M=$(cd "$(dirname "$0")" && pwd -P) || exit 97
. "$M/env" || exit 98
cd "$M" || exit 96
[ "$(hostname -s 2>/dev/null || uname -n)" = "$NODE" ] || { echo "mission: launched on the wrong node (want $NODE)" >&2; exit 95; }
unset WASM_AGENT_RAW_CODE  # native run(code=...) is the one execution path (Victor 21/11); never inherit another
export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"
export PATH="$TOOLCHAIN/cargo/bin:$PATH"
export CARGO_TARGET_DIR="$TARGET"
# Resource limits for a process that can spawn wa children: no core files, and a descriptor ceiling so a
# runaway fan-out hits a limit instead of the machine.
ulimit -c 0 2>/dev/null || true
ulimit -n 8192 2>/dev/null || true
rm -f "$M/done" "$M/run.pid"
date -u +%FT%TZ > "$M/started"
printf "MISSION='%s'\nSESSION=''\nWORKTREE='%s'\nNODE='%s'\nLAUNCHER='%s'\nLOCKED='%s'\n" "$NAME" "$WT" "$NODE" "$$" "$(date -u +%FT%TZ)" > "$M/run.lock"
printf 'take %s launcher=%s session=- (before the node is asked for one)\n' "$(date -u +%FT%TZ)" "$$" >> "$M/lease.log"
errlines=0; [ -f "$M/err.log" ] && errlines=$(wc -l < "$M/err.log" 2>/dev/null)
errlines=${errlines:-0}
"$WA" chat --once "$(cat "$M/prompt.md")" >> "$M/out.log" 2>> "$M/err.log" &
cli=$!
echo "$cli" > "$M/run.pid"
# TIMEOUT: signals the CLI pid this runner started, and nothing else - never a pattern.
#
# NO SIX-HOUR SLEEP OUTLIVES THIS RUNNER (measured 23/11 on avell: 108 orphaned `sleep 21600` processes,
# parent systemd --user, in batches of six - one batch per mission launch). The shape this replaces was
# `( sleep 21600; kill ... ) &`, and `kill $watchdog` kills the SUBSHELL, not the `sleep` inside it: every
# launch that ended normally left its sleep behind for the rest of the day. So the deadline is COUNTED in
# short steps: the watchdog leaves the loop as soon as the CLI is gone (a normal launch ends it at once, not
# after the deadline), and the most a killed watchdog can leave behind is ONE STEP of 5 s.
# ITS OWN OUTPUT IS /dev/null: a sleep that inherited a caller pipe keeps that pipe open and a
# `$(bash run.sh)` never saw EOF (measured by scripts/test-mission-verb.sh, 22/11).
wa_deadline=${MISSION_TIMEOUT_SECONDS:-21600}
case "$wa_deadline" in ''|*[!0-9]*) wa_deadline=21600 ;; esac
( wa_waited=0
  while [ "$wa_waited" -lt "$wa_deadline" ]; do
    sleep 5; wa_waited=$((wa_waited + 5))
    kill -0 "$cli" 2>/dev/null || exit 0
  done
  kill -TERM "$cli" 2>/dev/null; sleep 30; kill -KILL "$cli" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
i=0
while [ "$i" -lt 300 ]; do
  sid=$(sed -n 's/^wa: session \([^ ]*\) .*/\1/p' "$M/err.log" 2>/dev/null | tail -n +$((errlines + 1)) | tail -1)
  case $sid in ''|*[!0-9a-f-]*) sid='' ;; *) [ "${#sid}" -eq 36 ] || sid='' ;; esac
  [ -n "${sid:-}" ] && break
  kill -0 "$cli" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
if [ -n "${sid:-}" ]; then
  printf "MISSION='%s'\nSESSION='%s'\nWORKTREE='%s'\nNODE='%s'\nLAUNCHER='%s'\nLOCKED='%s'\n" "$NAME" "$sid" "$WT" "$NODE" "$$" "$(date -u +%FT%TZ)" > "$M/run.lock"
  printf 'bind %s session=%s (the node named it)\n' "$(date -u +%FT%TZ)" "$sid" >> "$M/lease.log"
fi
wait "$cli"; rc=$?
kill "$watchdog" 2>/dev/null || true
# A REFUSED TURN IS NOT A FAILED RUN (22/11). While a deploy waits for or installs on this node the CLI
# refuses a NEW turn by name and exits 2 (`deploy_waiting: waiting for the install of <sha>`,
# docs/SCRIPTED-RUNS.md). Nothing was asked and nothing answered, so the launch waits and asks again - up to
# WA_DEPLOY_WAIT_LIMIT seconds, in WA_DEPLOY_WAIT_STEP steps - instead of recording rc=2 as if the mission's
# first turn had failed. Past the limit the refusal stands as itself: rc=2 in `done`, and the line written here
# says why, because a wait that never ends is a fact the operator must see and not a silence.
step=${WA_DEPLOY_WAIT_STEP:-15}; case "$step" in ''|*[!0-9]*|0) step=15 ;; esac
limit=${WA_DEPLOY_WAIT_LIMIT:-900}; case "$limit" in ''|*[!0-9]*) limit=900 ;; esac
waited=0
while [ "$rc" -eq 2 ] && tail -c 4000 "$M/out.log" 2>/dev/null | grep -q deploy_waiting; do
  if [ "$waited" -ge "$limit" ]; then
    printf 'deploy-wait %s gave up after %ss: the node is still waiting for or installing a build, so this turn never started (nothing ran)\n' "$(date -u +%FT%TZ)" "$waited" >> "$M/out.log"
    break
  fi
  sleep "$step"
  waited=$((waited + step))
  printf 'deploy-wait %s the node is waiting for or installing a build: asking again (%ss of %ss)\n' "$(date -u +%FT%TZ)" "$waited" "$limit" >> "$M/out.log"
  printf 'deploy-wait %s refused (nothing ran; asking again in %ss)\n' "$(date -u +%FT%TZ)" "$step" >> "$M/lease.log"
  "$WA" chat --once "$(cat "$M/prompt.md")" >> "$M/out.log" 2>> "$M/err.log" &
  cli=$!
  echo "$cli" > "$M/run.pid"
  ( wa_waited=0
  while [ "$wa_waited" -lt "$wa_deadline" ]; do
    sleep 5; wa_waited=$((wa_waited + 5))
    kill -0 "$cli" 2>/dev/null || exit 0
  done
  kill -TERM "$cli" 2>/dev/null; sleep 30; kill -KILL "$cli" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$cli"; rc=$?
  kill "$watchdog" 2>/dev/null || true
done
printf 'rc=%s %s\n' "$rc" "$(date -u +%FT%TZ)" > "$M/done"
printf 'cli-exit %s rc=%s session=%s (the lock stays: the node keeps the run)\n' "$(date -u +%FT%TZ)" "$rc" "${sid:--}" >> "$M/lease.log"
exit "$rc"
]==]

-- The prompt: the marker first (it becomes the session title, which is how the node's session is matched
-- back to this mission), then the brief, then where the session is.
function M.prompt_text(marker, brief, fields, note)
  local body = (brief:gsub("\r\n", "\n"):gsub("\n+$", ""))
  local parts = {
    marker, "",
    body, "",
    "## Where you are",
    "Your code is the git worktree " .. fields.wt .. " (branch " .. fields.branch .. ", base " .. fields.base
      .. "); use absolute paths and cd there in shell commands.",
    "Build and test HERE on this node (" .. tostring(fields.node or "") .. "): CARGO_TARGET_DIR=" .. fields.target
      .. " is this mission's only build dir. Never build, test or sync code on another node.",
    "Commit locally; never push.",
    "",
    "## Amendments",
    "The brief above is what you were started with. A change can arrive WHILE you work: it reaches you as a"
      .. " message that begins \"[amendment <UTC> from the planner]\", and the same text is appended to brief.md"
      .. " under that stamp. An amendment is NEWER than the brief where the two disagree: act on the amendment,"
      .. " not on the sentence it replaces. Name every amendment you acted on in your report with its UTC stamp,"
      .. " and name the ones you did not act on with the reason.",
  }
  if note and note ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "## Note from the orchestrator"
    parts[#parts + 1] = (note:gsub("\n+$", ""))
  end
  return table.concat(parts, "\n") .. "\n"
end

local function env_text(fields)
  local order = { "NAME", "BRANCH", "BASE", "BASE_SHA", "NODE", "WT", "TOOLCHAIN", "TARGET", "WA" }
  local lines = {}
  for _, key in ipairs(order) do lines[#lines + 1] = key .. "='" .. tostring(fields[key:lower()] or fields[key] or "") .. "'" end
  return table.concat(lines, "\n") .. "\n"
end

--------------------------------------------------------------------------- launch
function M.launch(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why, effect = "none" } end
  local base = tostring(args.base or "")
  if base == "" then return { error = "base_required", effect = "none" } end
  local dir = M.dir(name, args.root)
  local brief = M.read_file(dir .. "/brief.md")
  if not brief or brief == "" then
    return { error = "no_brief", detail = "no brief at " .. dir .. "/brief.md", effect = "none" }
  end
  local wt = dir .. "/wt"
  if M.exists(wt .. "/.git") then
    return { error = "already_staged", detail = "already staged: " .. wt .. " exists", effect = "none" }
  end
  local repository = args.repository or host.getenv("MISSION_REPO") or ""
  if repository == "" then return { error = "repository_required", effect = "none" } end
  local branch = "change/" .. name
  local added, why = M.git(repository, "worktree add -q -b " .. string.format("%q", branch) .. " "
    .. string.format("%q", wt) .. " " .. string.format("%q", base))
  if not added then return { error = "worktree_add_failed", detail = why, effect = "none" } end
  local base_sha = (M.git(wt, "rev-parse HEAD") or ""):gsub("%s+$", "")
  local home = host.getenv("HOME") or ""
  local fields = {
    name = name, branch = branch, base = base, base_sha = base_sha, wt = wt,
    node = M.node_name(),
    toolchain = host.getenv("MISSIONS_TOOLCHAIN") or (home .. "/wasm-agent/toolchain"),
    target = (host.getenv("MISSIONS_TARGET_ROOT") or (home .. "/wasm-agent/target")) .. "/m-" .. name,
    wa = args.wa or "wa",
  }
  local made, made_why = M.ensure_dir(dir)
  if not made then return { error = made_why, effect = "none" } end
  local wrote, write_why = M.write_file(dir .. "/env", env_text(fields))
  if not wrote then return { error = "cannot_write_env", detail = write_why, effect = "none" } end
  local note = M.read_file(dir .. "/note.md") or ""
  local prompt_ok, prompt_why = M.write_file(dir .. "/prompt.md", M.prompt_text(M.marker_of(name, wt), brief, fields, note))
  if not prompt_ok then return { error = "cannot_write_prompt", detail = prompt_why, effect = "none" } end
  local runner_ok, runner_why = M.write_file(dir .. "/run.sh", M.RUNNER)
  if not runner_ok then return { error = "cannot_write_runner", detail = runner_why, effect = "none" } end
  pcall(host.exec, "chmod +x " .. string.format("%q", dir .. "/run.sh"), "", 30)
  return { ok = true, name = name, worktree = wt, branch = branch, base_sha = base_sha,
    prompt = dir .. "/prompt.md", runner = dir .. "/run.sh",
    next_action = "wa mission start " .. name }
end

--------------------------------------------------------------------------- start
local function spawn_detached(command, dir, log_out, log_err)
  local line = "setsid nohup bash -c " .. string.format("%q", command)
    .. " </dev/null >>" .. string.format("%q", log_out) .. " 2>>" .. string.format("%q", log_err) .. " & echo $!"
  local ok, raw = pcall(host.exec, line, dir, 60)
  if not ok or type(raw) ~= "string" then return nil, "cannot_spawn" end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return nil, "spawn_answer_unreadable" end
  local pid = tostring(decoded.stdout or ""):match("%d+")
  if not pid then return nil, "spawn_returned_no_pid" end
  return tonumber(pid)
end

function M.alive(pid)
  local value = tonumber(pid)
  if not value or value <= 0 then return false end
  local ok, raw = pcall(host.exec, "kill -0 " .. tostring(value) .. " 2>/dev/null", "", 20)
  if not ok or type(raw) ~= "string" then return false end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return false end
  return tonumber(decoded.code) == 0
end

-- The node's own word about a session's run: "active", "released", or "unknown". Asked through the
-- steering status, the same read scripts/mission.sh makes, and never inferred from a pid: a CLI that
-- exited while the node kept writing looks finished to a pid check. An answer this cannot read is
-- "unknown", which no launch treats as permission.
function M.run_verdict(session_id, dir)
  if not M.session_id_ok(session_id) then return "unknown", "no_session_id" end
  local ok, raw = pcall(host.exec, "wa steer " .. session_id .. " --status --json", dir or "", 30)
  if not ok or type(raw) ~= "string" then return "unknown", "node_did_not_answer" end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return "unknown", "node_answer_unreadable" end
  local text = tostring(decoded.stdout or "")
  local body_ok, body = pcall(json.decode, text)
  if not body_ok or type(body) ~= "table" then
    if text:find("no such session", 1, true) then
      -- The node does not hold this session at all: nothing of it is running, which is a released run.
      return "released", "the node does not hold this session"
    end
    return "unknown", "node_answer_unreadable"
  end
  -- WHAT THE NODE ACTUALLY ANSWERS (measured 23/11 from this node and in this file's own fixture): one flat
  -- object, {"target":{...,"state":"active"|"settled"|"failed"|"unknown"},"receipts":[...]}. This used to
  -- read a key called `active` that the answer has never carried, so every session the node knew about came back
  -- "unknown" - and "unknown" refuses every launch and every resume beside it, which is a verb that cannot work.
  -- The run row's own state is the word, and `body.active` stays supported for a stub that speaks the older
  -- shape. `target` absent is the node saying it records no run for this session: nothing is in flight.
  local state = type(body.target) == "table" and tostring(body.target.state or "") or ""
  if body.active == true or state == "active" then
    return "active", "the node holds a live run for this session"
  end
  if body.active == false or state == "settled" or state == "failed" then
    return "released", "the node says the run is " .. (state ~= "" and state or "settled")
  end
  if state == "unknown" or state == "deferred" then
    return "unknown", "the node says the run is " .. state .. ": an interruption nobody can vouch for"
  end
  if body.target == nil and body.active == nil then
    return "released", "the node records no run for this session"
  end
  if body.error then return "unknown", tostring(body.error) end
  return "unknown", "node_did_not_say"
end

-- The one permitting answer. An unknown verdict is never yes: a node that did not answer is a refusal,
-- because a launch beside a run nobody could see is exactly the second writer this check prevents.
local function launch_permitted(dir)
  local session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  local standing = M.launch_standing(dir)
  if session then
    -- A named session is the stronger fact: the node's own word about its run decides, and a live
    -- launcher only makes the refusal more certain.
    local verdict, why = M.run_verdict(session, dir)
    if verdict ~= "released" then
      return nil, verdict, "the node's word about session " .. session .. " is " .. verdict
        .. " (" .. tostring(why) .. ")"
    end
    if standing and M.alive(standing) then
      return nil, "launcher", "session " .. session .. " is settled, but the runner that launched it (pid "
        .. standing .. ") is still alive, so a launch now would be a second writer in " .. M.worktree_of(dir)
    end
    return true, "released", why
  end
  if standing and M.alive(standing) then
    return nil, "launcher", "a launch is standing (pid " .. standing .. ") and has not named its session yet,"
      .. " so a launch now is a second writer in " .. M.worktree_of(dir)
  end
  return true, "released", "no session of this mission exists yet"
end

function M.start(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why } end
  local dir = M.dir(name, args.root)
  if not M.exists(dir .. "/env") then return { error = "not_staged", detail = "not staged: " .. dir .. "/env missing" } end
  if not M.exists(dir .. "/run.sh") then return { error = "no_runner", detail = "no runner at " .. dir .. "/run.sh - re-launch" } end
  if args.force then
    return { error = "force_not_supported",
      detail = "a launch is refused on the node's word; a stuck mission is cleared by hand (docs/MISSIONS.md)" }
  end
  local permitted, verdict, why = launch_permitted(dir)
  if not permitted then
    return { error = "launch_refused", state = verdict, why = why,
      clear = "wait for " .. dir .. "/done, or inspect it with: wa mission status " .. name }
  end
  local previous = nil
  if M.exists(dir .. "/done") then previous = (M.read_file(dir .. "/done") or ""):gsub("%s+$", "") end
  pcall(host.exec, "rm -f " .. string.format("%q", dir .. "/run.pid") .. " "
    .. string.format("%q", dir .. "/launch.pid"), "", 20)
  local pid, spawn_why = spawn_detached("exec bash " .. string.format("%q", dir .. "/run.sh"), dir,
    dir .. "/out.log", dir .. "/err.log")
  if not pid then return { error = spawn_why, effect = "unknown" } end
  if not M.write_file(dir .. "/launch.pid", tostring(pid) .. "\n") then
    return { error = "launcher_pid_not_recorded", pid = pid, effect = "started",
      detail = "the runner was started (pid " .. pid .. ") but its pid could not be recorded" }
  end
  -- The window closes when the runner has its run.pid or has ended, so a runner that died before writing
  -- one is a refusal instead of a "started" that launched nothing.
  local cap = tonumber(args.wait_seconds or host.getenv("MISSION_START_WAIT_SECONDS")) or M.DEFAULT_START_WAIT_SECONDS
  local step = 0
  while not M.exists(dir .. "/run.pid") and step < cap * 10 do
    if not M.alive(pid) then break end
    pcall(host.sleep, 100)
    step = step + 1
  end
  if not M.exists(dir .. "/run.pid") then
    if M.alive(pid) then
      return { error = "launcher_slow", pid = pid, waited_seconds = step / 10, effect = "started",
        detail = "the runner is alive (pid " .. pid .. ") but wrote no run.pid in " .. tostring(cap) .. "s" }
    end
    return { error = "launcher_ended", pid = pid, effect = "none",
      detail = "the runner ended before it wrote run.pid, so this was NOT a launch (94 depth guard,"
        .. " 95 wrong node, 96 cannot cd, 97 no mission dir, 98 no env)" }
  end
  -- The SESSION is named one step after run.pid: the runner writes run.lock when the CLI prints its id.
  -- 'start' reports that id, so it waits for it on the same bounded window, while the runner lives - a
  -- loaded node (land242's gate) took longer than the zero wait this used to give it, and answered
  -- "not named yet" for a session that was named a moment later.
  local session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  step = 0
  local session_cap = math.min(cap, 30)
  while not session and step < session_cap * 10 and M.alive(pid) do
    pcall(host.sleep, 100)
    step = step + 1
    session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  end
  return { ok = true, name = name, pid = pid, session = session or "not named yet",
    previous = previous, status = "wa mission status " .. name }
end

--------------------------------------------------------------------------- status
function M.one_status(name, dir)
  local status = { name = name, dir = dir }
  local env = M.read_file(dir .. "/env") or ""
  status.worktree = M.field(env, "WT") or (dir .. "/wt")
  status.branch = M.field(env, "BRANCH") or "-"
  status.base = (M.field(env, "BASE") or "-") .. " @ " .. (M.field(env, "BASE_SHA") or "-")
  local base_sha = M.field(env, "BASE_SHA")
  if base_sha and base_sha ~= "" then
    local commits = M.git(status.worktree, "rev-list --count " .. string.format("%q", base_sha .. "..HEAD"))
    status.commits = commits and tonumber((commits:gsub("%s+", ""))) or "?"
    local files = M.git(status.worktree, "diff --name-only " .. string.format("%q", base_sha) .. " HEAD")
    status.files = files and select(2, files:gsub("[^\r\n]+", "")) or "?"
  end
  local porcelain = M.git(status.worktree, "status --porcelain")
  status.dirty = porcelain and select(2, porcelain:gsub("[^\r\n]+", "")) or "?"
  local session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  status.session = session or "-"
  if session then
    local verdict, why = M.run_verdict(session, dir)
    status.run = verdict
    status.run_detail = why
  else
    status.run = "none"
    status.run_detail = "no session of this mission was ever named"
  end
  local done = M.read_file(dir .. "/done")
  status.done = done and (done:gsub("%s+$", "")) or "-"
  local standing = M.launch_standing(dir)
  status.launcher = standing and ("pid " .. standing) or "none recorded"
  local out = M.read_file(dir .. "/out.log") or ""
  local failures, last = 0, nil
  for line in out:gmatch("[^\r\n]+") do
    if line:match("^! run_failed") then failures = failures + 1; last = line end
  end
  status.failures = failures
  status.last_failure = last
  status.lock = M.exists(dir .. "/run.lock")
    and ("held (session " .. tostring(M.lock_field(dir, "SESSION") or "-") .. ")") or "none"
  local report = M.read_file(status.worktree .. "/REPORT.md")
  if report then
    status.report = status.worktree .. "/REPORT.md (" .. #report .. " bytes)"
  else
    local round = M.read_file(status.worktree .. "/docs/missions/reports/" .. name .. ".md")
    if round then status.report = status.worktree .. "/docs/missions/reports/" .. name .. ".md (" .. #round .. " bytes)" end
  end
  return status
end

function M.status(args, ctx)
  args = args or {}
  if args.name then
    local name, why = M.check_name(args.name)
    if not name then return { error = why } end
    local dir = M.dir(name, args.root)
    if not M.exists(dir) then return { error = "no_mission", detail = "no mission at " .. dir } end
    return M.one_status(name, dir)
  end
  local root = args.root or M.root()
  local listed = {}
  local ok, raw = pcall(host.exec, "ls -1 " .. string.format("%q", root) .. " 2>/dev/null", "", 30)
  if ok and type(raw) == "string" then
    local decoded_ok, decoded = pcall(json.decode, raw)
    local text = ""
    if decoded_ok and type(decoded) == "table" then text = tostring(decoded.stdout or "") end
    for line in text:gmatch("[^\r\n]+") do
      local dir = root .. "/" .. line
      if M.exists(dir .. "/env") or M.exists(dir .. "/wt") then
        local item_ok, item = pcall(M.one_status, line, dir)
        listed[#listed + 1] = item_ok and item or { name = line, error = "status_failed" }
      end
    end
  end
  return { root = root, missions = listed }
end

--------------------------------------------------------------------------- preflight
-- wa mission preflight <name>: the gate this branch will meet, run BEFORE anybody lands it (item 2 of
-- the factory round - a mission is done only when the landing's gate is green, and this is how the
-- worker's own loop finds that out without the orchestrator in the path).
--
-- The work is scripts/preflight.sh's, run as a process. One implementation, shared with the operator's
-- `bash ~/Work/missions/preflight.sh <name>`, so the verb and the script cannot disagree - and the file in
-- the missions root is a symlink to the runtime tree's copy, so an update lands both. A root without one is
-- refused by name with the command that installs it: a verb that ran a second implementation would be the
-- drift this verb exists to prevent.
--
-- effect is always none on the fleet: a preflight merges and gates, and pushes nothing anywhere.
local PREFLIGHT_SECONDS = 3600
function M.preflight(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why, effect = "none" } end
  local root = args.root or M.root()
  local dir = M.dir(name, root)
  if not M.exists(dir) then return { error = "no_mission", detail = "no mission at " .. dir, effect = "none" } end
  local script = root .. "/preflight.sh"
  if not M.exists(script) then
    local tree = args.repository or host.getenv("WA_LAND_REPO") or (host.getenv("HOME") or "") .. "/wasm-agent/checkout"
    return { error = "preflight_script_missing", detail = script .. " is not there", effect = "none",
      next_action = "install it from the runtime tree: ln -s " .. tostring(tree) .. "/scripts/preflight.sh " .. script }
  end
  local command = "bash " .. string.format("%q", script) .. " " .. string.format("%q", name)
  local called, raw = pcall(host.exec, command, dir, PREFLIGHT_SECONDS)
  if not called or type(raw) ~= "string" then
    return { error = "preflight_not_run", detail = tostring(raw), effect = "none" }
  end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then
    return { error = "preflight_answer_unreadable", effect = "none" }
  end
  local code = tonumber(decoded.code) or -1
  local report = M.read_file(dir .. "/preflight.json")
  local fields = nil
  if report then
    local parsed_ok, parsed = pcall(json.decode, report)
    if parsed_ok and type(parsed) == "table" then fields = parsed end
  end
  local result = { name = name, exit = code, effect = "none",
    preflight = (code == 0 and "green") or (code == 1 and "red") or "refused",
    report = dir .. "/preflight.json", log = dir .. "/preflight.log",
    output = tostring(decoded.stdout or "") }
  if fields then
    result.ok = fields.ok == true
    result.main_sha = fields.main_sha
    result.tree_sha = fields.tree_sha
    result.seconds = fields.seconds
    result.failed = fields.failed or {}
    result.why = fields.why
  elseif code ~= 2 then
    -- An exit code with no report is not an answer: the script writes one on every path it judges, so a
    -- missing report means it did not judge - named, never read as an empty (green) failure list.
    result.error = "preflight_no_report"
    result.detail = "no preflight.json at " .. dir .. "/preflight.json (exit " .. tostring(code) .. ")"
  end
  if code == 2 then result.error = result.error or "preflight_refused" end
  -- THE PREFLIGHT IS AN EVENT (a `mission` row in the ledger, lua/core/event_ledger.lua): green, red or
  -- refused, with the rows that made it red and the main it judged. A worker's own loop, the operator and an
  -- outside agent then read the same fact, and `wa events --follow --kind mission` shows it as it happens.
  -- Best effort: a preflight's answer must not be lost because its row could not be written.
  local recorded = pcall(function()
    local failed = {}
    for _, row in ipairs(((result.failed) or {})) do
      failed[#failed + 1] = tostring(type(row) == "table" and (row.row or row.path or row.name) or row)
    end
    return dofile("lua/core/event_ledger.lua").record({ kind = "mission", step = "preflight",
      result = result.preflight, mission = name, branch = "change/" .. name,
      sha = tostring(result.tree_sha or result.main_sha or ""),
      detail = (#failed > 0 and ("red rows: " .. table.concat(failed, ", ")))
        or tostring(result.why or ("the gate on main " .. tostring(result.main_sha or "?") .. " is " .. tostring(result.preflight))),
      source = "wa mission preflight" })
  end)
  return result
end

--------------------------------------------------------------------------- stop
-- Only the pids this mission recorded: the CLI first (so the run stops), then the runner (so it relaunches
-- nothing). Never a pattern, and nothing that a launch here did not write down.
function M.stop(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why } end
  local dir = M.dir(name, args.root)
  if not M.exists(dir) then return { error = "no_mission", detail = "no mission at " .. dir } end
  local signalled, stopped = {}, {}
  local function end_pid(path, label)
    local text = M.read_file(path)
    local pid = text and tonumber(text:match("%d+"))
    if not pid or pid <= 0 then return end
    if not M.alive(pid) then stopped[#stopped + 1] = label .. " " .. pid .. " already gone"; return end
    pcall(host.exec, "kill -TERM " .. tostring(pid) .. " 2>/dev/null", "", 20)
    signalled[#signalled + 1] = label .. " " .. pid
    local waited = 0
    while M.alive(pid) and waited < 20 do pcall(host.sleep, 200); waited = waited + 1 end
    if M.alive(pid) then
      pcall(host.exec, "kill -KILL " .. tostring(pid) .. " 2>/dev/null", "", 20)
      stopped[#stopped + 1] = label .. " " .. pid .. " did not stop on TERM; KILL sent"
    else
      stopped[#stopped + 1] = label .. " " .. pid .. " stopped"
    end
  end
  end_pid(dir .. "/run.pid", "cli")
  end_pid(dir .. "/launch.pid", "runner")
  local session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  return { name = name, signalled = signalled, stopped = stopped, session = session or "-",
    note = "stopped the pids this mission recorded; the node's run lease is read by wa mission status" }
end

--------------------------------------------------------------------------- resume
-- A HICCUP list, not "try again": a run that failed for a real reason is not resumed behind a success
-- line. FORCE overrides, and the answer says which one it was.
M.HICCUPS = "reasoning is not an answer|provider_stalled|returned no answer|first-response deadline"
  .. "|tool_call_markup_as_text|run_block_in_thinking|reasoning_only|compaction_answer|plan_only|stale_shutdown_notice"

M.RESUME_RUNNER = [==[
#!/usr/bin/env bash
# generated by wa mission resume - do not edit.
set -uo pipefail
[ -n "${WA_MISSION_CHILD:-}" ] && { echo 'mission: resume runner inside a runner (depth guard)' >&2; exit 94; }
export WA_MISSION_CHILD=1
M=$(cd "$(dirname "$0")" && pwd -P) || exit 97
cd "$M" || exit 96
# THE MISSION'S ENVIRONMENT, IN BOTH SHAPES IT ARRIVES IN (23/11, mission-resume-keeps-provider): `env` from
# `wa mission launch`, and `serve.env` from the factory's own launcher/start.sh, which copies wa-serve's
# environment. This used to be `. "$M/env"` alone and `wa mission resume` refused a factory mission as
# not_staged. `set -a` is what carries the file's provider settings to the CLI: a sourced line is a shell
# variable, and a child only sees exported ones.
set -a
env_files=0
for env_file in "$M/env" "$M/serve.env"; do
  [ -r "$env_file" ] || continue
  . "$env_file" || { printf 'mission: %s could not be sourced\n' "$env_file" >&2; exit 98; }
  env_files=$((env_files + 1))
done
set +a
[ "$env_files" -gt 0 ] || { printf 'mission: neither %s/env nor %s/serve.env exists, so a resumed turn would start with no provider settings\n' "$M" "$M" >&2; exit 99; }
unset WASM_AGENT_RAW_CODE  # native run(code=...) is the one execution path (Victor 21/11); never inherit another
[ -n "${TOOLCHAIN:-}" ] && { export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"; export PATH="$TOOLCHAIN/cargo/bin:$PATH"; }
[ -n "${TARGET:-}" ] && export CARGO_TARGET_DIR="$TARGET"
# The mission's own wa when its environment names one, PATH otherwise: a factory mission's serve.env carries
# no WA, and an empty command is how a resume turns into "nothing happened, quietly".
WA=${WA:-$(command -v wa 2>/dev/null || true)}
[ -n "$WA" ] || { printf 'mission: no wa to resume with: neither env nor PATH names one\n' >&2; exit 93; }
ulimit -c 0 2>/dev/null || true
ulimit -n 8192 2>/dev/null || true
sid=$1; rc=1
rm -f "$M/done"
for try in $(seq 1 25); do
  echo "--- resume $try of $sid $(date -u +%FT%TZ)" >> "$M/out.log"
  step=${WA_DEPLOY_WAIT_STEP:-15}; case "$step" in ''|*[!0-9]*|0) step=15 ;; esac
  limit=${WA_DEPLOY_WAIT_LIMIT:-900}; case "$limit" in ''|*[!0-9]*) limit=900 ;; esac
  waited=0
  while :; do
    "$WA" chat --resume "$sid" --once "${MSG:-[orchestrator] Your last response ended without an answer or action. Continue exactly where you stopped.}" >> "$M/out.log" 2>> "$M/err.log"; rc=$?
    # A REFUSED TURN IS NOT A TRY (22/11): exit 2 with `deploy_waiting` means a build is waiting for or
    # installing on this node, so nothing was asked and nothing answered. Wait and ask again rather than
    # spending one of the 25 tries on a wait; past the limit the refusal stands as rc=2 and the line says why.
    [ "$rc" -eq 2 ] && tail -c 4000 "$M/out.log" 2>/dev/null | grep -q deploy_waiting || break
    if [ "$waited" -ge "$limit" ]; then
      echo "deploy-wait gave up after ${waited}s: the node is still waiting for or installing a build, so this resume never ran" >> "$M/out.log"
      break
    fi
    sleep "$step"
    waited=$((waited + step))
    echo "deploy-wait the node is waiting for or installing a build: asking again (${waited}s of ${limit}s)" >> "$M/out.log"
  done
  [ $rc -eq 0 ] && tail -c 3000 "$M/out.log" | grep -q "</turn>" && break
  tail -c 3000 "$M/out.log" | grep -qE "reasoning is not an answer|provider_stalled|returned no answer|first-response deadline|tool_call_markup_as_text|run_block_in_thinking|reasoning_only|compaction_answer|plan_only|stale_shutdown_notice" || break
  sleep 15
done
echo "rc=$rc $(date -u +%FT%TZ)" > "$M/done"
exit $rc
]==]

function M.resume(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why } end
  local dir = M.dir(name, args.root)
  -- THE MISSION IS STAGED WHEN IT HAS AN ENVIRONMENT A TURN CAN RUN IN, in either shape (23/11): `env` from
  -- `wa mission launch` here, or `serve.env` from the factory's own start.sh. Refusing on `env` alone made a
  -- factory mission unresumable BY THE CLI, and the runner that did start answered "No provider is configured".
  if not M.exists(dir .. "/env") and not M.exists(dir .. "/serve.env") then
    return { error = "not_staged", detail = "not staged: neither " .. dir .. "/env nor " .. dir .. "/serve.env is there" }
  end
  local standing = M.launch_standing(dir)
  if standing and M.alive(standing) then
    return { error = "launch_refused", state = "launcher", why = "a launch is standing (pid " .. standing .. ")" }
  end
  local session = M.lock_field(dir, "SESSION") or M.recorded_session(dir)
  if not session then return { error = "no_session", detail = "no session id recorded for " .. name } end
  local verdict, verdict_why = M.run_verdict(session, dir)
  if verdict == "active" then
    return { error = "launch_refused", state = "active", why = "the node holds a live run for session " .. session }
  end
  if verdict == "unknown" then
    -- UNKNOWN IS NOT YES (the rule every other verb here keeps): a resume beside a run nobody can vouch for is
    -- a second writer in one worktree, so it refuses by name and says what to read.
    return { error = "run_unknown", state = "unknown", session = session,
      why = "the node does not say that run is settled (" .. tostring(verdict_why) .. ")",
      next_action = "wa steer " .. session .. " --status" }
  end
  if not args.force then
    local out = M.read_file(dir .. "/out.log") or ""
    if not out:sub(math.max(1, #out - 3000)):find(M.HICCUPS) then
      return { error = "not_a_hiccup", state = "refused",
        why = "this session did not stop on a resumable fault (force overrides)" }
    end
  end
  local ok, why = M.write_file(dir .. "/resume-run.sh", M.RESUME_RUNNER)
  if not ok then return { error = "cannot_write_runner", detail = why } end
  local pid, spawn_why = spawn_detached(string.format("exec env MSG=%q bash %q %q",
    tostring(args.message or args.msg or ""), dir .. "/resume-run.sh", session), dir,
    dir .. "/out.log", dir .. "/err.log")
  if not pid then return { error = spawn_why, effect = "unknown" } end
  M.write_file(dir .. "/launch.pid", tostring(pid) .. "\n")
  -- "RESUMED" IS A CLAIM ABOUT A TURN, NOT ABOUT A PID (23/11, the same rule scripts/mission.sh amend keeps):
  -- a missing session fails here by name, and so does a runner that exited before the turn began - the CLI's
  -- own words are quoted back instead of a success line (measured: "No provider is configured and nothing in
  -- memory matched", with no model request at all).
  local start = #(M.read_file(dir .. "/out.log") or "")
  local step = 0
  while step < 600 do
    local fresh = (M.read_file(dir .. "/out.log") or ""):sub(start + 1)
    if fresh:find("no such session", 1, true) then
      return { error = "session_not_found", session = session, detail = "the CLI did not find this session" }
    end
    -- A COMPLETED ANSWER IS THE PROOF, NOT THE CLI'S "Thinking" LINE (23/11): "Thinking" is printed when the
    -- model request STARTS (measured in scripts/test-mission-amend-resume.mjs), so a turn whose provider answers
    -- nothing prints it and fails - the false "resumed" this file already records on 23/11. `</turn>` is the
    -- answer itself, and the run lease is the node's own word.
    if fresh:find("</turn>", 1, true) then
      return { ok = true, resumed = session, pid = pid }
    end
    if step % 5 == 0 then
      local verdict = select(1, M.run_verdict(session, dir))
      if verdict == "active" then return { ok = true, resumed = session, pid = pid } end
    end
    if not M.alive(pid) then
      local last_out, last_err = "", ""
      for line in fresh:gmatch("[^\r\n]+") do if line:match("%S") then last_out = line end end
      for line in (M.read_file(dir .. "/err.log") or ""):gmatch("[^\r\n]+") do if line:match("%S") then last_err = line end end
      local done = ""
      for line in (M.read_file(dir .. "/done") or ""):gmatch("[^\r\n]+") do if line:match("%S") then done = line end end
      return { error = "resume_failed", session = session, pid = pid, exit = done,
        detail = "the runner exited before any turn started (done: " .. done .. "); out.log: " .. last_out
          .. " | err.log: " .. last_err }
    end
    pcall(host.sleep, 100); step = step + 1
  end
  return { error = "resume_unconfirmed", session = session, pid = pid,
    detail = "the runner is running but no turn has started yet; watch " .. dir .. "/out.log" }
end

--------------------------------------------------------------------------- amend
-- A CHANGE INTO A WORKER THAT IS ALREADY RUNNING, as one verb: THE SAME CODE as `scripts/mission.sh amend`
-- (docs/MISSIONS.md 4b), never a second implementation - the script carries the measured rules (append with a
-- UTC stamp, deliver through the product's own steering, resume a settled worker, and say "resumed" only once a
-- turn is seen running). This function is the door: it finds that script, runs it, and returns its exit code and
-- its words unchanged.
--
-- WHERE THE SCRIPT IS, in this order (an allow-list, and nothing found is a refusal by name):
--   * an explicit `--script <path>` - a path the operator named is the path, so a missing one is refused;
--   * `<missions root>/mission.sh` - the operator's installed copy, beside preflight.sh, exactly the way this
--     file's preflight verb already finds its script;
--   * `<runtime tree>/scripts/mission.sh`, the tree being WASM_AGENT_LUA_ROOT, then WA_LAND_REPO, then
--     ~/wasm-agent/checkout - the tree the running binary was built from.
-- THE MISSION'S OWN BINARY IS NAMED (WA_BIN): the script asks the node through `wa steer`, and the PATH a
-- child of host.exec gets is the one the node was started with - measured 21/11, a serve unit started with a
-- bare environment had no `wa` on it at all (every mission died with "wa: command not found"). Naming the
-- binary removes the lookup: `host.runtime_info().binary_path` is the CLI running this verb.
M.AMEND_SECONDS = 600

function M.amend_script(root, explicit)
  if explicit and explicit ~= "" then
    local path = tostring(explicit)
    if M.read_file(path) then return path end
    return nil, path .. " (named with --script, and it cannot be read)"
  end
  local candidates = { root .. "/mission.sh" }
  local tree = host.getenv("WASM_AGENT_LUA_ROOT")
  if not tree or tree == "" then tree = host.getenv("WA_LAND_REPO") end
  if not tree or tree == "" then tree = (host.getenv("HOME") or "") .. "/wasm-agent/checkout" end
  candidates[#candidates + 1] = tree .. "/scripts/mission.sh"
  for _, path in ipairs(candidates) do
    if M.read_file(path) then return path end
  end
  return nil, table.concat(candidates, ", ")
end

function M.amend(args, ctx)
  args = args or {}
  local name, name_why = M.check_name(args.name)
  if not name then return { error = name_why, effect = "none" } end
  local root = args.root or M.root()
  local dir = M.dir(name, root)
  if not M.exists(dir) then return { error = "no_mission", detail = "no mission at " .. dir, effect = "none" } end
  local script, why = M.amend_script(root, args.script)
  if not script then
    return { error = "amend_script_missing", effect = "none", detail = "no mission.sh among: " .. tostring(why),
      next_action = "install it from the runtime tree: ln -s <runtime tree>/scripts/mission.sh " .. root .. "/mission.sh" }
  end
  local path, temporary = args.file, nil
  if (not path or path == "") and args.text and tostring(args.text):match("%S") then
    temporary = dir .. "/amend-input.txt"
    local wrote, write_why = M.write_file(temporary, tostring(args.text) .. "\n")
    if not wrote then return { error = "cannot_write_amendment", detail = tostring(write_why), effect = "none" } end
    path = temporary
  end
  if not path or path == "" then
    return { error = "file_required", effect = "none",
      detail = "usage: wa mission amend <name> <file> | wa mission amend <name> --text <words>" }
  end
  local binary = args.wa
  if (not binary or binary == "") and host.runtime_info then
    local ok, raw = pcall(host.runtime_info)
    if ok then
      local decoded_ok, info = pcall(json.decode, type(raw) == "string" and raw or json.encode(raw))
      if decoded_ok and type(info) == "table" and type(info.binary_path) == "string" and info.binary_path ~= "" then
        binary = info.binary_path
      end
    end
  end
  local command = "MISSIONS_DIR=" .. string.format("%q", root)
  if binary and binary ~= "" then command = command .. " WA_BIN=" .. string.format("%q", binary) end
  command = command .. " bash " .. string.format("%q", script) .. " amend " .. string.format("%q", name)
    .. " " .. string.format("%q", path)
  local called, raw = pcall(host.exec, command, dir, M.AMEND_SECONDS)
  if temporary then pcall(host.exec, "rm -f " .. string.format("%q", temporary), "", 20) end
  if not called or type(raw) ~= "string" then return { error = "amend_not_run", detail = tostring(raw), effect = "unknown" } end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then
    return { error = "amend_answer_unreadable", effect = "unknown" }
  end
  local code = tonumber(decoded.code) or -1
  local text = tostring(decoded.stdout or "")
  local problems = tostring(decoded.stderr or "")
  local result = { name = name, exit = code, script = script, file = path, output = text, errors = problems }
  if code ~= 0 then
    -- THE SCRIPT'S OWN WORDS, unchained: a refusal and a failed resume are its sentences, and they name what to
    -- fix. The exit code is the script's, so a shell caller reads the same number it would from the script.
    local why = problems:match("([^\r\n]+)[\r\n]*$") or text:match("([^\r\n]+)[\r\n]*$") or ""
    result.error = "amend_failed"
    result.why = why
  end
  return result
end

return M
