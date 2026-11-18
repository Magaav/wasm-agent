-- Update another node from distance, by the node's own installer.
--
-- The operator's decision (2026-11-10): "we should be able to install from distance, that is the
-- intent of fabric ... allow openclaw to be updated by distance". Measured the same day, from
-- `wasm_the_first`: nothing from here could install anything anywhere else. `wa update` and
-- `wa-sentinel request deploy` were both refused with `*_coordinator_only`, because a *relayed
-- shell* on the peer carries `WASM_AGENT_PROVENANCE=child` - the peer correctly refuses an install
-- asked for by a child task, and a remote `bash` is exactly that.
--
-- So the door is not a shell. It is a capability the peer admits the way it admits every other peer
-- call: a signed request from a node the roster and the binding already trust, executed by the
-- peer's own node process - not by a process it spawned. What is admitted is therefore *a signed
-- master request*, not any child shell: the child-provenance refusal stays exactly as it is, and a
-- master that has not been granted this peer still cannot ask it to install anything.
--
-- This module has two halves and they run on different nodes:
--
--   peer half   `serve(args, caller)` - called from `lua/core/server.lua`'s `node_capability` for
--               capability `update`. It refuses a guest, writes one audit record naming the
--               requesting master and the target commit, moves the peer's runtime tree to the
--               requested commit (a fast-forward of a landed commit, never a reset), and then hands
--               the install to the peer's own machinery (`lua/core/update.lua`): the same
--               preconditions the local `/update` uses (a verified watcher, no stop file, no deploy
--               already waiting), the same pre-update backup, and one `wa-sentinel request deploy`
--               written into the peer's own sentinel box. The peer's Sentinel performs it under its
--               existing rules - prebuilt binary when the commit is covered, disk floor, deploy
--               lock, one outcome record. This module installs nothing itself.
--
--               `--rendezvous` asks for the registry where the node runs one: the tree is moved to
--               the same landed commit and the peer's Sentinel performs `scripts/deploy-rendezvous.sh`
--               through `request run`, which is the supported path that script was written for
--               (it refuses a run, and requires HEAD == origin/main == the full commit it is given).
--
--   master half `request` / `status` - the master sends one signed call and keeps the record id it
--               gets back (`<config>/remote-update/requests/<id>.json`). `status` reads the peer's
--               record and the peer's durable outcome files (the sentinel's `done/`, `failed/`,
--               the installer's own `deploy-result.json` and `installed.txt`, and the
--               `deploy-outcome` ledger when one was opened) and answers with what is installed.
--               It reports a settled outcome ONCE per request per session (`notice`), so a caller
--               that asks twice is not told twice.
--
-- Why the notice lands on the master and not on the peer's sentinel. The sentinel's report is a
-- `wake` request in *its own* request box, which wakes a session *on that node*. A master's
-- session lives somewhere else, and a peer below the master may not call up (docs/MESH.md: a node
-- may call and control nodes at its own level or below). So the peer keeps the durable record and
-- the master's own loop carries the notice: the `node_update` tool schedules one self-wake
-- (`lua/core/selfloop.lua`, the harness's own mechanism) and `status` hands the outcome over
-- exactly once. Nothing here pretends a peer session reported back.
--
-- Authority is the node's existing one. `serve` refuses anyone `lua/core/nodes.lua`'s `author_of`
-- does not name as a master, and the capability is not classified in `server.lua`'s `MESH_VERBS`,
-- so a mesh attestation grades it `call` - the strongest grant, which is the right price for
-- installing a runtime - rather than inheriting a weaker verb.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local nodes = dofile('lua/core/nodes.lua')
local update = dofile('lua/core/update.lua')
-- The pins store (lua/core/pins.lua): a node held where an operator put it is not a node to move forward.
local pins = dofile('lua/core/pins.lua')

local M = {}

M.CAPABILITY = 'update'
-- 'unpin' is the peer half of `wa update <node> --unpin`: the node's OWN pin store is the one that gates
-- the installs started on it, and a release that only cleared the coordinator's copy left the node refusing
-- every install with "node_pinned" while the operator had been told it was free (round-3 item 5).
M.ACTIONS = { 'request', 'status', 'check', 'unpin' }

-- Where a peer keeps the audit record and the outcome of each remote request. One file per
-- request, named after the record id the master is given back: a record that two processes write
-- at once would be a record nobody can trust, and this path is written by the node that performed
-- the request and read by the one that asked.
local RECORD_SCHEMA = 1

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function slashes(path)
  -- A recorded Windows path is unusable by the POSIX shell this node runs commands in.
  return (tostring(path or ''):gsub('\\', '/'))
end

local function quote(value) return "'" .. tostring(value or ''):gsub("'", "'\\''") .. "'" end

local function first_line(text) return (tostring(text or ''):match('^%s*([^\r\n]*)') or '') end

local function read(path)
  if not path then return nil end
  local ok, text = pcall(host.read_file, path)
  return (ok and text) or nil
end

local function shell(command, cwd)
  local ok, raw = pcall(host.exec, command, cwd or '')
  if not ok or type(raw) ~= 'string' then return nil end
  local decoded_ok, decoded = pcall(json.decode, raw)
  return (decoded_ok and type(decoded) == 'table') and decoded or nil
end

local function git(tree, arguments)
  local result = shell('git -C ' .. quote(slashes(tree)) .. ' ' .. arguments .. ' 2>&1')
  if not result then return nil, 'git_unavailable' end
  local text = tostring(result.stdout or '')
  if (result.code or 1) ~= 0 then return nil, trim(text) end
  return text, nil
end

local function rev(tree, spec)
  local text = git(tree, 'rev-parse ' .. quote(spec))
  local value = trim(text or '')
  if value == '' then return nil end
  return value
end

-- Two commit ids name the same commit when one is a prefix of the other and at least 7 hex.
-- `installed.txt` records the short form on a build and the full id on a prebuilt install, so a
-- comparison on equality alone would report "not installed" about an install that is right there.
local function same_commit(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  a, b = a:lower(), b:lower()
  local n = math.min(#a, #b)
  if n < 7 or a:sub(1, n) ~= b:sub(1, n) then return false end
  return a:sub(1, n):match('^%x+$') ~= nil
end

-- Is the requested commit INSTALLED, even when the install went further? The deploy door builds the
-- tree, and main can move while a request waits (measured on `work`, 2026-11-10: a request for
-- c76c180a installed 4eba0d14, a descendant, and the old answer was "running" forever). A commit that
-- is an ancestor of what installed.txt names is contained in that install; one that is not is a
-- different install, and the answer must say so rather than call it done.
local function installed_contains(tree, installed, target)
  if same_commit(installed, target) then return true, 'exact' end
  if type(tree) ~= 'string' or tree == '' then return false end
  if type(installed) ~= 'string' or installed == '' or type(target) ~= 'string' or target == '' then return false end
  local answer = git(tree, 'merge-base --is-ancestor ' .. quote(target) .. ' ' .. quote(installed))
  if answer ~= nil then return true, 'contains' end
  return false
end

local function decode(raw)
  if type(raw) ~= 'string' or raw == '' then return nil end
  local ok, value = pcall(json.decode, raw)
  return (ok and type(value) == 'table') and value or nil
end

-- ---------------------------------------------------------------- records (peer side)

function M.dir()
  -- `records_root` is the test seam: a test must be able to write and read these records without
  -- touching the config directory of the node it runs on. It is never set by the module itself.
  return M.records_root or (slashes(paths.config()) .. '/remote-update')
end

local function record_path(id)
  if type(id) ~= 'string' or id == '' or id:find('[^%w%-]') then return nil end
  return M.dir() .. '/' .. id .. '.json'
end

function M.record(id)
  local path = record_path(id)
  if not path then return nil end
  return decode(read(path))
end

local function write_record(record)
  local path = record_path(record and record.id)
  if not path then return false end
  local ok, wrote = pcall(host.write_file, path, json.encode(record))
  return ok and wrote == true
end

-- Every request gets one id before anything is attempted. It is the id the master is handed, the
-- name of the audit record, and the name this module is asked about later - so a status question
-- can never be answered about a different request than the one that was admitted.
local function new_record(kind, target, reason, caller, args)
  local identity = nodes.identity() or {}
  return {
    schema = RECORD_SCHEMA,
    id = host.uuid(),
    kind = kind,
    state = 'requested',
    requested_at = math.floor(host.now()),
    target_commit = target,
    reason = reason,
    requester = {
      node_id = tostring(caller.node_id or ''),
      name = tostring(caller.name or ''),
      role = tostring(caller.role or ''),
      -- The key is the identity every other peer check rests on; the record keeps a prefix of it so
      -- an operator can match a record to a node without the record carrying a whole key.
      key_prefix = tostring(caller.public_key or ''):sub(1, 16),
      basis = tostring(caller.mesh or 'binding'),
      level = tonumber(caller.level),
      session = trim(args and args.session),
    },
    server = {
      node_id = tostring(identity.node_id or ''),
      name = tostring(nodes.node_name() or ''),
      install = nil,
      tree = nil,
    },
  }
end

-- The audit line. One sentence, in the peer's own log, naming who asked for what: the node log is
-- where an operator looks first, and the record beside it holds the same facts in full.
local function audit(event, record, detail)
  local who = record.requester.name ~= '' and record.requester.name or record.requester.node_id
  local message = string.format('remote-update %s: %s (%s) asked for %s%s on %s%s', event,
    who ~= '' and who or 'an unnamed caller', record.requester.node_id ~= '' and record.requester.node_id or 'no node id',
    tostring(record.kind or '?'), record.kind == 'rendezvous' and ' of the rendezvous' or '',
    tostring(record.target_commit or 'origin/main'):sub(1, 12), detail and (' - ' .. tostring(detail)) or '')
  if emit then pcall(emit, { type = 'log', message = message }) end
  record.audit = record.audit or {}
  record.audit[#record.audit + 1] = { at = math.floor(host.now()), event = event, line = message }
  return message
end

-- ---------------------------------------------------------------- the peer's tree, moved to the target
--
-- The gate builds a clean checkout of a landed commit. This moves the peer's runtime tree there by
-- fast-forward only: `HEAD` has to be an ancestor of the target, so no commit is ever dropped and a
-- tree that diverged is refused by name instead of being reset. A target that is not on origin/main
-- is refused too - a node installs what main says, which is the same rule the deploy gate applies.
local function prepare_tree(tree, commit)
  local fetched = shell('git -C ' .. quote(slashes(tree)) .. ' fetch --quiet origin 2>&1')
  if not fetched or (fetched.code or 1) ~= 0 then
    return nil, { error = 'source_fetch_failed',
      observed = trim(fetched and (fetched.stderr ~= '' and fetched.stderr or fetched.stdout) or 'git fetch returned no result') }
  end
  local origin_main = rev(tree, 'origin/main')
  if not origin_main then return nil, { error = 'origin_main_unavailable', observed = 'origin/main is not available after fetching origin' } end
  local target = trim(commit)
  if target == '' then target = origin_main else target = rev(tree, target .. '^{commit}') end
  if not target then return nil, { error = 'commit_unknown', observed = 'the requested commit is not in this tree' } end
  local landed = git(tree, 'merge-base --is-ancestor ' .. quote(target) .. ' ' .. quote(origin_main))
  if not landed then
    return nil, { error = 'commit_not_on_main',
      observed = target:sub(1, 12) .. ' is not an ancestor of origin/main ' .. origin_main:sub(1, 12) ..
        '; a node installs a landed commit, never an arbitrary one' }
  end
  local head = rev(tree, 'HEAD')
  if head ~= target then
    local forward = git(tree, 'merge --ff-only --quiet ' .. quote(target))
    if not forward then
      return nil, { error = 'commit_not_reachable',
        observed = 'HEAD is ' .. tostring(head and head:sub(1, 12)) .. ' and it does not fast-forward to ' ..
          target:sub(1, 12) .. '; a remote update never resets a tree (rollback is upgrade.sh\'s job)' }
    end
    head = rev(tree, 'HEAD')
    if head ~= target then
      return nil, { error = 'source_moved', observed = 'HEAD is ' .. tostring(head and head:sub(1, 12)) .. ' after the fast-forward, not ' .. target:sub(1, 12) }
    end
  end
  local dirty = git(tree, 'status --porcelain --untracked-files=no')
  if dirty == nil then return nil, { error = 'source_status_unavailable' } end
  if trim(dirty) ~= '' then
    return nil, { error = 'tree_dirty', observed = 'the runtime tree has uncommitted changes, and the gate refuses a dirty tree' }
  end
  return { tree = slashes(tree), commit = target, origin_main = origin_main }
end

-- ---------------------------------------------------------------- the peer's installer doors

-- The node: exactly the request the local `/update` writes, so the peer's Sentinel performs it
-- under the same preconditions, the same backup and the same outcome record.
local function request_node(record)
  local request = {
    skip_source_sync = true,
    expected_commit = record.target_commit,
    -- A forced request is honoured by THIS node's pin gate (lua/core/update.lua M.verdict) and carried into the
    -- Sentinel request it writes, so the installer that runs afterwards is the one that was forced and not a
    -- fresh ordinary deploy that refuses on the same pin one step later.
    force = record.forced == true,
    -- This call is a signed master request the binding/roster already admitted (see `serve`), not a
    -- child shell: `update.run` clears the child marker for the one sentinel command it writes.
    signed_request = true,
    reason = record.reason ~= '' and record.reason or ('remote update from ' .. (record.requester.name ~= '' and record.requester.name or record.requester.node_id)),
  }
  -- The install and sentinel directory are the peer's own in production; a test points both at a
  -- fixture with the same options `update.run` already takes.
  for key, value in pairs(M.facts_options or {}) do request[key] = value end
  local verdict = update.run(request)
  if verdict == nil then return nil, { error = 'update_unavailable' } end
  if verdict.ok ~= true or verdict.status ~= 'queue' then
    return nil, {
      error = tostring(verdict.error or verdict.status or 'update_refused'),
      message = tostring(verdict.message or ''),
      observed = tostring(verdict.observed or ''),
      next = verdict.next,
    }
  end
  return {
    door = 'deploy',
    request = tostring(verdict.request or ''),
    sentinel = tostring(verdict.sentinel or ''),
    commit = tostring(verdict.commit or record.target_commit),
    backup = verdict.backup,
  }
end

-- The `request run` door: `request run` takes a script path and no arguments, so the arguments live in a
-- short wrapper written into a directory the peer's sentinel is already allowed to execute from. That
-- directory is the operator's own `WA_SENTINEL_SCRIPTS`; this refuses by name when none of them can be
-- written.
--
-- Three callers share it, and each wrapper is a path plus an `exec`, never a sentence of shell the master
-- composed: the rendezvous deploy (`scripts/deploy-rendezvous.sh`), the binary-only node install
-- (`scripts/deploy.sh` with WA_DEPLOY_PREBUILT_ONLY=1) and the rollback
-- (`scripts/rollback-node.sh`). A master request is admitted or refused; it is never a relayed child shell.
local function run_wrapper(label, body, record)
  local scripts = tostring(host.getenv('WA_SENTINEL_SCRIPTS') or '')
  if scripts == '' then
    return nil, { error = 'rendezvous_scripts_unconfigured',
      observed = 'WA_SENTINEL_SCRIPTS is empty on this node, so `request run` cannot execute anything' }
  end
  local stamp = tostring(math.floor(host.now())) .. '-' .. record.id:sub(1, 8)
  local lines = {
    '#!/usr/bin/env bash',
    '# written by lua/core/remote_update.lua for remote request ' .. record.id .. ' (' .. label .. ')',
    'set -euo pipefail',
  }
  for _, line in ipairs(body) do lines[#lines + 1] = line end
  lines[#lines + 1] = ''
  local text = table.concat(lines, '\n')
  local tried = {}
  for dir in scripts:gmatch('[^;]+') do
    dir = trim(dir)
    if dir ~= '' then
      local path = slashes(dir) .. '/remote-' .. label .. '-' .. stamp .. '.sh'
      local ok, wrote = pcall(host.write_file, path, text)
      if ok and wrote == true then
        shell('chmod +x ' .. quote(path) .. ' 2>/dev/null')
        return path, nil
      end
      tried[#tried + 1] = path
    end
  end
  return nil, { error = 'rendezvous_scripts_not_writable',
    observed = 'no directory in WA_SENTINEL_SCRIPTS could be written: ' .. table.concat(tried, ', ') }
end

local function request_run(record, label, body, what)
  local facts = M.facts()
  local blocked = update.preconditions(facts)
  if blocked then
    return nil, { error = tostring(blocked.error or blocked.status), message = tostring(blocked.message or ''),
      observed = tostring(blocked.observed or ''), next = blocked.next }
  end
  local script, problem = run_wrapper(label, body, record)
  if not script then return nil, problem end
  local reason = 'remote update from ' .. (record.requester.name ~= '' and record.requester.name or record.requester.node_id)
    .. ': ' .. (record.reason ~= '' and record.reason or what)
  -- The same authority the deploy door uses: this request was admitted as a signed master request by
  -- `serve`, and the node stamps `child` on shells it runs for a peer call. Cleared for this command only.
  local command = 'WASM_AGENT_PROVENANCE= ' .. table.concat({
    quote(facts.sentinel), 'request', 'run', '--script', quote(script), '--reason', quote(reason),
  }, ' ')
  -- The box before the call: a request file that appears during it is this call's, even when the sentinel
  -- prints nothing (the node door proves the same thing, `update.M.new_requests`).
  local box_before = update.request_box(facts)
  local result = shell(command)
  if not result then return nil, { error = 'sentinel_unreachable', observed = 'calling ' .. tostring(facts.sentinel) .. ' produced no answer' } end
  if (result.code or 0) ~= 0 then
    return nil, { error = 'sentinel_refused',
      observed = 'the sentinel exited ' .. tostring(result.code) .. ': ' .. trim(result.stderr ~= '' and result.stderr or result.stdout) }
  end
  local requested = tostring(result.stdout or ''):match('requested run:%s*([^\r\n]+)')
  if not requested then
    local fresh = update.new_requests(box_before)
    if #fresh == 1 then
      local text = read(fresh[1])
      local ok, request = pcall(json.decode, tostring(text or ''))
      if ok and type(request) == 'table' and request.verb == 'run' then
        return { door = 'run', request = fresh[1], script = script, sentinel = trim(first_line(result.stdout)), commit = record.target_commit }
      end
    end
    return nil, { error = 'sentinel_unverifiable',
      observed = 'the sentinel exited ' .. tostring(result.code) .. ' naming no run request; stdout ' ..
        (#trim(tostring(result.stdout or '')) > 0 and trim(tostring(result.stdout)) or 'was empty') .. '; stderr ' ..
        (trim(tostring(result.stderr or '')) ~= '' and trim(tostring(result.stderr)) or 'was empty'),
      evidence = { code = result.code, sentinel_dir = box_before.root, appeared = #fresh } }
  end
  return { door = 'run', request = trim(requested), script = script, sentinel = trim(first_line(result.stdout)), commit = record.target_commit }
end

-- The rendezvous: the registry where this node runs one, moved to the same landed commit and restarted by
-- `scripts/deploy-rendezvous.sh` (which refuses to run inside a run, and requires HEAD == origin/main ==
-- the full commit it is given).
local function request_rendezvous(record)
  local body = {
    -- `exec bash <script>`: the script is mode 100644 in git, so `exec <script>` answers EACCES
    -- (`code=126 Permission denied`, measured on openclaw 2026-11-10).
    'exec bash ' .. quote(slashes(record.server.tree) .. '/scripts/deploy-rendezvous.sh') .. ' '
      .. quote(record.target_commit) .. ' ' .. quote(record.reason ~= '' and record.reason or 'remote update'),
  }
  return request_run(record, 'rendezvous', body, 'rendezvous deploy')
end

-- The binary-only node: the same installer every other node uses, with the one variable that says "install
-- the published release, never build here". Its refusal is a named one
-- (`refused(no_prebuilt_binary)`), so a node with no toolchain is told what is missing instead of spending
-- an hour failing a build - which is what the hand-run upnode procedure was for.
local function request_binary(record)
  local body = {
    'export WA_DEPLOY_PREBUILT_ONLY=1',
    'exec bash ' .. quote(slashes(record.server.tree) .. '/scripts/deploy.sh'),
  }
  return request_run(record, 'binary', body, 'binary install')
end

-- The rollback: the pair the last install replaced, put back by the copy the install shipped beside it.
-- Deliberately independent of the tree and of a release feed: the node this is about may be the reason it
-- is needed.
local function request_rollback(record)
  local install = slashes(record.server.install or '')
  if install == '' then return nil, { error = 'no_install_dir', observed = 'this node reported no install directory' } end
  local body = {
    'exec bash ' .. quote(install .. '/scripts/rollback-node.sh') .. ' --install ' .. quote(install)
      .. ' --reason ' .. quote(record.reason ~= '' and record.reason or 'remote rollback'),
  }
  return request_run(record, 'rollback', body, 'rollback')
end

-- The sentinel names a request id in the path it prints; that id is what its own `done/`,
-- `failed/` and `deploy-outcome` records are keyed by.
local function request_id_of(path)
  return tostring(path or ''):gsub('\\', '/'):match('([%w%-]+)%.json$')
end

-- ---------------------------------------------------------------- the peer half

-- The install and sentinel directory this module answers about. Production: this node's own, which is
-- exactly what `update.facts()` answers with no options. `facts_options` is the test seam (a fixture
-- install), never set by the module itself.
function M.facts() return update.facts(M.facts_options or {}) end

-- The checkout a pin's release question is asked of. "Does this target contain the awaited commit?" is a git
-- question, and the coordinator's own runtime tree is where a target commit is resolved; asking it of an empty
-- path (which this call used to do: pins.released(pin, target, '')) can only answer "cannot tell", so no pin
-- ever released by ancestry. A node with no tree answers "cannot tell" too, and that is reported, never read
-- as released.
local function release_tree()
  local ok, tree = pcall(function() return nodes.worktree() end)
  if ok and type(tree) == 'string' then return slashes(tree) end
  return ''
end

function M.serve(args, caller)
  args = type(args) == 'table' and args or {}
  local author = nodes.author_of(caller)
  if not author then
    return { error = 'forbidden_role', effect = 'none', capability = M.CAPABILITY,
      role = tostring(type(caller) == 'table' and caller.role or '?'),
      note = 'only a node the binding or the roster names as a master may ask this node to update itself' }
  end
  local action = trim(args.action)
  if action == '' then action = 'request' end
  if action == 'request' then return M.admit(args, caller) end
  if action == 'status' then return M.read_status(args, caller) end
  if action == 'check' then return M.check(args, caller) end
  if action == 'unpin' then return M.unpin(args, caller) end
  return { error = 'unknown_update_action', action = tostring(args.action or ''), allowed = M.ACTIONS, effect = 'none' }
end

-- Admit one remote install: authorise, record, move the tree, hand it to the peer's own installer.
function M.admit(args, caller)
  local commit = trim(args.commit)
  if commit ~= '' and not commit:match('^%x+$') then
    return { error = 'commit_invalid', effect = 'none', observed = 'a commit id is hex; ' .. tostring(args.commit):sub(1, 20) .. ' is not' }
  end
  local rendezvous = args.rendezvous == true or args.rendezvous == 'true'
  -- The four modes of one verb (`wa update <node>`): a tree deploy, a binary-only install, a rollback, and
  -- the rendezvous where the node runs one. `mode` is refused by name rather than ignored, so a typo cannot
  -- silently perform the default install.
  local mode = trim(args.mode)
  local rollback = args.rollback == true or args.rollback == 'true' or mode == 'rollback'
  if mode ~= '' and mode ~= 'tree' and mode ~= 'binary' and mode ~= 'rollback' then
    return { error = 'mode_unknown', effect = 'none', mode = mode, allowed = { 'tree', 'binary', 'rollback', 'rendezvous' } }
  end
  local kind = rollback and 'rollback' or (rendezvous and 'rendezvous' or (mode == 'binary' and 'binary' or 'node'))
  local reason = trim(args.reason)
  if #reason > 400 then return { error = 'reason_too_long', effect = 'none', limit = 400 } end
  -- A FORCE IS A REASON OR IT IS NOTHING. The coordinator sends force_note when it moves a pinned node with
  -- --force --reason, and until now NO NODE READ IT: the flag was decoration, the force was invisible in the
  -- node's own record, and the install below refused on the node's own pin anyway. The node honours a forced
  -- deploy now - and only with a reason, which it writes down (round-3 item 5).
  local force_note = trim(args.force_note)
  if force_note ~= '' and reason == '' then
    return { error = 'override_reason_required', effect = 'none', capability = M.CAPABILITY, observed = force_note,
      message = 'a forced deploy must say why: --force --reason <text>, and the reason is recorded on this node and in this request. Nothing was queued.' }
  end
  local forced = force_note ~= ''
  local facts = M.facts()
  -- A rollback is the one action that must work on a node whose tree is behind or broken (the install
  -- shipped scripts/rollback-node.sh beside the binary for exactly that), so it does not require a tree and
  -- never moves one.
  if not facts.tree and not rollback then
    return { error = 'no_runtime_tree', effect = 'none',
      observed = 'this node has no runtime-worktree.txt and does not run from a checkout, so there is no tree to move to a commit' }
  end
  local record = new_record(kind, '', reason, caller, args)
  if forced then
    record.forced = true
    record.force_note = force_note
    record.override_reason = reason
    if emit then pcall(emit, { type = 'log', message = 'remote-update forced: ' .. tostring(record.id) .. ' (' ..
      tostring(record.requester and record.requester.name or '?') .. ') forced past the pin: ' .. reason }) end
  end
  record.server.install = facts.install
  record.server.tree = facts.tree and slashes(facts.tree) or nil
  if rollback then
    -- The commit a rollback is about is the one being replaced, and it is read (not guessed) from the
    -- install record: an operator asking later needs to know what was undone.
    local installed = update.installed_record(facts.install)
    record.replaced_commit = tostring(installed.commit or '')
    record.target_commit = tostring(installed.commit or '')
    local done, error = request_rollback(record)
    if not done then
      error.effect = 'none'
      error.capability = M.CAPABILITY
      audit('refused', record, tostring(error.error))
      record.state, record.outcome = 'refused', 'refused'
      record.detail = tostring(error.error) .. (error.observed and (' - ' .. tostring(error.observed)) or '')
      write_record(record)
      error.audit_id = record.id
      return error
    end
    record.state = 'queued'
    record.door = done.door
    record.request_path = done.request
    record.sentinel_request_id = request_id_of(done.request)
    record.sentinel = done.sentinel
    if done.script then record.script = done.script end
    audit('admitted', record, done.request)
    if not write_record(record) then
      return { error = 'audit_record_not_written', effect = 'unknown', capability = M.CAPABILITY, record = record.id,
        request = done.request, note = 'the rollback was queued but this node could not write the record that names who asked for it' }
    end
    -- THE NODE KEEPS ITS OWN COPY OF THE PIN (item 6). A pin that lives only in the coordinator's store protects
    -- the node from requests made through that coordinator, and from nothing else: a deploy started ON the node -
    -- its own `wa update`, its sentinel's tree deploy, a hand-run upgrade.sh, fleet-install.sh or bootstrap.sh -
    -- never reads the coordinator's file. So a rollback writes the same record into the node's own pins.txt, under
    -- its own name AND its own node_id (an operator addresses it by either; pins.active matches both).
    --
    -- commit=unknown is honest here: what the rollback restores is named by installed.txt once rollback-node.sh
    -- has run, and this record is refreshed with that commit when the outcome is read back. The commit it went
    -- BACK FROM is recorded as rolled_back_from, for a reader - it is NOT an awaited commit (item 2).
    local own_identity = nodes.identity() or {}
    local own_name = tostring(nodes.node_name() or '')
    local own_id = tostring(own_identity.node_id or '')
    local from_commit = tostring(record.replaced_commit or '')
    local node_pin, node_pin_problem = pins.set({
      node = own_name ~= '' and own_name or own_id,
      node_id = own_id,
      kind = 'rollback',
      commit = 'unknown',
      rolled_back_from = from_commit,
      -- NO DEFAULT AWAITED COMMIT (round-3 item 2). This used to default await to the commit the rollback went
      -- BACK FROM - which is the history that CONTAINS the change the rollback was about. The next ordinary
      -- deploy of main contains it, so the pin released itself on exactly the move it existed to stop, and the
      -- record looked right while doing it. rolled_back_from is kept for display; an awaited commit is only ever
      -- the one an operator names (--await), and the way out of a pin with no await is --unpin with a reason.
      await = trim(args.await),
      until_ = trim(args['until']),
      reason = reason ~= '' and reason
        or ('rolled back by a request from ' .. tostring(record.requester.name ~= '' and record.requester.name or record.requester.node_id)),
    })
    local identity = nodes.identity() or {}
    return {
      ok = true, status = 'queued', record = record.id, kind = kind,
      commit = record.target_commit, door = done.door, request = done.request,
      sentinel_request_id = record.sentinel_request_id,
      pin = node_pin, pin_problem = node_pin_problem,
      pin_next = 'this node stays where it is until the pin is released: ' .. pins.escape_hatch(own_name ~= '' and own_name or own_id),
      target_node = { node_id = tostring(identity.node_id or ''), name = tostring(nodes.node_name() or '') },
      requester = record.requester.name ~= '' and record.requester.name or record.requester.node_id,
      requested_at = record.requested_at,
      message = 'queued: this node\'s own Sentinel will restore the pair the last install replaced and restart the node under it. Nothing is restored yet.',
      next = 'ask again with {action="status", id="' .. record.id .. '"}; the record lands in ' .. M.dir(),
    }
  end
  local prepared, refusal = prepare_tree(facts.tree, commit)
  if not prepared then
    refusal.effect = 'none'
    refusal.capability = M.CAPABILITY
    audit('refused', record, refusal.error)
    record.state = 'refused'
    record.outcome = 'refused'
    record.detail = tostring(refusal.error) .. (refusal.observed and (' - ' .. tostring(refusal.observed)) or '')
    write_record(record)
    -- A refusal is recorded too, and the answer names the record: "why not" is evidence an operator
    -- reads on the peer, not an error word the master has to guess about.
    refusal.audit_id = record.id
    return refusal
  end
  record.target_commit = prepared.commit
  record.server.origin_main = prepared.origin_main
  record.server.tree = prepared.tree
  local done, error = nil, nil
  if kind == 'rendezvous' then done, error = request_rendezvous(record)
  elseif kind == 'binary' then done, error = request_binary(record)
  else done, error = request_node(record) end
  if not done then
    error.effect = 'none'
    error.capability = M.CAPABILITY
    error.record = nil
    audit('refused', record, tostring(error.error))
    record.state = 'refused'
    record.outcome = 'refused'
    record.detail = tostring(error.error) .. (error.observed and (' - ' .. tostring(error.observed)) or '')
    write_record(record)
    -- A refusal still answers with the record id, so the master can read what the peer wrote about
    -- its own request instead of guessing from an error word.
    error.audit_id = record.id
    return error
  end
  record.state = 'queued'
  record.door = done.door
  record.request_path = done.request
  record.sentinel_request_id = request_id_of(done.request)
  record.sentinel = done.sentinel
  if done.script then record.script = done.script end
  if done.backup then record.backup = done.backup end
  audit('admitted', record, done.request)
  if not write_record(record) then
    return { error = 'audit_record_not_written', effect = 'unknown', capability = M.CAPABILITY,
      record = record.id, request = done.request,
      note = 'the install was queued but this node could not write the record that names who asked for it' }
  end
  local identity = nodes.identity() or {}
  return {
    ok = true, status = 'queued', record = record.id, kind = kind,
    commit = record.target_commit, door = done.door, request = done.request,
    sentinel_request_id = record.sentinel_request_id,
    target_node = { node_id = tostring(identity.node_id or ''), name = tostring(nodes.node_name() or '') },
    requester = record.requester.name ~= '' and record.requester.name or record.requester.node_id,
    requested_at = record.requested_at,
    message = 'queued: this node\'s own Sentinel will perform the ' ..
      (kind == 'rendezvous' and 'rendezvous deploy' or (kind == 'binary' and 'binary-only install (published release, no build here)' or 'deploy')) ..
      ' under its existing rules. This is not installed yet.',
    next = 'ask again with {action="status", id="' .. record.id .. '"}; the record lands in ' .. M.dir(),
  }
end

-- The node's own pin, refreshed with the commit the rollback actually restored. The queued record could only
-- say commit=unknown (rollback-node.sh had not run yet); reading the outcome is the moment the node knows which
-- commit it is on, and a pin that names it is a record an operator can compare with installed.txt.
-- Idempotent: the same commit twice writes nothing.
local function pin_restored_commit(restored)
  local commit = trim(restored)
  if commit == '' or commit == 'unknown' then return nil end
  local own_identity = nodes.identity() or {}
  local own_name = tostring(nodes.node_name() or '')
  local own_id = tostring(own_identity.node_id or '')
  local key = own_name ~= '' and own_name or own_id
  local active = pins.active(key, own_id)
  if not active or trim(active.kind) ~= 'rollback' then return nil end
  if trim(active.commit) == commit then return active end
  return pins.set({ node = key, node_id = own_id, kind = 'rollback', commit = commit,
    rolled_back_from = trim(active.rolled_back_from), await = trim(active.await),
    until_ = trim(active.until_), reason = trim(active.reason) })
end

-- What the peer can prove about one request, from files that survive the install it performs.
local function outcome_of(record)
  local facts = M.facts()
  local sentinel_dir = facts.sentinel_dir
  local id = record.sentinel_request_id or ''
  local outcome = { state = 'queued' }
  local function settled(state, detail, extra)
    outcome.state = state
    outcome.detail = detail
    for key, value in pairs(extra or {}) do outcome[key] = value end
    return outcome
  end
  -- The installer's own verdict for this exact request id, in the install directory.
  local result = decode(read(facts.install .. '/deploy-result.json'))
  if result and tostring(result.request_id or '') == id and id ~= '' then
    outcome.installer = { ok = result.ok == true, commit = result.commit, at = result.at, detail = result.detail }
  end
  if record.kind == 'rendezvous' or record.kind == 'rollback' then
    local what = record.kind == 'rollback' and 'the rollback' or 'the rendezvous deploy'
    local done = decode(read(sentinel_dir .. '/done/' .. id .. '.json'))
    local failed = decode(read(sentinel_dir .. '/failed/' .. id .. '.json'))
    if failed then
      return settled('failed', tostring(failed.detail or failed.phase or 'refused by the sentinel'), { refused = true })
    end
    if done then
      if done.ok == true and tostring(done.phase or '') ~= 'failed' then
        -- A rollback's own record is the install record it rewrote: report what is installed now, so
        -- "installed" is a commit an operator can compare, not just the word.
        local restored = update.installed_record(facts.install)
        pin_restored_commit(restored.commit)
        return settled('installed', tostring(done.detail or (what .. ' settled')),
          { installed_commit = restored.commit, pin = pin_restored_commit(restored.commit) })
      end
      return settled('failed', tostring(done.detail or (what .. ' did not settle')))
    end
    return outcome
  end
  local installed = update.installed_record(facts.install)
  outcome.installed_commit = installed.commit
  outcome.installed_binary = { source = installed.binary_source, release = installed.binary_release }
  local failed = decode(read(sentinel_dir .. '/failed/' .. id .. '.json'))
  if failed then
    return settled('failed', tostring(failed.detail or failed.phase or 'refused by the sentinel'), { refused = true })
  end
  local contained, how = installed_contains(record.server and record.server.tree, installed.commit, record.target_commit)
  if record.target_commit ~= '' and contained then
    local detail = 'installed.txt names ' .. tostring(installed.commit)
    if how == 'contains' then
      detail = detail .. ', which contains the requested ' .. tostring(record.target_commit):sub(1, 12) ..
        ' (main moved while the request waited; the deploy installs the tree it was given)'
    end
    if installed.binary_source then detail = detail .. ' (' .. tostring(installed.binary_source) .. (installed.binary_release and (' ' .. installed.binary_release) or '') .. ')' end
    return settled('installed', detail, { verified = true, contains_target = how == 'contains' })
  end
  local ledger = decode(read(sentinel_dir .. '/deploy-outcome/' .. id .. '.json'))
  if ledger and ledger.state == 'settled' then
    local state = ledger.outcome == 'success' and 'installed' or (ledger.outcome == 'silent' and 'silent' or 'failed')
    if state == 'installed' and ledger.outcome == 'success' and not same_commit(installed.commit, record.target_commit) then
      -- The installer said success for this request, but the install record does not name the commit
      -- that was asked for: report what is installed rather than repeat the claim.
      return settled('unknown', tostring(ledger.detail or '') .. '; installed.txt names ' .. tostring(installed.commit))
    end
    return settled(state, tostring(ledger.detail or ledger.outcome), { settled_at = ledger.settled_at })
  end
  local done = decode(read(sentinel_dir .. '/done/' .. id .. '.json'))
  if done then
    outcome.spawned = tostring(done.phase or '')
    outcome.sentinel_detail = tostring(done.detail or '')
    if done.ok ~= true or tostring(done.phase or '') == 'failed' then
      return settled('failed', tostring(done.detail or 'the sentinel reported the request failed'))
    end
    return settled('running', tostring(done.detail or 'the installer is running'))
  end
  return outcome
end

-- One record, as the master reads it. The first time an outcome is known it is written into the
-- record, so the peer keeps its own durable answer even after the sentinel's folders are swept.
function M.read_status(args, caller)
  local id = trim(args.id)
  if id == '' then
    -- No id: the newest record this caller asked for. A caller never sees another node's records.
    local listing = shell('ls -1t ' .. quote(M.dir()) .. ' 2>/dev/null | head -50')
    for name in tostring(listing and listing.stdout or ''):gmatch('[^\r\n]+') do
      local candidate = M.record((trim(name):gsub('%.json$', '')))
      if candidate and tostring(candidate.requester and candidate.requester.node_id or '') == tostring(caller.node_id or '') then
        id = candidate.id
        break
      end
    end
    if id == '' then
      return { error = 'no_remote_update_record', effect = 'none', requester = tostring(caller.node_id or '') }
    end
  end
  local record = M.record(id)
  if not record then return { error = 'unknown_remote_update', id = id, effect = 'none' } end
  if tostring(record.requester and record.requester.node_id or '') ~= tostring(caller.node_id or '') then
    return { error = 'not_your_record', id = id, effect = 'none',
      note = 'a remote update record is readable by the node that asked for it' }
  end
  local outcome = outcome_of(record)
  local reply = {
    ok = true, record = id, kind = record.kind, commit = record.target_commit,
    state = outcome.state, detail = outcome.detail,
    requested_at = record.requested_at, door = record.door,
    request = record.request_path, sentinel_request_id = record.sentinel_request_id,
    installed_commit = outcome.installed_commit, installed_binary = outcome.installed_binary,
    verified = outcome.verified == true, refused = outcome.refused == true,
    contains_target = outcome.contains_target == true,
    server = record.server,
  }
  if (outcome.state == 'installed' or outcome.state == 'failed' or outcome.state == 'silent') and record.outcome == nil then
    record.outcome = outcome.state
    record.settled_at = math.floor(host.now())
    record.installed_commit = outcome.installed_commit
    record.detail = outcome.detail
    write_record(record)
    audit('settled', record, outcome.state .. ': ' .. tostring(outcome.detail or ''))
  end
  return reply
end

-- What this node would do, without doing it: the facts a master needs before it asks (or that a
-- test needs to see). Read-only.
function M.check(args, caller)
  local author = nodes.author_of(caller)
  if not author then return { error = 'forbidden_role', effect = 'none' } end
  local facts = M.facts()
  local record = update.installed_record(facts.install)
  return {
    ok = true, node = nodes.node_name(), node_id = (nodes.identity() or {}).node_id,
    install = facts.install, tree = facts.tree, tree_commit = facts.tree_commit,
    installed_commit = record.commit, installed_binary = { source = record.binary_source, release = record.binary_release },
    watcher = facts.sentinel_running == true, stopped = facts.sentinel_stopped == true,
    pending_deploys = facts.pending_deploys or {},
    dirty = facts.dirty or 0,
    preconditions = update.preconditions(facts),
  }
end

-- Release the pin on THIS node, on purpose and on the record.
--
-- WHY THIS IS A PEER ACTION AND NOT A FILE EDIT. A pin is read by the script that installs (scripts/lib/
-- node-pins.sh, from deploy.sh, upgrade.sh, fleet-install.sh and bootstrap.sh) and by this node's own update
-- path (lua/core/update.lua). A coordinator that cleared only its own store told the operator "unpinned: ordinary
-- deploys may move it again" while the node's own record still refused every install started ON the node - the
-- message overclaimed and the pin stayed (round-3 item 5). So the release travels to the store that gates the
-- node, names the node it is about, and carries a reason that is written into the record.
function M.unpin(args, caller)
  local author = nodes.author_of(caller)
  if not author then
    return { error = 'forbidden_role', effect = 'none', capability = M.CAPABILITY,
      note = 'only a node the binding or the roster names as a master may release a pin on this node' }
  end
  local reason = trim(args.reason)
  if reason == '' then
    return { ok = false, error = 'unpin_reason_required', effect = 'none', node = tostring(nodes.node_name() or ''),
      message = 'releasing a pin is a decision nobody can review if it does not say why: pass --reason <text>. Nothing was released and nothing was changed.' }
  end
  if #reason > 400 then return { ok = false, error = 'reason_too_long', effect = 'none', limit = 400 } end
  local own_identity = nodes.identity() or {}
  local own_name = tostring(nodes.node_name() or '')
  local own_id = tostring(own_identity.node_id or '')
  local key = own_name ~= '' and own_name or own_id
  local active = pins.active(key, own_id)
  if not active then
    return { ok = true, status = 'not_pinned', released = false, node = key,
      message = 'this node (' .. tostring(key) .. ') carries no active pin in its own store: nothing was released, and nothing was changed.' }
  end
  local who = tostring(caller and (caller.name or '') or '')
  if who == '' then who = tostring(caller and caller.node_id or '') end
  if who == '' then who = 'an unnamed master' end
  local cleared, problem = pins.clear(key, { node_id = own_id, kind = 'unpin',
    reason = 'released on request by ' .. who .. ': ' .. reason })
  if not cleared then
    return { ok = false, error = 'pin_not_clearable', node = key,
      observed = tostring(problem and problem.error or 'unknown'),
      message = 'the release could not be written, so the pin on this node is still in force. Nothing was changed.' }
  end
  if emit then pcall(emit, { type = 'log', message = 'node-pin released on ' .. tostring(key) .. ': was pinned to ' ..
    tostring(active.commit or 'unknown') .. ' (pin ' .. tostring(active.id or '?') .. '), released on request by ' ..
    who .. ': ' .. reason }) end
  return { ok = true, status = 'unpinned', released = true, node = key, node_id = own_id,
    released_pin = { id = tostring(active.id or ''), commit = tostring(active.commit or 'unknown'),
                     reason = tostring(active.reason or ''), await = tostring(active.await or '') },
    reason = reason,
    message = 'released the pin on this node (' .. tostring(key) .. '): it was pinned to ' ..
      tostring(active.commit or 'unknown'):sub(1, 12) .. ' (pin ' .. tostring(active.id or '?') .. '); why: ' .. reason }
end

-- ---------------------------------------------------------------- the master half
--
-- `call` is the signed peer call (`nodes.remote_call`, injected so a test can answer it without a
-- network). The rest is local bookkeeping: what this node asked for, for which session, and whether
-- that session has already been told the outcome.

function M.pending_dir() return (M.records_root or (slashes(paths.config()) .. '/remote-update')) .. '/requests' end

local function pending_path(record_id)
  if type(record_id) ~= 'string' or record_id == '' or record_id:find('[^%w%-]') then return nil end
  return M.pending_dir() .. '/' .. record_id .. '.json'
end

function M.pending(record_id)
  local path = pending_path(record_id)
  if not path then return nil end
  return decode(read(path))
end

local function remember(record_id, fields)
  local path = pending_path(record_id)
  if not path then return nil end
  local existing = M.pending(record_id) or { schema = 1, id = record_id }
  for key, value in pairs(fields or {}) do existing[key] = value end
  existing.updated_at = math.floor(host.now())
  local ok, wrote = pcall(host.write_file, path, json.encode(existing))
  if not ok or wrote ~= true then return nil end
  return existing
end

-- One line a human (and a model) can act on. It names the node, the commit and the state, and it
-- never says "updated" for a request that has not been proven installed.
function M.summary(reply)
  if type(reply) ~= 'table' then return 'no answer from the peer' end
  if reply.error then
    local detail = tostring(reply.observed or reply.message or '')
    return string.format('%s %s%s%s', tostring(reply.node or 'peer'), tostring(reply.error),
      detail ~= '' and (': ' .. detail) or '',
      reply.audit_id and (' (record ' .. tostring(reply.audit_id) .. ')') or '')
  end
  local state = tostring(reply.state or (reply.status == 'queued' and 'queued') or 'unknown')
  local parts = { string.format('remote update of %s: %s', tostring(reply.target_node and reply.target_node.name or reply.node or 'peer'), state) }
  if reply.commit and reply.commit ~= '' then parts[#parts + 1] = 'commit ' .. tostring(reply.commit):sub(1, 12) end
  if reply.kind == 'rendezvous' then parts[#parts + 1] = 'rendezvous' end
  if reply.detail and reply.detail ~= '' then parts[#parts + 1] = tostring(reply.detail) end
  if reply.installed_commit and reply.installed_commit ~= '' and state ~= 'installed' then parts[#parts + 1] = 'installed ' .. tostring(reply.installed_commit) end
  return table.concat(parts, '; ')
end

-- Ask a peer to update itself. One signed call; the peer answers with the record id and the
-- request it wrote into its own sentinel box. The local record is what `status` needs later and
-- what says which session is owed the one notice.
function M.request(call, selector, options)
  options = type(options) == 'table' and options or {}
  -- A PINNED NODE DOES NOT MOVE FORWARD, and this is the moment the decision is made: a request is a deploy
  -- asked for. The pin is the record an operator wrote when they put a node somewhere on purpose
  -- (lua/core/pins.lua); without this gate the next ordinary deploy quietly undid it - measured 18/11, three
  -- hand-made rollbacks and not one of them survived the next deploy.
  --
  -- Two ways out, both explicit: the pin named an awaited commit and this target contains it (then the pin is
  -- doing its job and releases), or the caller says --force with a reason, which is recorded by the pin
  -- history and in this request's own audit record. A rollback is never gated: going back is what a pin is
  -- for, and refusing it would trap a node on the wrong bytes.
  local node_key = trim(selector)
  -- ALIASES BEFORE THE GATE. A node answers to its name and to its node_id, and the pin may have been written
  -- under either (a rollback records the node the operator named; the node's own store records the id). Resolve
  -- the selector first and gate on both, or a pin written under one spelling would not gate a request made with
  -- the other - which is exactly how a pin becomes a decoration.
  local ok_find, resolved = pcall(function() return nodes.find(selector) end)
  local node_id = (ok_find and type(resolved) == 'table') and tostring(resolved.node_id or '') or ''
  local pin_in_force = pins.active(node_key, node_id)
  local wants_back = options.rollback == true or trim(options.mode) == 'rollback'
  local force_note = nil
  if pin_in_force and not wants_back then
    local target = trim(options.commit)
    local released = nil
    if target ~= '' then released = pins.released(pin_in_force, target, release_tree()) end
    if released and released.released == true then
      -- THE PIN DID ITS JOB AND RELEASES, as a record: the ledger then says when and why the node was let go,
      -- instead of the pin being silently ignored. A plain "wa update <node>" to a target that contains the
      -- awaited commit is the ordinary way out of a pin, and it used to be impossible.
      local cleared, problem = pins.clear(node_key, { node_id = node_id, kind = 'released',
        reason = 'released by a target that ' .. tostring(released.why) })
      if cleared then
        pin_in_force = nil
      else
        return {
          ok = false, error = 'pin_release_not_recorded', node = node_key, pin = pin_in_force,
          observed = tostring(problem and problem.error or 'unknown'),
          message = 'this deploy would release the pin and the release could not be recorded, so nothing was asked of the node.',
          next = pins.escape_hatch(node_key, pin_in_force),
        }
      end
    elseif options.force == true then
      -- A FORCE IS ONLY AN OVERRIDE WHEN IT SAYS WHY. The bypass used to be "force ~= true", so --force with no
      -- --reason moved a pinned node and left nothing behind saying who did it or why.
      if trim(options.reason) == '' then
        return {
          ok = false, error = 'override_reason_required', node = node_key, pin = pin_in_force,
          observed = pins.summary_line(pin_in_force),
          message = '--force overrides a pin, which is a record that this node was put somewhere on purpose, and an override nobody can read later is not a decision anyone can review.',
          next = 'say why: --force --reason <text> (recorded in the pin history and in this request), or ' .. pins.escape_hatch(node_key, pin_in_force),
        }
      end
      force_note = 'forced past pin ' .. tostring(pin_in_force.id or '?') .. ': ' .. trim(options.reason)
      pins.set({ node = node_key, node_id = node_id, kind = 'force', state = 'active',
        commit = trim(pin_in_force.commit), binary_sha256 = trim(pin_in_force.binary_sha256),
        reason = 'FORCED PAST: ' .. trim(options.reason) .. ' (pin ' .. tostring(pin_in_force.id or '?') .. ': ' .. tostring(pin_in_force.reason or '') .. ')',
        await = trim(pin_in_force.await), until_ = trim(pin_in_force.until_) })
    else
      -- AN ORDINARY UPDATE IS NOT A RELEASE, AND IT SAYS SO. With no --commit there is no target here to compare
      -- with the pin's awaited commit, so nothing about this move can release it; a pin with no awaited commit
      -- cannot be released by ANY deploy. Claiming otherwise would be the fail-open this whole file is about
      -- (round-3 item 6).
      local no_target = target == '' and (' An ordinary `wa update ' .. node_key ..
        '` with no --commit names no target to compare, so it releases nothing: the pin stays in force after it.') or ''
      return {
        ok = false, error = 'node_pinned', node = node_key, pin = pin_in_force,
        observed = pins.summary_line(pin_in_force) .. (released and released.why and ('; ' .. tostring(released.why)) or ''),
        message = 'the node carries an active pin, so this deploy was refused: a pin is a record that the node was put somewhere on purpose.' .. no_target,
        next = 'move it on purpose: ' .. pins.escape_hatch(node_key, pin_in_force),
      }
    end
  end
  local args = { action = 'request', reason = trim(options.reason), session = trim(options.session) }
  if trim(options.commit) ~= '' then args.commit = trim(options.commit) end
  if options.rendezvous == true then args.rendezvous = true end
  -- The pin this move will write is the SAME record on both sides (item 6: the target node keeps its own copy),
  -- so the awaited commit travels with the request instead of being invented again on the node.
  if trim(options.await) ~= '' then args.await = trim(options.await) end
  if trim(options.until_) ~= '' then args['until'] = trim(options.until_) end
  if force_note then args.force_note = force_note end
  -- One verb, four modes: a tree deploy (default), a binary-only install, a rollback, or the rendezvous.
  local mode = trim(options.mode)
  if mode ~= '' and mode ~= 'tree' then args.mode = mode end
  if options.rollback == true then args.rollback = true end
  local reply = call(selector, M.CAPABILITY, args)
  if type(reply) ~= 'table' then return { ok = false, error = 'remote_answer_unreadable', node = tostring(selector) } end
  local record_id = tostring(reply.record or reply.audit_id or '')
  if record_id ~= '' then
    remember(record_id, {
      node = tostring(reply.target_node and reply.target_node.name or selector),
      node_id = tostring(reply.target_node and reply.target_node.node_id or ''),
      selector = tostring(selector), commit = tostring(reply.commit or args.commit or ''),
      kind = tostring(reply.kind or (args.rollback and 'rollback' or (args.rendezvous and 'rendezvous' or (mode == 'binary' and 'binary' or 'node')))),
      requested_at = tonumber(reply.requested_at) or math.floor(host.now()),
      session = trim(options.session), state = tostring(reply.state or reply.status or 'unknown'),
      request = tostring(reply.request or ''), refused = reply.error ~= nil,
    })
    reply.record = record_id
  end
  reply.node = reply.node or tostring(reply.target_node and reply.target_node.name or selector)
  -- GOING BACK IS A RECORD. A rollback or an explicit --to pins the node where it now is, after the peer has
  -- answered - so a pin never names a move that was refused, and the next ordinary deploy reads it. The pin
  -- is part of the answer (reply.pin); a pin that could not be written is named in reply.pin_problem rather
  -- than dropped, because the move did happen and the missing record is the thing left to fix.
  local kind_name = trim(reply.kind or (args.rollback and 'rollback' or 'node'))
  if reply.ok and (kind_name == 'rollback' or options.pin == 'to') then
    -- WHAT A ROLLBACK PIN NAMES. It used to write commit=unknown with no await, so the pin could never release
    -- by an awaited commit and its only way out was --unpin by hand - a pin that blocked its own fix.
    --
    -- The commit a rollback goes BACK FROM is the one that was installed a moment ago, and the peer reports it
    -- (reply.commit is the replaced commit for a rollback). It is recorded as rolled_back_from and shown in the
    -- pin's own sentence, and it is NOT the awaited commit: the operator names that with --await, because only
    -- the operator can say which landing makes the way forward open again (round-3 item 2).
    local from_commit = trim(options.commit)
    if from_commit == '' and kind_name == 'rollback' then from_commit = trim(reply.commit) end
    -- NO DEFAULT AWAIT (round-3 item 2): only an operator-named --await releases a pin by ancestry, so a
    -- rollback's pin cannot release itself on the deploy that carries the commit it rolled back from.
    local await_default = trim(options.await)
    local written, problem = pins.set({
      node = node_key, node_id = node_id,
      kind = kind_name == 'rollback' and 'rollback' or 'to',
      commit = trim(options.commit) ~= '' and trim(options.commit) or 'unknown',
      rolled_back_from = kind_name == 'rollback' and from_commit or '',
      reason = trim(options.reason) ~= '' and trim(options.reason)
        or (kind_name == 'rollback' and 'rolled back on purpose' or 'moved to a named commit on purpose'),
      until_ = trim(options.until_), await = await_default,
    })
    if written then
      reply.pin = written
      reply.summary = M.summary(reply) .. ' | pin: ' .. tostring(written.summary)
      reply.pin_next = 'this node stays where it is: ' .. pins.escape_hatch(node_key, written)
    else
      reply.pin_problem = problem
      reply.summary = M.summary(reply) .. ' | pin NOT recorded: ' .. tostring(problem and problem.error or 'unknown')
    end
  end
  reply.summary = reply.summary or M.summary(reply)
  return reply
end

-- Read one request back. `notice=true` marks the outcome delivered for `session` and answers once:
-- a second call with the same session gets the same facts but `notice=false`, so a session is not
-- woken twice for one deploy and not told "installed" twice.
function M.status(call, selector, options)
  options = type(options) == 'table' and options or {}
  local id = trim(options.id)
  if id == '' then id = trim(options.record) end
  local args = { action = 'status' }
  if id ~= '' then args.id = id end
  local reply = call(selector, M.CAPABILITY, args)
  if type(reply) ~= 'table' then return { ok = false, error = 'remote_answer_unreadable', node = tostring(selector) } end
  if reply.error then
    reply.node = reply.node or tostring(selector)
    reply.summary = M.summary(reply)
    return reply
  end
  local record_id = tostring(reply.record or id)
  local pending = M.pending(record_id)
  local session = trim(options.session)
  if session == '' and pending then session = trim(pending.session) end
  local settled = reply.state == 'installed' or reply.state == 'failed' or reply.state == 'silent'
  local notice = false
  if settled and pending and session ~= '' and trim(pending.session) == session and trim(pending.notified_at) == '' then
    remember(record_id, { notified_at = math.floor(host.now()), notified_state = tostring(reply.state), session = session })
    notice = true
  end
  reply.record = record_id
  reply.node = reply.node or tostring(reply.target_node and reply.target_node.name or selector)
  reply.notice = notice
  reply.summary = M.summary(reply)
  if notice then
    reply.notice_text = string.format('[remote update] %s: %s is %s. %s', tostring(reply.node), tostring(reply.commit or ''):sub(1, 12),
      tostring(reply.state), tostring(reply.detail or ''))
  end
  return reply
end

-- The one thing this module adds to a session: a wake that comes back to ask. The peer cannot wake
-- a session on another node (see the header), so the requesting session owns the follow-up; this
-- schedules it with the harness's own `selfloop` and the prompt names the exact call to make.
function M.schedule_followup(session, node, reply, in_seconds)
  if type(session) ~= 'table' or trim(session.session_id) == '' then return nil end
  local ok, selfloop = pcall(dofile, 'lua/core/selfloop.lua')
  if not ok or type(selfloop) ~= 'table' or type(selfloop.schedule) ~= 'function' then return nil end
  local record_id = tostring(reply and reply.record or '')
  local prompt = string.format(
    'Remote update of %s (%s%s) was queued%s. Read its outcome with the node_update tool: {"node":"%s","action":"status","id":"%s"}, then report what is installed. Queued is not installed.',
    tostring(node), tostring(reply and reply.commit or 'origin/main'):sub(1, 12),
    (reply and reply.kind == 'rendezvous') and ', rendezvous deploy' or '',
    record_id ~= '' and (' as record ' .. record_id) or '', tostring(node), record_id)
  local scheduled = selfloop.schedule({
    in_seconds = tonumber(in_seconds) or 180,
    reason = 'remote update of ' .. tostring(node) .. ' ' .. tostring(reply and reply.commit or ''):sub(1, 12),
    prompt = prompt,
  }, session)
  if type(scheduled) ~= 'table' or scheduled.error then return nil end
  return scheduled
end

-- What the peer would do, without asking it to do it. Read-only on both sides: one signed call whose
-- handler (`M.check`) gathers facts and writes nothing.
function M.inspect(call, selector, options)
  options = type(options) == 'table' and options or {}
  local reply = call(selector, M.CAPABILITY, { action = 'check' })
  if type(reply) ~= 'table' then return { ok = false, error = 'remote_answer_unreadable', node = tostring(selector) } end
  reply.node = reply.node or tostring(selector)
  return reply
end

-- ---------------------------------------------------------------- the CLI half
--
-- `wa update <node> [--commit <sha>] [--rendezvous]` asks another node to update itself;
-- `wa update <node> --status [--id <record>]` reads back what it installed. With no node named,
-- `wa update` is exactly what it was: this node updating itself (lua/core/update.lua). The CLI is
-- the same two calls the `node_update` tool makes, so a human and a model see one answer.
--
-- Returns nil when the arguments do not name a node, so the caller keeps its local path, and an exit
-- code otherwise (0 settled/queued, 1 refused) - a script can tell a refusal from a result.
function M.cli(argv)
  argv = type(argv) == 'table' and argv or {}
  local selector = argv[2]
  if type(selector) ~= 'string' or selector == '' or selector:sub(1, 2) == '--' then return nil end
  local options, as_json = {}, false
  local index = 3
  while argv[index] do
    local flag = tostring(argv[index])
    if flag == '--json' then as_json = true; index = index + 1
    elseif flag == '--rendezvous' then options.rendezvous = true; index = index + 1
    elseif flag == '--binary' then options.mode = 'binary'; index = index + 1
    elseif flag == '--tree' then options.mode = 'tree'; index = index + 1
    elseif flag == '--rollback' then options.rollback = true; index = index + 1
    elseif flag == '--force' then options.force = true; index = index + 1
    elseif flag == '--unpin' then options.unpin = true; index = index + 1
    elseif flag == '--pin' then options.pin = true; index = index + 1
    elseif flag == '--to' or flag == '--until' or flag == '--await' or flag == '--bytes' then
      local value = argv[index + 1]
      if type(value) ~= 'string' or value == '' or value:sub(1, 2) == '--' then
        print('wa update: ' .. flag .. ' needs a value')
        return 1
      end
      if flag == '--to' then options.commit = value; options.pin = 'to'
      elseif flag == '--until' then options.until_ = value
      elseif flag == '--bytes' then options.bytes = value
      else options.await = value end
      index = index + 2
    elseif flag == '--status' or flag == '--watch' then options.status = true; index = index + 1
    elseif flag == '--commit' or flag == '--id' or flag == '--reason' or flag == '--session' or flag == '--node' then
      local key = flag:sub(3)
      local value = argv[index + 1]
      if type(value) ~= 'string' or value == '' or value:sub(1, 2) == '--' then
        print('wa update: ' .. flag .. ' needs a value')
        return 1
      end
      options[key] = value
      index = index + 2
    elseif flag == '--help' or flag == '-h' then
      print('wa update <node> [--commit <sha>] [--binary|--tree] [--rendezvous] [--reason <text>] [--session <id>] [--json]')
      print('wa update <node> --status [--id <record>] [--json]')
      print('wa update <node> --rollback   put back the pair that node\'s last install replaced, and PIN it there')
      print('wa update <node> --to <sha>   move it to that commit on purpose, and PIN it there')
      print('wa update <node> --pin [--commit <sha>] [--bytes <sha256>]   record a pin only; nothing is deployed')
      print('wa update <node> --unpin --reason <text>                     release the pin here AND on the node; says what was released')
      print('  --reason <text>  why. Required for --pin, --unpin and --force; it is stored with the record')
      print('  --until <text>   an optional condition or date; a date that has passed is reported OVERDUE')
      print('  --await <sha>    the commit whose landing releases the pin; a target that contains it is not blocked')
      print('  --force          do the move anyway. A pinned node and a known downgrade both refuse without it')
      print('wa update                 update this node (the local deploy request)')
      print('  --binary   install the published release only (a node with no toolchain; never builds there)')
      print('  --tree     the default: the node\'s own Sentinel deploys its tree (build or published binary)')
      return 0
    else
      print('wa update: unknown option ' .. flag .. '; nothing was asked')
      return 1
    end
  end
  if options.session == nil and host.getenv then
    local ambient = trim(host.getenv('WA_SESSION_ID'))
    if ambient ~= '' then options.session = ambient end
  end
  local reply
  if options.unpin then
    -- UNPIN NAMES THE NODE, SAYS WHY, AND REACHES THE NODE'S OWN STORE (round-3 item 5).
    --
    -- What this used to do: clear the COORDINATOR's store only, take no reason, and answer "unpinned <node>:
    -- ordinary deploys may move it again". Both halves of that were wrong. A pin is written twice - here, and in
    -- the node's own pins.txt by its own rollback - and the install scripts read the NODE's copy, so the node went
    -- on refusing every install started on it while the operator had been told it was free. And a release with no
    -- reason is a decision nobody can review, which is the rule every other override in this tree follows.
    local reason = trim(options.reason)
    if reason == '' then
      reply = { ok = false, node = selector, error = 'unpin_reason_required',
        message = 'releasing a pin is a decision nobody can review if it does not say why, and this one is written into the node\'s own record.',
        next = 'say why: wa update ' .. tostring(selector) .. ' --unpin --reason <text>; nothing was released' }
    elseif #reason > 400 then
      reply = { ok = false, node = selector, error = 'reason_too_long', limit = 400 }
    else
      -- 1. this coordinator's own store: what the deploy gate here reads.
      local here, here_problem = pins.clear(selector, { reason = reason, kind = 'unpin' })
      local here_text
      if here then
        here_text = 'this coordinator\'s store: released (it was pinned to ' ..
          tostring(here.commit or 'unknown'):sub(1, 12) .. ')'
      else
        here_text = 'this coordinator\'s store: nothing to release (' ..
          tostring(here_problem and here_problem.error or 'no pin') .. ')'
      end
      -- 2. the node's own store, through the capability the node serves. A release that does not arrive is
      -- reported as exactly that; the message never says the node may move when it may not.
      local peer = nodes.remote_call(selector, M.CAPABILITY, { action = 'unpin', reason = reason })
      local peer_text, peer_ok
      if type(peer) ~= 'table' then
        peer_ok = false
        peer_text = 'the node did NOT answer, so its own pin is still in force'
      elseif peer.error then
        peer_ok = false
        peer_text = 'the node refused (' .. tostring(peer.error) .. ')' ..
          (peer.message and (' - ' .. tostring(peer.message)) or '') .. ', so its own pin is still in force'
      elseif peer.released == true then
        peer_ok = true
        peer_text = 'the node\'s own store: ' .. tostring(peer.message or 'released')
      else
        peer_ok = true
        peer_text = 'the node\'s own store: nothing to release (' .. tostring(peer.status or 'no pin') .. ')'
      end
      reply = { ok = peer_ok, status = peer_ok and 'unpinned' or 'partly_released', node = selector,
        pin = here, peer = peer, reason = reason,
        message = 'unpin ' .. tostring(selector) .. ': ' .. here_text .. '; ' .. peer_text,
        summary = 'unpin ' .. tostring(selector) .. ': ' .. here_text .. '; ' .. peer_text }
      if not peer_ok then
        reply.error = 'node_pin_not_released'
        reply.next = 'the node keeps refusing installs while its own pin stands: fix the path to it (wa nodes), or run wa update ' ..
          tostring(selector) .. ' --unpin --reason <text> ON that node. This coordinator\'s copy was cleared; the node\'s was not.'
      end
    end
  elseif options.pin == true then
    -- Record-only: with --commit it records that commit, without one it records that nobody can name the
    -- bytes yet (a binary older than --build-info). It never deploys - this is the form used to write a pin
    -- for a move that already happened by hand, which is how the three 18/11 rollbacks were recorded.
    local written, problem = pins.set({
      node = selector, kind = 'pin',
      commit = trim(options.commit),
      -- A binary older than --build-info cannot name a commit, and the record it left beside itself is a
      -- claim. The bytes can still be named by their sha256, so a pin that cannot name a commit names those.
      binary_sha256 = trim(options.bytes),
      reason = trim(options.reason),
      until_ = trim(options.until_), await = trim(options.await),
    })
    if not written then
      reply = { ok = false, node = selector, error = tostring(problem and problem.error or 'pin_not_written'),
        observed = tostring(problem and problem.observed or '') }
    else
      reply = { ok = true, status = 'pinned', node = selector, pin = written,
        message = 'recorded: ' .. tostring(selector) .. ' is pinned. Nothing was deployed and the node was not touched.',
        summary = 'pinned ' .. tostring(selector) .. ': ' .. tostring(written.summary) }
    end
  elseif options.status then reply = M.status(nodes.remote_call, selector, options)
  else reply = M.request(nodes.remote_call, selector, options) end
  if as_json then
    print(json.encode(reply))
  elseif reply.error then
    print(M.summary(reply))
    if reply.next then print('next: ' .. tostring(reply.next)) end
  elseif options.status then
    if reply.notice and reply.notice_text then print(reply.notice_text) end
    print(M.summary(reply))
    if reply.installed_binary and reply.installed_binary.source then
      print('binary: ' .. tostring(reply.installed_binary.source) .. (reply.installed_binary.release and (' ' .. tostring(reply.installed_binary.release)) or ''))
    end
    if reply.state ~= 'installed' and reply.state ~= 'failed' and reply.state ~= 'silent' then
      print('next: ask again with the same --id; queued is not installed')
    end
  else
    -- A reply that wrote a pin carries the pin's own sentence (lua/core/pins.lua's summary_line): "pinned X: ...
    -- until ... (OVERDUE)" says more than the generic deploy summary, and the message says what did NOT happen.
    print(reply.summary or M.summary(reply))
    if reply.pin and reply.message then print(reply.message) end
    if reply.record then print('record ' .. tostring(reply.record) .. (options.session and (' for session ' .. options.session) or '')) end
    if reply.next then print('next: ' .. tostring(reply.next)) end
  end
  if reply.error then return 1 end
  if options.status and reply.state == 'failed' then return 1 end
  return 0
end

return M
