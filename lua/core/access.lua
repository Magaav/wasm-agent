-- Network access handoff between nodes of the same rank.
--
-- A master-master bind is a pairing of equals, so a node promoted to master should not have to be
-- configured by hand for capabilities its peer already has. This module defines what travels: MCP
-- connector *definitions* and their approved tool tiers. Nothing else, and nothing secret.
--
-- What deliberately does not travel: credential values. A definition carries `env`/`headers` as
-- environment *references* and `args` that name a credential FILE; the receiving node resolves those
-- from its own vault. Copying a password to a second machine would turn "you are a master" into "you
-- now hold every secret the first node held", which no bind ever meant.
--
-- A guest is granted access explicitly, one connector at a time, by the operator; this module refuses
-- to push to a guest and refuses to apply on a guest.
local json = dofile('lua/vendor/json.lua')
local mcp = dofile('lua/core/mcp.lua')
local nodes = dofile('lua/core/nodes.lua')

local M = { SCHEMA = 1 }

-- Only a node that is master may send or receive access. The check is the node's own role file, not
-- a claim in the package: the receiving side never trusts the sender's assertion about rank.
local function local_is_master()
  local role = nodes.role()
  return role == 'master'
end

local function connector_of(definition)
  -- Field-by-field rather than a copy of whatever arrived: an unknown field would otherwise travel
  -- into the registry unchecked, and `mcp.validate` is the one place that decides what is allowed.
  return {
    id = definition.id, name = definition.name, transport = definition.transport,
    program = definition.program, args = definition.args, url = definition.url, cwd = definition.cwd,
    timeout_seconds = definition.timeout_seconds, tools = definition.tools,
    env = definition.env, headers = definition.headers, secret_env = definition.secret_env,
  }
end

-- The local snapshot: what this node can hand to a peer it considers an equal.
function M.package()
  local inventory = mcp.inventory()
  local connectors = {}
  for _, server in ipairs(inventory.servers or {}) do
    if type(server.definition) == 'table' then connectors[#connectors + 1] = connector_of(server.definition) end
  end
  local identity = nodes.identity() or {}
  return { schema = M.SCHEMA, node = identity.node_id, revision = inventory.revision,
           generated_at = host.now(), connectors = connectors }
end

-- Apply a peer's package: put (disabled) -> probe -> enable, in that order, per connector. A
-- connector whose probe fails is reported, never enabled and never silently dropped. The return
-- value names every outcome so the caller can say "promoted, and these two refused because this node
-- has no credential for them".
function M.apply(package, ctx)
  ctx = ctx or {}
  if not local_is_master() then return { ok = false, error = 'access_requires_master' } end
  if type(package) ~= 'table' or package.schema ~= M.SCHEMA or type(package.connectors) ~= 'table' then
    return { ok = false, error = 'access_package_invalid' }
  end
  local applied, refused = {}, {}
  for _, candidate in ipairs(package.connectors) do
    local definition = connector_of(candidate)
    local problem = mcp.validate(definition)
    if problem then
      refused[#refused + 1] = { id = candidate.id, error = problem }
    else
      local put = mcp.control({ action = 'put', expected_revision = mcp.inventory().revision,
                                definition = definition }, { role = 'master' })
      if not put.ok then
        refused[#refused + 1] = { id = definition.id, error = put.error or 'put_refused' }
      else
        local probed = mcp.control({ action = 'probe', id = definition.id,
                                     expected_revision = mcp.inventory().revision }, { role = 'master' })
        if probed.ok ~= true then
          -- Probe leaves the definition disabled by design; keep that and say why.
          refused[#refused + 1] = { id = definition.id, error = probed.error or 'probe_refused',
                                    probe = probed }
        else
          local enabled = mcp.control({ action = 'enable', id = definition.id,
                                        expected_revision = mcp.inventory().revision }, { role = 'master' })
          if enabled.ok == true then
            applied[#applied + 1] = { id = definition.id, tools = #(probed.tools or {}) }
          else
            refused[#refused + 1] = { id = definition.id, error = enabled.error or 'enable_refused' }
          end
        end
      end
    end
  end
  return { ok = #refused == 0, applied = applied, refused = refused,
           credentials = 'not transferred: each node resolves its own vault references' }
end

-- Peer-facing entry point. `package` hands out this node's access; `apply` takes the caller's.
function M.call(args, caller)
  args = args or {}
  local action = args.action or 'package'
  if action == 'package' then
    if not local_is_master() then return { ok = false, error = 'access_requires_master' } end
    return { ok = true, package = M.package() }
  elseif action == 'apply' then
    if not local_is_master() then return { ok = false, error = 'access_requires_master' } end
    return M.apply(args.package, { caller = caller })
  end
  return { ok = false, error = 'unknown_access_action' }
end

-- Two-way convergence with one peer. Called when a pairing makes both sides master: the promoting
-- side hands its access over and takes the peer's, so neither needs a second manual step.
function M.sync(peer)
  if not local_is_master() then return { ok = false, error = 'access_requires_master' } end
  local theirs = nodes.remote_call(peer, 'access', { action = 'package' })
  local received = nil
  if theirs and theirs.ok and type(theirs.package) == 'table' then
    received = M.apply(theirs.package, { peer = peer })
  else
    received = { ok = false, error = (theirs and theirs.error) or 'access_package_unavailable' }
  end
  local mine = M.package()
  local sent = nodes.remote_call(peer, 'access', { action = 'apply', package = mine })
  return { ok = received.ok and (sent and sent.ok or false), received = received, sent = sent }
end

return M
