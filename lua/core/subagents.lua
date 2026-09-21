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
    description = "Read-only investigation: search, read and diagnose. Cannot write or run a shell.",
    instructions = "Investigate the task read-only and report what you found with exact file paths and line references. Do not modify anything.",
    allowed_tools = { "read", "read_many", "grep", "ls", "diagnose" },
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

local function as_set(list)
  local set = {}
  for _, name in ipairs(list or {}) do set[tostring(name)] = true end
  return set
end

local function check_profile(profile, path)
  local problems = {}
  if type(profile.allowed_tools) ~= "table" or #profile.allowed_tools == 0 then
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

  local ceiling = as_set(ctx.ceiling or {})
  if next(ceiling) == nil then
    -- No server-built ceiling was supplied (a direct policy call): derive it from
    -- the role's own schema list rather than trusting a caller to narrow itself.
    for _, item in ipairs(tools.all(ctx.role or "master")) do
      local name = item["function"] and item["function"].name
      if name then ceiling[name] = true end
    end
  end
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

  return {
    id = profile.id,
    description = profile.description or "",
    instructions = tostring(profile.instructions or ""),
    allowed_tools = allowed_list,
    allowed = allowed_set,
    resources = profile.resources or {},
    limits = {
      max_depth = math.min(tonumber(limits.max_depth) or 0, max_depth),
      timeout_seconds = tonumber(limits.timeout_seconds) or 600,
      max_output_bytes = tonumber(limits.max_output_bytes) or 65536,
      max_tokens = tonumber(limits.max_tokens) or 200000,
      max_cost_usd = tonumber(limits.max_cost_usd),
      max_children = tonumber(limits.max_children),
    },
    model = profile.model,
    reasoning = profile.reasoning,
    approved_models = profile.approved_models,
    operator_authorized = profile.operator_authorized == true,
    builtin = profile.builtin == true,
    file = profile.file,
  }
end

-- The caller's authorized tool names, from the same schema list they run with.
local function ceiling_for(role)
  local set = {}
  for _, item in ipairs(tools.all(role or "master")) do
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
  if not requested or requested == "" then return true, nil end
  local reasoning = provider.reasoning(model)
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
  }
end

local function truthy_limits(profile)
  local limits = profile.limits or {}
  return {
    max_depth = limits.max_depth,
    timeout_seconds = limits.timeout_seconds,
    max_output_bytes = limits.max_output_bytes,
    max_tokens = limits.max_tokens,
    max_cost_usd = limits.max_cost_usd,
    max_children = limits.max_children,
  }
end

-- Start one child. Ownership, depth and the allowed set are derived here; the
-- caller supplies only the task, an optional profile, and approved overrides.
function M.start(args, ctx)
  args = args or {}
  ctx = derive_ctx(ctx)
  if ctx.subagent then return { error = "subagent_recursion_forbidden" } end
  local prompt = tostring(args.prompt or "")
  if prompt == "" then return { error = "prompt_required" } end
  local profile_id = tostring(args.profile or "explore")
  local profile, refusal, detail = M.resolve(profile_id, ctx)
  if not profile then
    local out = { error = refusal }
    if detail then for key, value in pairs(detail) do out[key] = value end end
    return out
  end

  local caller_model = provider.settings().model
  local model = args.model
  if model == nil or model == "" then model = profile.model end
  local model_ok, model_error = approved_model(profile, model, caller_model)
  if not model_ok then return { error = model_error } end
  local effective_model = model or caller_model
  local reasoning = args.reasoning
  if reasoning == nil or reasoning == "" then reasoning = profile.reasoning end
  local reasoning_ok, reasoning_error = approved_reasoning(effective_model, reasoning)
  if not reasoning_ok then return { error = reasoning_error } end
  local limits = truthy_limits(profile)
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
    id = tostring(args.id or host.uuid()),
    session_id = session_id,
    profile = profile.id,
    prompt = prompt,
    context = tostring(args.context or ""),
    instructions = profile.instructions,
    allowed_tools = profile.allowed_tools,
    limits = limits,
    model = model,
    reasoning = reasoning,
    owner_user = ctx.user_id,
    parent_session_id = ctx.session_id,
    parent_run_id = tostring(args.parent_run_id or ctx.run_id),
    node_id = ctx.node_id,
    role = ctx.role,
    depth = ctx.depth,
    timeout_seconds = limits.timeout_seconds,
    idempotency_key = idempotency,
    resources = profile.resources,
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
  if args.id then call.id = tostring(args.id) end
  if action == "await" then call.wait_ms = tonumber(args.wait_ms) or 60000 end
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
  }
  local allowed = as_set(profile.allowed_tools)
  local child_role = tostring(receipt.role or "master")
  local events = {}
  local child_ok, child = pcall(agentlib.new, receipt.session_id, function(event)
    -- Events stay local: a child must never write into the parent's stream.
    events[#events + 1] = event
  end, child_role, tostring(receipt.owner_user or "master"), tostring(receipt.node_id or ""), {
    subagent = {
      id = profile.id, allowed = allowed, allowed_tools = profile.allowed_tools,
      instructions = profile.instructions, limits = limits,
      model = profile.model, reasoning = profile.reasoning,
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
    reply = reply:sub(1, limits.max_output_bytes) .. "\n[truncated at the child's output budget]"
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
