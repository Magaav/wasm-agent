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

function M.run(io, opts)
  -- One builder for both surfaces: the panel this loop draws and the stack the client draws while a
  -- run is in flight (M.views -> lua/core/local_views.lua) are the same spec, so a label that changes
  -- here changes there and nowhere else has to be remembered.
  local set = M.views(opts)
  local list = set.nodes
  if not io.panel then
    io.print(cluster_line())
    for _, node in ipairs(list) do io.print(label(node) .. "  " .. hint(node)) end
    return true
  end
  local index = 1
  local focus = 1
  while true do
    local view = set.views[index]
    -- Back lands on the node that was open, as it always has.
    if index == 1 then view.selected = focus end
    local answer = io.panel({
      title = view.title, lines = view.lines, options = view.options, selected = view.selected,
    })
    if type(answer) ~= "table" then return true end
    if answer.action == "cancel" then
      if index == 1 then return true end
      index = 1
    elseif answer.action ~= "select" then
      return true
    else
      local chosen = view.options[answer.index]
      if not chosen then return true end
      if chosen.pop then index = 1
      elseif chosen.view then focus = answer.index; index = chosen.view
      else return true end
    end
  end
end

-- The whole view as data: the root list and one page per node, as panel specs plus the links between
-- them (`options[i].view`, and the `Back` option's `pop`). This is what `lua/core/local_views.lua`
-- publishes for `host.local_view`, and what `M.run` draws, so the two cannot disagree.
--
-- `opts.cached` builds it from the roster this process already has, with no network read: the only
-- version safe to take while a run is in flight.
function M.views(opts)
  opts = opts or {}
  local list = nodes.list({ cached = opts.cached })
  local views = { {
    title = "Nodes",
    lines = { cluster_line(), (#list - 1) == 1 and "1 peer" or ((#list - 1) .. " peers") },
    options = {},
    selected = 1,
  } }
  for n, node in ipairs(list) do
    views[1].options[n] = { label = label(node), hint = hint(node), view = n + 1 }
    views[n + 1] = { title = label(node), lines = M.details(node), options = { { label = "Back", hint = "", pop = true } } }
  end
  return { command = "/nodes", captured_at = host.now(), views = views, nodes = list }
end

return M
