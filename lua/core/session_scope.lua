-- Which session is acting, and whether it may act outside it.
--
-- THE RULE (mission change/session-isolation, 18/11): every surface is OWNED by the session (run) that
-- created it. Another session sees or acts on it only through an explicit node scope - the argument
-- `scope:"node"` - which is written to the audit journal with the SURFACE that asked. Unknown owner = not
-- yours: an owner that cannot be named refuses the caller rather than serving it.
--
-- WHO MAY ASK FOR IT, corrected in round 2: not "the operator role", because every session on this node
-- carries the operator's credential and a role check therefore refused nothing. It is an operator SURFACE
-- (Fleet View, the mastermind window, the window's operation route, the terminal CLI) OR a session the
-- operator explicitly marked mastermind. A model tool call in an ordinary session is refused by name, and
-- the refusal says how to get it. See M.SURFACES and M.grant below.
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
function M.audit(memory, session, user_id, role, tool, surface)
  if type(memory) ~= 'table' or type(memory.journal) ~= 'function' then return end
  pcall(memory.journal, "session_scope", tostring(session or ""), {
    scope = M.NODE_SCOPE, tool = tostring(tool or ""), user = tostring(user_id or ""),
    role = tostring(role or ""), surface = tostring(surface or ""),
    at = host and host.now and host.now() or nil,
  })
end

-- THE NODE SCOPE IS A SURFACE'S, NOT A ROLE'S (operator decision, 18/11; item 7 round 2).
--
-- Round 1 gave scope:"node" to the operator ROLE, and every session on this node carries the operator's
-- credential - so any model tool call could reach every other session's operations, which is the leak the
-- whole mission is about, re-opened one layer up. A role says who the human is; it says nothing about
-- which code is asking. So the grant now needs ONE of these, in addition to the role:
--
--   * a SURFACE - the node's own code acting for the operator: Fleet View, the mastermind window, the
--     window's operation route, the terminal CLI's --node flag. A surface names itself in its own ctx,
--     which a model tool call cannot set;
--   * a session the OPERATOR has marked mastermind (/mastermind in that conversation, journalled), for
--     the one case where an agent IS the mastermind.
--
-- A model call in an ordinary operator session is refused by name, and the refusal says how to get it.
M.SURFACES = { fleetview = true, mastermind = true, window = true, cli = true }

-- The surface this call belongs to, or nil for a model tool call, or "unknown" for a name nothing here
-- implements (which is a refusal, not a guess).
function M.surface(ctx)
  local name = type(ctx) == 'table' and tostring(ctx.surface or "") or ""
  if name == "" then return nil end
  if not M.SURFACES[name] then return "unknown" end
  return name
end

-- Is this conversation one the operator has marked mastermind? Answered by the ledger, so a session that
-- was marked does not have to carry the mark in its own arguments.
function M.mastermind(memory, session)
  if type(memory) ~= 'table' or type(session) ~= 'string' or session == "" then return false end
  if type(memory.session_mastermind) ~= 'function' then return false end
  local ok, value = pcall(memory.session_mastermind, session)
  return ok and value == true
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
    local surface = M.surface(ctx)
    if surface == "unknown" then
      return nil, { error = "scope_surface_unknown", effect = "none", surface = tostring(ctx.surface),
        note = 'the node scope belongs to a surface this node implements: fleetview, mastermind, window, cli' }
    end
    local marked = M.mastermind(memory, session)
    if surface == nil and not marked then
      return nil, { error = "scope_node_forbidden", effect = "none", role = tostring(role or ""),
        session = tostring(session or ""),
        note = 'scope:"node" is not a model tool call: it reaches every session on this node and belongs to an operator surface (Fleet View, the mastermind window, the terminal CLI with --node) or to a session the operator has marked mastermind. To get it for this conversation, ask the operator to run /mastermind here; to read your own work, call again without a scope.' }
    end
    M.audit(memory, session, user_id, role, tool, surface or "mastermind")
    return { session = session, node = true, surface = surface or "mastermind" }
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