-- Which session is acting, and whether it may act outside it.
--
-- THE RULE (mission change/session-isolation, 18/11): every surface is OWNED by the session (run) that
-- created it. Another session sees or acts on it only through an explicit node scope - the argument
-- `scope:"node"` - which the operator role alone gets, which is written to the audit journal, and
-- which is what Fleet View / mastermind use. Unknown owner = not yours: an owner that cannot be named
-- refuses the caller rather than serving it.
--
-- Why one module instead of a check per tool: the checks drifted. `operation` stamped `owner` and never
-- compared it, `subagent` scoped by user rather than session, `codemode` dropped a nil session from its
-- scope key - three spellings of "not mine", and none of them was a decision anybody could find.
--
-- What is NOT here, by design: shared memory scopes, master search across sessions, one TMPDIR, vault
-- operator signing rights, node-wide MCP approvals and the peer chat thread per peer. Those are
-- documented as shared in the mission report; making them per-session would break a promise each one
-- was built to keep.
local M = {}

-- The only scope a tool takes, and the only role that gets it. `users.normalize` maps the legacy alias
-- `admin` onto `master`, so the operator's own credential is the one that reaches this (a session is
-- not a role: every session of the operator's carries it, which is why the grant is also audited).
M.NODE_SCOPE = "node"
function M.operator(role)
  return dofile('lua/core/users.lua').is_master(role)
end

-- Record the grant. A node-wide read or act leaves a line an operator can find afterwards: the session
-- that asked, the tool, the role, the user and the clock, in the node's own replication journal (which
-- is the durable trail this node already has, `memory.journal`).
function M.audit(memory, session, user_id, role, tool)
  if type(memory) ~= 'table' or type(memory.journal) ~= 'function' then return end
  pcall(memory.journal, "session_scope", tostring(session or ""), {
    scope = M.NODE_SCOPE, tool = tostring(tool or ""), user = tostring(user_id or ""),
    role = tostring(role or ""), at = host and host.now and host.now() or nil,
  })
end

-- The grant for one call: `{ session = <the acting session>, node = <bool> }`, or `nil, refusal`.
--
--   * no `scope` at all           -> the caller's own session, and nothing else;
--   * `scope:"node"`, operator    -> the node, audited;
--   * `scope:"node"`, anyone else -> refused by name;
--   * any other scope             -> refused by name (a scope this node does not have is not a guess to
--                                   make: "guest" and "global" mean memory scopes, not process surfaces).
function M.grant(memory, args, ctx, role, user_id, tool)
  local wanted = type(args) == 'table' and args.scope or nil
  local session = type(ctx) == 'table' and ctx.session_id or nil
  if wanted ~= nil and type(wanted) ~= 'string' then
    return nil, { error = "scope_invalid", effect = "none",
      note = 'a scope is the string "node" or nothing at all' }
  end
  if wanted ~= nil and wanted ~= "" and wanted ~= M.NODE_SCOPE then
    return nil, { error = "scope_unknown", effect = "none", scope = wanted,
      note = 'the only scope a tool takes is scope:"node" (the whole node, operator only)' }
  end
  if wanted == M.NODE_SCOPE then
    if not M.operator(role) then
      return nil, { error = "scope_node_forbidden", effect = "none", role = tostring(role or ""),
        note = 'scope:"node" is the operator role\'s alone: it reaches every session on this node' }
    end
    M.audit(memory, session, user_id, role, tool)
    return { session = session, node = true }
  end
  return { session = session, node = false }
end

-- The same decision, spelled for a reader that only has a role and a role's own credential (an engine
-- route, a peer call): a node scope is granted only when the caller asked for it AND may have it.
function M.node_allowed(memory, args, ctx, role, user_id, tool)
  local grant = M.grant(memory, args, ctx, role, user_id, tool)
  return grant ~= nil and grant.node == true
end

return M