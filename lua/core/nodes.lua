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

local function fetch_peers(fresh)
  local url = M.rendezvous_url()
  if url == "" then return {} end
  local now = host.now()
  -- `fresh` skips the cache. A step that changes state - may this caller run tools on this
  -- node - must not be made from a list read fifteen seconds ago: a peer removed from the
  -- rendezvous would stay welcome here for the rest of the window. A display can live with that;
  -- a capability check cannot.
  if not fresh and cache and (now - cache_at) < CACHE_TTL then return cache end
  local peers = {}
  pcall(function()
    local headers = json.encode(M.signed_headers("nodes") or {})
    local response = json.decode(host.http("GET", url:gsub("/+$", "") .. "/nodes", headers, ""))
    if response and tonumber(response.status) == 200 then
      local ok, payload = pcall(json.decode, response.body)
      if ok and type(payload) == "table" and type(payload.nodes) == "table" then
        peers = payload.nodes
      end
    end
  end)
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

-- Local host node + every other peer the rendezvous knows about.
function M.list()
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
  for _, peer in ipairs(fetch_peers()) do
    if peer.node_id ~= identity.node_id then
      peer.id = peer.node_id
      peer.kind = "peer"
      peer.local_node = false
      out[#out + 1] = peer
    end
  end
  return out
end

function M.find(selector)
  if not selector or selector == "" then return nil end
  for _, node in ipairs(M.list()) do
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
    local response = json.decode(host.http("GET", url:gsub("/+$", "") .. "/lookup?node_id=" .. node_id, headers, ""))
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

-- Send a request to a node: directly when it advertises a routable endpoint,
-- otherwise through the relay. `headers` are forwarded to the target.
function M.request(node, path, body, inner_headers)
  local headers = normalize_headers(inner_headers)
  headers["Content-Type"] = headers["Content-Type"] or "application/json"
  local endpoint = M.endpoint(node)
  local direct = nil
  if endpoint then
    local response = json.decode(host.http("POST", endpoint:gsub("/+$", "") .. path,
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
    local DEADLINE, started = 60, host.now()
    for attempt = 1, 3 do
      local relay_headers = M.signed_headers("relay-send")
      if not relay_headers then return { error = "no_identity" } end
      local envelope = json.encode({
        rid = rid, to = node.node_id, method = "POST", path = path,
        headers = headers, body = body or "",
      })
      local response = json.decode(host.http("POST", relay:gsub("/+$", "") .. "/relay/send",
        json.encode(relay_headers), envelope))
      if response and tonumber(response.status) == 200 then
        local decoded = json.decode(response.body)
        if decoded and decoded.ok then
          return { status = decoded.status, body = decoded.body, rid = rid, transport = "relay" }
        end
        -- relay_timeout is retryable too: the relay keeps the result for two
        -- minutes and the id is stable, so a retry re-fetches it.
        if not (decoded and decoded.error == "relay_timeout") then
          return { error = (decoded and decoded.error) or "relay_error" }
        end
      elseif response and tonumber(response.status) == 503 then
        -- Retired by the relay (it holds now), kept for an older rendezvous:
        -- the node was not attached, which is a reason to wait, not to fail.
        last_error = "node_not_attached"
      elseif response and tonumber(response.status) == 504 then
        -- The relay held the request and the node did not answer: either it
        -- never attached (retry when it is back) or it is busy and the action
        -- may still be running - which is exactly why the retry reuses the id.
        local decoded = json.decode(response.body)
        last_error = (decoded and decoded.error) or "node_no_answer"
        if decoded and decoded.retry_after_ms then
          host.sleep(tonumber(decoded.retry_after_ms) / 1000)
        end
      elseif response and tonumber(response.status) == 409 and M.relay_code(response.body) == "request_in_flight" then
        -- The same rid is still running at the target: waiting re-collects it.
        last_error = "request_in_flight"
      elseif response and (tonumber(response.status) or 0) >= 400 then
        -- The relay itself refused (401/403/404/400/409/413): retrying the same request cannot
        -- change that answer, and reporting it as `relay_timeout` hid the reason.
        local status = tonumber(response.status)
        return { error = "relay_refused", relay_status = status,
          reason = M.relay_code(response.body) or "unrecognized", rid = rid }
      end
      if (host.now() - started) > DEADLINE then break end
      if attempt < 3 then host.sleep(750 * attempt) end
    end
    -- Say that it is retryable, and which reason it kept hitting: "could not
    -- reach the node" and "the node is busy" call for different next steps.
    return { error = last_error or "relay_timeout", rid = rid, retryable = true }
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
    return json.decode(host.http("GET", url:gsub("/+$", "") .. "/lookup?node_id=" .. node_id, headers, ""))
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

-- Call a capability on a peer: direct when possible, else through the relay.
function M.remote_call(selector, capability, args)
  local node = M.find(selector)
  if not node then return { error = "unknown_node:" .. tostring(selector) } end
  local ts = math.floor(host.now())
  -- The body is built before it is signed, and the signature travels in the headers rather than
  -- inside the body: what was signed is the body as it is sent, so the receiver can hash the
  -- bytes it got. `from_node_id` and the public key stay in the body for readability - they are
  -- covered by the hash like everything else.
  local body = json.encode({
    from_node_id = (M.identity() or {}).node_id,
    to_node_id = node.node_id,
    request_id = host.uuid(),
    capability = capability,
    args = args or {},
  })
  local headers, problem = M.signed_headers("call", body)
  if not headers then return { error = problem } end
  local response = M.request(node, "/node/call", body, headers)
  if not response then return { error = "remote_unreachable", node = node.name } end
  if response.error == "relay_refused" then
    local refusal = M.refusal("relay", response.reason, response.relay_status, node)
    refusal.rid = response.rid
    return refusal
  end
  if response.error then
    return { error = "remote_error", detail = tostring(response.error), node = node.name,
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

function M.endpoint(node)
  local list = (node and node.endpoints) or {}
  local endpoint = list[1]
  if not endpoint or endpoint == "" then return nil end
  if endpoint:match("^https?://") then return endpoint end
  return "http://" .. endpoint
end

return M
