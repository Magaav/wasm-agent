-- Spells v2: deterministic, *verified* macros.
--
-- A spell is a parameterised sequence of client actions with declared
-- preconditions and — mandatorily — postconditions. The postconditions are the
-- effect settlement: a spell does not report success unless the goal state is
-- observed afterwards. This is the architectural answer to the v8 failure mode
-- where a repair "succeeded" while doing nothing.
--
-- Contract (enforced by M.validate):
--   * every spell has at least one `post` assertion;
--   * steps are addressed by parameters, not baked-in literals where avoidable;
--   * retries are only allowed on steps explicitly marked `idempotent`;
--   * the first failing step or assertion stops the run with a typed error and
--     a trace — nothing continues blindly.
--
-- Step kinds:
--   { kind="client", action="cdp"|"click"|"type"|"key"|"shell"|"move", ..., idempotent=true? }
--   { kind="wait",   ms=500 }
--   { kind="assert", script="...", equals=|contains=|matches=|gt=|lt=|truthy= }
--   { kind="sentinel", verb="wait-idle"|"upgrade"|"restart"|"wait-health", binary=?, ... }
--
-- The `sentinel` kind is the one step this process cannot perform itself, and it exists because some
-- plans are about *this node*: an upgrade stops the worker, so a turn running on that worker cannot
-- survive its own plan and its `post` assertions never run. Such a step therefore does not execute
-- here - it declares what the sentinel should do, and `M.export` writes the plan for `wa-sentinel
-- request spell --file ...`, which runs it outside the node and settles the effect from there.
--
-- A sentinel step inside a normal `M.run` is refused rather than skipped: silently ignoring it would
-- report success for a plan whose point never happened.
--
-- Assertions also gate preconditions (`pre`) and postconditions (`post`).
-- Strings support {{param}} substitution.
local json = dofile("lua/vendor/json.lua")
local M = {}

local state = dofile("lua/core/state.lua")

local function path()
  return state.path("spells.json")
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function load()
  local text = state.read("spells.json")
  if text and text ~= "" then
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.spells) == "table" then
      return decoded
    end
  end
  return { spells = {} }
end

local function store(data)
  if host.write_file then host.write_file(path(), json.encode(data)) end
end

-- ---- parameter substitution ---------------------------------------------
local function substitute(value, params)
  if type(value) == "string" then
    return (value:gsub("{{([%w_]+)}}", function(key)
      local resolved = params[key]
      if resolved == nil then return "{{" .. key .. "}}" end
      return tostring(resolved)
    end))
  end
  if type(value) == "table" then
    local out = {}
    for key, item in pairs(value) do out[key] = substitute(item, params) end
    return out
  end
  return value
end

local function resolve_params(spec, provided)
  local params = {}
  for name, definition in pairs(spec or {}) do
    local value = (provided and provided[name] ~= nil) and provided[name] or definition.default
    if value == nil then return nil, "missing_param:" .. name end
    local kind = definition.type or "string"
    if kind == "number" then
      value = tonumber(value)
      if value == nil then return nil, "bad_param:" .. name end
    elseif kind == "boolean" then
      value = value and true or false
    else
      value = tostring(value)
    end
    params[name] = value
  end
  for name in pairs(provided or {}) do
    if not (spec and spec[name]) then return nil, "unknown_param:" .. name end
  end
  return params
end

-- ---- observation ---------------------------------------------------------
local function client_action(action, args)
  local ok, raw = pcall(host.client, action or "", json.encode(args))
  if not ok then return nil, tostring(raw) end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return nil, tostring(raw) end
  return decoded
end

local function observe(script)
  local decoded, failure = client_action("cdp", {
    action = "cdp", target = "evaluate", script = script,
  })
  if not decoded then return nil, "evaluate_failed: " .. tostring(failure) end
  if decoded.error then return nil, tostring(decoded.error) end
  return decoded.value and decoded.value.value
end

