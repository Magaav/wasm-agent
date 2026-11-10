-- Remote update: admit a master, refuse a guest, record who asked and for what commit, and hand the
-- outcome back to the requesting session exactly once.
--
-- The shape this exists for was measured on 2026-11-10, from `wasm_the_first`: no install could cross
-- a node boundary. `wa update <peer>` and `wa-sentinel request deploy` were both refused, because a
-- relayed shell on the peer carries `WASM_AGENT_PROVENANCE=child` - correctly, a child task may not
-- ask for an install. `lua/core/remote_update.lua` is the door that replaces the shell: a signed
-- master request, executed by the peer's own node process, which then writes the request the peer's
-- own `/update` writes.
--
-- What is proved here, one check at a time:
--   * a guest is refused (and nothing is written or executed);
--   * a master is admitted, the peer's tree is fast-forwarded to the named landed commit, and exactly
--     ONE `request deploy` is handed to the peer's own Sentinel - with `--if-no-pending`;
--   * a commit that is not on origin/main, a tree that cannot fast-forward, and a dirty tree are each
--     refused by name, with the audit record still written;
--   * the audit line names the requesting node, its id and the target commit, on the peer;
--   * the outcome is read from the peer's own durable files (`installed.txt`, the installer's
--     `deploy-result.json`, the sentinel's `done/`), reports the PREBUILT binary when that is what was
--     installed, and reaches the requesting session as `notice=true` exactly once;
--   * `--rendezvous` writes the wrapper the sentinel's `request run` can execute and issues that door;
--   * `wa update` with no node named is untouched (the local path is still the local path).
--
-- The fixture is a real directory under this run's home (the fast path gives every Lua test a scratch
-- home), so the module's own file writes are exercised rather than imitated. Only two things are
-- scripted: `git` (there is no repository here) and the peer's `wa-sentinel` (there is no watcher).
--
--   WA_SCRIPT=scripts/test-remote-update.lua wa --db /tmp/wa-remote-update.db
--
-- Prints `remote update ok`; a failed check raises, so the gate reads a verdict and not a summary.

local json = dofile("lua/vendor/json.lua")
local real_host = host
local records_root = host.paths().home .. "/remote-update-fixture/config/remote-update"
local fixture = host.paths().home .. "/remote-update-fixture"
local config = fixture .. "/config"
local install = fixture .. "/install"
local sentinel_dir = config .. "/sentinel"
local tree = fixture .. "/tree"

local BASE = string.rep("1", 40)
local TARGET = string.rep("2", 40)
local NEWER = string.rep("3", 40)

