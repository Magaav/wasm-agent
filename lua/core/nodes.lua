-- Node registry: this node plus peers discovered through the rendezvous.
--
-- Nodes bind by ed25519 key, not address. The rendezvous is the source of truth
-- for a peer's public key, so a caller is only trusted when its key matches what
-- the rendezvous has on file.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
local enrollment = dofile("lua/core/enrollment.lua")
local M = {}

-- The environment a probe child is started with (see probe_peers). A child started before this name
-- existed inherits nothing and is caught by its argv, which carries the same word.
M.PROBE_CHILD_ENV = "WA_NODES_PROBE_CHILD"

local CACHE_TTL = 15
local cache, cache_at = nil, 0
local operator_cache = {} -- node_id -> { at, value }: see M.operator_status

function M.rendezvous_url()
  local binding=dofile('lua/core/binding.lua')
  if binding.present() then local s=binding.saved();return s and s.service or '' end
  return host.getenv("WASM_AGENT_RENDEZVOUS") or ""
end

function M.identity()
  local ok, raw = pcall(host.node_identity)
  if not ok or not raw then return nil end
  return json.decode(raw)
end

-- Where a name someone chose is kept: beside the identity, because a name belongs to the
-- node rather than to the shell that started it. A restart must not forget it.
function M.name_file()
  return paths.config() .. "/node.name"
end

-- A node is either the master's own workspace or a guest that carries out a master's wishes on
-- its own directory. The difference is not decoration: a guest has no worktree *identity*, so
-- it is never named after one and a rename never moves a branch on its behalf. It still edits
-- files on this machine when a master asks - that is what a guest is for - but the work belongs
-- to the master who asked, not to the guest.
function M.role_file()
  return paths.config() .. "/node.role"
end

-- `guest` when either the environment or the role file says so, `master` otherwise. An
-- unrecognised value is a master rather than a silent guest: a typo must not quietly demote a
-- node that is in the middle of work.
function M.role()
  if enrollment.managed() then return enrollment.role() end
  local from_env = tostring(host.getenv("WASM_AGENT_NODE_ROLE") or ""):lower():gsub("%s+", "")
  if from_env ~= "" then return from_env == "guest" and "guest" or "master" end
  local stored = host.read_file(M.role_file())
  if type(stored) == "string" then
    stored = stored:lower():gsub("%s+", "")
    if stored ~= "" then return stored == "guest" and "guest" or "master" end
  end
  return "master"
end

function M.is_master()
  return M.role() == "master"
end

-- The author of a call from a peer.
--
-- `verify_peer` in server.lua has already refused a caller whose node is not a master, so this
-- returns the master's name and nothing else: a guest cannot command a peer, and a node
-- executing a master's wish signs the result with the master's name. The default is the safe
-- one - a caller record with no role at all is not a master.
local function normalize_role(role)
  if role == "admin" then return "master" end
  return role or "guest"
end

function M.author_of(caller)
  if enrollment.managed() then return enrollment.author(caller) end
  if type(caller) ~= "table" then return nil end
  if normalize_role(caller.role) ~= "master" then return nil end
  -- Who is allowed to be a master at all. The rendezvous only grants master to its operator's
  -- WASM_AGENT_NETWORK_ADMINS, but it is still a third party. With this set, an enrolled list of
  -- node ids decides instead. Ids only: an id is the hash of the key the caller signed with, while a
  -- name is whatever the caller registered, so matching a name would let any node claim to be one.
  -- Unset means "the rendezvous is the authority" - said out loud here so the choice is visible.
  local enrolled = tostring(host.getenv("WASM_AGENT_TRUSTED_MASTERS") or "")
  if enrolled ~= "" then
    local node_id = tostring(caller.node_id or "")
    local name = tostring(caller.name or "")
    for entry in enrolled:gmatch("[^,]+") do
      entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
      if entry ~= "" and entry == node_id then return name ~= "" and name or node_id end
    end
    return nil
  end
  local name = tostring(caller.name or "")
  if name ~= "" then return name end
  local id = tostring(caller.node_id or "")
  if id ~= "" then return id end
  return nil
end

-- Requests already answered, so a signature captured on the wire cannot be replayed inside the
-- window where it is still fresh. Keyed by the whole request (caller, action, timestamp and
-- signature), so replaying it is the only way to collide with it - and a forgery cannot produce
-- the same key without the same signature. Kept in SQLite, not in this interpreter: the node runs
-- several interpreters and restarts on deploys, and a per-interpreter table let the same request
-- run once on each of them.
function M.seen_before(id)
  return enrollment.seen_before(id)
end

-- What a human calls this node when four of them are in a list.
--
-- Order: a name someone set, then the *branch this node is standing on* (which is the node's
-- name by construction - see AGENTS.md, "Which branch am I on?"), then the worktree directory,
-- then the environment, then "host". The branch comes before the environment deliberately: a
-- list of nodes should read as a list of checkouts, and WASM_AGENT_NODE_NAME is the older
-- mechanism - a leftover value in a shell profile would otherwise make every node on the
-- machine claim the same name, which is the confusion this exists to remove.
function M.node_name()
  local stored = host.read_file(M.name_file())
  if type(stored) == "string" then
    local trimmed = stored:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then return trimmed end
  end
  -- Only a master's node is named after its worktree. A guest has no worktree identity of its
  -- own - it carries out a master's wishes on this machine - so the directory it happens to be
  -- running in is not its name.
  if M.is_master() then
    local dir = M.worktree()
    if dir and dir ~= "" then return dir end
  end
  local configured = host.getenv("WASM_AGENT_NODE_NAME")
  if configured and configured ~= "" then return configured end
  return "host"
end

-- The directory name of the checkout this node was started in, or "" when it cannot be
-- known. This is the default name, not a promise that the node is in a worktree.
function M.worktree()
  local cwd = platform.cwd()
  if type(cwd) ~= "string" or cwd == "" then return "" end
  local normal = function(path)
    return tostring(path):gsub("\\", "/"):gsub("/+$", ""):lower()
  end
  -- A node started from a home directory is not working in a project: "Victor" or
  -- "ubuntu" as a node name is noise, and the machine name (or an explicit setting) says
  -- more. The name answers "which checkout am I?", so a directory that is not a checkout
  -- says nothing at all.
  if normal(cwd) == normal(paths.home()) then return "" end
  local dir = cwd:gsub("/+$", ""):match("([^/]+)$")
  return dir or ""
end

-- Run a command and read the result. host.exec hands it back as a JSON string, not a
-- table, so the code has to be decoded rather than compared directly.
local function run(command)
  local ok, raw = pcall(host.exec, command, "")
  if not ok then return nil end
  local ok2, decoded = pcall(json.decode, raw)
  if not ok2 or type(decoded) ~= "table" then return nil end
  return decoded
end

