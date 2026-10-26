-- `/model` and `/reasoning` (alias `/thinking`) in `wa chat`: pick from what the active provider
-- serves and what the model supports, as a panel (Esc goes back) or, without a raw editor, as a
-- numbered question. A change applies from the next turn: a run pins its model at start.
--
-- `io`: print(text), ask(question) -> line|nil, panel(spec) -> result (optional), paint(text, role).
local provider = dofile("lua/core/provider.lua")
local state = dofile("lua/core/state.lua")
local M = {}

local DOT = "\226\143\186"
local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function paint(io, text, role) return io.paint and io.paint(text, role) or text end
local function said(io, ok, text) io.print(paint(io, DOT, ok and "success" or "error") .. " " .. text) end

-- One choice from `options` ({label, hint}): a 1-based index, or nil when the reader backs out.
local function choose(io, title, lines, options, selected)
  if io.panel then
    local answer = io.panel({ title = title, lines = lines, options = options, selected = selected })
    return answer.action == "select" and answer.index or nil
  end
  io.print(title)
  for _, line in ipairs(lines) do io.print(line) end
  for n, option in ipairs(options) do
    io.print(string.format("%d. %s%s", n, option.label, option.hint ~= "" and ("  " .. option.hint) or ""))
  end
  local answer = tonumber(trim(io.ask("Choose 1-" .. #options .. " (Enter to cancel):")))
  return answer and options[answer] and answer or nil
end

function M.model(io)
  local settings = provider.settings()
  local models = provider.list_models()
  if type(models) ~= "table" or #models == 0 then said(io, false, "This provider lists no models."); return false end
  local options, selected = {}, 1
  for n, name in ipairs(models) do
    local current = name == settings.model
    options[#options + 1] = { label = tostring(name), hint = current and "current" or "" }
    if current then selected = n end
  end
  local index = choose(io, "Select model", { "Provider: " .. tostring(settings.label or settings.provider),
    "Applies from the next turn." }, options, selected)
  if not index then return false end
  local name = models[index]
  if name == settings.model then said(io, true, "Model unchanged: " .. name); return true end
  local ok, problem = provider.set_model(name, state.revision())
  said(io, ok, ok and ("Model set to " .. name) or ("Could not set the model: " .. tostring(problem)))
  return ok
end

function M.reasoning(io)
  local model = provider.settings().model
  local info = provider.reasoning(model)
  if not info.supported then said(io, false, tostring(model) .. " has no reasoning levels to choose from."); return false end
  local options, selected = {}, 1
  for n, level in ipairs(info.levels) do
    local current = level == info.selected
    options[#options + 1] = { label = level, hint = current and "current" or "" }
    if current then selected = n end
  end
  local index = choose(io, "Reasoning", { "Model: " .. tostring(model), "How much the model thinks before it answers; applies from the next turn." },
    options, selected)
  if not index then return false end
  local level = info.levels[index]
  if level == info.selected then said(io, true, "Reasoning unchanged: " .. level); return true end
  local ok, problem = provider.set_reasoning(level, state.revision())
  said(io, ok, ok and ("Reasoning set to " .. level) or ("Could not set reasoning: " .. tostring(problem)))
  return ok
end

return M
