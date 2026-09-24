-- Local subagents: the policy half of the runtime.
--
-- A subagent is a supervised child task with its own fresh context, its own
-- session and bounded execution (docs/EXECUTION.md). Rust (`rust/wa-host/src/subagents.rs`)
-- owns the OS thread, the durable record, capacity and the cancel flag; this file
-- owns everything an agent is allowed to decide: which profile, which exact
-- tools, which prompt, which budgets and how a caller's ownership is derived.
--
-- One public facade serves three callers: the model's `subagent` tool, the HTTP
-- control route (`wa_subagents(body, session)`), and a job delivery starting a
-- specialist child. All three pass a `ctx` that the *server* built; no owner,
-- depth or allowed-tool list is ever read from the request body.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local tools = dofile("lua/core/tools.lua")
local agentlib = dofile("lua/core/agent.lua")
local users = dofile("lua/core/users.lua")
local nodes = dofile("lua/core/nodes.lua")
local paths = dofile("lua/core/paths.lua")
local redact = dofile("lua/core/redact.lua")

local M = {}

-- Tools that reach outside a sandbox conversation. Any profile that names one
-- must be explicitly operator-authorized; a built-in read-only profile never is.
local BROAD = {
  bash = true, shell = true, client = true, remote = true,
  write = true, edit = true, spell_save = true, spell_run = true, spell_export = true,
}

-- Built-in profiles. `explore` is the default and is read-only; `guest` is the
-- only profile a guest may start. Anything broader is a file under
-- `<config>/subagent-profiles/` that an operator put there, and it must say
-- `"operator_authorized": true`.
local BUILTIN = {
  explore = {
    schema_version = 1,
    id = "explore",
    builtin = true,
    description = "Read-only investigation: search, read, navigate the code graph and diagnose. Cannot write or run a shell.",
    instructions = "Investigate the task read-only and report what you found with exact file paths and line references. For a navigation question - where is X defined, who calls it, how does A reach B - call `graph` first; use `grep`/`read` for the lines behind the answer. Do not modify anything.",
    -- `graph` is read-only in effect: query/explain/path/caps/stats only read the index, and
    -- `index` rebuilds the node's own local graph.db. It reaches no external state, so a
    -- read-only investigator may use it. Without it, a child delegated code exploration is
    -- blind to the navigation capability the parent already has.
    allowed_tools = { "read", "read_many", "grep", "ls", "graph", "diagnose" },
    resources = {},
    limits = { max_depth = 0, timeout_seconds = 600, max_output_bytes = 65536, max_tokens = 200000 },
  },
  guest = {
    schema_version = 1,
    id = "guest",
    builtin = true,
    description = "A guest's own memory only. Cannot read files, run commands or reach the network.",
    instructions = "Answer from the memory tools only. If the answer is not stored, say so plainly; do not guess.",
    allowed_tools = { "remember", "recall", "memories", "skill", "capabilities" },
    resources = {},
    limits = { max_depth = 0, timeout_seconds = 300, max_output_bytes = 32768, max_tokens = 100000 },
  },
}

local function profile_dir()
  return paths.config() .. "/subagent-profiles"
end

