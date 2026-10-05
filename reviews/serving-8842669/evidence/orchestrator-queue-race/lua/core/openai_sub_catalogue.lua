-- The subscription route's catalogue - ours, checked in, and the only thing the runtime reads.
--
-- Why this file exists: the route's ids, windows and thinking levels used to be read from pi's
-- local store (`~/.pi/agent/models-store.json`) at every request, so the ChatGPT-subscription route
-- could not answer for a model unless a third-party package happened to be installed and happened
-- to have written that file. That is a dependency on someone else's disk layout for a fact about
-- *our* route. The facts are now here, and the path is a one-way door: nothing in `lua/` reads
-- `~/.pi` for this route any more. `M.import_from_pi()` below is the documented way to refresh
-- them, and it runs when a maintainer asks for it, never during a run.
--
-- What is published per id, and why exactly these fields:
--   * `id`            - the id sent as the Responses request's `model`.
--   * `context_window`- what the route accepts as input, so a caller can decide whether a
--                       transcript fits before spending a request on it.
--   * `max_output`    - the route's own output ceiling for that id.
--   * `reasoning`     - whether the id is a reasoning model at all, which is what decides whether
--                       `reasoning` belongs in the request body.
--   * `supports_image`- whether the id accepts image parts, which is what decides whether an image
--                       inside a tool result is sent as a part list or replaced by
--                       "(see attached image)".
--   * `thinking_levels` - level -> the value this id takes in the Responses body's
--                       `reasoning.effort`. Read per id and not route-wide because only the id can
--                       say what *it* honours.
-- The store also publishes `cost`, and `compat` flags for grammar tools and tool search. They are
-- deliberately not carried: nothing in this client uses them, and a field copied into a file we
-- own that no code reads is a claim nobody checks. `input` is carried as the one boolean above it
-- because the wire does read it.
--
-- The nil-vs-empty rule, which is load-bearing and must survive every edit here:
-- `M.thinking_level_map(id)` returns nil - never `{}` - when this catalogue cannot answer: the id
-- is not in it, or it publishes no map. "Cannot say" stays distinguishable from "no levels"; a
-- tool with no catalogue must report a route that cannot be described, not a model with no
-- reasoning. A `{}` return would be read as "this id honours no levels", which refuses every level
-- a child can be given, and a child always carries one. `lua/core/provider.lua` unions whatever is
-- returned with the route's shipped declaration for the same reason.
--
-- Entries pi published as `null` (gpt-6-astra and gpt-6.1-sol publish `off: null`) are absent here.
-- That is not a claim that the level does not exist - it is the same table the old read returned,
-- because the JSON decoder dropped the null (lua/vendor/json.lua: literal_map null=nil), and
-- provider.lua's union depends on that shape. Changing it here would silently change what that
-- union means.
--
-- Refresh path: `WA_SCRIPT=scripts/import-openai-sub-catalogue.lua <node> --db <scratch>`, with
-- `WASM_AGENT_PI_MODELS_STORE` naming the store to read (default `~/.pi/agent/models-store.json`).
-- It rewrites only the block between the two markers below and prints what it changed; the
-- reviewed diff is the point, which is why it is a script and not something a run does.
local json = dofile('lua/vendor/json.lua')
local M = {}

-- The route this catalogue answers for. The pair is what `provider.lua` uses to decide
-- servability, so an entry published for another `api` is not an entry for this route.
M.route = 'openai-codex'
M.api = 'openai-codex-responses'

