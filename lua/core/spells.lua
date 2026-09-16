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
--
-- Assertions also gate preconditions (`pre`) and postconditions (`post`).
-- Strings support {{param}} substitution.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function path()
  return (os.getenv("HOME") or ".") .. "/.wasm-agent/spells.json"
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function load()
  local text = host.read_file and host.read_file(path())
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
    if (tonumber(step.retries) or 0) > 0 and kind ~= "assert" and step.idempotent ~= true then
      return "step_" .. index .. "_retries_require_idempotent"
    end
  end
  for index, check in ipairs(spec.post) do
    if type(check.script) ~= "string" then return "post_" .. index .. "_script_required" end
  end
  return nil
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

-- ---- execution -----------------------------------------------------------
function M.run(name, params)
  local spell = M.get(name)
  if not spell then return { error = "unknown_spell:" .. tostring(name) } end
  local problem = M.validate(spell)
  if problem then return { error = "invalid_spell:" .. problem } end
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
