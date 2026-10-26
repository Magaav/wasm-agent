-- `/nodes` in `wa chat`: this node and the peers of the cluster it is bound to, as a panel the
-- reader moves through (Enter opens a node, Esc goes back) - the way `/login` and `/model` look.
-- Without a raw editor it prints one line per node. `/nodes pending` stays a binding command.
--
-- `io`: print(text), panel(spec) -> result (optional), paint(text, role).
local nodes = dofile("lua/core/nodes.lua")
local M = {}

local MIDDOT = "\194\183"

local function paint(io, text, role) return io.paint and io.paint(text, role) or text end
local function short(id) return tostring(id or "?"):sub(1, 8) end

local function gib(bytes)
  local n = tonumber(bytes)
  return n and string.format("%.1f GiB", n / 1073741824) or "?"
end

local function ago(ts)
  local seconds = tonumber(ts) and math.max(0, host.now() - tonumber(ts))
  if not seconds then return "never" end
  if seconds < 60 then return seconds .. "s ago" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end

-- Where the peers come from: the bound service, or the rendezvous named in the environment.
local function cluster_line()
  local url = nodes.rendezvous_url()
  if url == "" then return "Cluster: none - this node is not bound (/bind to join one)" end
  return "Cluster: " .. url
end

local function label(node)
  local name = tostring(node.name or "")
  if name == "" then name = short(node.node_id) end
  return node.local_node and (name .. " (this node)") or name
end

local function hint(node)
  local parts = { tostring(node.role or "?") }
  if node.local_node then parts[#parts + 1] = "local"
  else parts[#parts + 1] = node.online and "online" or ("offline " .. MIDDOT .. " seen " .. ago(node.last_seen)) end
  parts[#parts + 1] = short(node.node_id)
  return table.concat(parts, " " .. MIDDOT .. " ")
end

function M.details(node)
  local lines = {
    "Node id: " .. tostring(node.node_id or "?"),
    "Role: " .. tostring(node.role or "?") .. "   " .. (node.local_node and "this node"
      or ((node.online and "online" or "offline") .. ", seen " .. ago(node.last_seen))),
  }
  if node.worktree and node.worktree ~= "" then lines[#lines + 1] = "Worktree: " .. tostring(node.worktree) end
  local endpoints = type(node.endpoints) == "table" and node.endpoints or {}
  if #endpoints > 0 then
    local shown = {}
    for _, e in ipairs(endpoints) do shown[#shown + 1] = type(e) == "table" and tostring(e.url or e.address or e.kind or "?") or tostring(e) end
    lines[#lines + 1] = "Endpoints: " .. table.concat(shown, ", ")
  elseif not node.local_node then
    lines[#lines + 1] = "Endpoints: none (reached through the relay)"
  end
  local r = type(node.resources) == "table" and node.resources or nil
  if r then
    if type(r.cpu) == "table" then
      lines[#lines + 1] = string.format("CPU: %s cores, %s%% used", tostring(r.cpu.logical_cores or "?"), tostring(r.cpu.used_percent or "?"))
    end
    if type(r.memory) == "table" then
      lines[#lines + 1] = string.format("Memory: %s free of %s", gib(r.memory.available_bytes), gib(r.memory.total_bytes))
    end
    if type(r.disk) == "table" then
      lines[#lines + 1] = string.format("Disk: %s free of %s", gib(r.disk.available_bytes), gib(r.disk.total_bytes))
    end
  end
  if type(node.capabilities) == "table" and #node.capabilities > 0 then
    lines[#lines + 1] = "Tools: " .. table.concat(node.capabilities, ", ")
  end
  return lines
end

function M.run(io)
  local list = nodes.list()
  if not io.panel then
    io.print(cluster_line())
    for _, node in ipairs(list) do io.print(label(node) .. "  " .. hint(node)) end
    return true
  end
  local selected = 1
  while true do
    local options = {}
    for n, node in ipairs(list) do options[n] = { label = label(node), hint = hint(node) } end
    local peers = #list - 1
    local answer = io.panel({
      title = "Nodes",
      lines = { cluster_line(), peers == 1 and "1 peer" or (peers .. " peers") },
      options = options, selected = selected,
    })
    if answer.action ~= "select" or not list[answer.index] then return true end
    selected = answer.index
    local node = list[selected]
    local back = io.panel({ title = label(node), lines = M.details(node), options = { { label = "Back", hint = "" } } })
    if back.action ~= "select" and back.action ~= "cancel" then return true end
  end
end

return M
