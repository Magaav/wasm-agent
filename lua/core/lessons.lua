-- Lessons: what this fleet learned the hard way, kept so a later session does not repeat it.
--
-- The store is with the node's own state (`state.read`/`state.write`, key `lessons`), so it survives
-- a restart, and it is **on demand only**: nothing here is injected into a session's instructions,
-- its notes or its context. The model asks (`lessons` tool, action `recall` or `list`) when the
-- fleetops skill tells it to, and adds to it with one call (`action = "add"`). The hard rule that
-- decided this (docs/FLEET-OPS.md): fresh agents get no cross-session long-term notes at session
-- start; memory is looked up, never pushed.
--
-- Shape of one lesson - the four fields are the whole point, because a lesson without a rule is an
-- anecdote and one without a cause cannot be recognised again:
--
--   { id, at, symptom, cause, fix, rule, tags = {...}, source }
--
-- `cause` and `fix` may be "unknown" (a half-understood incident still teaches its rule); `symptom`
-- and `rule` may not - both are refused instead of stored empty, so a recall can never answer with a
-- lesson that says nothing.
--
-- The shipped seeds live with the skill that explains them (`skills/fleetops/incidents.json`), not
-- in this file: the skill is what an operator reads, and a seed that diverged from it would be two
-- stories about one incident. `M.ensure()` loads a seed once, by id, and never overwrites an entry
-- the model or the operator has since edited.
local json = dofile('lua/vendor/json.lua')
local state = dofile('lua/core/state.lua')
local skills = dofile('lua/core/skills.lua')

local M = {}

M.VERSION = 1
M.KEY = 'lessons'
-- Bounded: a lesson is a paragraph, not a transcript, and the store is read whole on every recall.
M.MAX_ENTRIES = 200
M.MAX_FIELD = 2000
-- The searches that find something without a match are refused rather than answered with everything:
-- "no lesson matched these words" is a usable answer, an unfiltered dump is not.
M.MAX_RESULTS = 20

local function clean(text, limit)
  if type(text) ~= 'string' then return nil end
  local value = text:gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' then return nil end
  if limit and #value > limit then value = value:sub(1, limit) .. '…' end
  return value
end

local function decode(text)
  if type(text) ~= 'string' or text == '' then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= 'table' then return nil end
  return value
end

