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
--
-- Drawing is not this file's: the page goes to `lua/core/balloon.lua` (`io.show`), which opens the
-- overlay in a terminal and prints the same page in a pipe. The numbered fallback that lived here - a
-- second way to ask the same question, with its own list layout - is gone with it.
local balloon = dofile("lua/core/balloon.lua")

local function choose(io, title, lines, options, selected)
  local page = balloon.page({ title = title, lines = lines, options = options, selected = selected or 1 })
  local answer = balloon.drive(io, { page }, { start = 1 })
  if type(answer) ~= "table" or answer.action ~= "select" then return nil end
  return tonumber(answer.index) or nil
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
