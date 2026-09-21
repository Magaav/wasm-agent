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

function M.rendezvous_url()
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
  -- Who is allowed to be a master at all. The rendezvous records what each node says about
  -- itself, which is fine while every node is honest and useless once one is not: the record is
  -- evidence of identity, not of intent. With this set, the rendezvous stops being the only
  -- authority and an enrolled list decides. Unset means "the rendezvous is the authority", which
  -- is the default - said out loud here so the choice is visible.
  local enrolled = tostring(host.getenv("WASM_AGENT_TRUSTED_MASTERS") or "")
  if enrolled ~= "" then
    local node_id = tostring(caller.node_id or "")
    local name = tostring(caller.name or "")
    for entry in enrolled:gmatch("[^,]+") do
      entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
      if entry ~= "" and (entry == node_id or entry == name) then return name ~= "" and name or node_id end
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
-- the same key without the same signature.
local seen = {}

function M.seen_before(id)
  if enrollment.managed() then return enrollment.seen_before(id) end
  if seen[id] then return true end
  local now = host.now()
  for key, at in pairs(seen) do
    if (now - at) > 300 then seen[key] = nil end
  end
  seen[id] = now
  return false
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
function M.verify_caller(node_id, public_key, opts)
  if enrollment.managed() then return enrollment.caller(node_id, public_key) end
  if not node_id or not public_key then return nil end
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
  if endpoint then
    local response = json.decode(host.http("POST", endpoint:gsub("/+$", "") .. path,
      json.encode(headers), body or ""))
    if response and tonumber(response.status) == 200 then return response end
  end
  local relay = M.relay_url()
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
          return { status = decoded.status, body = decoded.body, rid = rid }
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
  if response.error then return { error = "remote_error", detail = tostring(response.error) } end
  if tonumber(response.status) ~= 200 then
    return {
      error = "remote_http_" .. tostring(response.status),
      detail = tostring(response.body):sub(1, 240),
      node = node.name,
    }
  end
  local ok, decoded = pcall(json.decode, response.body)
  if not ok or type(decoded) ~= "table" then return { result = response.body, node = node.name } end
  decoded.node = node.name
  return decoded
end

-- Registry authority first, then the recipient's pinned local grant. Report partial changes.
function M.network_role(node_id, role)
  if role ~= "master" and role ~= "guest" then return { error = "invalid_role" } end
  local body = json.encode({ node_id = node_id, role = role, nonce = host.uuid() })
  local headers = M.signed_headers("grant-role", body)
  local response = json.decode(host.http("POST", M.rendezvous_url():gsub("/+$", "") .. "/role", json.encode(headers), body))
  if not response or tonumber(response.status) ~= 200 then
    return { error = "network_role_refused", detail = response and response.body }
  end
  M.invalidate()
  local result = M.remote_call(node_id, "set_role", { role = role })
  if result.error then return { error = "network_role_changed_local_update_failed", network_role = role, detail = result } end
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
  -- or endpoint. The body is the envelope; the prompt is its `text` field.
  local body = json.encode({ to_node_id = node.node_id, text = text or "" })
  local headers, problem = M.signed_headers("chat", body)
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
