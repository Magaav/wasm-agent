-- Spells: crystallize inferred actions into deterministic, replayable macros.
--
-- A spell is an ordered list of client actions (CDP, input, shell, ...) plus
-- waits and assertions. The agent can record one after working a task out, and
-- replay it later without the model in the loop.
--
-- Step shapes:
--   { kind = "client", action = "cdp", target = "evaluate", script = "..." }
--   { kind = "client", action = "click", x = 10, y = 20 }
--   { kind = "wait",   ms = 500 }
--   { kind = "assert", script = "document.title", equals = "Inbox" }
--
-- Stored at ~/.wasm-agent/spells.json.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function path()
  return (os.getenv("HOME") or ".") .. "/.wasm-agent/spells.json"
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

function M.list()
  local out = {}
  for _, spell in ipairs(load().spells) do
    out[#out + 1] = {
      name = spell.name,
      description = spell.description or "",
      steps = #(spell.steps or {}),
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

function M.save(name, description, steps)
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return { error = "name_required" } end
  if type(steps) ~= "table" or #steps == 0 then return { error = "steps_required" } end
  local data = load()
  local entry = { name = name, description = description or "", steps = steps, saved_at = host.now() }
  local replaced = false
  for index, spell in ipairs(data.spells) do
    if spell.name == name then
      data.spells[index] = entry
      replaced = true
    end
  end
  if not replaced then data.spells[#data.spells + 1] = entry end
  store(data)
  return { ok = true, name = name, steps = #steps, replaced = replaced }
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

local function client_action(action, args)
  local ok, raw = pcall(host.client, action or "", json.encode(args))
  if not ok then return nil, tostring(raw) end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return nil, tostring(raw) end
  return decoded
end

-- Replay a spell step by step. Stops at the first failure.
function M.run(name)
  local spell = M.get(name)
  if not spell then return { error = "unknown_spell:" .. tostring(name) } end
  local trace = {}
  for index, step in ipairs(spell.steps) do
    local kind = step.kind or "client"
    if kind == "wait" then
      host.sleep(tonumber(step.ms) or 250)
      trace[#trace + 1] = { step = index, kind = "wait", ms = step.ms }
    elseif kind == "assert" then
      local decoded = client_action("cdp", { action = "cdp", target = "evaluate", script = step.script })
      local value = decoded and decoded.value and decoded.value.value
      if step.equals ~= nil and tostring(value) ~= tostring(step.equals) then
        return { error = "assert_failed", step = index, expected = step.equals, actual = value, trace = trace }
      end
      trace[#trace + 1] = { step = index, kind = "assert", value = value }
    else
      local args = {}
      for key, value in pairs(step) do
        if key ~= "kind" then args[key] = value end
      end
      local decoded, failure = client_action(step.action, args)
      if not decoded or decoded.error then
        return { error = "step_failed", step = index, detail = decoded or failure, trace = trace }
      end
      trace[#trace + 1] = { step = index, kind = "client", action = step.action }
    end
  end
  return { ok = true, spell = name, steps = #spell.steps, trace = trace }
end

return M