local function check_assertion(check)
  local value, error = observe(check.script)
  if error then return false, error, value end
  local text = value == nil and "" or tostring(value)
  local ok = true
  if check.equals ~= nil then ok = ok and text == tostring(check.equals) end
  if check.not_equals ~= nil then ok = ok and text ~= tostring(check.not_equals) end
  if check.contains ~= nil then ok = ok and text:find(tostring(check.contains), 1, true) ~= nil end
  if check.matches ~= nil then ok = ok and text:match(check.matches) ~= nil end
  if check.truthy ~= nil then ok = ok and (value and true or false) == check.truthy end
  if check.gt ~= nil then ok = ok and (tonumber(value) or -math.huge) > tonumber(check.gt) end
  if check.lt ~= nil then ok = ok and (tonumber(value) or math.huge) < tonumber(check.lt) end
  return ok, nil, value
end

-- ---- validation ----------------------------------------------------------
-- The verbs a `sentinel` step may name. Mirrors ALLOWED_STEPS in rust/wa-sentinel/src/spell.rs,
-- and that duplication is deliberate-but-checked: the sentinel refuses anything not in *its* list, so
-- a verb added here alone fails loudly at the sentinel with the list printed, rather than silently
-- doing nothing. A spell chooses which step, never how it runs - `run` is absent on purpose, because
-- a plan that could reach it would be a shell.
local SENTINEL_VERBS = { ["wait-idle"] = true, ["upgrade"] = true, ["restart"] = true, ["wait-health"] = true }

-- A `run` step: the node-side deterministic step a skill needs for the part that never required a
-- model. Its outcome contract is the one the `run` job action already uses - exit 0 *and* a JSON
-- object on stdout - so the system has one outcome shape rather than two.
--
-- `expect` compares named fields of that object. A mismatch is a failed step, never a warning: a step
-- that reports success while the world says otherwise is the failure this module exists to prevent.
-- Exported as `M.run_step` so it can be tested without a browser and without running a command.
--
-- It cannot reach the sentinel: `M.export` refuses any step whose kind is not `sentinel`, and
-- `rust/wa-sentinel/src/spell.rs` refuses a plan containing one. A `run` step executes in the node's
-- worker, where a turn is already running - never in the process that can restart this node.
function M.run_step(step)
  local command = tostring(step.script or "")
  if command == "" then return false, "run_step_script_required" end
  local started_ok, raw = pcall(host.exec, command, "")
  if not started_ok then return false, "run_step_exec_failed" end
  local decoded_ok, wrapper = pcall(json.decode, raw or "")
  if not decoded_ok or type(wrapper) ~= "table" then return false, "run_step_unreadable_result" end
  if (tonumber(wrapper.code) or 1) ~= 0 then
    return false, "run_step_exit_" .. tostring(wrapper.code)
  end
  local result_ok, result = pcall(json.decode, wrapper.stdout or "")
  if not result_ok or type(result) ~= "table" then return false, "run_step_stdout_not_json" end
  -- An *object* is the contract: `expect` names fields, and an array has none. The decoder maps both
  -- to a Lua table, so a numeric key is what tells them apart.
  for key in pairs(result) do
    if type(key) == "number" then return false, "run_step_stdout_not_json" end
  end
  for field, expected in pairs(step.expect or {}) do
    local actual = result[field]
    if actual ~= expected then
      return false, "run_step_expect_" .. tostring(field) .. ": " .. json.encode(actual)
        .. " ~= " .. json.encode(expected)
    end
  end
  return true, nil, result
end