local function split_list(value)
  local out = {}
  for part in tostring(value or ""):gmatch("[^,]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end

-- Read every approved profile file. A malformed or misnamed file is reported,
-- never silently ignored: a profile that does not load is a capability that
-- looks absent for no reason.
local function file_profiles()
  local out, errors = {}, {}
  local dir = profile_dir()
  if host.list_dir then
    local ok, raw = pcall(host.list_dir, dir)
    if ok and raw then
      local listed = json.decode(raw)
      for _, entry in ipairs((listed or {}).entries or {}) do
        local name = tostring(entry.name or "")
        if entry.kind == "file" and name:match("%.json$") then
          local path = dir .. "/" .. name
          local text = host.read_file and host.read_file(path)
          local decoded_ok, decoded = false, nil
          if text and text ~= "" then decoded_ok, decoded = pcall(json.decode, text) end
          local stem = name:gsub("%.json$", "")
          if not decoded_ok or type(decoded) ~= "table" then
            errors[#errors + 1] = { path = path, error = "invalid_json" }
          elseif decoded.schema_version ~= 1 then
            errors[#errors + 1] = { path = path, error = "unsupported_schema_version" }
          elseif tostring(decoded.id or "") ~= stem then
            errors[#errors + 1] = { path = path, error = "id_must_match_filename", id = tostring(decoded.id or "") }
          else
            decoded.file = path
            out[stem] = decoded
          end
        end
      end
    end
  end
  return out, errors
end

-- All profiles the caller may see: built-ins plus approved files. File profiles
-- override a built-in with the same id only when they are authorized.
function M.profiles()
  local profiles = {}
  for id, profile in pairs(BUILTIN) do profiles[id] = profile end
  local files, errors = file_profiles()
  for id, profile in pairs(files) do profiles[id] = profile end
  return profiles, errors
end

local function as_set(value)
  -- Accepts either a list of names or a name->true map, because a caller may pass
  -- a ceiling in either shape; `ipairs` alone silently emptied the map case.
  local set = {}
  if type(value) ~= "table" then return set end
  for key, entry in pairs(value) do
    if type(key) == "number" then
      set[tostring(entry)] = true
    else
      set[tostring(key)] = true
    end
  end
  return set
end

local function check_profile(profile, path)
  local problems = {}
  -- An empty `allowed_tools` is allowed: it means reasoning-only, with no tools
  -- at all. A missing table is still refused, because that is a profile that
  -- forgot the field rather than one that chose to have none.
  if type(profile.allowed_tools) ~= "table" then
    problems[#problems + 1] = "allowed_tools_required"
  else
    local seen = {}
    for _, name in ipairs(profile.allowed_tools) do
      if type(name) ~= "string" or name == "" then
        problems[#problems + 1] = "allowed_tools_must_be_strings"
      elseif seen[name] then
        problems[#problems + 1] = "duplicate_tool:" .. name
      end
      seen[name] = true
    end
  end
  if profile.limits ~= nil and type(profile.limits) ~= "table" then
    problems[#problems + 1] = "limits_must_be_an_object"
  end
  return problems
end

-- Resolve a profile for a specific caller: validate it, reject anything that
-- reaches beyond the caller's own authority, and never let a profile grant the
-- `subagent` tool (a child does not spawn children).
function M.resolve(id, ctx)
  ctx = ctx or {}
  local profiles, errors = M.profiles()
  local profile = profiles[tostring(id or "explore")]
  if not profile then
    local available = {}
    for key in pairs(profiles) do available[#available + 1] = key end
    table.sort(available)
    return nil, "unknown_profile:" .. tostring(id), { available = available }
  end
  local problems = check_profile(profile)
  if #problems > 0 then return nil, "invalid_profile:" .. table.concat(problems, ",") end

  local ceiling = ctx.ceiling
  if ceiling == nil then
    -- No server-built ceiling was supplied (a direct policy call): derive it from
    -- the role's *catalog* - what the principal may execute or delegate, which is
    -- wider than what its prompt shows. An explicitly empty ceiling is NOT re-derived
    -- - "this principal has no tools" must mean none, not the role default.
    ceiling = {}
    for _, item in ipairs(tools.catalog(ctx.role or "master")) do
      local name = item["function"] and item["function"].name
      if name then ceiling[name] = true end
    end
  end
  ceiling = as_set(ceiling)
  local allowed_list, allowed_set = {}, {}
  for _, name in ipairs(profile.allowed_tools) do
    name = tostring(name)
    if name == "subagent" then return nil, "subagent_recursion_forbidden" end
    if not ceiling[name] then return nil, "profile_exceeds_caller:" .. name end
    if BROAD[name] and profile.operator_authorized ~= true then
      return nil, "profile_not_authorized:" .. name
    end
    if not allowed_set[name] then
      allowed_set[name] = true
      allowed_list[#allowed_list + 1] = name
    end
  end

  local limits = profile.limits or {}
  local depth = tonumber(ctx.depth) or 1
  local max_depth = tonumber(host.getenv("WASM_AGENT_SUBAGENT_MAX_DEPTH")) or 1
  if depth > max_depth then return nil, "depth_exceeded" end
  if depth > 1 and (tonumber(limits.max_depth) or 0) < depth then
    return nil, "profile_depth_exceeded"
  end

  -- Pass every declared limit through so a specialist profile's own budget
  -- names (context_messages, body_bytes, sends_per_run) survive to the child;
  -- clamp only the fields this runtime owns. A malformed, negative or NaN budget
  -- on a field this runtime enforces is refused, not silently coerced.
  for _, key in ipairs({ "max_depth", "timeout_seconds", "max_output_bytes", "max_tokens",
      "max_cost_usd", "max_children", "max_prompt_bytes" }) do
    local raw_value = limits[key]
    if raw_value ~= nil and (type(raw_value) ~= "number" or raw_value ~= raw_value) then
      return nil, "invalid_limit:" .. key
    end
  end
  local resolved_limits = {}
  for key, value in pairs(limits) do resolved_limits[key] = value end
  resolved_limits.max_depth = math.min(tonumber(limits.max_depth) or 0, max_depth)
  resolved_limits.timeout_seconds = tonumber(limits.timeout_seconds) or 600
  resolved_limits.max_output_bytes = tonumber(limits.max_output_bytes) or 65536
  resolved_limits.max_tokens = tonumber(limits.max_tokens) or 200000
  resolved_limits.max_cost_usd = tonumber(limits.max_cost_usd)
  resolved_limits.max_children = tonumber(limits.max_children)
  resolved_limits.max_prompt_bytes = tonumber(limits.max_prompt_bytes) or 262144
  for _, key in ipairs({ "max_depth", "timeout_seconds", "max_output_bytes", "max_tokens",
      "max_cost_usd", "max_children", "max_prompt_bytes" }) do
    local value = resolved_limits[key]
    if value ~= nil and (type(value) ~= "number" or value ~= value or value < 0) then
      return nil, "invalid_limit:" .. key
    end
  end

  return {
    id = profile.id,
    description = profile.description or "",
    instructions = tostring(profile.instructions or ""),
    allowed_tools = allowed_list,
    allowed = allowed_set,
    resources = profile.resources or {},
    limits = resolved_limits,
    model = profile.model,
    reasoning = profile.reasoning,
    approved_models = profile.approved_models,
    operator_authorized = profile.operator_authorized == true,
    builtin = profile.builtin == true,
    file = profile.file,
  }
end

-- The caller's authorized tool names, from its catalog - authority, not prompt visibility.
-- A tool hidden from the parent's prompt is still delegable, so this must read the catalog.
local function ceiling_for(role)
  local set = {}
  for _, item in ipairs(tools.catalog(role or "master")) do
    local name = item["function"] and item["function"].name
    if name then set[name] = true end
  end
  return set
end

local function approved_model(profile, requested, caller_model)
  if not requested or requested == "" then return true, nil end
  if requested == caller_model then return true, nil end
  for _, name in ipairs(profile.approved_models or {}) do
    if name == requested then return true, nil end
  end
  for _, name in ipairs(split_list(host.getenv("WASM_AGENT_SUBAGENT_MODELS"))) do
    if name == requested then return true, nil end
  end
  return false, "model_not_approved:" .. tostring(requested)
end

local function approved_reasoning(model, requested)
  if not requested or requested == "" or requested == "provider" then return true, nil end
  local reasoning = provider.reasoning(model)
  -- A model with no reasoning levels ignores the field; an explicit level for it
  -- is a request the provider cannot honour, so it is refused rather than dropped.
  if not reasoning.supported then return false, "reasoning_not_supported:" .. tostring(requested) end
  for _, level in ipairs(reasoning.levels or {}) do
    if level == requested then return true, nil end
  end
  return false, "reasoning_not_approved:" .. tostring(requested)
end

local function derive_ctx(ctx)
  ctx = ctx or {}
  local role = tostring(ctx.role or "master")
  -- A child caller is detected by the profile snapshot the agent carries, never
  -- by anything the request said; depth therefore cannot be spoofed upward.
  local depth = 1
  if ctx.subagent then
    depth = (tonumber(ctx.subagent.depth) or 1) + 1
  end
  return {
    user_id = tostring(ctx.user_id or "master"),
    role = role,
    session_id = tostring(ctx.session_id or ""),
    run_id = tostring(ctx.run_id or ""),
    node_id = tostring(ctx.node_id or ""),
    subagent = ctx.subagent,
    depth = depth,
    ceiling = ctx.ceiling or ceiling_for(role),
    -- The caller's *actual* model/reasoning, so inheritance means the model that
    -- run is using and not merely whatever is configured globally.
    model = ctx.model,
    reasoning = ctx.reasoning,
  }
end

local function truthy_limits(profile)
  -- Copy every declared limit: the child loop enforces the generic budgets, and a
  -- specialist module (whatsapp) reads its own. A dropped field is a budget that
  -- silently does not apply.
  local limits = {}
  for key, value in pairs(profile.limits or {}) do limits[key] = value end
  return limits
end

-- Bound a caller-supplied text or table. A table is JSON-encoded (never
-- `tostring`, which yields "table: 0x..."), and both shapes are clipped inside
-- the profile's prompt budget with an explicit marker.
local function bounded_text(value, maximum)
  maximum = tonumber(maximum) or 262144
  local text
  if value == nil then
    text = ""
  elseif type(value) == "table" then
    local ok, encoded = pcall(json.encode, value)
    text = ok and encoded or "{}"
  else
    text = tostring(value)
  end
  if #text > maximum then
    local marker = "\n[truncated: input exceeded the profile's prompt budget]"
    text = text:sub(1, math.max(0, maximum - #marker)) .. marker
  end
  return text
end

-- Is this conversation in the profile's approved scope?
local function scope_has(profile, conversation_id)
  local resources = profile.resources or {}
  if type(resources.allowed_conversations) == "table" then
    for _, value in ipairs(resources.allowed_conversations) do
      if value == conversation_id then return true end
    end
  end
  if resources.conversation == conversation_id then return true end
  return resources.allowed_conversation == conversation_id
end

local function profile_is_scoped(profile)
  local resources = profile.resources or {}
  return resources.conversation ~= nil or resources.allowed_conversation ~= nil
    or type(resources.allowed_conversations) == "table"
end

-- Resolve the trusted event from the ledger: the caller may name a message id,
-- and nothing else. The conversation is read off the row, so an event cannot
-- choose its own scope, and a scoped profile refuses a message outside it. A raw
-- event field like a script, path or endpoint is ignored entirely.
local function resolve_event(profile, args)
  local requested = args.event
  local scoped = profile_is_scoped(profile)
  if type(requested) ~= "table" then
    if scoped then return nil, "event_context_required" end
    return nil, nil
  end
  local message_id = tostring(requested.message_id or "")
  if message_id == "" then
    if scoped then return nil, "event_context_required" end
    return nil, nil
  end
  local row = memory.ledger_message(message_id)
  if not row then return nil, "event_message_unknown_or_ambiguous" end
  if scoped and not scope_has(profile, row.conversation_id) then
    return nil, "event_conversation_not_in_profile"
  end
  return { conversation_id = row.conversation_id, message_id = row.message_id }, nil
end

-- Start one child. Ownership, depth and the allowed set are derived here; the
-- caller supplies only the task, an optional profile, and approved overrides.
function M.start(args, ctx)
  args = args or {}
  ctx = derive_ctx(ctx)
  if ctx.subagent then return { error = "subagent_recursion_forbidden" } end
  local raw_prompt = tostring(args.prompt or "")
  if raw_prompt == "" then return { error = "prompt_required" } end
  local profile_id = tostring(args.profile or "explore")
  local profile, refusal, detail = M.resolve(profile_id, ctx)
  if not profile then
    local out = { error = refusal }
    if detail then for key, value in pairs(detail) do out[key] = value end end
    return out
  end

  local caller_model = ctx.model
  if caller_model == nil or caller_model == "" then caller_model = provider.settings().model end
  local model = args.model
  if model == nil or model == "" then model = profile.model end
  local model_ok, model_error = approved_model(profile, model, caller_model)
  if not model_ok then return { error = model_error } end
  local effective_model = model or caller_model
  local reasoning = args.reasoning
  if reasoning == nil or reasoning == "" then reasoning = profile.reasoning end
  if reasoning == nil or reasoning == "" then reasoning = ctx.reasoning end
  local reasoning_ok, reasoning_error = approved_reasoning(effective_model, reasoning)
  if not reasoning_ok then return { error = reasoning_error } end
  local limits = truthy_limits(profile)
  -- Bound the task and its context before a child session or a native thread is
  -- created, so an oversized payload is refused rather than queued.
  local prompt = bounded_text(raw_prompt, limits.max_prompt_bytes)
  local context = bounded_text(args.context, limits.max_prompt_bytes)
  local event, event_error = resolve_event(profile, args)
  if event_error then return { error = event_error } end
  -- A dollar cap is only meaningful when the model's rates are known. Fail
  -- closed: an unpriceable model cannot promise a dollar bound.
  if limits.max_cost_usd and not provider.rates(effective_model) then
    return { error = "cost_budget_requires_rates", model = effective_model }
  end

  local idempotency = tostring(args.idempotency_key or "")
  if idempotency == "" and args.delivery_id and tostring(args.delivery_id) ~= "" then
    idempotency = "delivery:" .. tostring(args.delivery_id)
  end
  if idempotency ~= "" then
    local existing = json.decode(host.subagent("resolve", json.encode({
      owner_user = ctx.user_id, idempotency_key = idempotency })))
    if type(existing) == "table" and existing.subagent_id then
      existing.deduplicated = true
      return existing
    end
  end

  local session_id = memory.start_session(ctx.node_id, "subagent", {
    user_id = ctx.user_id,
    node_id = ctx.node_id,
    title = "subagent:" .. profile.id,
    parent_session_id = ctx.session_id,
  })
  local spec = {
    -- Generated here, never taken from the caller: the id is a path component and
    -- a caller-supplied one would be a traversal and a collision with an existing
    -- child. The acceptance contract accepts `subagent_id` as an *output* only.
    id = host.uuid(),
    session_id = session_id,
    profile = profile.id,
    prompt = prompt,
    context = context,
    instructions = profile.instructions,
    allowed_tools = profile.allowed_tools,
    limits = limits,
    model = effective_model,
    reasoning = reasoning,
    owner_user = ctx.user_id,
    parent_session_id = ctx.session_id,
    -- Derived from the authenticated context, not from the body: a caller cannot
    -- name the run a child is filed under.
    parent_run_id = ctx.run_id,
    node_id = ctx.node_id,
    role = ctx.role,
    depth = ctx.depth,
    timeout_seconds = limits.timeout_seconds,
    idempotency_key = idempotency,
    resources = profile.resources,
    event = event,
  }
  local receipt = json.decode(host.subagent("start", json.encode(spec)))
  if type(receipt) ~= "table" then return { error = "subagent_runtime_error" } end
  if receipt.error then
    -- Admission failed: close the child session we optimistically created so it
    -- does not linger as an empty open thread.
    pcall(memory.finish_session, session_id)
    return receipt
  end
  if receipt.deduplicated then
    pcall(memory.finish_session, session_id)
    return receipt
  end
  receipt.profile = profile.id
  return receipt
end

-- The single control facade. `ctx` is server-built for every caller.
function M.control(args, ctx)
  args = args or {}
  ctx = derive_ctx(ctx)
  local action = tostring(args.action or "list")
  if ctx.subagent then
    -- A child has no subagents of its own and may not inspect or control any.
    return { error = "subagent_recursion_forbidden" }
  end

  if action == "start" then return M.start(args, ctx) end
  if action == "profiles" then
    local profiles, errors = M.profiles()
    local listed = {}
    for id, profile in pairs(profiles) do
      local resolved, refusal = M.resolve(id, ctx)
      if resolved then
        listed[#listed + 1] = {
          id = resolved.id, description = resolved.description,
          allowed_tools = resolved.allowed_tools, builtin = resolved.builtin,
          operator_authorized = resolved.operator_authorized,
          limits = resolved.limits,
        }
      else
        listed[#listed + 1] = { id = id, available = false, reason = refusal }
      end
    end
    table.sort(listed, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return { profiles = listed, errors = errors or {} }
  end

  local call = { owner_user = ctx.user_id }
  -- `subagent_id`/`timeout_ms` are the agreed acceptance aliases for the same
  -- fields; a caller may use either name.
  local target = args.id or args.subagent_id
  if target then call.id = tostring(target) end
  if action == "await" then call.wait_ms = tonumber(args.wait_ms) or tonumber(args.timeout_ms) or 60000 end
  if action == "list" then
    return json.decode(host.subagent("list", json.encode({ owner_user = ctx.user_id })))
  end
  local result = json.decode(host.subagent(action, json.encode(call)))
  if type(result) ~= "table" then return { error = "subagent_runtime_error" } end
  return result
end

-- The child entrypoint. Rust calls this on a fresh interpreter, on its own
-- thread, with the durable receipt. It never comes from the model and never
-- reads the parent transcript, the operator instruction file or the parent's
-- tool set.
function wa_subagent_run(receipt_json)
  local ok, receipt = pcall(json.decode, receipt_json or "")
  if not ok or type(receipt) ~= "table" then
    return json.encode({ state = "failed", error = "invalid_receipt" })
  end
  local limits = receipt.limits or {}
  local profile = {
    id = tostring(receipt.profile or "explore"),
    allowed_tools = receipt.allowed_tools or {},
    instructions = tostring(receipt.instructions or ""),
    limits = limits,
    model = receipt.model,
    reasoning = receipt.reasoning,
    -- The resolved resource bindings (permitted conversation, action, account,
    -- destination). They are the child's trusted snapshot, resolved once at
    -- admission by an approved profile, and travel with the receipt so the child
    -- cannot be handed a different set than the one that was approved.
    resources = receipt.resources or {},
  }
  local allowed = as_set(profile.allowed_tools)
  local child_role = tostring(receipt.role or "master")
  local events = {}
  -- The approved profile is snapshotted here, immutably: a specialist tool
  -- (whatsapp) must see the resources and limits the operator approved, not a
  -- re-derived or caller-supplied subset.
  local profile_snapshot = {
    schema_version = 1,
    id = profile.id,
    allowed_tools = profile.allowed_tools,
    instructions = profile.instructions,
    resources = profile.resources,
    limits = profile.limits,
  }
  -- Durable effects and the persistent per-child send budget, bound to this
  -- child's session.
  local effects = dofile("lua/core/effects.lua").new(receipt.session_id)
  local sends = { count = effects.count(), limit = tonumber(limits.sends_per_run) or 1 }
  local child_ok, child = pcall(agentlib.new, receipt.session_id, function(event)
    -- Events stay local: a child must never write into the parent's stream.
    events[#events + 1] = event
  end, child_role, tostring(receipt.owner_user or "master"), tostring(receipt.node_id or ""), {
    subagent = {
      id = profile.id, allowed = allowed, allowed_tools = profile.allowed_tools,
      instructions = profile.instructions, limits = limits,
      model = profile.model, reasoning = profile.reasoning,
      resources = profile.resources,
      profile = profile_snapshot,
      event = receipt.event,
      effects = effects,
      sends = sends,
      depth = tonumber(receipt.depth) or 1,
    },
  })
  if not child_ok then
    return json.encode({ state = "failed", error = redact.text(tostring(child)), session_id = receipt.session_id })
  end
  local prompt = tostring(receipt.prompt or "")
  if tostring(receipt.context or "") ~= "" then
    prompt = prompt .. "\n\nContext:\n" .. tostring(receipt.context)
  end
  local ran, reply = pcall(child.run, child, prompt, {})
  if not ran then
    return json.encode({ state = "failed", error = redact.text(tostring(reply)), session_id = receipt.session_id })
  end
  reply = tostring(reply or "")
  local truncated = false
  if limits.max_output_bytes and #reply > limits.max_output_bytes then
    -- The marker counts against the cap: the stored reply must not exceed the
    -- budget it was given.
    local marker = "\n[truncated at the child's output budget]"
    reply = reply:sub(1, math.max(0, limits.max_output_bytes - #marker)) .. marker
    truncated = true
  end
  local usage = child.usage_total and child.usage_total.last or {}
  return json.encode({
    state = "completed",
    result = {
      reply = reply,
      session_id = receipt.session_id,
      usage = usage,
      truncated = truncated,
      events = #events,
    },
  })
end

-- HTTP/Lua control entrypoint for `POST /subagents` (and a GET control route).
-- The owner is resolved from the authenticated session, exactly as the model
-- tool resolves it from `ctx`; the request body can never name an owner, a
-- depth or a tool list.
function wa_subagents(body, session)
  local decoded = {}
  if body and body ~= "" then
    local ok, value = pcall(json.decode, body)
    if ok and type(value) == "table" then decoded = value end
  end
  local user = users.current(session)
  local role = user.role
  if not nodes.is_master() then role = "guest" end
  -- The conversation a child is filed under may be named in the body, but it must
  -- belong to the caller: a session link is not a way to attach a child to someone
  -- else's thread. Everything else (owner, depth, allowed tools) is derived, never
  -- read from the body.
  local parent = tostring(decoded.thread or "")
  local requested = tostring(decoded.parent_session_id or "")
  if requested ~= "" then
    local existing = memory.session(requested)
    if existing and (existing.user_id == user.id or users.is_master(role)) then parent = requested end
  end
  local ctx = {
    user_id = user.id,
    role = role,
    session_id = parent,
    run_id = decoded.parent_run_id or "",
    node_id = "",
  }
  local ok, result = pcall(M.control, decoded, ctx)
  if not ok then
    return json.encode({ error = redact.text(tostring(result)) })
  end
  return json.encode(result)
end

return M