-- ---- the host the module is given ----------------------------------------------------------------
--
-- Files are real (fixture paths under this run's home). `git` answers from the scripted repository
-- state below; the sentinel answers as a running watcher whose `request` verbs name a request file,
-- which is exactly what the real one prints.

local issued, log_lines = {}, {}
local head = BASE
local origin_main = TARGET
local ancestor = { [TARGET] = true, [BASE] = true }
local ff_fails = false
local dirty = ""
local sentinel_pid = 4242

local function escaped(text)
  return (tostring(text or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

local function wrapper(code, stdout, stderr)
  return '{"code":' .. tostring(code) .. ',"stdout":"' .. escaped(stdout) .. '","stderr":"' .. escaped(stderr) .. '"}'
end

local function listing(dir)
  local result = real_host.exec and real_host.exec("ls -1 \"" .. dir .. "\" 2>/dev/null", "")
  if type(result) ~= "string" then return "" end
  local ok, decoded = pcall(json.decode, result)
  return (ok and decoded and decoded.stdout) or ""
end

local function git_answer(command)
  if command:find("fetch", 1, true) and command:find(" fetch ", 1, true) then return wrapper(0, "", "") end
  if command:find("merge%-base %-%-is%-ancestor") then
    -- The first quoted word is the tree (`git -C '<tree>'`); the commit under test comes after the verb.
    local target = (command:match("is%-ancestor (.*)") or ""):match("'([^']+)'")
    return wrapper(ancestor[target] and 0 or 1, "", "")
  end
  if command:find("merge %-%-ff%-only") then
    if ff_fails then return wrapper(1, "", "fatal: Not possible to fast-forward, aborting.") end
    local target = (command:match("%-%-ff%-only %-%-quiet (.*)") or ""):match("'([^']+)'")
    head = target or head
    return wrapper(0, "", "")
  end
  if command:find("status %-%-porcelain") then return wrapper(0, dirty, "") end
  local spec = command:match("rev%-parse '([^']+)'")
  -- `lua/core/update.lua` asks unquoted (`rev-parse --short HEAD`, `rev-parse HEAD`); this module asks
  -- quoted. Both are the same question.
  if not spec then spec = command:match("rev%-parse (%-%-short HEAD)") end
  if not spec then spec = command:match("rev%-parse (HEAD)") end
  if not spec then spec = command:match("rev%-parse (origin/main)") end
  if spec then
    if spec == "origin/main" then return wrapper(0, origin_main .. "\n", "") end
    if spec == "HEAD" then return wrapper(0, head .. "\n", "") end
    if spec == "--short HEAD" then return wrapper(0, head:sub(1, 7) .. "\n", "") end
    local commit = spec:gsub("%^%{commit%}$", "")
    if ancestor[commit] or commit == NEWER then return wrapper(0, commit .. "\n", "") end
    return wrapper(128, "", "unknown revision " .. commit)
  end
  return nil
end

host = {
  platform = function() return real_host.platform() end,
  paths = function() return real_host.paths() end,
  getenv = function(name) return os.getenv(name) end,
  now = function() return os.time() end,
  uuid = function() return "fixture-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) end,
  node_identity = function() return json.encode({ node_id = "peer-node-id", public_key = string.rep("ab", 32) }) end,
  read_file = function(path) return real_host.read_file(path) end,
  write_file = function(path, text) return real_host.write_file(path, text) end,
  exec = function(command, cwd)
    issued[#issued + 1] = command
    local answer = git_answer(command)
    if answer then return answer end
    if command:find(" preflight", 1, true) then
      return wrapper(0, json.encode({
        schema = 1, watcher = "running", watcher_pid = sentinel_pid, ownership = "watcher_lifetime_lock",
        stop_file = false, pending_deploys = {}, inventory_verified = true,
        capabilities = { health_free = true, atomic_deploy_dedupe = true },
      }), "")
    end
    if command:find(" request deploy", 1, true) then
      return wrapper(0, "  requested deploy: " .. sentinel_dir .. "/requests/1700000000-11.json\n", "")
    end
    if command:find(" request run", 1, true) then
      return wrapper(0, "  requested run: " .. sentinel_dir .. "/requests/1700000000-22.json\n", "")
    end
    if command:find("chmod %+x", 1) then return wrapper(0, "", "") end
    if command:find("^ls %-1t ", 1) then return wrapper(0, listing((command:match("^ls %-1t '([^']+)'") or "")), "") end
    -- `test -s` and anything else the module asks about this machine: answered for real.
    return real_host.exec(command, cwd)
  end,
}
setmetatable(host, { __index = function(_, key) return real_host[key] end })

-- One audit line per admit/refuse/settle, captured the way the node captures its own log.
emit = function(event)
  if type(event) == "table" and event.message then log_lines[#log_lines + 1] = tostring(event.message) end
end

local remote = dofile("lua/core/remote_update.lua")
-- The records live under this fixture, not under this node's real config: the test must be able to
-- write and read them without touching the machine it runs on.
remote.records_root = records_root
remote.facts_options = { install = install, sentinel_dir = sentinel_dir }

-- ---- the fixture --------------------------------------------------------------------------------

local MASTER = { role = "master", node_id = "master-node-id", public_key = string.rep("cd", 32),
  name = "wasm_the_first", mesh = "roster", level = 0 }
local GUEST = { role = "guest", node_id = "guest-node-id", public_key = string.rep("ef", 32), name = "a-guest" }

local function put(path, text)
  assert(host.write_file(path, text) == true, "fixture write failed: " .. path)
end

put(install .. "/runtime-worktree.txt", tree .. "\n")
put(install .. "/installed.txt", "commit=" .. BASE .. "\nbranch=main\n")
put(install .. "/wa-sentinel", "#!/bin/sh - the fixture's sentinel\n")
-- The name `update.lua` looks for is the platform's (wa-sentinel.exe on Windows); both are written so
-- this test means the same thing whichever host runs it.
put(install .. "/wa-sentinel.exe", "#!/bin/sh - the fixture's sentinel\n")
put(sentinel_dir .. "/sentinel.pid", tostring(sentinel_pid) .. "\n")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""), 2) end
  print("  ok: " .. label)
end

local function issued_matching(fragment)
  local found = {}
  for _, command in ipairs(issued) do if command:find(fragment, 1, true) then found[#found + 1] = command end end
  return found
end

local function record_of(id)
  local ok_read, text = pcall(host.read_file, records_root .. "/" .. id .. ".json")
  if not ok_read or type(text) ~= "string" then return nil end
  local decoded_ok, value = pcall(json.decode, text)
  return (decoded_ok and type(value) == "table") and value or nil
end

-- ---- 0. the capability is WIRED, not only implemented --------------------------------------------
-- Measured 2026-11-10 (openclaw, 3ea2917f): the branch that serves `update` in
-- lua/core/server.lua was added with its comment and WITHOUT the line that calls this module, so
-- every remote update answered `plugin_not_found:update` - the call fell through to the plugin
-- dispatcher. This test calls the module directly, so it was green; nothing here could see the
-- wiring. These two checks read the server the way the node loads it: the branch must return this
-- module, and the capability must be named in the managed allow-list (else a bound peer answers
-- `capability_not_granted` before the branch is reached).
local server_source = host.read_file("lua/core/server.lua") or ""
local lines = {}
for line in server_source:gmatch("%C+") do lines[#lines + 1] = line end
local branch = nil
for index, line in ipairs(lines) do
  if line:find('elseif capability == "update" then', 1, true) then branch = index break end
end
ok(branch ~= nil, "lua/core/server.lua has an `update` branch in node_capability")
local call
for index = (branch or 0) + 1, #lines do
  local line = lines[index]
  if line:match("^%s*%-%-") then
    -- a comment is not a statement; keep looking
  else
    call = line
    break
  end
end
ok(call ~= nil and call:find('return dofile("lua/core/remote_update.lua").serve(args, caller)', 1, true) ~= nil,
  "and its first statement hands the call to this module (a comment alone is an empty block, and Lua accepts it)",
  tostring(call))
ok(server_source:find("update=true", 1, true) ~= nil,
  "the capability is named in the managed allow-list a bound peer checks first")
ok(server_source:find('MESH_VERBS', 1, true) ~= nil and server_source:find("update = true", 1, true) == nil,
  "and it is NOT classified in MESH_VERBS, so a roster attestation grades it `call`")

-- ---- 1. a guest is refused, and nothing happens -------------------------------------------------
issued = {}
local refused = remote.serve({ action = "request", commit = TARGET }, GUEST)
ok(refused and refused.error == "forbidden_role", "a guest is refused", refused and refused.error)
ok(#issued_matching("request deploy") == 0, "and no install was asked for")
ok(#issued_matching("git") == 0, "and the guest could not even move this node's tree")
ok(head == BASE, "the tree did not move for a guest")

-- ---- 2. a master is admitted, and the peer's own installer door is used -------------------------
issued, log_lines = {}, {}
local admitted = remote.serve({ action = "request", commit = TARGET, reason = "the fabric update test",
  session = "session-1" }, MASTER)
ok(admitted and admitted.ok == true and admitted.status == "queued", "a master is admitted",
  admitted and (admitted.error or admitted.status))
ok(head == TARGET, "the peer's tree is at the requested landed commit", head)
ok(admitted.record ~= nil and admitted.record ~= "", "the answer names an audit record")
local deploy_calls = issued_matching("request deploy")
ok(#deploy_calls == 1, "exactly one deploy request was written", tostring(#deploy_calls))
ok(deploy_calls[1]:find("--if-no-pending", 1, true) ~= nil, "and it dedupes like the local /update")
ok(deploy_calls[1]:find("the fabric update test", 1, true) ~= nil, "and it carries the reason the master gave")
ok(#issued_matching("preflight") >= 1, "the peer's own watcher was proved before queueing")

-- ---- 3. the audit line names the requester, its id and the target commit ------------------------
local record = record_of(admitted.record)
ok(record ~= nil, "the audit record was written on the peer")
ok(record.requester.node_id == MASTER.node_id, "it names the requesting node's id", record.requester.node_id)
ok(record.requester.name == MASTER.name, "and its name", record.requester.name)
ok(record.requester.basis == "roster", "and the basis it was admitted on", record.requester.basis)
ok(record.requester.session == "session-1", "and the requesting session", record.requester.session)
ok(record.target_commit == TARGET, "and the target commit", record.target_commit)
ok(record.state == "queued" and record.door == "deploy", "and which door performed it", record.door)
local audited = false
for _, line in ipairs(log_lines) do
  if line:find("remote-update admitted", 1, true) and line:find(MASTER.node_id, 1, true)
    and line:find(TARGET:sub(1, 12), 1, true) then audited = true end
end
ok(audited, "the audit LINE carries the requester id and the commit prefix")
ok(#log_lines == 1, "one line per admitted request, not a stream", tostring(#log_lines))

-- ---- 4. a commit that is not on main, a tree that cannot fast-forward, a dirty tree -------------
issued = {}
local not_landed = remote.serve({ action = "request", commit = NEWER }, MASTER)
ok(not_landed.error == "commit_not_on_main", "a commit that is not on origin/main is refused", not_landed.error)
ok(#issued_matching("request deploy") == 0, "and nothing was queued for it")
ok(not_landed.audit_id ~= nil and record_of(not_landed.audit_id) ~= nil, "the refusal is recorded too")

head = BASE
ff_fails = true
local unreachable = remote.serve({ action = "request", commit = TARGET }, MASTER)
ok(unreachable.error == "commit_not_reachable", "a tree that cannot fast-forward is refused", unreachable.error)
ok(#issued_matching("request deploy") == 0, "and nothing was queued for it either")
ff_fails = false
head = TARGET
dirty = " M lua/core/update.lua\n"
local dirty_refusal = remote.serve({ action = "request", commit = TARGET }, MASTER)
ok(dirty_refusal.error == "tree_dirty", "a dirty tree is refused, as the gate refuses it", dirty_refusal.error)
dirty = ""

-- ---- 5. the outcome comes back from the peer's own files, and says PREBUILT ---------------------
-- The installer's own verdict for this exact request id, in the install directory, and an install
-- record that names the requested commit with the prebuilt release it came from.
put(install .. "/deploy-result.json", json.encode({ ok = true, commit = TARGET:sub(1, 8),
  request_id = record.sentinel_request_id, detail = "installed " .. TARGET:sub(1, 8), at = os.date("!%Y-%m-%dT%H:%M:%SZ") }))
put(install .. "/installed.txt", "commit=" .. TARGET .. "\nbranch=main\nbinary_source=prebuilt-release\nbinary_release=node-" .. TARGET:sub(1, 12) .. "\n")

local peer_status = remote.serve({ action = "status", id = admitted.record }, MASTER)
ok(peer_status.ok == true and peer_status.state == "installed", "status reads it as installed", peer_status.state)
ok(peer_status.verified == true, "and says it is verified by installed.txt")
ok(peer_status.installed_binary and peer_status.installed_binary.source == "prebuilt-release",
  "and names the prebuilt release that was installed", peer_status.installed_binary and peer_status.installed_binary.source)
ok(record_of(admitted.record).outcome == "installed", "the peer's record settled once, in place")

-- Another master's record is not readable through this node's id.
local stranger = remote.serve({ action = "status", id = admitted.record },
  { role = "master", node_id = "another-master", name = "elsewhere" })
ok(stranger.error == "not_your_record", "a record is readable by the node that asked for it", stranger.error)

-- ---- 6. one outcome notice, back to the requesting session -------------------------------------
-- The master half speaks to the peer through the same signed call the fabric uses; here that call is
-- this node answering itself, so the notice path is exercised end to end rather than imitated.
local function loopback(selector, capability, args)
  assert(capability == "update", "the master must call the update capability")
  return remote.serve(args, MASTER)
end

local asked = remote.request(loopback, "peer", { commit = TARGET, reason = "notice test", session = "session-1" })
ok(asked.ok == true and asked.record ~= nil, "the master's request returns the peer's record id")
local pending = remote.pending(asked.record)
ok(pending ~= nil and pending.session == "session-1", "the master remembers which session asked",
  pending and pending.session)

local first = remote.status(loopback, "peer", { id = asked.record, session = "session-1" })
ok(first.state == "installed", "status reports the settled state", first.state)
ok(first.notice == true and first.notice_text ~= nil, "the first read hands the outcome to the requesting session")
ok(first.notice_text:find("installed", 1, true) ~= nil, "and the notice says what happened", first.notice_text)
local second = remote.status(loopback, "peer", { id = asked.record, session = "session-1" })
ok(second.state == "installed" and second.notice == false, "a second read does not tell the session twice")
local other_session = remote.status(loopback, "peer", { id = asked.record, session = "session-99" })
ok(other_session.notice == false, "and a different session is not handed someone else's notice")
ok(remote.pending(asked.record).notified_at ~= nil, "the delivery is recorded, not inferred")

-- ---- 7. the rendezvous door ---------------------------------------------------------------------
-- `request run` takes a script and no arguments, so the arguments live in a wrapper written into a
-- directory this node's sentinel may execute from (`WA_SENTINEL_SCRIPTS`).
local scripts_dir = install .. "/scripts"
put(scripts_dir .. "/.keep", "")
local previous_scripts = os.getenv("WA_SENTINEL_SCRIPTS")
local scripts_env = scripts_dir
host.getenv = function(name)
  if name == "WA_SENTINEL_SCRIPTS" then return scripts_env end
  return os.getenv(name)
end
issued = {}
local rendezvous = remote.serve({ action = "request", rendezvous = true, commit = TARGET, reason = "rendezvous test" }, MASTER)
ok(rendezvous.ok == true and rendezvous.kind == "rendezvous", "the rendezvous door is admitted",
  rendezvous and (rendezvous.error or rendezvous.kind))
local run_calls = issued_matching("request run")
ok(#run_calls == 1, "and exactly one run request was written", tostring(#run_calls))
local wrapper_path = run_calls[1] and run_calls[1]:match("%-%-script '([^']+)'")
ok(wrapper_path ~= nil and wrapper_path:find((scripts_dir:gsub("\\", "/")), 1, true) == 1,
  "the script is inside a directory WA_SENTINEL_SCRIPTS names", wrapper_path)
local wrapper_text = wrapper_path and host.read_file(wrapper_path) or ""
ok(wrapper_text:find("deploy-rendezvous.sh", 1, true) ~= nil, "the wrapper calls the supported script")
ok(wrapper_text:find(TARGET, 1, true) ~= nil, "with the exact landed commit")
ok(wrapper_text:find(MASTER.name, 1, true) ~= nil or wrapper_text:find("rendezvous test", 1, true) ~= nil,
  "and a reason that names who asked")
-- A finished rendezvous deploy: the sentinel's own run record is the outcome.
put(sentinel_dir .. "/done/1700000000-22.json", json.encode({ at = os.time(), ok = true, phase = "completed",
  detail = "rendezvous installed " .. TARGET:sub(1, 8) }))
local rendezvous_status = remote.serve({ action = "status", id = rendezvous.record }, MASTER)
ok(rendezvous_status.state == "installed", "the run record settles the rendezvous request", rendezvous_status.state)
-- A node whose sentinel has no script directory refuses by name rather than queueing something that
-- cannot run. (`host.getenv` here reports the node's own `WA_SENTINEL_SCRIPTS`; the test controls it so
-- both answers are reachable.)
scripts_env = ""
local unconfigured = remote.serve({ action = "request", rendezvous = true, commit = TARGET }, MASTER)
ok(unconfigured.error == "rendezvous_scripts_unconfigured", "an unconfigured run door is refused by name",
  tostring(unconfigured.error) .. " / " .. tostring(unconfigured.observed))
scripts_env = scripts_dir
host.getenv = real_host.getenv

-- ---- 8. `wa update` with no node still means this node -----------------------------------------
ok(remote.cli({ "update", "--check" }) == nil, "`wa update --check` is not the remote form")
ok(remote.cli({ "update" }) == nil, "`wa update` is not the remote form")
ok(remote.cli({ "update", "peer", "--bogus" }) == 1, "an unknown option is refused without asking anyone")
ok(remote.cli({ "update", "peer", "--help" }) == 0, "and asking what the remote form does writes nothing")

print(string.format("remote update ok (%d checks)", checks))