-- Everything between the markers is imported, verbatim and in pi's own order.
-- BEGIN IMPORTED CATALOGUE
M.models = {
  { id = 'gpt-5.3-codex-spark', context_window = 128000, max_output = 128000, reasoning = true,
    supports_image = false,
    thinking_levels = { minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-5.5', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-5.6-luna', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { max = 'max', minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-5.6-sol', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { max = 'max', minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-5.6-terra', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { max = 'max', minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-6-astra', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { high = 'high', low = 'low', max = 'max', medium = 'medium', minimal = 'low', xhigh = 'xhigh' } },
  { id = 'gpt-6-luna', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { high = 'high', low = 'low', max = 'max', medium = 'medium', minimal = 'low', off = 'none', xhigh = 'xhigh' } },
  { id = 'gpt-6-sol', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { high = 'high', low = 'low', max = 'max', medium = 'medium', minimal = 'low', off = 'none', xhigh = 'xhigh' } },
  { id = 'gpt-6.1-sol', context_window = 272000, max_output = 128000, reasoning = true,
    supports_image = true,
    thinking_levels = { high = 'high', low = 'low', max = 'max', medium = 'medium', minimal = 'low', xhigh = 'xhigh' } },
}
-- END IMPORTED CATALOGUE

-- Authored, and deliberately not imported: the ids whose store entry publishes `off: null`.
--
-- The distinction this encodes is real and load-bearing. `"off": null` says "this id does not
-- honour the off level", while a missing `off` key says "off is passed through as `none`".
-- `lua/vendor/json.lua` decodes `null` as an absent key, so an import cannot tell those two apart -
-- which is why this list is written by hand, next to the import, instead of being derived from it.
-- Any refresh of the block above has to be compared against this list by the person reviewing it.
--
-- It matters for the request body: for these ids a ceiled level clamps to the id's own first
-- supported level (pi's `clampThinkingLevel`), and `lua/core/subscription_wire.lua` reports what
-- effort that produces. It also matters to `provider.lua`'s level offer, which has excluded
-- gpt-6-astra's `off` for exactly this reason since before this catalogue existed.
M.off_not_supported = {
  ['gpt-6-astra'] = true,
  ['gpt-6.1-sol'] = true,
}

-- Where those entries were imported from, so a stale catalogue can be recognised as one. Not read
-- by anything at request time - `M.import` is provenance, not a path this module follows.
M.import = {
  source = 'pi 0.87.1 openai-codex models-store.json (openai-codex-responses entries)',
  at = '2026-09-30',
  store = '~/.pi/agent/models-store.json',
}

local by_id = {}
for _, model in ipairs(M.models) do
  by_id[model.id] = model
end

-- The catalogue entry for `id`, or nil when it is not published here.
function M.get(id)
  return by_id[tostring(id or '')]
end

-- Every id this route publishes, in catalogue order. The *picker* list a reader chooses from is a
-- separate, shorter decision that lives in `lua/core/openai_sub.lua`; this is the route's
-- catalogue, and a caller that refuses from a picker list instead of from here is the defect
-- provider.lua documents.
function M.ids()
  local ids = {}
  for index, model in ipairs(M.models) do ids[index] = model.id end
  return ids
end

-- The thinking levels `id` is published with, or nil when this catalogue cannot answer.
-- nil, never `{}`: see the header. Not a copy - callers only read it.
function M.thinking_level_map(id)
  local model = M.get(id)
  if type(model) ~= 'table' then return nil end
  local levels = model.thinking_levels
  if type(levels) ~= 'table' then return nil end
  return levels
end

-- The windows `id` is published with, or nil when it is not published here. Two fields, because
-- two questions are asked: does the transcript fit (`context_window`) and what may the answer
-- spend (`max_output`).
function M.window(id)
  local model = M.get(id)
  if type(model) ~= 'table' then return nil end
  if type(model.context_window) ~= 'number' or type(model.max_output) ~= 'number' then return nil end
  return { context_window = model.context_window, max_output = model.max_output }
end

-- Does this route publish `id`, over the api this route speaks? true / false. Every entry here was
-- imported with `entry.api == M.api` as the filter, so membership *is* the answer; `api` is not
-- carried per entry because a second copy of it could disagree with the filter that produced it.
function M.serves(id)
  return type(M.get(id)) == 'table'
end

-- Import the store's entries for this route into a catalogue block, or nil when the file cannot be
-- read or does not parse. Read-only and one-shot: a caller (the refresh script) decides what to do
-- with the result. The import keeps pi's own order and only the fields this module documents, so
-- regenerating after a store update produces a small, reviewable diff.
function M.import_from_pi(path)
  local text = host.read_file(path)
  if not text then return nil end
  local ok, store = pcall(json.decode, text)
  if not ok or type(store) ~= 'table' then return nil end
  local profile = store[M.route]
  local models = {}
  -- ipairs, not pairs: the store's model list is an array, and the import keeps its order so
  -- regenerating an unchanged store produces no diff at all.
  for _, entry in ipairs(type(profile) == 'table' and profile.models or {}) do
    if type(entry) == 'table' and entry.id and entry.api == M.api then
      local levels = {}
      local keys = {}
      for key in pairs(type(entry.thinkingLevelMap) == 'table' and entry.thinkingLevelMap or {}) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      for _, key in ipairs(keys) do levels[key] = entry.thinkingLevelMap[key] end
      local inputs = type(entry.input) == 'table' and entry.input or {}
      local supports_image = false
      for _, part in ipairs(inputs) do
        if part == 'image' then supports_image = true end
      end
      models[#models + 1] = {
        id = entry.id,
        context_window = tonumber(entry.contextWindow),
        max_output = tonumber(entry.maxTokens),
        reasoning = entry.reasoning == true,
        supports_image = supports_image,
        thinking_levels = levels,
      }
    end
  end
  return { models = models, source = path, count = #models }
end

-- Render a catalogue block exactly as the imported section above is written, so the refresh script
-- rewrites the file instead of reflowing it.
function M.render(models)
  local out = {'M.models = {'}
  local function quote(value)
    return "'" .. tostring(value):gsub("'", "\\'") .. "'"
  end
  for _, model in ipairs(models) do
    local levels = {}
    for key, value in pairs(model.thinking_levels or {}) do
      levels[#levels + 1] = { key, value }
    end
    table.sort(levels, function(left, right) return left[1] < right[1] end)
    local rendered = {}
    for _, pair in ipairs(levels) do
      rendered[#rendered + 1] = string.format('%s = %s', pair[1], quote(pair[2]))
    end
    out[#out + 1] = string.format(
      "  { id = %s, context_window = %d, max_output = %d, reasoning = %s,\n" ..
      "    supports_image = %s,\n    thinking_levels = { %s } },",
      quote(model.id), model.context_window or 0, model.max_output or 0,
      tostring(model.reasoning == true), tostring(model.supports_image == true),
      table.concat(rendered, ', '))
  end
  out[#out + 1] = '}'
  return table.concat(out, '\n')
end

return M