function M.validate(spec)
  if type(spec) ~= "table" then return "spec_required" end
  if trim(spec.name) == "" then return "name_required" end
  if type(spec.steps) ~= "table" or #spec.steps == 0 then return "steps_required" end
  if type(spec.post) ~= "table" or #spec.post == 0 then
    return "post_required: a spell must settle its effect with at least one assertion"
  end
  for index, step in ipairs(spec.steps) do
    local kind = step.kind or "client"
    if kind == "client" and (type(step.action) ~= "string" or step.action == "") then
      return "step_" .. index .. "_action_required"
    end
    if kind == "wait" and tonumber(step.ms) == nil then
      return "step_" .. index .. "_ms_required"
    end
    if kind == "assert" and type(step.script) ~= "string" then
      return "step_" .. index .. "_script_required"
    end
    if kind == "run" then
      -- A deterministic node-side step: a command whose outcome is exit 0 *and* a JSON object on
      -- stdout - the contract the `run` job action already has, so one outcome shape rather than two.
      if type(step.script) ~= "string" or step.script == "" then
        return "step_" .. index .. "_script_required"
      end
      if step.expect ~= nil and type(step.expect) ~= "table" then
        return "step_" .. index .. "_expect_must_be_a_table"
      end
    end
    if kind == "sentinel" then
      if type(step.verb) ~= "string" or not SENTINEL_VERBS[step.verb] then
        return "step_" .. index .. "_sentinel_verb_unknown"
      end
      if step.verb == "upgrade" and (type(step.binary) ~= "string" or step.binary == "") then
        return "step_" .. index .. "_sentinel_upgrade_needs_binary"
      end
    end
    if (tonumber(step.retries) or 0) > 0 and kind ~= "assert" and step.idempotent ~= true then
      return "step_" .. index .. "_retries_require_idempotent"
    end
  end
  for index, check in ipairs(spec.post) do
    if type(check.script) ~= "string" then return "post_" .. index .. "_script_required" end
  end
  return nil
end

-- True if this spell contains a step only the sentinel can perform.
function M.needs_sentinel(spec)
  for _, step in ipairs((spec and spec.steps) or {}) do
    if (step.kind or "client") == "sentinel" then return true end
  end
  return false
end

