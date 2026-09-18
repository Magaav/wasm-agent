-- Node registry: this node plus peers discovered through the rendezvous.
--
-- Nodes bind by ed25519 key, not address. The rendezvous is the source of truth
-- for a peer's public key, so a caller is only trusted when its key matches what
-- the rendezvous has on file.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
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

-- What a human calls this node when four of them are in a list.
--
-- Order: a name someone set, then the *worktree this node is running in*, then the
-- environment, then "host". The worktree comes before the environment deliberately: a list
-- of nodes should read as a list of checkouts, and WASM_AGENT_NODE_NAME is the older
-- mechanism - a leftover value in a shell profile would otherwise make every node on the
-- machine claim the same name, which is the confusion this exists to remove.
function M.node_name()
  local stored = host.read_file(M.name_file())
  if type(stored) == "string" then
    local trimmed = stored:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then return trimmed end
  end
  local dir = M.worktree()
  if dir and dir ~= "" then return dir end
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
  local ok, wrote = pcall(host.write_file, M.name_file(), name .. "\n")
  if not ok or wrote == false then return nil, "node_name_write_failed" end
  M.invalidate()
  return name
end

local function fetch_peers()
  local url = M.rendezvous_url()
  if url == "" then return {} end
  local now = host.now()
  if cache and (now - cache_at) < CACHE_TTL then return cache end
  local peers = {}
  pcall(function()
    local headers = json.encode({ ["Accept"] = "application/json", ["User-Agent"] = "wasm-agent/0.1 node" })
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
      role = "master",
      online = true,
      local_node = true,
      worktree = M.worktree(),
      endpoints = {},
      capabilities = {
        "bash", "read", "write", "edit", "ls", "grep",
        "shell", "client", "spell_save", "spell_run", "spell_get",
      },
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
function M.verify_caller(node_id, public_key)
  if not node_id or not public_key then return nil end
  for _, node in ipairs(fetch_peers()) do
    if node.node_id == node_id and node.public_key == public_key then
      return node
    end
  end
  return nil
end

-- Sign `action|node_id|ts` with this node's key.
function M.sign_action(action, ts)
  local identity = M.identity()
  if not identity or not identity.node_id then return nil, nil, "no_identity" end
  local message = table.concat({ action, identity.node_id, tostring(ts) }, "|")
  local signed = json.decode(host.sign(message))
  if not signed or not signed.signature then return identity, nil, "sign_failed" end
  return identity, signed.signature
end

-- The relay that fronts nodes which cannot accept inbound connections.
function M.relay_url()
  return host.getenv("WASM_AGENT_RELAY") or ""
end

function M.signed_headers(action)
  local ts = math.floor(host.now())
  local identity, signature, problem = M.sign_action(action, ts)
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
  local identity, signature, problem = M.sign_action("call", ts)
  if not identity then return { error = problem } end
  local body = json.encode({
    from_node_id = identity.node_id,
    public_key = identity.public_key,
    ts = ts,
    capability = capability,
    args = args or {},
    signature = signature,
  })
  local response = M.request(node, "/node/call", body)
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

-- Stream a turn on a peer. Direct: its SSE is forwarded live. Via the relay the
-- stream is buffered there and replayed here, so the UI looks the same.
function M.remote_chat(selector, text)
  local node = M.find(selector)
  if not node then return { error = "unknown_node:" .. tostring(selector) } end
  if node.local_node then return { error = "not_remote" } end
  local headers, problem = M.signed_headers("chat")
  if not headers then return { error = problem } end
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Accept"] = "text/event-stream"

  local endpoint = M.endpoint(node)
  if endpoint then
    local result = json.decode(host.relay(endpoint:gsub("/+$", "") .. "/node/chat",
      json.encode(headers), text or ""))
    if result and tonumber(result.status) == 200 then
      return { ok = true, node = node.name, transport = "direct" }
    end
  end

  local response = M.request(node, "/node/chat", text or "", headers)
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