-- The branch this node is on, or "" when it is not in a checkout at all.
function M.branch()
  local result = run("git rev-parse --abbrev-ref HEAD")
  if not result then return "" end
  local name = tostring(result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

-- One branch per node, plus main: that is the whole point of the node's own branch. So a node
-- rename renames its branch - and only its own. A node sitting on main, or on a branch that is
-- not the name it currently answers to, is refused rather than allowed to rename someone
-- else's branch out from under them.
--
-- Returns true plus a note, or nil plus a reason.
function M.rename_branch(from, to)
  -- A guest owns no branch, so there is none to move. Refused rather than silently skipped:
  -- a caller asking for a rename should hear that it did not happen.
  if not M.is_master() then return nil, "guest_has_no_branch" end
  local current = M.branch()
  if current == "" then return nil, "not_a_git_checkout" end
  if current == "main" or current == "master" then return nil, "refusing_to_rename_main" end
  if current ~= from then return nil, "node_is_on_branch_" .. current end
  -- The name is validated before it gets here: word characters, spaces, dot, underscore, dash.
  -- No quote can appear, so single-quoting it for the shell is enough.
  local function sh(command) return run(command) end
  local function failed(result) return not result or tonumber(result.code) ~= 0 end
  if failed(sh("git branch -m '" .. to .. "'")) then return nil, "local_rename_failed" end
  if failed(sh("git push -u origin '" .. to .. "'")) then
    sh("git branch -m '" .. from .. "'")
    return nil, "github_push_failed"
  end
  if failed(sh("git push origin --delete '" .. from .. "'")) then
    -- Both names are on GitHub now. Put GitHub back to one rather than leaving the tree and the
    -- remote disagreeing about which branch this node is.
    sh("git push origin --delete '" .. to .. "'")
    sh("git branch -m '" .. from .. "'")
    return nil, "github_delete_failed"
  end
  return true, "branch_renamed"
end

-- Rename this node. Returns the new name, or nil plus a reason.
--
-- The name is validated rather than trusted: it appears in lists and in log lines, so a
-- newline or a control character in it would forge structure somewhere downstream.
function M.set_name(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil, "node_name_required" end
  if #name > 40 then return nil, "node_name_too_long" end
  -- A space literal, not %s: %s matches newlines, and a name with a newline in it forges
  -- structure in every list and log line it reaches.
  if not name:match("^[%w][%w %._%-]*$") then return nil, "node_name_invalid" end
  -- Third party first. A name the node's own branch disagrees with is the state this exists to
  -- prevent, so the branch moves (locally and on GitHub) before the node believes anything.
  local previous = M.node_name()
  -- A master's rename stays transactional - branch first (locally, then GitHub), name second.
  -- A guest takes a name without touching a branch, because it has none to move.
  local transactional = M.is_master()
  if transactional and previous ~= name then
    local renamed, note = M.rename_branch(previous, name)
    if not renamed then return nil, note end
  end
  local ok, wrote = pcall(host.write_file, M.name_file(), name .. "\n")
  if not ok or wrote == false then
    -- The branch moved and the name could not be written: give the branch back, or the tree and
    -- the node would be left pointing at each other with different names.
    if transactional and previous ~= name then M.rename_branch(name, previous) end
    return nil, "node_name_write_failed"
  end
  M.invalidate()
  return name
end

local function decode_body(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then return nil end
  return value
end
M.decode_body = decode_body

local function fetch_peers(fresh, cached_only)
  local url = M.rendezvous_url()
  if url == "" then return {} end
  local now = host.now()
  -- `fresh` skips the cache. A step that changes state - may this caller run tools on this
  -- node - must not be made from a list read fifteen seconds ago: a peer removed from the
  -- rendezvous would stay welcome here for the rest of the window. A display can live with that;
  -- a capability check cannot.
  if not fresh and cache and ((now - cache_at) < CACHE_TTL or cached_only) then return cache end
  -- `cached_only` is the display that must not wait: a roster snapshot taken *inside* a run, by an
  -- interpreter that will hand it to the client (lua/core/local_views.lua). An empty cache answers
  -- with this node alone, which is true and cheap; a network read here would put the rendezvous'
  -- latency inside somebody else's turn.
  if cached_only then return cache or {} end
  local peers, read_ok = {}, false
  pcall(function()
    local headers = json.encode(M.signed_headers("nodes") or {})
    local response = decode_body(host.http("GET", url:gsub("/+$", "") .. "/nodes", headers, ""))
    if response and tonumber(response.status) == 200 then
      local ok, payload = pcall(json.decode, response.body)
      if ok and type(payload) == "table" and type(payload.nodes) == "table" then
        peers = payload.nodes
        read_ok = true
      end
    end
  end)
  -- Whether the last roster read could reach the registry, so a caller can tell "no such peer" from
  -- "I could not ask". Without it a COLD cache during an outage answered unknown_node for every name,
  -- which reads as "that node never existed" when the truth is "the rendezvous was unreachable".
  M.roster_last_read = read_ok and {ok = true, at = now} or {ok = false, at = now, error = "roster_unavailable"}
  if not read_ok then
    -- A roster read that FAILED is not a roster that is empty. Measured 19/11 ~12:17 UTC, home
    -- network down: 38 relay detaches, and when the laptop had internet again `wa nodes` listed only
    -- itself - every peer had been replaced by the empty answer of a failed read, so every
    -- `wa call <peer>` was unknown_node:<peer> until a restart. A peer that is merely unreachable
    -- stays KNOWN and is marked offline, with when it was last seen; only a read that succeeded may
    -- remove one from the roster.
    local kept = {}
    for _, peer in ipairs(cache or {}) do
      local copy = {}
      for key, value in pairs(peer) do copy[key] = value end
      copy.online = false
      copy.last_seen = peer.last_seen or cache_at
      copy.roster_stale = true
      kept[#kept + 1] = copy
    end
    -- The cache is served with a short TTL, so a link that is still down is retried, and a link that
    -- came back is re-read. The peers themselves are never dropped by a failed read.
    cache, cache_at = kept, now - CACHE_TTL + 1
    return kept
  end
  cache, cache_at = peers, now
  return peers
end

function M.peers(opts)
  return fetch_peers(type(opts) == "table" and opts.fresh)
end

function M.invalidate()
  cache, cache_at = nil, 0
  operator_cache = {}
end

-- Probe peers AT ONCE, through one supervised child process each, and answer { <node_id> = {capabilities, reason} }.
--
-- WHY PROCESSES: host.http is one blocking call, so a loop over peers is a sum of their timeouts. The only
-- concurrency this node has is supervised operations (host.operation), and a child "wa nodes probe <id>" is
-- the same probe with its own process, its own cache and its own deadline. The children are started
-- together, awaited together, and a child that cannot start is left out of the answer so the caller falls
-- back to the in-process probe and says the same named reason as before.
--
-- PROBE_DEADLINE_S bounds the whole fan-out, so a hundred unreachable peers cost one deadline, not a hundred.
local PROBE_DEADLINE_S = 20
-- HOW MANY PROBE CHILDREN THIS PROCESS MAY HAVE ALIVE (item 0, the 19/11 OOM).
--
-- A child lives up to PROBE_DEADLINE_S. M.list is called many times inside one turn (a row, a view, a
-- tool), and every call started one child per peer with no memory of the call before it, so children
-- ACCUMULATED: measured in scripts/test-remote-refusals.lua, 125 live "wa nodes probe" processes for a
-- 6-peer roster, each ~14-70 MB - the crowd that took the node to 23 GB.
-- The registry is process-wide for the same reason the marker is (dofile gives every caller its own M
-- table): a second call inside the deadline JOINS the running child for that peer, and past the cap this
-- process starts no more and names the reason (probe_capacity) instead of forking an unbounded tree.
--   _G.WA_PROBE_INFLIGHT[peer_id] = { op = <operation_id>, at = <host.now()> }
local PROBE_MAX_CHILDREN = 64

-- HOW MANY PROBE CHILDREN ARE ALIVE FOR THIS LEDGER, ACROSS EVERY PROCESS (item 0, growth D).
--
-- The registry below is ONE process memory, and measurement at row 37 of a --jobs 2 run showed why that
-- is not enough: 554 live wa nodes-probe children, about 92 PER PEER, with their parents already
-- re-parented to systemd --user. Ninety-two separate processes had each started its own set and none
-- could see the others. The bound therefore has to be asked of something the processes SHARE, and the
-- node already has one: the operation table. host.operation list answers every operation this ledger
-- knows, each with its owner, so this asks it - and asks defensively, because a host without the verb
-- must still probe (one named reason, never a crash).
--
-- The rule: if this ledger already has PROBE_MAX_CHILDREN live children owned by nodes-probe, start
-- none and say probe_capacity by name. A peer whose child is already running is joined, not duplicated.
local PROBE_OWNER = "nodes-probe"
-- The host caps one await at 10 s and defaults to 1 s (operations.rs); a slice is what makes a long
-- deadline a real wait instead of a 1 s look followed by a cancel.
local PROBE_WAIT_SLICE_MS = 5000

-- THE REGISTRY THAT ACTUALLY BOUNDS IT IS A FILE, NOT A TABLE (item 0, growth E, measured).
--
-- Both guards above are per Lua STATE, and a codemode run gets a FRESH one: measured on this node, one
-- row ran 92 sandboxed scripts and each of them saw an empty registry, so one row alone started 552 probe
-- children (~92 per peer). The only thing every state in this node shares is the disk.
--
-- So a lease is a small JSON file in the node's OWN data directory: a list of {at, peer}. A run reads it,
-- drops entries older than PROBE_DEADLINE_S (that child is gone), and either JOINS the entry for its peer,
-- writes one more, or - when the list is already PROBE_MAX_CHILDREN long - starts nothing and says
-- probe_capacity by name. The file is small, it is written at most once per peer per deadline, and a write
-- that fails degrades to the per-process table above with the reason named (never to an unbounded tree).
-- THIS PROCESS, BY SOMETHING NO OTHER PROCESS CAN WEAR (review r2, B/MUST 3).
--
-- The lease used to record the NODE id as its owner, and that is the same string for every process on
-- the node: a second state read "owner" and believed the child was its own, so it awaited an id the
-- host refuses (operation_not_yours) and every peer answered probe_leaseholder_pending. The key must
-- name the PROCESS. pid alone is not enough either - pids are reused - so it is the pid plus the
-- kernel's boot id, which is stable for a boot and different after a reboot. Measured: /proc/sys/
-- kernel/random/boot_id exists on Linux; where it does not, the pid alone is used and the key says so.
local function probe_process_key()
  -- The host already reports both halves (measured: runtime_info carries boot_id and process_id), so
  -- nothing is read from /proc and nothing is invented.
  local runtime = json.decode(host.runtime_info and host.runtime_info() or "") or {}
  local pid = tostring(runtime.process_id or "")
  local boot = tostring(runtime.boot_id or "")
  if pid == "" then pid = tostring(host.now()) end
  if boot ~= "" then return "pid:" .. pid .. ":boot:" .. boot end
  return "pid:" .. pid
end

-- A DIRECTORY OF ONE FILE PER PROCESS, NOT ONE FILE (review r2, B/MUST 4).
--
-- The single lease file was read, merged and written back by every caller: an unlocked
-- read-modify-write, so two states writing at once lost one of the two entries - and the entry lost was
-- exactly the child the other one was about to join. The host has no flock, no rename and no O_EXCL
-- (measured: host.exec, host.read_file, host.list_dir, host.write_file and no locking primitive), so the
-- fix is to remove the shared write entirely: each process owns <dir>/<process-key>.json and writes ONLY
-- that file. There is no merge to lose. A reader lists the directory and reads every file, and a file
-- whose own `at` is past the deadline belongs to a process that is gone.
local function probe_lease_dir()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok or type(paths) ~= "table" or type(paths.data) ~= "function" then return nil end
  local dir = paths.data()
  if type(dir) ~= "string" or dir == "" then return nil end
  return dir .. "/nodes-probe-inflight"
end

local function probe_lease_file()
  local dir = probe_lease_dir()
  if not dir then return nil end
  local key = probe_process_key():gsub("[^%w]", "_")
  return dir .. "/" .. key .. ".json"
end

local function probe_lease_entries(raw, now, live)
  local decoded = json.decode(raw)
  local rows = type(decoded) == "table" and (decoded.peers or decoded) or {}
  if type(rows) ~= "table" then return end
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local at = tonumber(row.at or 0) or 0
      local peer = tostring(row.peer or "")
      if peer ~= "" and (now - at) < PROBE_DEADLINE_S then
        -- KEEP THE WHOLE ENTRY: result (the answer the holder published), op (its operation id, awaitable
        -- only by the caller that owns it) and owner (which caller that is).
        live[#live + 1] = { at = at, peer = peer, op = tostring(row.op or ""),
          owner = tostring(row.owner or ""), result = type(row.result) == "table" and row.result or nil }
      end
    end
  end
end

-- READ EVERY PROCESS FILE, not one shared one (review r2, B/MUST 4): each process writes only
-- <dir>/<its own key>.json, so a reader merges by listing the directory. A file this process cannot read
-- is skipped, not fatal - another run being killed mid-write must not blind this one.
local function probe_lease_read(dir, now)
  if type(dir) ~= "string" or dir == "" then return {} end
  local live = {}
  local listed = host.list_dir and host.list_dir(dir) or nil
  if type(listed) == "string" then listed = json.decode(listed) end
  for _, item in ipairs(type(listed) == "table" and (listed.entries or {}) or {}) do
    local name = tostring(type(item) == "table" and item.name or "")
    if name:match("%.json$") then
      local ok, raw = pcall(host.read_file, dir .. "/" .. name)
      if ok and type(raw) == "string" and raw ~= "" then probe_lease_entries(raw, now, live) end
    end
  end
  return live
end

local function probe_lease_write(path, live)
  -- REVIEW r1 MUST 5: this was `local ok = pcall(...); return ok`, which is true whenever the CALL did
  -- not raise - so probe_lease_unwritable could never fire for a write the host refused. The host
  -- returns its own success flag; both are required.
  local ok, wrote = pcall(host.write_file, path, json.encode({ peers = live }))
  return ok and wrote ~= false and wrote ~= nil
end
local function probe_children_alive(now)
  if type(host.operation) ~= "function" then return nil, "no_operation_host" end
  local ok, raw = pcall(host.operation, "list", json.encode({}))
  if not ok or type(raw) ~= "string" then return nil, "operation_list_unavailable" end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return nil, "operation_list_unreadable" end
  local rows = decoded.operations or decoded.ops or decoded
  if type(rows) ~= "table" then return nil, "operation_list_shape" end
  local alive = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" and tostring(row.owner or "") == PROBE_OWNER then
      local state = tostring(row.state or row.status or "")
      local started = tonumber(row.started_at or row.created_at or 0) or 0
      local fresh = (started == 0) or ((now - started) < PROBE_DEADLINE_S)
      local live = (state == "" or state == "running" or state == "started" or state == "accepted" or state == "pending")
      if live and fresh then
        local key = tostring(row.label or row.id or row.operation_id or "")
        if key ~= "" then alive[key] = true end
      end
    end
  end
  local count = 0
  for _ in pairs(alive) do count = count + 1 end
  return count
end

local function probe_inflight()
  local t = _G.WA_PROBE_INFLIGHT
  if type(t) ~= "table" then t = {}; _G.WA_PROBE_INFLIGHT = t end
  local now, alive = host.now(), 0
  for id, entry in pairs(t) do
    if type(entry) == "table" and (now - tonumber(entry.at or 0)) < PROBE_DEADLINE_S then
      alive = alive + 1
    else
      t[id] = nil -- past its deadline: that child is not running any more
    end
  end
  return t, now, alive
end

local function probe_peers(peers, opts)
  opts = opts or {}
  if type(host.operation) ~= "function" then return {} end
  local runtime = json.decode(host.runtime_info and host.runtime_info() or "") or {}
  local program = tostring(runtime.binary_path or "")
  if program == "" then return {} end
  local inflight, now, alive = probe_inflight()
  -- The lease is a DIRECTORY of one file per process (see probe_lease_dir): lease_path names this
  -- process own file, lease_dir the directory every state reads.
  local lease_dir = probe_lease_dir()
  local lease_path = probe_lease_file()
  local lease, lease_why = nil, nil
  if lease_path then
    local ok, live = pcall(probe_lease_read, lease_dir, now)
    if ok and type(live) == "table" then lease = live else lease_why = "probe_lease_unreadable" end
  else
    lease_why = "probe_lease_no_data_dir"
  end
  -- host.operation(list) answers only THIS process (measured), so it is a floor, never the authority.
  local shared, why_shared = probe_children_alive(now)
  _G.WA_PROBE_SHARED_BOUND = why_shared or nil
  if shared and shared > alive then alive = shared end
  local launched, at_capacity = {}, {}
  local lease_join, lease_add = {}, {}
  if lease then
    for _, entry in ipairs(lease) do lease_join[entry.peer] = entry end
    alive = math.max(alive, #lease)
  end
  -- THE RESULT A LEASEHOLDER PUBLISHES (review item 1). A joiner must never await the holder id: that
  -- id belongs to ANOTHER caller, and the host refuses an await from a session that does not own it
  -- (rust/wa-capabilities/src/operations.rs, owned()). Measured shape of the defect: a joiner recorded
  -- "lease:<peer>", the await was refused, the code cancelled it and answered probe_timeout - 20 s of
  -- waiting for an answer that was already on disk. The lease now carries the holder ANSWER, written
  -- when the child settles, and a joiner reads it instead of awaiting anything.
  local published, published_at = {}, {}
  if lease then
    for _, entry in ipairs(lease) do
      if type(entry.result) == "table" then
        published[entry.peer] = entry.result
        -- WHEN that answer was produced, so a caller can say how old what it was told is (23/11).
        published_at[entry.peer] = tonumber(entry.at) or now
      end
    end
  end
  for _, peer in ipairs(peers or {}) do
    local id = tostring(peer.node_id or "")
    if id ~= "" then
      local running = inflight[id]
      local joined = lease_join[id]
      if published[id] then
        launched[#launched + 1] = { id = id, joined = true, from_lease = true, result = published[id],
          at = published_at[id] }
      elseif type(joined) == "table" and joined.result ~= nil then
        launched[#launched + 1] = { id = id, joined = true, from_lease = true, result = joined.result,
          at = tonumber(joined.at) or now }
      elseif type(joined) == "table" and joined.owner == probe_process_key() then
        -- The lease is OURS: this process (or a state in it) owns the child, so awaiting its real id is
        -- allowed and is the honest way to get the answer. Only an owned child may be awaited.
        launched[#launched + 1] = { id = id, operation_id = joined.op, joined = true, owned = true }
      elseif type(joined) == "table" then
        -- Another caller owns the child and has not published yet: WAIT ON THE LEASE FILE, never on its
        -- operation id. The holder writes the result when the child settles.
        launched[#launched + 1] = { id = id, wait_lease = true, joined = true }
      elseif type(running) == "table" and (now - tonumber(running.at or 0)) < PROBE_DEADLINE_S then
        launched[#launched + 1] = { id = id, operation_id = running.op, joined = true }
      elseif alive >= PROBE_MAX_CHILDREN then
        at_capacity[#at_capacity + 1] = id
      else
        local argv = { "nodes", "probe", id }
        local db = host.getenv("WASM_AGENT_DB")
        if db and db ~= "" then argv = { "--db", db, "nodes", "probe", id } end
        local ok, receipt = pcall(host.operation, "start", json.encode({ program = program, args = argv,
          timeout_seconds = tonumber(opts.deadline_s or PROBE_DEADLINE_S), kind = "command",
          owner = "nodes-probe" }))
        local answer = ok and (json.decode(receipt) or {}) or {}
        if answer.operation_id then
          launched[#launched + 1] = { id = id, operation_id = answer.operation_id }
          inflight[id] = { op = answer.operation_id, at = now }
          lease_add[#lease_add + 1] = { at = now, peer = id, op = answer.operation_id,
            owner = probe_process_key() }
          alive = alive + 1
          -- WRITTEN RIGHT AFTER START (review r2, B/MUST 4), not after the awaits. The old shape wrote the
          -- lease only when every await had finished, so a second state starting in the meantime saw no
          -- entry, started a duplicate child, and the fan-out the lease exists to prevent happened anyway.
          -- One write per started child, into THIS process own file: there is no merge to lose.
          if lease_path then probe_lease_write(lease_path, lease_add) end
        end
      end
    end
  end
  local out = {}
  for _, id in ipairs(at_capacity) do
    out[id] = { capabilities = nil, reason = "probe_capacity" }
  end
  if why_shared then out.__shared_bound = why_shared end
  -- Collect the answers this call is entitled to get, and publish every one of them for the next caller.
  local settled_results = {}
  -- A NEGATIVE IS PUBLISHED TOO (review r2, B/MUST 6): a joiner that finds no answer spins for the whole
  -- deadline and then reports its own timeout, which is a second 20 s wait for a fact the first caller
  -- already learned. probe_timeout and probe_unreadable go into the lease like any other answer.
  local negative = {}
  for _, entry in ipairs(launched) do
    if entry.wait_lease then
      -- WAIT ON THE FILE: the owner publishes there. Polling the lease is the only cross-caller wait that
      -- needs no permission from the host, and it stops the moment the answer arrives or the deadline does.
      local waited_ms = 0
      -- `opts.wait_s` is how long THIS CALL may wait (a tool that must answer a model in under a second),
      -- and it is not the child's own deadline: the child keeps `deadline_s` and keeps running, so the
      -- answer it produces is what the next call joins.
      local limit_ms = tonumber(opts.wait_s or opts.deadline_s or PROBE_DEADLINE_S) * 1000
      while waited_ms < limit_ms do
        local again = probe_lease_read(lease_dir, now)
        local found, found_at = nil, nil
        for _, row in ipairs(again) do
          if row.peer == entry.id and type(row.result) == "table" then
            found, found_at = row.result, tonumber(row.at) or now
          end
        end
        if found then
          out[entry.id] = found
          out[entry.id].at = found_at
          settled_results[entry.id] = found
          break
        end
        if host.sleep then pcall(host.sleep, 100) else break end
        waited_ms = waited_ms + 100
      end
      if out[entry.id] == nil then out[entry.id] = { capabilities = nil, reason = "probe_leaseholder_pending" } end
    elseif entry.result then
      out[entry.id] = entry.result
      if type(out[entry.id]) == "table" and out[entry.id].at == nil then out[entry.id].at = entry.at or now end
      settled_results[entry.id] = entry.result
    else
      -- MUST 1 + MUST 2 (review r2). The host decides ownership by the OWNER the caller names
      -- (operations.rs, Caller::owns: a sessionless caller owns the rows started under its own owner),
      -- so an await that names no owner is refused even for the child this process started - measured:
      -- every peer answered probe_leaseholder_pending. And the host reads wait_ms only (cap 10 s,
      -- default 1 s): wait_s is ignored, so a 20 s deadline was really a 1 s wait followed by a
      -- cancel. The wait is therefore slices of wait_ms up to the deadline, refreshing `now` each time.
      local deadline_ms = tonumber(opts.wait_s or opts.deadline_s or PROBE_DEADLINE_S) * 1000
      local waited_ms, snapshot = 0, {}
      while true do
        local slice = math.min(PROBE_WAIT_SLICE_MS, math.max(1, deadline_ms - waited_ms))
        local settled, state = pcall(host.operation, "await", json.encode({ id = entry.operation_id,
          owner = PROBE_OWNER, wait_ms = slice }))
        snapshot = settled and (json.decode(state) or {}) or {}
        if type(snapshot) ~= "table" or snapshot.settled == true or snapshot.error then break end
        waited_ms = waited_ms + slice
        if waited_ms >= deadline_ms then break end
        now = host.now()
      end
      if type(snapshot) == "table" and snapshot.error and not entry.owned then
        -- The host refused this id (not ours). Never cancel someone else operation, and never call that
        -- a timeout: the leaseholder still owns it and will publish.
        out[entry.id] = { capabilities = nil, reason = "probe_leaseholder_pending" }
      elseif snapshot.settled ~= true and opts.keep_running then
        -- A CALLER THAT COULD NOT WAIT IS NOT A CHILD THAT FAILED (23/11). Cancelling here is what made
        -- `tools.nodes()` cost its whole deadline and still answer nothing: the child was killed a
        -- moment before it would have answered, so the next call started another one. With
        -- `keep_running` the child is left alone (it publishes its answer on the lease for whoever asks
        -- next, including this process), NO negative is published, and the answer says "not answered
        -- yet" with no age instead of pretending a timeout.
        out[entry.id] = { capabilities = nil, reason = "probe_pending" }
      elseif snapshot.settled ~= true then
        -- The caller COULD wait and the child still did not answer: that is a timeout, it is named, and
        -- the child is stopped so the next caller does not join a process that will never answer.
        pcall(host.operation, "cancel", json.encode({ id = entry.operation_id, owner = PROBE_OWNER }))
        negative[entry.id] = { capabilities = nil, reason = "probe_timeout" }
        out[entry.id] = negative[entry.id]
      else
        local read_ok, chunk = pcall(host.operation, "read", json.encode({ id = entry.operation_id,
          stream = "stdout", offset = 0, limit = 65536, owner = PROBE_OWNER }))
        -- A child's stdout is NOT trusted to be JSON (measured: a child that inherited WA_SCRIPT printed a
        -- test's own "ok" line, and an unguarded decode turned that into a crash of the caller). Every
        -- decode here is guarded; a line that is not an answer is skipped and the probe reads as unreadable.
        local text = {}
        if read_ok then local good, value = pcall(json.decode, chunk); if good and type(value) == "table" then text = value end end
        local body = tostring(text.content or text.data or "")
        local decoded = nil
        for line in body:gmatch("[^\r\n]+") do
          local good, one = pcall(json.decode, line)
          if not good then one = nil end
          if type(one) == "table" and (one.capabilities ~= nil or one.reason ~= nil or one.error ~= nil) then decoded = one end
        end
        if decoded then
          local answer = { capabilities = type(decoded.capabilities) == "table" and decoded.capabilities or nil,
            reason = decoded.reason or decoded.error or (decoded.capabilities and "asked" or "unknown") }
          -- Asked and answered just now, so the age of this answer is zero.
          answer.at = now
          out[entry.id] = answer
          settled_results[entry.id] = answer
        else
          negative[entry.id] = { capabilities = nil, reason = "probe_unreadable" }
          out[entry.id] = negative[entry.id]
        end
      end
    end
  end
  -- PUBLISH WHAT WAS LEARNED (and keep every other live lease). This is what makes a joiner cheap.
  for peer_id, value in pairs(negative) do settled_results[peer_id] = value end
  if lease_path and (next(settled_results) ~= nil or #lease_add > 0) then
    local merged, seen = {}, {}
    for _, entry in ipairs(lease or {}) do
      if not seen[entry.peer] then
        seen[entry.peer] = true
        merged[#merged + 1] = entry
      end
    end
    for _, entry in ipairs(lease_add) do
      if not seen[entry.peer] then
        seen[entry.peer] = true
        merged[#merged + 1] = entry
      end
    end
    for peer_id, result in pairs(settled_results) do
      local found = false
      for _, entry in ipairs(merged) do
        if entry.peer == peer_id then entry.result = result; entry.at = now; found = true end
      end
      if not found then merged[#merged + 1] = { at = now, peer = peer_id, result = result } end
    end
    if not probe_lease_write(lease_path, merged) then lease_why = "probe_lease_unwritable" end
  end
  _G.WA_PROBE_LEASE_BOUND = lease_why or nil
  return out
end

-- Local host node + every other peer the rendezvous knows about.
--
-- `opts.cached` reads the roster this process already has and never asks the rendezvous (see
-- `fetch_peers`): what a snapshot taken during a run is made of. Every existing caller passes no
-- options and behaves exactly as before.
function M.list(opts)
  opts = opts or {}
  local identity = M.identity() or {}
  local out = {
    {
      id = identity.node_id or "local",
      node_id = identity.node_id or "local",
      name = M.node_name(),
      kind = "host",
      role = M.role(),
      online = true,
      local_node = true,
      -- A guest has no worktree of its own. Reporting one would say it is a checkout that can be
      -- handed off, and it is not.
      worktree = M.is_master() and M.worktree() or "",
      endpoints = {},
      resources = (host.system_resources and json.decode(host.system_resources())) or nil,
      -- A guest's own capabilities are read-only. It edits files when a master asks, through
      -- /node/call, which runs as that master - not on its own initiative. So the write tools
      -- are absent here rather than merely discouraged.
      capabilities = M.is_master() and {
        "bash", "read", "write", "edit", "ls", "grep",
        "shell", "client", "spell_save", "spell_run", "spell_get",
      } or { "read", "ls", "grep", "spell_save", "spell_run", "spell_get" },
    },
  }
  -- THE FAN-OUT (item 10 of the node-ops round). Measured before: a peer that could not be reached held
  -- the whole list for its own deadline, one peer after another - four unreachable peers meant four
  -- timeouts before a display drew anything. host.http is one blocking call, so the concurrency comes from
  -- supervised PROCESSES: one "wa nodes probe <node_id>" per peer, ALL started before any is awaited, and
  -- read back together. A cached view asks nobody, and a view with no live probe keeps its old shape.
  local live_probes = {}
  -- THREE WAYS TO NOT PROBE: a cached view, a caller that said so, and a process that IS a probe child
  -- (M.probe sets _in_probe_child). The third is the one whose absence took the node down.
  -- THE MARKER IS PROCESS-WIDE, NOT MODULE-WIDE (item 0, the 19/11 OOM). This file is `dofile`d by
  -- fifteen callers, and each dofile gets its OWN M table: a flag set on one instance was unset on every
  -- other, so a second instance inside a probe child fanned out again - recursively, 1,653 processes,
  -- 23 GB. `_G.WA_IN_PROBE_CHILD` is shared by every instance in the process, and an inherited env var
  -- carries it into a child before its first line runs.
  -- A TEST PROCESS IS NOT A NODE (item 2 of the harness-fixes-2 round). The fan-out below starts one
  -- `wa nodes probe <peer>` CHILD per peer against the real fleet. Every `scripts/test-*.lua` row that
  -- called list() unstubbed therefore started real probe children from a test (measured 20/11:
  -- test-network-roster-offline, test-remote-refusals), which is a live fleet call the rules forbid. The
  -- process can say what it is (host.script_run, item 1), so a script run refuses to probe unless the row
  -- ASKS for it: `nodes.list{ probe = true }`. An allow-list, not a block-list - a row that tests probing
  -- is the only kind that opts in, and every other row gets the refusal for free.
  local probing_why = nil
  if host.script_run and host.script_run() and opts.probe ~= true then probing_why = "probe_disabled_script_run" end
  if not opts.cached and opts.live_capabilities ~= false and probing_why == nil and not M._in_probe_child
     and not _G.WA_IN_PROBE_CHILD and host.getenv(M.PROBE_CHILD_ENV) ~= '1' then
    -- opts.peers is the roster, for a caller that has one already (a test drives the fan-out with a
    -- stubbed host, and a real caller passes nothing and gets the rendezvous' answer as before).
    local peers = type(opts.peers) == "table" and opts.peers or fetch_peers(false, opts.cached)
    local candidates = {}
    for _, peer in ipairs(peers) do
      if peer.node_id ~= identity.node_id then candidates[#candidates + 1] = peer end
    end
    if #candidates > 0 then live_probes = probe_peers(candidates, opts) end
  end
  local roster = type(opts.peers) == "table" and opts.peers or fetch_peers(false, opts.cached)
  for _, peer in ipairs(roster) do
    if peer.node_id ~= identity.node_id then
      peer.id = peer.node_id
      peer.kind = "peer"
      peer.local_node = false
      -- What the peer ACCEPTS, from the peer (item 7 of the node-ops round). The rendezvous stores no
      -- capabilities at all, so a list built from it answered [] for every peer - including one that
      -- accepts bash - and a reader had to guess. Three states, and the field always says which:
      --   capabilities = {...}   the peer answered; these are the names it admits for this caller.
      --   capabilities = nil     the peer could not be asked (offline, no binding, an older build):
      --                          capabilities_reason names why, and `opts.cached` means nobody asked.
      -- A cached display (opts.cached, taken inside somebody else's turn) never pays a network round
      -- trip: it shows what is already known and says it did not ask.
      if opts.cached then
        local known = caps_cache[tostring(peer.node_id or "")]
        peer.capabilities = known and known.capabilities or nil
        peer.capabilities_reason = known and known.capabilities and "cached" or "not_asked_cached_view"
        if known and known.capabilities then
          peer.capabilities_at = known.at
          peer.capabilities_age_s = math.max(0, host.now() - (tonumber(known.at) or host.now()))
        end
      elseif opts.live_capabilities == false then
        peer.capabilities = nil
        peer.capabilities_reason = "not_asked"
      else
        -- Answered from the ONE fan-out below, never asked here: asking inside this loop is the serial
        -- sum of every peer's timeout, which is what item 10 of the node-ops round removed.
        local answer = live_probes[tostring(peer.node_id or "")]
        if answer then
          peer.capabilities = answer.capabilities
          peer.capabilities_reason = answer.reason
          -- HOW OLD THIS IS: the moment the answer was produced (a child that settled a second ago and
          -- one that was read from disk ten seconds ago are not the same fact), and the age in seconds.
          -- A peer that has not answered yet carries no age at all rather than a zero that reads as fresh.
          if answer.at then
            peer.capabilities_at = answer.at
            peer.capabilities_age_s = math.max(0, host.now() - (tonumber(answer.at) or host.now()))
          end
        elseif probing_why ~= nil then
          -- REFUSED, BY NAME. A script run did not ask to probe, so neither a child is started nor the
          -- peer is asked in-process (that is a live network call). The field carries the reason, as it
          -- does for every other unasked peer: a reader can tell "not asked" from "asked, no answer".
          peer.capabilities = nil
          peer.capabilities_reason = probing_why
        else
          -- No child could be started for this peer (no runtime_info, no operation host): the probe
          -- still happens, in this process, and says the same named reason it always did.
          local capabilities, why = M.peer_capabilities(peer)
          peer.capabilities = capabilities
          peer.capabilities_reason = capabilities and "asked" or tostring(why or "unknown")
          if capabilities then peer.capabilities_at = host.now(); peer.capabilities_age_s = 0 end
        end
      end
      out[#out + 1] = peer
    end
  end
  return out
end

-- True when the roster could NOT be read: a caller must then answer "unreachable", not "unknown".
function M.roster_unreadable()
  return M.roster_last_read ~= nil and M.roster_last_read.ok == false
end

function M.find(selector)
  if not selector or selector == "" then return nil end
  for _, node in ipairs(M.list({ live_capabilities = false })) do
    if node.name == selector or node.node_id == selector or node.id == selector then
      return node
    end
  end
  return nil
end

-- Trust a caller only when the rendezvous agrees on its key.
--
-- This is the whole of the remote-trust story, so it is worth being exact about what it proves:
-- the caller holds the private key for a public key that the rendezvous, right now, associates
-- with that node id. It does not prove the caller is well-intentioned - that is what the role
-- check and `author_of`'s enrolment list are for - and it fails closed: no rendezvous, no answer.
-- One node's record, straight from the rendezvous. `/lookup` of an admin needs no credential, so a
-- guest can verify the master calling it - `/nodes` (the whole list) is masters-only once the
-- rendezvous has admins, and a guest asking for it gets nothing.
local function lookup_node(node_id)
  local url = M.rendezvous_url()
  if url == "" or not tostring(node_id):match("^%x+$") then return nil end
  local ok, node = pcall(function()
    local headers = json.encode(M.signed_headers("lookup") or {})
    local response = decode_body(host.http("GET", url:gsub("/+$", "") .. "/lookup?node_id=" .. node_id, headers, ""))
    return response and tonumber(response.status) == 200 and json.decode(response.body) or nil
  end)
  return ok and type(node) == "table" and node or nil
end

function M.verify_caller(node_id, public_key, opts)
  if enrollment.managed() then return enrollment.caller(node_id, public_key) end
  if not node_id or not public_key then return nil end
  if type(opts) == "table" and opts.fresh then
    local node = lookup_node(node_id)
    if node and node.node_id == node_id and node.public_key == public_key then return node end
  end
  local peers = fetch_peers(type(opts) == "table" and opts.fresh)
  for _, node in ipairs(peers) do
    if node.node_id == node_id and node.public_key == public_key then
      return node
    end
  end
  return nil
end

-- Sign `action|node_id|ts`, plus the hash of the body when there is one.
--
-- The body has to be in the signature. Without it a signed call was a signed *verb*: anyone who
-- could see the request could change what the verb applied to - `read` this file becomes `write`
-- that file - and the signature still verified, because it never mentioned the arguments. The
-- direct peer hop is plain HTTP, so anyone on the path could do it. It also made two different
-- calls in the same second indistinguishable, which turned the replay guard into something that
-- refuses honest calls.
function M.sign_action(action, ts, body)
  local identity = M.identity()
  if not identity or not identity.node_id then return nil, nil, "no_identity" end
  local parts = { action, identity.node_id, tostring(ts) }
  if type(body) == "string" then parts[#parts + 1] = host.sha256(body) end
  local message = table.concat(parts, "|")
  local signed = json.decode(host.sign(message))
  if not signed or not signed.signature then return identity, nil, "sign_failed" end
  return identity, signed.signature
end

-- The relay that fronts nodes which cannot accept inbound connections.
function M.relay_url()
  local binding=dofile('lua/core/binding.lua')
  if binding.present() then local s=binding.saved();return s and s.service or '' end
  return host.getenv("WASM_AGENT_RELAY") or ""
end

function M.signed_headers(action, body)
  local ts = math.floor(host.now())
  local identity, signature, problem = M.sign_action(action, ts, body)
  if not identity then return nil, problem end
  return {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["User-Agent"] = "wasm-agent/0.1 node",
    ["X-WA-Node"] = identity.node_id,
    ["X-WA-Pub"] = identity.public_key,
    ["X-WA-Ts"] = tostring(ts),
    ["X-WA-Sig"] = signature,
  }
end

local function normalize_headers(headers)
  local out = {}
  for key, value in pairs(headers or {}) do out[key] = value end
  return out
end

-- Is the mesh on for this node *now*? The host answers, through `host.mesh_call`'s `{gate: true}`
-- mode, with the one resolver every other gate in the node uses: `WA_MESH`/`WASM_AGENT_MESH`, then this
-- node's own `policy.json` `mesh.enabled`, then off (docs/MESH.md, "The gate: one resolver, for every
-- path"). Asked per call and deliberately **not** cached here: the environment cannot change under a
-- running node, but a roster pushed to one writes `mesh.enabled` into that file, and the very next call
-- must follow it — which is exactly the call that used to go down the legacy path and be refused
-- (`remote_refused: not a pinned operator`) on a node whose policy said the mesh was on. The host keeps
-- the question cheap: it re-reads the file only when its mtime or size changed.
--
-- A host that cannot answer the gate question at all (a binary from before that mode existed) keeps the
-- answer it used to give — the process flag — rather than silently never trying the mesh.
function M.mesh_enabled()
  if type(host.mesh_call) == "function" then
    local ok, raw = pcall(host.mesh_call, json.encode({ gate = true }))
    if ok and type(raw) == "string" then
      local decoded_ok, answer = pcall(json.decode, raw)
      if decoded_ok and type(answer) == "table" and type(answer.enabled) == "boolean" then
        return answer.enabled
      end
    end
  end
  return tostring(host.getenv("WA_MESH") or "") == "1"
    or tostring(host.getenv("WASM_AGENT_MESH") or "") == "1"
end

-- The headers as the pairs the crate's envelope carries, in a stable order so the bytes are the same
-- every time (the crate hashes them as part of the signed body).
local function header_pairs(headers)
  local names = {}
  for name in pairs(headers or {}) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do out[#out + 1] = { name, tostring(headers[name]) } end
  return out
end

-- Try the direct path before today's. Returns `{ response = ... }` when the peer answered,
-- `{ refused = ... }` when the mesh decided against the call, and nil when nobody answered (which is
-- the only case that may fall back). The difference is the whole point: a denial is an answer, and
-- the relay behind this function knows none of the hierarchy and would allow it.
--
-- A peer whose last mesh attempt died **on the wire** (an address that does not resolve, a connection
-- reset by the relay) is skipped for MESH_COOLDOWN seconds, so the next call goes straight to the
-- relay path instead of paying the same dead attempt again. This changes which transport is tried
-- first, never how many times a capability is sent: the refusal itself is still returned for the call
-- that hit it (the mesh may already have carried it), only the *following* calls short-circuit. The
-- 10/11 session spent a dozen calls this way before anyone noticed the mesh was on with no reachable
-- address.
M.MESH_COOLDOWN = 120
local mesh_down = {}
local function mesh_transport_failure(reason)
  local text = tostring(reason or "")
  return text:match("^unreachable") ~= nil or text:match("^read_failed") ~= nil
end
function M.mesh_attempt(node, capability, args, body, headers)
  if type(host.mesh_call) ~= "function" then return nil end
  local key = node.node_id
  local seen = mesh_down[key]
  if seen and (os.time() - seen) < M.MESH_COOLDOWN then return nil end
  local ok, raw = pcall(host.mesh_call, json.encode({
    node = node.node_id,
    capability = capability,
    args = args or {},
    -- The request this call would have sent anyway, signed with this node's key: the target hands it
    -- to its own `/node/call`, so a mesh call executes exactly like any other peer call.
    inner_body = body,
    inner_headers = header_pairs(headers),
    -- Discovery the node already has (the rendezvous `/nodes` answer). The crate caches it, which is
    -- what keeps the next call working when the rendezvous is down.
    peers = { nodes = fetch_peers() },
  }))
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, answer = pcall(json.decode, raw)
  if not decoded_ok or type(answer) ~= "table" then return nil end
  if answer.ok then
    mesh_down[key] = nil
    return { response = {
      status = tonumber(answer.status) or 200,
      body = tostring(answer.body or ""),
      transport = "mesh",
      node = node.name,
    } }
  end
  if answer.error == "mesh_unreachable" or answer.error == "mesh_disabled" then return nil end
  -- A transport death is remembered, so the *next* call to this peer starts on the relay instead of
  -- repeating it; the call that hit it still answers with the refusal it got.
  if mesh_transport_failure(answer.reason) or answer.error == "mesh_relay_failed" then
    mesh_down[key] = os.time()
  end
  return { refused = {
    error = answer.error == "mesh_denied" and "mesh_denied" or "mesh_refused",
    reason = tostring(answer.reason or answer.code or answer.error),
    detail = answer.detail,
    layer = "mesh",
    verified = answer.verified == true,
    transport = "mesh",
    retryable = false,
    node = node.name,
    node_id = node.node_id,
    level = answer.level,
  } }
end

-- A transport answer is bytes until proven otherwise. These bodies cross a plain-HTTP hop and a proxy,
-- so a 200 or a 503 can carry an HTML error page, an empty body, or a truncated frame; rxi's json.decode
-- RAISES on all of those, and an uncaught raise inside a caller's slot accounting leaked the slot for
-- good (four leaked slots = peer_busy_caller forever, with nothing sent and nothing run). Everything
-- that reads a transport body goes through here, and a body that is not JSON is a named failure.

-- Send a request to a node: directly when it advertises a routable endpoint,
-- otherwise through the relay. `headers` are forwarded to the target.
function M.request(node, path, body, inner_headers)
  local headers = normalize_headers(inner_headers)
  headers["Content-Type"] = headers["Content-Type"] or "application/json"
  local endpoint = M.endpoint(node)
  local direct = nil
  if endpoint then
    local response = decode_body(host.http("POST", endpoint:gsub("/+$", "") .. path,
      json.encode(headers), body or ""))
    if response and tonumber(response.status) == 200 then response.transport = "direct"; return response end
    direct = response
  end
  local relay = M.relay_url()
  -- No relay to fall back to: the node's own non-200 answer is the evidence, not `no_route`.
  if relay == "" and type(direct) == "table" and tonumber(direct.status) then
    direct.transport = "direct"
    return direct
  end
  local last_error = nil
  if relay ~= "" and node and node.node_id then
    -- One request id for the whole retry loop: the relay queues the action at
    -- most once, so a retry only re-fetches the result. Actions are never run
    -- twice because a fetch was slow.
    local rid = host.uuid()
    -- Bounded overall: the relay holds ~20s per attempt, so an absent node would
    -- otherwise keep the caller waiting for well over a minute before it hears
    -- anything. Two attempts is enough to cover a node that is between polls.
    -- The three numbers live in ONE place (M.RELAY_*), because the model-facing error names the cap it
    -- hit and a number written twice drifts (19/11, item E).
    local DEADLINE, started = M.RELAY_DEADLINE_SECONDS, host.now()
    -- One caller holds at most M.RELAY_MAX_IN_FLIGHT relayed calls to this node (see the constant).
    -- Refused BEFORE anything is sent, so a full queue costs the peer nothing.
    local slot, slot_problem = M.acquire_slot(node.node_id)
    if not slot then
      return { error = slot_problem, node = node.name, node_id = node.node_id, retryable = true,
        message = string.format("this node already holds %d relayed calls to %s (its cap): nothing was "
          .. "sent and nothing ran. Wait for one to answer, then retry.", M.RELAY_MAX_IN_FLIGHT,
          tostring(node.name or node.node_id)) }
    end
    -- EVERY exit from the relay loop goes through here - the answered path, the named refusal below,
    -- and the no-identity refusal that used to return past the release. A slot that is not given back
    -- is a caller that can never call that node again in this process.
    local function finish(value)
      M.release_slot(node.node_id)
      return value
    end
    for attempt = 1, M.RELAY_ATTEMPTS do
      local relay_headers = M.signed_headers("relay-send")
      if not relay_headers then return finish({ error = "no_identity", node = node.name, retryable = false }) end
      local envelope = json.encode({
        rid = rid, to = node.node_id, method = "POST", path = path,
        headers = headers, body = body or "",
      })
      local response = decode_body(host.http("POST", relay:gsub("/+$", "") .. "/relay/send",
        json.encode(relay_headers), envelope))
      if response and tonumber(response.status) == 200 then
        local decoded = decode_body(response.body)
        if decoded and decoded.ok then
          -- `late` is the relay's word that the answer arrived after the deadline this caller was
          -- given: a result, but not a fresh one, and the caller is told so rather than guessing.
          return finish({ status = decoded.status, body = decoded.body, rid = rid, transport = "relay",
            late = decoded.late == true })
        end
        -- relay_timeout is retryable too: the relay keeps the result for two
        -- minutes and the id is stable, so a retry re-fetches it.
        if not (decoded and decoded.error == "relay_timeout") then
          return finish({ error = (decoded and decoded.error) or "relay_error" })
        end
      elseif response and tonumber(response.status) == 503 then
        -- Retired by the relay (it holds now), kept for an older rendezvous:
        -- the node was not attached, which is a reason to wait, not to fail. A `node_busy` answer is
        -- different: the target was reached and refused before starting, so the same rid may be sent
        -- again and nothing has run twice.
        local decoded = decode_body(response.body)
        last_error = (decoded and decoded.error == "node_busy") and "node_busy" or "node_not_attached"
        -- The rendezvous is over ITS cap (19/11: too_many_connections to everyone). Back off with
        -- jitter and honour Retry-After when the relay names one; never a tight retry, because a
        -- fleet coming back at once is what filled the cap in the first place.
        local reason = M.relay_code(response.body)
        if reason == "too_many_connections" or reason == "relay_busy" then
          last_error = "relay_busy"
          local hint = nil
          local got, body = pcall(json.decode, response.body)
          if got and type(body) == "table" then
            if body.retry_after_ms ~= nil then
              -- The field NAMES milliseconds and relay_backoff_ms reads anything under 1000 as SECONDS,
              -- so it is handed over as seconds - clamped FIRST: 1,000,000 ms / 1000 = 1000 would be read
              -- back as 1000 MILLISECONDS, i.e. a ten-minute hint turned into a one-second wait.
              hint = math.min(30000, tonumber(body.retry_after_ms) or 0) / 1000
            else
              hint = body.retry_after
            end
          end
          host.sleep(M.relay_backoff_ms(attempt, hint) / 1000)
        end
      elseif response and tonumber(response.status) == 504 then
        -- The relay held the request and the node did not answer: either it
        -- never attached (retry when it is back) or it is busy and the action
        -- may still be running - which is exactly why the retry reuses the id.
        local decoded = decode_body(response.body)
        last_error = (decoded and decoded.error) or "node_no_answer"
        -- One policy for every retry wait: the relay's hint goes through relay_backoff_ms like the 503
        -- hints do, so it is never shorter than the hint, never longer than the cap, and never the same
        -- instant for every caller. Before this it slept the hint raw - and the 504's hint is a fixed
        -- 750 ms (rendezvous.rs), so every caller that missed its wait woke together.
        if decoded and decoded.retry_after_ms then
          -- The hint is MILLISECONDS here and relay_backoff_ms reads anything under 1000 as SECONDS
          -- (its documented rule), so it is handed over as seconds: 750 ms -> 0.75 -> 750 ms. Clamped
          -- first, so a hint past the cap is the cap and never round-trips into the other unit.
          local hint_ms = math.min(30000, tonumber(decoded.retry_after_ms) or 0)
          host.sleep(M.relay_backoff_ms(attempt, hint_ms / 1000) / 1000)
        end
      elseif response and tonumber(response.status) == 409 and M.relay_code(response.body) == "request_in_flight" then
        -- The same rid is still running at the target: waiting re-collects it.
        last_error = "request_in_flight"
      elseif response and (tonumber(response.status) or 0) >= 400 then
        -- The relay itself refused (401/403/404/400/409/413): retrying the same request cannot
        -- change that answer, and reporting it as `relay_timeout` hid the reason.
        local status = tonumber(response.status)
        return finish({ error = "relay_refused", relay_status = status,
          reason = M.relay_code(response.body) or "unrecognized", rid = rid })
      end
      if (host.now() - started) > DEADLINE then break end
      -- The count comes from the ONE constant the loop above iterates (not a second literal 3), so a
      -- change to RELAY_ATTEMPTS cannot leave this backoff on the old count (round 3, item 7).
      -- Jittered: 750 ms doubling, capped at 8 s, never the same instant for every caller.
      if attempt < M.RELAY_ATTEMPTS then host.sleep(M.relay_backoff_ms(attempt) / 1000) end
    end
    -- Say that it is retryable, and which reason it kept hitting: "could not
    -- reach the node" and "the node is busy" call for different next steps. The cap itself travels with
    -- the answer, so the sentence the model reads is built from what this loop enforced.
    return finish({ error = last_error or "relay_timeout", rid = rid, retryable = true,
      deadline_seconds = DEADLINE, attempts = M.RELAY_ATTEMPTS })
  end
  return { error = "no_route" }
end

-- Refusals a peer sends BEFORE it has authenticated the caller. They cannot be signed - the reply
-- signature binds an answer to a verified request, and these answer an unverified one - so the relay
-- (or anything on a plain-HTTP hop) could forge or alter them. The caller therefore reports them as a
-- diagnosis, `verified=false`, never as a result, and keeps only an allow-listed code: no other byte
-- of the unsigned body reaches the model. Every code `wa_node_call`/`verify_peer` (server.lua), the
-- bound runtime (binding.lua `tick`) and the node's relay dispatch (serve.rs) can send is mapped;
-- a code outside this table still passes the pattern check and gets the generic hint.
M.NODE_REFUSALS = {
  unknown_caller = "this node is not a pinned operator of %s's binding (or %s's binding is inactive/expired, or the rendezvous does not vouch for this node's key). Check `nodes`: operator_of_peer and peer_operators say who %s accepts; an administrator must bind %s with this node as an operator (docs/BINDING.md). Do not sign as another node.",
  forbidden_role = "%s sees this node as a guest; only masters may call a peer. An administrator must /promote this node (docs/BINDING.md).",
  bad_signature = "%s could not verify this node's call signature (body altered in transit, or a peer on an older signing protocol). Retry once; if it repeats, compare versions.",
  stale_request = "%s judged the call older than 120 s: the clocks differ or the call was delayed. Compare `date -u` on both nodes.",
  replayed_request = "%s already answered this exact signed request. A new `remote` call is signed afresh; if this repeats, something on the path is replaying.",
  wrong_target = "the call reached a node other than %s, the one it was signed for (stale node list or a redirecting relay). Re-run `nodes` and address the peer by node_id.",
  bad_request = "%s could not read the call (missing caller header or an unreadable body). Nothing ran.",
  remote_cannot_recurse = "`remote` cannot be relayed through %s; call the final node directly.",
  binding_route_not_granted = "%s's bound runtime only serves /node/call over the relay.",
  relay_route_forbidden = "%s refuses that route over the relay; only /node/call, /node/chat and /sync/push are served.",
  not_found = "%s has no such route (an older node?).",
}
-- Refusals from the relay itself, keyed by code; `unknown_node` differs by status (401: the relay does
-- not know THIS node; 404: it does not know the target).
M.RELAY_REFUSALS = {
  forbidden_role = "the rendezvous lists this node as a guest; only masters may send through the relay. An administrator must /promote it.",
  binding_not_accepted = "this node's or %s's binding is not accepted (pending, revoked or expired) at the registry: `wa bind status` here; an administrator checks %s.",
  bad_signature = "the relay rejected this node's signature: this node's key differs from the one registered for its id.",
  stale_request = "the relay judged this node's request stale: check this node's clock.",
  unknown_node_401 = "the relay does not know THIS node: it is not registered or its heartbeat stopped (check WASM_AGENT_RENDEZVOUS / `wa bind status`).",
  unknown_node_404 = "%s is not registered at the rendezvous. Re-run `nodes`.",
  node_id_required = "this node sent no identity header; it has no node key.",
  to_required = "no target node id was sent.",
  request_id_conflict = "the relay holds a different request under this rid; send a new call.",
  request_too_large = "the request exceeds the relay's body limit; send less (split the call).",
  node_busy = "%s is running its limit of relayed calls and refused this one before starting it: nothing ran, and the same request may be sent again.",
  relay_busy = "%s is running its limit of relayed calls; nothing ran.",
  relay_request_timeout = "%s stopped work that passed the deadline its caller was given; the result is not fresh - re-run the call if the action is still needed (docs/RENDEZVOUS.md, Relay).",
}
local UNSIGNED_NOTE = "Unsigned: a peer cannot sign a refusal of a caller it has not verified, so the relay or the network path could have forged or altered this. Diagnostic only; nothing here is a result."

local function refusal_code(value)
  if type(value) ~= "string" or #value == 0 or #value > 64 then return nil end
  if not value:match("^[a-z][a-z0-9_%.%-]*$") then return nil end
  return value
end

-- The `error` code of an unsigned JSON body, allow-listed by pattern; nil when there is none.
function M.relay_code(body)
  local ok, value = pcall(json.decode, body or "")
  if not ok or type(value) ~= "table" then return nil end
  return refusal_code(value.error)
end

local function fill(text, name)
  name = tostring(name or "the peer")
  return (text:gsub("%%s", function() return name end))
end

-- The model-facing form of an unsigned refusal. `layer` says who answered: the peer node itself
-- (`node`, carrying the node's HTTP status) or the relay in front of it (`relay`).
function M.refusal(layer, reason, status, node)
  local name = node and (node.name or node.node_id) or nil
  local out = { error = layer == "relay" and "relay_refused" or "remote_refused", reason = reason or "unrecognized",
    layer = layer, verified = false, node = name, note = UNSIGNED_NOTE }
  local hint
  if layer == "relay" then
    out.relay_status = status
    hint = M.RELAY_REFUSALS[reason .. "_" .. tostring(status)] or M.RELAY_REFUSALS[reason]
  else
    out.node_status = status
    hint = M.NODE_REFUSALS[reason]
  end
  out.hint = fill(hint or ("the " .. (layer == "relay" and "relay" or "peer") .. " refused with `" .. tostring(out.reason)
    .. "` before authorizing the call; see docs/BINDING.md and docs/RENDEZVOUS.md."), name)
  return out
end

-- Only target-authenticated bytes are a result (also used for sync acknowledgments).
-- Returns the decoded reply, or nil plus a code plus (for a pre-authorization refusal) its detail.
function M.verified_reply(node, headers, body)
  local ok,envelope=pcall(json.decode,body)
  if not ok or type(envelope)~='table' then return nil,'unsigned_reply' end
  if type(envelope.reply)~='string' then
    -- A refusal the peer could not sign. Keep only its code; never the rest of the body.
    if envelope.error ~= nil then
      local refusal=M.refusal('node',refusal_code(envelope.error) or 'unrecognized',200,node)
      return nil,'remote_refused',refusal
    end
    return nil,'unsigned_reply'
  end
  local message=table.concat({'reply',node.node_id,headers['X-WA-Ts'],host.sha256(headers['X-WA-Sig']..'\n'..envelope.reply)},'|')
  if not node.public_key or not host.verify(node.public_key,message,envelope.reply_sig or '') then return nil,'remote_reply_unverified' end
  local decoded_ok,decoded=pcall(json.decode,envelope.reply)
  if not decoded_ok or type(decoded)~='table' then return nil,'bad_reply' end
  return decoded
end

-- Is THIS node one of the operators pinned in a peer's binding? Read from the rendezvous `/lookup`
-- (the accepted binding request carries the exact operator pins the peer's `binding.authorize`
-- checks), cached per peer so `nodes` is not one lookup per peer per call.
--
--   true    pinned in the peer's accepted, unexpired registry binding
--   false   the peer has a binding and this node is not pinned, or the binding is not accepted /
--           expired - either way the peer answers `unknown_caller`
--   unknown no binding on record (the peer trusts the rendezvous role or a local enrollment this
--           node cannot see), or the lookup failed
--
-- `true` is the registry's view, not a promise: the peer also needs its own local consent active.
local OPERATOR_TTL = 60

local function lookup_record(node_id)
  local url = M.rendezvous_url()
  if url == "" then return nil, "no_rendezvous" end
  if not tostring(node_id):match("^%x+$") then return nil, "bad_node_id" end
  local ok, response = pcall(function()
    local headers = json.encode(M.signed_headers("lookup") or {})
    return decode_body(host.http("GET", url:gsub("/+$", "") .. "/lookup?node_id=" .. node_id, headers, ""))
  end)
  if not ok or type(response) ~= "table" then return nil, "lookup_failed" end
  if tonumber(response.status) ~= 200 then
    return nil, "lookup_http_" .. tostring(response.status) .. (M.relay_code(response.body) and (":" .. M.relay_code(response.body)) or "")
  end
  local decoded_ok, record = pcall(json.decode, response.body)
  if not decoded_ok or type(record) ~= "table" then return nil, "lookup_unreadable" end
  return record
end

local function short_id(id) return tostring(id or ""):sub(1, 12) end

-- What a peer accepts RIGHT NOW, as the peer itself answers it (lua/core/server.lua, capability
-- "capabilities"). Item 7 of the node-ops round: M.list gave every peer whatever the rendezvous had
-- stored, which carried no capabilities at all, so tools.nodes reported [] for a peer that accepts bash
-- - a reader concludes the peer can do nothing, and the field was simply never filled.
--
-- The cost rule: a peer that has already answered is not asked again for NODE_CAPS_TTL seconds, and a
-- peer that could not be asked is not asked again for NODE_CAPS_RETRY - but it says SO, by name, in
-- capabilities_reason. An empty list with no reason would be the same lie in a quieter shape, so this
-- never answers [] without saying why.
local NODE_CAPS_TTL = 120
local NODE_CAPS_RETRY = 60
local caps_cache = {} -- node_id -> { at, capabilities, reason }

-- A read-only signed call to one peer, without the mesh first (this is a discovery read and must not
-- change routing state for real calls) and without a refusal's retry policy.
local function ask_capabilities(node)
  local id = tostring(node.node_id or "")
  local cache_entry = caps_cache[id]
  local now = host.now()
  if cache_entry then
    local ttl = (cache_entry.capabilities and #cache_entry.capabilities > 0) and NODE_CAPS_TTL or NODE_CAPS_RETRY
    if (now - cache_entry.at) < ttl then return cache_entry.capabilities, cache_entry.reason end
  end
  local body = json.encode({ from_node_id = (M.identity() or {}).node_id, to_node_id = node.node_id,
    request_id = host.uuid(), capability = "capabilities", args = {} })
  local headers, problem = M.signed_headers("call", body)
  if not headers then
    caps_cache[id] = { at = now, reason = tostring(problem) }
    return nil, tostring(problem)
  end
  local response = M.request(node, "/node/call", body, headers)
  if not response then
    caps_cache[id] = { at = now, reason = "remote_unreachable" }
    return nil, "remote_unreachable"
  end
  if response.error or response.status ~= 200 then
    local why = tostring(response.error or ("http_" .. tostring(response.status)))
    caps_cache[id] = { at = now, reason = why }
    return nil, why
  end
  local ok_decode, envelope = pcall(json.decode, tostring(response.body or ""))
  if not ok_decode or type(envelope) ~= "table" then
    caps_cache[id] = { at = now, reason = "answer_unreadable" }
    return nil, "answer_unreadable"
  end
  -- A verified reply carries the peer's own bytes as a string under `reply` (signed_reply in
  -- lua/core/server.lua); anything else is not the shape this asks for.
  local answer = envelope
  if type(envelope.reply) == "string" then
    local ok_reply, decoded = pcall(json.decode, envelope.reply)
    if ok_reply and type(decoded) == "table" then answer = decoded end
  end
  if type(answer.capabilities) ~= "table" then
    local why = tostring(answer.error or "capabilities_absent")
    caps_cache[id] = { at = now, reason = why }
    return nil, why
  end
  local list = {}
  for _, name in ipairs(answer.capabilities) do
    if type(name) == "string" then list[#list + 1] = name end
  end
  caps_cache[id] = { at = now, capabilities = list }
  return list, nil
end

function M.peer_capabilities(node, opts)
  if type(node) ~= "table" or node.local_node then return nil, "not_a_peer" end
  return ask_capabilities(node)
end

--- What this node ALREADY knows about its peers' capabilities, and how old each answer is.
---
--- No probe is started, nothing is awaited and no network call is made: this reads the answers this
--- process keeps (`caps_cache`) and the answers other callers in this node have already published on the
--- probe lease (`probe_lease_dir`). A caller that must answer now - a refusal that has to name the nodes
--- which list `mcp_whatsapp_*`, a view - reads this instead of paying a deadline, and a peer nobody has
--- asked yet simply is not in it (unknown is not "no").
---
---   { node_id = "...", capabilities = {"bash", ...}, reason = "asked"|"probe_timeout"|..., at = <epoch>,
---     age_s = <seconds> }
function M.known_capabilities()
  local now = host.now()
  local known = {}
  for id, entry in pairs(caps_cache) do
    if type(entry) == "table" then
      known[tostring(id)] = { node_id = tostring(id), capabilities = entry.capabilities,
        reason = entry.reason, at = tonumber(entry.at), age_s = math.max(0, now - (tonumber(entry.at) or now)) }
    end
  end
  local dir = probe_lease_dir()
  if dir then
    local ok, live = pcall(probe_lease_read, dir, now)
    for _, entry in ipairs(ok and type(live) == "table" and live or {}) do
      local result = entry.result
      if type(result) == "table" and entry.peer ~= "" then
        local at = tonumber(entry.at) or now
        local previous = known[entry.peer]
        -- The newer answer wins; an entry with no answer of its own (a child still running) is not one.
        if (result.capabilities ~= nil or result.reason ~= nil)
            and (not previous or (tonumber(previous.at) or 0) <= at) then
          known[entry.peer] = { node_id = entry.peer, capabilities = result.capabilities,
            reason = result.reason, at = at, age_s = math.max(0, now - at) }
        end
      end
    end
  end
  local out = {}
  for _, row in pairs(known) do out[#out + 1] = row end
  table.sort(out, function(a, b) return a.node_id < b.node_id end)
  return out
end

-- ONE peer's accepted capabilities, as a child process asks them (item 10 of the node-ops round).
--
-- This is the half a `wa nodes probe <node_id>` child runs: read the roster, find that peer, ask it, and
-- print ONE JSON line. It exists because the host has no concurrent HTTP primitive - host.http is one
-- blocking request - and the only concurrency a node has is supervised PROCESSES. M.list therefore starts
-- one of these per peer at once, so N unreachable peers cost one timeout instead of N.
function M.probe(selector)
  -- A PROBE CHILD NEVER PROBES AGAIN: it is already the answer, and a child that fanned out forked a
  -- tree of children (the 19/11 run that took the node down). The mark is set on the GLOBAL and on this
  -- instance: `dofile` gives every caller its own M table, so instance state alone left the other
  -- fourteen instances free to fan out.
  _G.WA_IN_PROBE_CHILD = true
  M._in_probe_child = true
  local node = M.find(selector)
  if not node then return { error = "node_unknown", node = tostring(selector or "") } end
  if node.local_node then return { node_id = node.node_id, local_node = true } end
  local capabilities, why = ask_capabilities(node)
  return { node_id = node.node_id, capabilities = capabilities, reason = capabilities and "asked" or tostring(why or "unknown") }
end

function M.operator_status(node, opts)
  if type(node) ~= "table" or node.local_node then return nil end
  local id = tostring(node.node_id or "")
  local now = host.now()
  local cached = operator_cache[id]
  if cached and not (type(opts) == "table" and opts.fresh) and (now - cached.at) < OPERATOR_TTL then return cached.value end
  local value = { operator_of_peer = "unknown" }
  local record, problem = lookup_record(id)
  local me = M.identity() or {}
  if not record then
    value.operator_basis = problem
  elseif node.public_key and record.public_key ~= node.public_key then
    value.operator_basis = "peer_identity_changed"
  elseif type(record.binding) ~= "table" or type(record.binding.request) ~= "table" then
    value.peer_binding = "none"
    value.operator_basis = "no_binding_on_record"
  else
    local b = record.binding
    local pins = type(b.request.operators) == "table" and b.request.operators or {}
    local expires = tonumber(b.request.expires_at)
    local state = refusal_code(b.state) or "unknown"
    if state == "accepted" and expires and expires <= now then state = "expired" end
    value.peer_binding = state
    local names, pinned = {}, false
    local known = {}
    for _, peer in ipairs(cache or {}) do if type(peer) == "table" and peer.node_id then known[peer.node_id] = peer.name end end
    if me.node_id then known[me.node_id] = M.node_name() end
    for _, pin in ipairs(pins) do
      if type(pin) == "table" then
        if pin.node_id == me.node_id and pin.public_key == me.public_key then pinned = true end
        names[#names + 1] = known[pin.node_id] or short_id(pin.node_id)
      end
    end
    value.peer_operators = names
    value.operator_of_peer = (pinned and state == "accepted") and true or false
    value.operator_basis = pinned and (state == "accepted" and "pinned" or "pinned_but_binding_" .. state)
      or "not_pinned"
  end
  operator_cache[id] = { at = now, value = value }
  return value
end

-- The relay's own numbers, in one place. The relay holds a queued call about RELAY_ATTEMPT_HOLD_SECONDS
-- (rust/wa-rendezvous), this loop makes RELAY_ATTEMPTS of them, and it stops after RELAY_DEADLINE_SECONDS
-- of its own clock. The model-facing error names these, because a caller told only "timed out" re-issues
-- the same long call for ever (19/11, item E).
M.RELAY_ATTEMPT_HOLD_SECONDS = 20
M.RELAY_ATTEMPTS = 3
M.RELAY_DEADLINE_SECONDS = 60

-- How many relayed calls ONE caller may hold against ONE node at a time, and the backoff it uses when
-- the relay says it is over its own cap.
--
-- Measured 19/11 12:20-12:45 UTC: the rendezvous (MAX_CONNECTIONS=256) answered 503
-- too_many_connections to everyone while ~470 TCP connections from the home IP kept coming; ~600
-- relayed calls/min were then logged as "attached but no answer within the caller's wait (45 s)" and
-- abandoned. A caller that only waits for its own answer will happily put another call on a node that
-- is already behind, so the queue never drains: every new call keeps one more slot busy.
--
-- WHICH callers, from the 19/11 evidence: the two nodes on the home link, **avell** and the **laptop**
-- (work's container). Their calls to **openclaw** ran at the highest rate the relay logged (~250/min),
-- with work as the other target. That is why the cap is per TARGET node and shared by every caller on
-- the calling node: it is those two machines answering each other, not a fleet-wide storm, and each of
-- them must bound its own share.
M.RELAY_MAX_IN_FLIGHT = 4

-- Per-node in-flight counters, shared by EVERY caller on this node.
--
-- The cap used to live in one Lua table, which is one interpreter: the serve lane builds a fresh one
-- per admitted call and "wa call" is its own process, so four concurrent callers each saw an empty
-- table and the cap never bound anything that mattered. The count therefore lives in the node's own
-- data directory - one file per held slot, named for the peer and the second it was taken. A holder
-- stamps its file with that second, so a process that dies leaves a file that EXPIRES and a crash
-- cannot fill the cap for good.
local SLOT_TTL_SECONDS = 120

-- The fallback for a host with no data directory (a fixture): the cap still applies in-process.
local relay_in_flight = {}

-- Per-node in-flight counters, THIS INTERPRETER ONLY.
--
-- A node-wide counter (one file per peer under paths.data(), so every caller process shares it) was
-- written here and is DELIBERATELY NOT KEPT: review r4 moved the per-peer call cap to the
-- fabric-transport mission, where the relay and the caller path are redesigned, and testing it against
-- today's transport would be work on the wrong base. What remains is the local cap, which is still
-- what stops one interpreter from putting unbounded calls on a peer, and it is honest about its
-- scope: it does not bind another process.
--
-- The file-based version also carried a real defect worth remembering: it formatted host.now() with %d,
-- and this host answers a FLOAT, so the first call raised "number has no integer representation" (a
-- fast-path row caught it). A counter that needs a clock should floor it.
local relay_in_flight = {}

function M.acquire_slot(node_id)
  node_id = tostring(node_id or "")
  local held = relay_in_flight[node_id] or 0
  if held >= M.RELAY_MAX_IN_FLIGHT then return nil, "peer_busy_caller" end
  relay_in_flight[node_id] = held + 1
  return true
end

function M.release_slot(node_id)
  node_id = tostring(node_id or "")
  local held = relay_in_flight[node_id] or 0
  if held <= 1 then relay_in_flight[node_id] = nil else relay_in_flight[node_id] = held - 1 end
  return true
end

function M.slots_held(node_id)
  return relay_in_flight[tostring(node_id or "")] or 0
end

-- Never a tight retry on an overloaded relay. The wait doubles per attempt, is capped, and is always
-- jittered so a fleet that was cut off does not come back in lockstep - the storm's own second half.
--
-- A Retry-After hint (seconds, or the milliseconds this tree already uses) is the server telling us the
-- EARLIEST time it can serve us again, so the wait is never shorter than the hint. It used to be obeyed
-- to the millisecond, which put every caller that hit the same hint back on the wire at the same instant -
-- the herd this function exists to break. The wait is therefore spread UPWARD over [hint, 1.5 x hint].
-- The cap is not decoration either: a hint of ten minutes blocked the caller for ten minutes, past its own
-- M.RELAY_DEADLINE_SECONDS, so it waited for an answer it had already given up on.
function M.relay_backoff_ms(attempt, retry_after)
  local hint = tonumber(retry_after)
  if hint then
    if hint < 1000 then hint = hint * 1000 end
    local floor = math.max(1, math.min(30000, math.floor(hint)))
    local spread = math.min(30000, math.floor(floor * 1.5))
    local jittered = math.floor(floor + math.random() * (spread - floor))
    return math.max(floor, math.min(30000, jittered))
  end
  local base = 750 * 2 ^ math.max(0, (tonumber(attempt) or 1) - 1)
  -- The cap is on the WAIT, so it is applied after the jitter: capping first and then multiplying by
  -- up to 1.5 would let a caller wait 12 s under an 8 s cap, and the comment would be a lie.
  local capped = math.min(8000, base)
  local jittered = math.floor(capped * (0.5 + math.random()))
  return math.max(1, math.min(8000, jittered))
end

-- The `operation` tool awaits with `wait_ms`, whose MAXIMUM is 10 s (lua/core/tools.lua, the "operation"
-- schema) - there is no `wait_s` parameter at all, and the 300 s this note used to name does not exist.
-- A slice must also stay under the relay cap above, or the call that waits is itself cut off by the relay:
-- one number, the smaller of the two sources, and scripts/test-remote-call-shape.lua checks it against
-- both (the schema's maximum and this cap).
M.OPERATION_AWAIT_MAX_MS = 10000
M.RELAY_AWAIT_SLICE_MS = math.min(M.OPERATION_AWAIT_MAX_MS, M.RELAY_DEADLINE_SECONDS * 1000)


-- How long a PEER may work on one relayed effectful call before it must answer a handle instead of an
-- outcome (change/remote-pending, item 1). The relay holds a queued call SEND_WAIT (45 s,
-- rust/wa-rendezvous/src/rendezvous.rs) and tells the node to finish ANSWER_MARGIN_MS (3 s) earlier, so
-- the honest budget is 42 s; this keeps 7 s of that for the return trip and the signature. It is
-- stamped in the SIGNED body (M.remote_call), so the peer adopts by the caller's own number and nothing
-- on the path can raise it.
M.RELAY_PEER_BUDGET_MS = 35000

-- The reasons the relay deadline produces. Any of them means the same thing to the caller: the answer did
-- not arrive in time, and the action may or may not have run on that node.
M.RELAY_DEADLINE_REASONS = { relay_timeout = true, node_no_answer = true, node_not_attached = true,
  node_busy = true, request_in_flight = true }

-- Model-facing: the real cap, and the exact call that does the same work ON that node instead of through
-- the relay. Numbers are read from the constants above, never written twice.
function M.relay_deadline_note(node, reason)
  local name = tostring((node and (node.name or node.node_id)) or "the peer")
  local why = (reason and reason ~= "") and (" (last reason: " .. tostring(reason) .. ")") or ""
  return string.format(
    "%s did not answer a relayed call within %d s (%d attempts; the relay holds a queued call about %d s "
      .. "each), so this call stopped waiting%s. A relayed bash that outlives that hold is ADOPTED, not "
      .. 'killed: it answers {state:"pending", op, node} and stays running there as a managed operation, '
      .. "and wait(op) or cancel(op) route back to that node. This answer is a different case: the relay "
      .. "never delivered the call's answer, and the peer may still have adopted it late - check "
      .. "operation list on that node before re-issuing it, because nothing here says the action did not "
      .. "run. Work that needs longer is started ON that node and awaited there: "
      .. 'tools.remote({node:"%s", capability:"operation", action:"start", command:"<the command>"}) returns '
      .. 'its id, and tools.remote({node:"%s", capability:"operation", action:"await", id:"<id>", '
      .. 'wait_ms:%d}): await in slices of %d s until it settles.',
    name, M.RELAY_DEADLINE_SECONDS, M.RELAY_ATTEMPTS, M.RELAY_ATTEMPT_HOLD_SECONDS, why, name, name,
    M.RELAY_AWAIT_SLICE_MS, M.RELAY_AWAIT_SLICE_MS / 1000)
end

-- A peer the roster already KNOWS but marks offline (a failed roster read kept it, see fetch_peers).
-- The answer names it and when it was last seen, instead of the unknown_node that made a network blip
-- look like a deleted node (19/11: after the link returned, every call to a peer was unknown_node).
function M.peer_offline(node)
  local name = tostring((node and (node.name or node.node_id)) or "the peer")
  local seen = node and tonumber(node.last_seen)
  local when = "unknown"
  if seen then
    local ok, formatted = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ", math.floor(seen))
    when = ok and formatted or ("unix " .. tostring(math.floor(seen)))
  end
  return { error = "peer_offline:" .. name .. " (last seen " .. when .. ")", node = name,
    connector = "peer_offline", online = false, last_seen = seen,
    message = string.format("%s is in the roster but unreachable right now (last seen %s): nothing was "
      .. "sent, so nothing ran. Check the link and the node, then retry - a peer that is merely "
      .. "unreachable is never removed from the roster.", name, when),
    retryable = true }
end

-- Call a capability on a peer: direct when possible, else through the relay.
function M.remote_call(selector, capability, args)
  local node = M.find(selector)
  if not node then
    -- A COLD roster during an outage is not "no such node": it is "the rendezvous could not be
    -- asked". Answering unknown_node here is what made a network blip look like a deleted peer.
    if M.roster_unreadable() then
      return { error = "roster_unavailable:" .. tostring(selector), node = tostring(selector),
        connector = "roster_unavailable", retryable = true,
        message = string.format("the roster could not be read, so %s cannot be looked up right now: "
          .. "nothing was sent and nothing ran. This is not a missing node - retry once the "
          .. "rendezvous answers.", tostring(selector)) }
    end
    return { error = "unknown_node:" .. tostring(selector) }
  end
  -- Known but offline, and with no endpoint to try directly: say so by name. A call that still has a
  -- direct endpoint is attempted below, because a stale roster mark is not proof the peer is gone.
  if node.online == false and not M.endpoint(node) then return M.peer_offline(node) end
  local ts = math.floor(host.now())
  -- The body is built before it is signed, and the signature travels in the headers rather than
  -- inside the body: what was signed is the body as it is sent, so the receiver can hash the
  -- bytes it got. `from_node_id` and the public key stay in the body for readability - they are
  -- covered by the hash like everything else.
  -- Only an effectful capability can outlive the relay hold, so only bash carries the budget a peer
  -- adopts by (item 1). It travels INSIDE args, which is what the peer hands its capability
  -- (server.lua: node_capability(capability, request.args, caller)), and it is inside the signed
  -- bytes either way: the peer reads it as the caller's own word. Copied, never mutating the caller's
  -- table, and stripped by the peer before the command is launched.
  local inner = args or {}
  if capability == "bash" and type(inner) == "table" then
    local copy = {}
    for key, value in pairs(inner) do copy[key] = value end
    copy.budget_ms = M.RELAY_PEER_BUDGET_MS
    inner = copy
  end
  local body = json.encode({
    from_node_id = (M.identity() or {}).node_id,
    to_node_id = node.node_id,
    request_id = host.uuid(),
    capability = capability,
    args = inner,
  })
  local headers, problem = M.signed_headers("call", body)
  if not headers then return { error = problem } end
  -- Mesh first when the operator turned it on: the peer decides against its own roster rather than
  -- the rendezvous, and only a transport failure falls back to the direct/relay path below.
  local mesh = M.mesh_enabled() and M.mesh_attempt(node, capability, args, body, headers) or nil
  if mesh and mesh.refused then return mesh.refused end
  local response = (mesh and mesh.response) or M.request(node, "/node/call", body, headers)
  if not response then
    -- The transport could not reach a peer the roster already marks offline: name it, do not pretend
    -- it never existed.
    if node.online == false then return M.peer_offline(node) end
    return { error = "remote_unreachable", node = node.name }
  end
  if response.error == "relay_refused" then
    local refusal = M.refusal("relay", response.reason, response.relay_status, node)
    refusal.rid = response.rid
    return refusal
  end
  if response.error then
    local detail = tostring(response.error)
    if M.RELAY_DEADLINE_REASONS[detail] then
      -- The sentence and the fix are supplied here, so the refusal renderer keeps them verbatim
      -- (lua/core/refusal.lua, M.finalize) and the model reads the cap rather than a bare code.
      local name = tostring(node.name or node.node_id or "the peer")
      return { error = "remote_error", detail = detail, node = node.name,
        retryable = response.retryable, rid = response.rid,
        deadline_seconds = response.deadline_seconds or M.RELAY_DEADLINE_SECONDS,
        attempts = response.attempts or M.RELAY_ATTEMPTS,
        message = M.relay_deadline_note(node, detail),
        fix = string.format('Start the work on that node and await it there: '
          .. 'tools.remote({node:"%s", capability:"operation", action:"start", command:"<the command>"}) '
          .. 'then tools.remote({node:"%s", capability:"operation", action:"await", id:"<id>", '
          .. 'wait_ms:%d}): await in slices of %d s until it settles. A bash that outlives the hold is '
          .. 'adopted on its own and answers {state:"pending", op, node}: resume it with wait(op) or stop '
          .. 'it with cancel(op).', name, name,
          M.RELAY_AWAIT_SLICE_MS, M.RELAY_AWAIT_SLICE_MS / 1000),
        input = tostring(capability or "the remote call") }
    end
    return { error = "remote_error", detail = detail, node = node.name,
      retryable = response.retryable, rid = response.rid }
  end
  if tonumber(response.status) ~= 200 then
    -- The node answered, but not 200. Its body is unsigned: keep the allow-listed code only.
    local code = M.relay_code(response.body)
    if code then
      local refusal = M.refusal("node", code, tonumber(response.status), node)
      refusal.transport = response.transport
      return refusal
    end
    return { error = "remote_http_" .. tostring(response.status), layer = "node", node_status = tonumber(response.status),
      verified = false, body_bytes = #tostring(response.body or ""), transport = response.transport, node = node.name,
      note = UNSIGNED_NOTE }
  end
  local decoded,problem,refusal=M.verified_reply(node,headers,response.body)
  if refusal then refusal.transport = response.transport; return refusal end
  if not decoded then return {error=problem,node=node.name,layer='node',verified=false,transport=response.transport} end
  decoded.node = node.name
  return decoded
end

-- Remove another node's registration from the rendezvous (administrators only). The one way to clear a
-- row whose key is gone - a deleted worktree, a scratch home, a reinstall; such a key can never sign
-- its own `/forget`. Exact node id only: a display name is self-chosen and may be shared.
-- Remove a node from the network for good (operator 17/11: a legacy node could be revoked but never left
-- the directory). The fleet key decides: the node must already be revoked in the VERIFIED roster
-- (`wa fleet revoke` + `wa fleet push-roster`). Then, at the rendezvous: if it is an operator it is retired
-- (`POST /operators` remove + retire, signed by this administrator), and its registration is forgotten.
-- Bound nodes that pinned it as an operator keep working: their admission does not count a pin the roster
-- revoked as lost (lua/core/binding.lua).
-- The message a second administrator signs to approve one retirement. The registry rebuilds it itself
-- (rust/wa-rendezvous, retirement_message), so this is the same sentence on both sides.
local function retirement_message(target, caller, nonce, ts)
  return table.concat({ "retire", target, caller, nonce, tostring(ts) }, "|")
end

-- "wa network approve <node-id> --for <caller-node-id> --nonce <nonce>": the second signature a
-- retirement needs, produced on ANOTHER administrator's node than the one that will ask. It signs this
-- exact retirement - the target, the asking administrator, the nonce and the time - so an approval
-- cannot be reused for another node, by another caller, or much later. Prints the approval to hand to
-- "wa network remove".
function M.network_approve_retire(target, caller, nonce)
  if type(target) ~= "string" or #target ~= 32 or not target:match("^%x+$") then return { error = "node_id_required" } end
  if type(caller) ~= "string" or #caller ~= 32 or not caller:match("^%x+$") then
    return { error = "caller_id_required", fix = "name the administrator that will ask: --for <its node id>" }
  end
  if type(nonce) ~= "string" or nonce == "" then
    return { error = "nonce_required", fix = "use the nonce the removing node printed with its refusal" }
  end
  if caller == target then return { error = "approval_target", fix = "a node cannot approve its own retirement" } end
  local identity = M.identity()
  if not identity or not identity.node_id then return { error = "node_identity_unavailable" } end
  if identity.node_id == caller then
    return { error = "approval_self", fix = "run this on a DIFFERENT administrator node: a retirement is two administrators' decision" }
  end
  local ts = math.floor(host.now())
  local signed = json.decode(host.sign(retirement_message(target, caller, nonce, ts)))
  if not signed or not signed.signature then return { error = "sign_failed" } end
  return { ok = true, approval = { node_id = identity.node_id, ts = ts, signature = signed.signature },
    target = target, caller = caller, nonce = nonce,
    next = "on the asking node: wa network remove " .. target .. " --nonce " .. nonce
      .. " --approval '" .. json.encode({ node_id = identity.node_id, ts = ts, signature = signed.signature }) .. "'" }
end

function M.network_remove(node_id, opts)
  if type(node_id) ~= "string" or not node_id:match("^%x+$") or #node_id ~= 32 then return { error = "node_id_required" } end
  if type(host.mesh_call) ~= "function" then return { error = "mesh_unavailable" } end
  local ok, raw = pcall(host.mesh_call, json.encode({ revoked = true }))
  local roster = ok and type(raw) == "string" and json.decode(raw) or nil
  if type(roster) ~= "table" or roster.ok ~= true then
    return { error = "roster_unverified", detail = roster and roster.error }
  end
  local revoked = false
  for _, id in ipairs(roster.revoked or {}) do if id == node_id then revoked = true end end
  if not revoked then
    return { error = "not_revoked_in_roster",
      fix = "revoke it in the signed roster first: wa fleet revoke <name> --roster <file> --key <fleet key>, then wa fleet push-roster <node> for each node" }
  end
  local url = M.rendezvous_url()
  if url == "" then return { error = "no_rendezvous" } end
  local base = url:gsub("/+$", "")
  local steps = {}
  -- The retirement is two administrators' decision (rust/wa-rendezvous, approval_problem): this
  -- administrator signs the request, and a SECOND one signs this exact retirement. The nonce is what
  -- ties the two signatures to one retirement, so it is chosen here and named in the refusal when the
  -- operator has not collected the approval yet.
  local nonce = tostring(opts.nonce or host.uuid())
  local approval = opts.approval
  if type(approval) == "string" then approval = json.decode(approval) or nil end
  if type(approval) ~= "table" or type(approval.signature) ~= "string" then
    local identity = M.identity() or {}
    return { error = "approval_required", nonce = nonce,
      fix = "a retirement needs another administrator's signature: on ANOTHER administrator node run "
        .. "wa network approve " .. node_id .. " --for " .. tostring(identity.node_id or "<this node>")
        .. " --nonce " .. nonce .. ", then repeat this command with --nonce " .. nonce
        .. " --approval '<the approval it printed>'" }
  end
  local body = json.encode({ remove = node_id, retire = true, nonce = nonce, approval = approval })
  local headers = M.signed_headers("operators", body)
  if not headers then return { error = "node_identity_unavailable" } end
  local response = json.decode(host.http("POST", base .. "/operators", json.encode(headers), body)) or {}
  local status = tonumber(response.status)
  if status == 200 then steps[#steps + 1] = "operator retired"
  elseif status == 404 then steps[#steps + 1] = "not an operator"
  else
    local reason = json.decode(tostring(response.body or "")) or {}
    return { error = "network_remove_operator_refused", status = status, detail = response.body,
      nonce = nonce, reason = reason.error }
  end
  local forgot = M.network_forget(node_id)
  if forgot.error and not (forgot.status == 404) then
    return { error = forgot.error, status = forgot.status, detail = forgot.detail, done = steps }
  end
  steps[#steps + 1] = forgot.error and "registration already gone" or "registration forgotten"
  M.invalidate()
  return { ok = true, removed = node_id, steps = steps }
end

function M.network_forget(node_id)
  if type(node_id) ~= "string" or not node_id:match("^%x+$") then return { error = "node_id_required" } end
  local url = M.rendezvous_url()
  if url == "" then return { error = "no_rendezvous" } end
  local body = json.encode({ node_id = node_id, nonce = host.uuid() })
  local headers = M.signed_headers("forget-node", body)
  if not headers then return { error = "node_identity_unavailable" } end
  local response = json.decode(host.http("POST", url:gsub("/+$", "") .. "/forget", json.encode(headers), body))
  if not response or tonumber(response.status) ~= 200 then
    return { error = "network_forget_refused", status = response and response.status, detail = response and response.body }
  end
  M.invalidate()
  return json.decode(response.body)
end

-- Registry authority first, then the recipient's pinned local grant. Report partial changes.
function M.network_role(node_id, role, preview)
  if role ~= "master" and role ~= "guest" then return { error = "invalid_role" } end
  -- Resolve one exact current registration; display-name ambiguity never chooses a target.
  local rows={};for _,n in ipairs(M.peers({fresh=true})) do if n.node_id==node_id then rows[#rows+1]=n end end
  if #rows~=1 then return {error='network_role_target_unknown'} end
  local request={node_id=node_id,public_key=rows[1].public_key,role=role,nonce=host.uuid()}
  local lookup=json.decode(host.http('GET',M.rendezvous_url()..'/lookup?node_id='..node_id,json.encode(M.signed_headers('lookup')),''))
  local value=lookup and lookup.status==200 and json.decode(lookup.body) or nil
  if not value or value.public_key~=request.public_key then return {error='network_role_identity_changed'} end
  if value.binding and value.binding.request then
    local b=value.binding
    if preview and (preview.node.public_key~=value.public_key or preview.node.role~=value.role or preview.binding.digest~=b.digest or preview.binding.revision~=b.revision) then return {error='binding_generation_changed'} end
    request.binding_id,request.binding_digest,request.binding_revision,request.expected_role=b.request.id,b.digest,b.revision,value.role
  end
  local body = json.encode(request)
  local headers = M.signed_headers("grant-role", body)
  local response = json.decode(host.http("POST", M.rendezvous_url():gsub("/+$", "") .. "/role", json.encode(headers), body))
  if not response or tonumber(response.status) ~= 200 then
    return { error = "network_role_refused", detail = response and response.body }
  end
  M.invalidate()
  local result = M.remote_call(node_id, "set_role", { role = role })
  if result.error or result.ok~=true or result.node_id~=node_id or result.role~=role then return { error = "network_role_changed_local_update_failed", network_role = role, detail = result } end
  local readback=json.decode(host.http('GET',M.rendezvous_url()..'/lookup?node_id='..node_id,json.encode(M.signed_headers('lookup')),''))
  local current=readback and readback.status==200 and json.decode(readback.body) or nil
  if not current or current.public_key~=request.public_key or current.role~=role then return {error='network_role_readback_unconfirmed',network_role=role,target_acknowledged=true} end
  -- Master-master means equals, so the promotion itself must carry access: the peer hands us its
  -- connector definitions and takes ours, and each side resolves its own credentials. Guests are
  -- granted access explicitly and are deliberately not synced here.
  if role == 'master' then
    local ok, synced = pcall(function() return dofile('lua/core/access.lua').sync(node_id) end)
    result.access = ok and synced or {ok=false,error=tostring(synced)}
    -- And the peer's connectors are usable from here at once, run where they live (lua/core/federation.lua).
    local fok, catalog = pcall(function() return dofile('lua/core/federation.lua').refresh() end)
    local peers = 0
    if fok and type(catalog) == 'table' then for _ in pairs(catalog.peers or {}) do peers = peers + 1 end end
    result.federation = fok and {ok=true,peers=peers} or {ok=false,error=tostring(catalog)}
  end
  return result
end

-- Stream a turn on a peer. Direct: its SSE is forwarded live. Via the relay the
-- stream is buffered there and replayed here, so the UI looks the same.
function M.remote_chat(selector, text)
  local node = M.find(selector)
  if not node then return { error = "unknown_node:" .. tostring(selector) } end
  if node.local_node then return { error = "not_remote" } end
  -- The intended target is inside the signed body, exactly as `/node/call` puts `to_node_id` there.
  -- A relay (or anyone on the path) can change the envelope's `to`, but the receiver checks this
  -- signed field against itself, so a valid chat for one node cannot be redirected to another node
  -- or endpoint. The signature domain is `chat-v2`, which is also what stops a new request from
  -- executing on an old receiver: the old verifier only knows `chat`, so it refuses `bad_signature`.
  local body = json.encode({ to_node_id = node.node_id, text = text or "" })
  local headers, problem = M.signed_headers("chat-v2", body)
  if not headers then return { error = problem } end
  headers["Content-Type"] = "application/json; charset=utf-8"
  headers["Accept"] = "text/event-stream"

  local endpoint = M.endpoint(node)
  if endpoint then
    local result = json.decode(host.relay(endpoint:gsub("/+$", "") .. "/node/chat",
      json.encode(headers), body))
    if result and tonumber(result.status) == 200 then
      return { ok = true, node = node.name, transport = "direct" }
    end
  end

  local response = M.request(node, "/node/chat", body, headers)
  if response and tonumber(response.status) == 200 then
    for line in tostring(response.body):gmatch("data: ([^\n]+)") do
      host.stream(line)
    end
    return { ok = true, node = node.name, transport = "relay" }
  end
  return { error = "remote_unreachable", node = node.name,
    detail = response and (response.error or response.status) or nil }
end

-- Can a call reach this peer without waiting out the relay hold? A peer with a direct endpoint, or one
-- the rendezvous reports as relay-attached, can. A registered peer that is not polling the relay cannot:
-- every relayed call to it is held ~20 s per attempt, up to the 60 s retry deadline. `nil` means the
-- rendezvous did not say (lookup failed, or an older rendezvous without `relay_attached`).
function M.reachable(node)
  if not node then return false, "unknown_node" end
  if M.endpoint(node) then return true end
  local record = lookup_node(node.node_id or node.id)
  if type(record) ~= "table" or record.relay_attached == nil then return nil end
  if record.relay_attached == true then return true end
  return false, "not_attached"
end

function M.endpoint(node)
  local list = (node and node.endpoints) or {}
  local endpoint = list[1]
  if not endpoint or endpoint == "" then return nil end
  if endpoint:match("^https?://") then return endpoint end
  return "http://" .. endpoint
end

return M