-- The portable plan: the resolved, literal steps the sentinel executes, with no model and no node
-- involved. This is the artifact `wa-sentinel request spell --file` consumes.
--
-- `post` travels as *declarations* rather than being resolved here, because the sentinel settles the
-- effect with its own tools (it checks /health itself), not with CDP. The declaration is kept so the
-- file states its own success condition, which is what makes it reviewable before it runs.
--
-- Returns the plan or nil and a reason. It refuses an empty result: exporting a plan with nothing to
-- do would produce a file that always "succeeds".
function M.export(name, params, binary)
  local spell = M.get(name)
  if not spell then return nil, "unknown_spell:" .. tostring(name) end
  local problem = M.validate(spell)
  if problem then return nil, "invalid_spell:" .. problem end
  -- The `binary` argument fills the `binary` parameter. It is supplied at export time because the
  -- build to install is a fact about *now*, not about the spell: the same plan is exported again for
  -- the next build. Merging it here (rather than requiring the caller to pass it twice, once as a
  -- param and once as an argument) is what lets `spell_export` be called with only a name and a path.
  local effective = {}
  for key, value in pairs(params or {}) do effective[key] = value end
  if binary and binary ~= "" and effective.binary == nil then effective.binary = binary end
  local resolved, param_error = resolve_params(spell.params, effective)
  if not resolved then return nil, param_error end

  local steps = {}
  for _, raw in ipairs(spell.steps) do
    local step = substitute(raw, resolved)
    local kind = step.kind or "client"
    if kind ~= "sentinel" then
      -- Refused rather than dropped: a plan that quietly omitted the client steps would look
      -- complete and do less than the spell says.
      return nil, "step_kind_not_exportable:" .. kind .. ": a sentinel plan may only contain `sentinel` steps"
    end
    local entry = { kind = "sentinel", verb = step.verb }
    -- The binary can be passed at export time, so the spell carries a placeholder and the caller
    -- supplies the actual build to install.
    if step.verb == "upgrade" then
      local chosen = binary
      if not chosen or chosen == "" then chosen = step.binary end
      if not chosen or chosen == "" then return nil, "upgrade_step_needs_binary" end
      entry.binary = chosen
    end
    steps[#steps + 1] = entry
  end

  return {
    name = spell.name,
    description = spell.description or "",
    version = spell.version or 1,
    exported_at = host.now(),
    params = resolved,
    steps = steps,
    -- Kept verbatim, and non-empty by M.validate: a plan without a stated success condition is the
    -- v8 failure mode in file form.
    post = spell.post,
  }
end

-- ---- store ---------------------------------------------------------------
function M.list()
  local out = {}
  for _, spell in ipairs(load().spells) do
    out[#out + 1] = {
      name = spell.name,
      description = spell.description or "",
      version = spell.version or 1,
      steps = #(spell.steps or {}),
      post = #(spell.post or {}),
      params = spell.params or {},
    }
  end
  return { spells = out }
end

function M.get(name)
  for _, spell in ipairs(load().spells) do
    if spell.name == name then return spell end
  end
  return nil
end

function M.save(spec)
  local problem = M.validate(spec)
  if problem then return { error = problem } end
  local data = load()
  local version = 1
  for _, existing in ipairs(data.spells) do
    if existing.name == spec.name then version = (tonumber(existing.version) or 1) + 1 end
  end
  local entry = {
    name = trim(spec.name),
    description = spec.description or "",
    version = version,
    target = spec.target or { node = "client" },
    params = spec.params or {},
    pre = spec.pre or {},
    steps = spec.steps,
    post = spec.post,
    created_at = host.now(),
  }
  local replaced = false
  for index, existing in ipairs(data.spells) do
    if existing.name == entry.name then
      data.spells[index] = entry
      replaced = true
    end
  end
  if not replaced then data.spells[#data.spells + 1] = entry end
  store(data)
  return { ok = true, name = entry.name, version = version, steps = #entry.steps, post = #entry.post }
end

function M.remove(name)
  local data = load()
  local kept, removed = {}, false
  for _, spell in ipairs(data.spells) do
    if spell.name == name then removed = true else kept[#kept + 1] = spell end
  end
  data.spells = kept
  store(data)
  return { ok = removed, name = name }
end

-- Validate without executing (dry run): shape + parameter resolution.
function M.validate_run(name, params)
  local spell = M.get(name)
  if not spell then return { error = "unknown_spell:" .. tostring(name) } end
  local resolved, problem = resolve_params(spell.params, params)
  if not resolved then return { error = problem } end
  return { ok = true, spell = name, version = spell.version, params = resolved, steps = #spell.steps }
end

-- Write the plan to disk and hand back the path, which is the whole artifact: one file, one
-- command, no model. The directory is created rather than assumed, because a spell that cannot be
-- exported is a step the agent cannot ask the sentinel to perform - and the failure has to be the
-- export saying so, not the sentinel finding no file.
function M.export_to_file(name, params, binary, path)
  local plan, problem = M.export(name, params, binary)
  if not plan then return { error = problem } end

  local target = path
  if not target or target == "" then
    target = state.path("spell-plans") .. "/" .. trim(name) .. ".json"
  end
  -- `host.write_file` creates the parent directory itself, so a plan can be written to a path whose
  -- directory does not exist yet. Nothing is created here first: the write is the thing that must
  -- say whether it worked, and a spell that cannot be exported is a step the agent cannot ask the
  -- sentinel to perform - so the failure has to be the export saying so, not the sentinel finding no
  -- file later.
  target = target:gsub("\\", "/")
  if not host.write_file then return { error = "write_unavailable" } end
  -- `host.write_file` creates the parent directory itself, so there is nothing to make first - and a
  -- `host.mkdir` call here would be a call to a function that does not exist.
  local wrote = host.write_file(target, json.encode(plan))
  if wrote ~= true then return { error = "write_failed:" .. target } end

  -- Read what was written back, by *path* rather than through `state.read` (which prefixes the state
  -- directory and would look for the name inside it). A plan that cannot be re-read is not a plan,
  -- and the sentinel would discover that at a worse moment - when the node is already expected to be
  -- replaced.
  local readback = host.read_file and host.read_file(target) or nil
  if not readback or readback == "" then return { error = "export_unreadable:" .. target } end
  local decoded_ok = pcall(json.decode, readback)
  if not decoded_ok then return { error = "export_not_json:" .. target } end

  return {
    ok = true, spell = plan.name, version = plan.version,
    path = target, steps = #plan.steps, post = #plan.post,
    command = "wa-sentinel request spell --file " .. target .. ' --reason "..."',
  }
end

-- ---- execution -----------------------------------------------------------
function M.run(name, params)
  local spell = M.get(name)
  if not spell then return { error = "unknown_spell:" .. tostring(name) } end
  local problem = M.validate(spell)
  if problem then return { error = "invalid_spell:" .. problem } end
  -- A sentinel step cannot run here, and skipping it would report success for a plan whose point
  -- never happened. Say which one and how to run it instead.
  if M.needs_sentinel(spell) then
    return {
      error = "needs_sentinel",
      detail = "this spell has a step only the sentinel can perform (it restarts or replaces this node, "
        .. "so a turn running on it cannot survive the plan or check its own postconditions). "
        .. "Export it and ask the sentinel: spell_export, then wa-sentinel request spell --file <path>.",
      spell = name,
    }
  end
  local resolved, param_error = resolve_params(spell.params, params)
  if not resolved then return { error = param_error } end

  local trace = {}
  local started = host.now()
  local function fail(kind, index, detail)
    return {
      error = kind, step = index, detail = detail, trace = trace,
      spell = name, version = spell.version, params = resolved,
    }
  end

  for index, check in ipairs(spell.pre or {}) do
    local resolved_check = substitute(check, resolved)
    local ok, error, value = check_assertion(resolved_check)
    trace[#trace + 1] = { phase = "pre", index = index, ok = ok, value = value, error = error }
    if not ok then return fail("precondition_failed", index, error or value) end
  end

  for index, raw in ipairs(spell.steps) do
    local step = substitute(raw, resolved)
    local kind = step.kind or "client"
    local retries = tonumber(step.retries) or 0
    local attempt, ok, detail = 0, false, nil
    repeat
      attempt = attempt + 1
      local step_started = host.now()
      if kind == "wait" then
        host.sleep(tonumber(step.ms) or 250)
        ok, detail = true, nil
      elseif kind == "run" then
        local passed, failure = M.run_step(step)
        ok, detail = passed, failure
      elseif kind == "assert" then
        local passed, error, value = check_assertion(step)
        ok, detail = passed, error or value
      else
        local args = {}
        for key, value in pairs(step) do
          if key ~= "kind" and key ~= "retries" and key ~= "retry_ms" and key ~= "idempotent" then
            args[key] = value
          end
        end
        local decoded, failure = client_action(step.action, args)
        ok = decoded ~= nil and decoded.error == nil
        detail = (decoded and decoded.error) or failure
      end
      trace[#trace + 1] = {
        phase = "step", index = index, kind = kind, attempt = attempt, ok = ok,
        ms = math.floor((host.now() - step_started) * 1000), detail = detail,
      }
      if not ok and attempt <= retries then host.sleep(tonumber(step.retry_ms) or 300) end
    until ok or attempt > retries
    if not ok then return fail("step_failed", index, detail) end
  end

  -- Effect settlement: the spell only succeeds if the goal state is observed.
  for index, check in ipairs(spell.post or {}) do
    local resolved_check = substitute(check, resolved)
    local ok, error, value = check_assertion(resolved_check)
    trace[#trace + 1] = { phase = "post", index = index, ok = ok, value = value, error = error }
    if not ok then return fail("postcondition_failed", index, error or value) end
  end

  return {
    ok = true, spell = name, version = spell.version, params = resolved,
    settled = true, ms = math.floor((host.now() - started) * 1000), trace = trace,
  }
end

return M
