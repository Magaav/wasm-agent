-- Node registry: this node plus peers discovered through the rendezvous.
--
-- Nodes bind by ed25519 key, not address. The rendezvous is the source of truth
-- for a peer's public key, so a caller is only trusted when its key matches what
-- the rendezvous has on file.
local json = dofile("lua/vendor/json.lua")
local M = {}

local CACHE_TTL = 15
local cache, cache_at = nil, 0

function M.rendezvous_url()
  return os.getenv("WASM_AGENT_RENDEZVOUS") or ""
end

function M.identity()
  local ok, raw = pcall(host.node_identity)
  if not ok or not raw then return nil end
  return json.decode(raw)
end

function M.node_name()
  return os.getenv("WASM_AGENT_NODE_NAME") or "host"
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

-- Call a capability on a peer: signed request to its /node/call endpoint.
function M.remote_call(selector, capability, args)
  local node = M.find(selector)
  if not node then return { error = "unknown_node:" .. tostring(selector) } end
  local endpoint = M.endpoint(node)
  if not endpoint then return { error = "no_endpoint", node = node.name } end
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
  local headers = json.encode({
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["User-Agent"] = "wasm-agent/0.1 node",
  })
  local response = json.decode(host.http("POST", endpoint:gsub("/+$", "") .. "/node/call", headers, body))
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

-- Stream a turn on a peer: the peer's SSE lines are relayed to our UI.
function M.remote_chat(selector, text)
  local node = M.find(selector)
  if not node then return { error = "unknown_node:" .. tostring(selector) } end
  if node.local_node then return { error = "not_remote" } end
  local endpoint = M.endpoint(node)
  if not endpoint then return { error = "no_endpoint", node = node.name } end
  local ts = math.floor(host.now())
  local identity, signature, problem = M.sign_action("chat", ts)
  if not identity then return { error = problem } end
  local headers = json.encode({
    ["Content-Type"] = "text/plain; charset=utf-8",
    ["Accept"] = "text/event-stream",
    ["User-Agent"] = "wasm-agent/0.1 node",
    ["X-WA-Node"] = identity.node_id,
    ["X-WA-Pub"] = identity.public_key,
    ["X-WA-Ts"] = tostring(ts),
    ["X-WA-Sig"] = signature,
  })
  local result = json.decode(host.relay(endpoint:gsub("/+$", "") .. "/node/chat", headers, text or ""))
  if not result then return { error = "relay_failed", node = node.name } end
  if result.error then return { error = result.error, node = node.name } end
  return { ok = true, node = node.name, status = result.status }
end

function M.endpoint(node)
  local list = (node and node.endpoints) or {}
  local endpoint = list[1]
  if not endpoint or endpoint == "" then return nil end
  if endpoint:match("^https?://") then return endpoint end
  return "http://" .. endpoint
end

return M