-- Everything stored, plus the shipped seeds that are not stored yet. A corrupt store is *named*,
-- never replaced by an empty one in silence: the caller is told `store_corrupt` and gets the seeds,
-- because claiming "no lessons" over a broken file is exactly the silent data loss this repo refuses.
local loaded = nil
local function load()
  if loaded then return loaded end
  local raw = state.read(M.KEY)
  local list, problem = {}, nil
  if type(raw) == 'string' and raw ~= '' then
    local decoded = decode(raw)
    if decoded and type(decoded.entries) == 'table' then
      for _, entry in ipairs(decoded.entries) do
        if type(entry) == 'table' and clean(entry.id) and clean(entry.rule) then list[#list + 1] = entry end
      end
      problem = decoded.error
    else
      problem = 'store_corrupt'
    end
  end
  loaded = { entries = list, problem = problem }
  return loaded
end

local function save(list)
  local ok = state.write(M.KEY, json.encode({ version = M.VERSION, entries = list }))
  loaded = { entries = list, problem = (not ok) and 'store_write_failed' or nil }
  return ok == true
end

-- The seeds the skill ships. Read once per process; a missing or unreadable file is a named problem,
-- not an exception, because a node without the skill still has to be able to recall.
function M.seed_path()
  local found = skills.find('fleetops')
  return found and found.dir and (found.dir .. '/incidents.json') or nil
end

function M.seeds()
  local path = M.seed_path()
  if not path or type(host.read_file) ~= 'function' then return {}, 'seed_missing' end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' or text == '' then return {}, 'seed_unreadable' end
  local decoded = decode(text)
  if not decoded or type(decoded.incidents) ~= 'table' then return {}, 'seed_unreadable' end
  local list = {}
  for _, entry in ipairs(decoded.incidents) do
    if type(entry) == 'table' and clean(entry.id) and clean(entry.symptom) and clean(entry.rule) then
      list[#list + 1] = entry
    end
  end
  return list, nil
end

-- Load the shipped seeds once, by id. An entry that already exists - seeded earlier, or added and
-- then corrected by hand - is left exactly as it is.
function M.ensure()
  local current = load()
  local seeded, problem = M.seeds()
  if #seeded == 0 then return current.entries, problem end
  local known = {}
  for _, entry in ipairs(current.entries) do known[entry.id] = true end
  local added = 0
  local list = {}
  for _, entry in ipairs(current.entries) do list[#list + 1] = entry end
  for _, entry in ipairs(seeded) do
    if not known[entry.id] then
      list[#list + 1] = entry
      added = added + 1
    end
  end
  if added > 0 then
    table.sort(list, function(a, b)
      return (tonumber(a.at) or 0) > (tonumber(b.at) or 0)
    end)
    if not save(list) then return list, 'store_write_failed' end
  end
  return list, current.problem
end

-- One call to add a lesson. `id` is derived from the symptom+rule when the caller gives none, so a
-- repeated identical lesson replaces itself instead of accumulating.
local function derive_id(entry)
  local ok, digest = pcall(host.sha256, tostring(entry.symptom) .. '\0' .. tostring(entry.rule))
  if ok and type(digest) == 'string' and digest ~= '' then return 'les-' .. digest:sub(1, 12) end
  return 'les-' .. tostring(#tostring(entry.symptom) .. #tostring(entry.rule))
end

function M.add(entry)
  if type(entry) ~= 'table' then return { ok = false, error = 'lesson_object_required' } end
  local symptom = clean(entry.symptom, M.MAX_FIELD)
  local rule = clean(entry.rule, M.MAX_FIELD)
  if not symptom then return { ok = false, error = 'lesson_symptom_required' } end
  if not rule then return { ok = false, error = 'lesson_rule_required' } end
  local lesson = {
    id = clean(entry.id) or derive_id({ symptom = symptom, rule = rule }),
    at = tonumber(entry.at) or math.floor((host.now() or 0) * 1000),
    symptom = symptom,
    cause = clean(entry.cause, M.MAX_FIELD) or 'unknown',
    fix = clean(entry.fix, M.MAX_FIELD) or 'unknown',
    rule = rule,
    source = clean(entry.source, 200) or 'agent',
  }
  if type(entry.tags) == 'table' then
    local tags = {}
    for _, tag in ipairs(entry.tags) do
      local value = clean(tag, 60)
      if value then tags[#tags + 1] = value:lower() end
    end
    lesson.tags = tags
  elseif type(entry.tags) == 'string' then
    local tags = {}
    for tag in tostring(entry.tags):gmatch('[^,%s]+') do tags[#tags + 1] = tag:lower() end
    lesson.tags = tags
  end
  local list = M.ensure()
  local replaced = false
  for index, existing in ipairs(list) do
    if existing.id == lesson.id then
      -- A correction keeps its original position in time: the incident did not un-happen.
      lesson.at = tonumber(existing.at) or lesson.at
      list[index] = lesson
      replaced = true
    end
  end
  if not replaced then
    -- Newest first, and the store stays bounded: the oldest entries fall out, which is a *visible*
    -- bound (`dropped`), not a silent truncation.
    table.insert(list, 1, lesson)
  end
  local dropped = 0
  while #list > M.MAX_ENTRIES do
    table.remove(list)
    dropped = dropped + 1
  end
  if not save(list) then return { ok = false, error = 'store_write_failed', id = lesson.id } end
  local out = { ok = true, id = lesson.id, replaced = replaced, count = #list, lesson = lesson }
  if dropped > 0 then out.dropped = dropped end
  return out
end

function M.list(limit)
  local list = M.ensure()
  limit = math.max(1, math.min(tonumber(limit) or M.MAX_RESULTS, M.MAX_RESULTS))
  local out = {}
  for index = 1, math.min(#list, limit) do out[index] = list[index] end
  return out
end

-- Plain lexical recall: every query token that appears in the lesson's own text counts, the rule and
-- the symptom weigh more than the tags, and the newest wins a tie. Search is lexical, so an empty
-- answer means "these words are not in the store", not "no such lesson exists" - the answer says that.
local function tokens(text, out)
  for token in tostring(text or ''):lower():gmatch('[%w][%w%-]+') do
    if #token > 2 then out[token] = true end
  end
  return out
end

local function haystack(lesson)
  return {
    rule = tostring(lesson.rule or ''):lower(),
    symptom = tostring(lesson.symptom or ''):lower(),
    cause = tostring(lesson.cause or ''):lower(),
    fix = tostring(lesson.fix or ''):lower(),
    tags = table.concat(lesson.tags or {}, ' '):lower(),
    id = tostring(lesson.id or ''):lower(),
  }
end

function M.recall(query, limit)
  local wanted = tokens(query, {})
  local names = {}
  for token in pairs(wanted) do names[#names + 1] = token end
  table.sort(names)
  if #names == 0 then return { lessons = {}, error = 'query_required', note = M.NOTE } end
  local scored, matched, missed = {}, {}, {}
  for _, lesson in ipairs(M.ensure()) do
    local text = haystack(lesson)
    local score, hits = 0, {}
    for _, token in ipairs(names) do
      local found = false
      if text.rule:find(token, 1, true) then score, found = score + 3, true end
      if text.symptom:find(token, 1, true) then score, found = score + 2, true end
      if text.tags:find(token, 1, true) then score, found = score + 2, true end
      if text.cause:find(token, 1, true) or text.fix:find(token, 1, true) then score, found = score + 1, true end
      if found then hits[#hits + 1] = token else missed[token] = (missed[token] or 0) + 1 end
    end
    if #hits > 0 then
      scored[#scored + 1] = { lesson = lesson, score = score, matched = table.concat(hits, ',') }
      matched[#hits == #names and 'all' or 'some'] = true
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (tonumber(a.lesson.at) or 0) > (tonumber(b.lesson.at) or 0)
  end)
  limit = math.max(1, math.min(tonumber(limit) or 5, M.MAX_RESULTS))
  local out = {}
  for index = 1, math.min(#scored, limit) do out[index] = scored[index].lesson end
  local absent = {}
  for _, token in ipairs(names) do if not matched.all and missed[token] and missed[token] == #scored then absent[#absent + 1] = token end end
  return {
    lessons = out,
    matched = #out,
    query = query,
    absent_terms = #absent > 0 and absent or nil,
    note = M.NOTE,
  }
end

-- The text a tool answer carries: episodic knowledge is looked up, so say how to use it and say why
-- an empty answer is not proof.
M.NOTE = 'Lessons are looked up on purpose, never injected. An empty answer means these words are not '
  .. 'in the store (search is lexical); add one with lessons {action:"add", symptom, cause, fix, rule}.'

function M.stats()
  local list = M.ensure()
  local tags, newest = {}, nil
  for _, lesson in ipairs(list) do
    for _, tag in ipairs(lesson.tags or {}) do tags[tag] = (tags[tag] or 0) + 1 end
    local at = tonumber(lesson.at) or 0
    if not newest or at > newest then newest = at end
  end
  return { count = #list, newest_at = newest, tags = tags, seed = M.seed_path(), max_entries = M.MAX_ENTRIES }
end

-- A test or a repair path may want the process-local cache dropped after writing the file directly.
function M.forget_cache()
  loaded = nil
end

return M
