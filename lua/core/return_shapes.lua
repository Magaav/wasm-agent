-- What a connector tool answers, as a compact shape the connector index prints next to its arguments
-- (15/11, real runs: every first call to an email or WhatsApp read was followed by `Object.keys(r)`,
-- because `get_message` nests under `message`, `search_messages` answers `messages` at the top and a
-- WhatsApp read answers `header` + `messages`; a wrong guess is `undefined`, silently).
--
--   name({args}) → {header:{chat,name,type},messages:[{id,at_local,from:{own,name},text}]}
--
-- Keys only, never values: an object is `{a,b:{...}}` (a scalar key is its bare name), an array is
-- `[first element's shape]` (an array is not a level of its own), at most three object levels deep and
-- about CAP characters. Three sources, best
-- first, chosen by `M.suffix`:
--   1. ours     - a static `returns` on a `lua/core/whatsapp.lua` tool, written from the component's
--                 answer (rust/components/wa-whatsapp/src/index.rs) - the keys a script reads;
--   2. declared - the MCP server's own `outputSchema` from the last probe (`mcp.output_schemas`);
--   3. learned  - the shape of the tool's real answers on this node, as the SCRIPT saw it (after
--                 `codemode.script_value`), recorded by `M.learn` from `codemode.settle_call`.
--
-- Learned shapes are a union of the answers seen for one argument schema (keyed by the tool name and the
-- sha256 of its `parameters`): an answer with an empty list or a missing optional field adds nothing, a
-- new key is added once, so the stored shape converges and the index stops changing (the prompt prefix is
-- frozen per session anyway - docs/PROMPT-CACHE.md - so a change reaches the next session, not this one).
-- A new argument schema starts the shape afresh.
--
-- Privacy: keys of a user-data map are data (a dict keyed by e-mail addresses, phone JIDs or names). An
-- object with more than MAX_KEYS keys, or with any key that does not look like a field name (contains
-- `@` or whitespace, is longer than 24, or is not identifier-like), is stored as `{…}` - its keys are
-- never written. Scalars are stored as their JS type word; no value is ever stored.
local json = dofile('lua/vendor/json.lua')
local M = {}

M.KEY = 'codemode.return_shapes.v1'
M.CAP = 120
M.DEPTH = 3
M.MAX_KEYS = 12
M.MAX_TOOLS = 256

local function data_like(key)
  return type(key) ~= 'string' or #key > 24 or key:find('[@%s]') ~= nil or not key:match('^[%a_$][%w_$%-]*$')
end

local function count_keys(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- A shape tree: 'string' | 'number' | 'boolean' | 'any' for a scalar, {o={key=tree}} an object,
-- {a=tree} an array (its first element), {e=true} an empty container, {c=true} an object whose keys are
-- not shown (data-like, too many, or deeper than DEPTH).
local function tree_of(value, depth)
  local kind = type(value)
  if kind == 'string' or kind == 'number' or kind == 'boolean' then return kind end
  if kind ~= 'table' then return 'any' end
  if next(value) == nil then return { e = true } end
  -- An array is its first element, at the same level: `messages:[{id,from:{name}}]` is two levels.
  if rawget(value, 1) ~= nil then return { a = tree_of(value[1], depth) } end
  if depth >= M.DEPTH then return { c = true } end
  if count_keys(value) > M.MAX_KEYS then return { c = true } end
  local o = {}
  for k, v in pairs(value) do
    if data_like(k) then return { c = true } end
    o[k] = tree_of(v, depth + 1)
  end
  return { o = o }
end
function M.tree(value) return tree_of(value, 0) end

-- The union of two trees. The older side wins every tie, so a second identical answer changes nothing.
local function merge(old, new)
  if old == nil then return new end
  if new == nil then return old end
  if type(old) ~= 'table' then return type(new) == 'table' and not new.e and new or old end
  if type(new) ~= 'table' then return old end
  if old.e then return new end
  if new.e then return old end
  if old.c then return old end
  if old.o and new.c then return { c = true } end
  if old.o and new.o then
    local o = {}
    for k, v in pairs(old.o) do o[k] = v end
    for k, v in pairs(new.o) do o[k] = merge(o[k], v) end
    if count_keys(o) > M.MAX_KEYS then return { c = true } end
    return { o = o }
  end
  if old.a and new.a then return { a = merge(old.a, new.a) } end
  return old
end
M.merge = merge

-- A JSON Schema as a tree, the same `data` unwrap the script sees (`script_value`: structured content
-- with a `data` member is that member).
local function schema_tree(schema, depth)
  if type(schema) ~= 'table' then return 'any' end
  for _, k in ipairs({ 'anyOf', 'oneOf', 'allOf' }) do
    if type(schema[k]) == 'table' then
      for _, branch in ipairs(schema[k]) do
        if type(branch) == 'table' and branch.type ~= 'null' then return schema_tree(branch, depth) end
      end
    end
  end
  local t = schema.type
  if type(t) == 'table' then
    local picked
    for _, v in ipairs(t) do if v ~= 'null' then picked = v; break end end
    t = picked
  end
  if t == nil and type(schema.properties) == 'table' then t = 'object' end
  if t == nil and type(schema.items) == 'table' then t = 'array' end
  if t == 'array' then
    return { a = type(schema.items) == 'table' and schema_tree(schema.items, depth) or 'any' }
  end
  if t == 'object' then
    if type(schema.properties) ~= 'table' or next(schema.properties) == nil or depth >= M.DEPTH then return { c = true } end
    local o = {}
    for k, v in pairs(schema.properties) do o[k] = schema_tree(v, depth + 1) end
    return { o = o }
  end
  if t == 'integer' then return 'number' end
  if t == 'string' or t == 'number' or t == 'boolean' then return t end
  return 'any'
end
function M.from_schema(schema)
  if type(schema) == 'table' and type(schema.properties) == 'table' and type(schema.properties.data) == 'table' then
    return schema_tree(schema.properties.data, 0)
  end
  return schema_tree(schema, 0)
end

local function sorted_keys(o)
  local keys = {}
  for k in pairs(o) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- One tree as text, `depth` container levels at most. `top` is a scalar answer's own word.
local function render(tree, depth, top)
  if type(tree) ~= 'table' then return top and tree or nil end
  if tree.e then return '[]' end
  if tree.c then return '{…}' end
  if tree.a then return '[' .. (render(tree.a, depth, true) or 'any') .. ']' end
  if depth <= 0 then return '{…}' end
  local parts = {}
  for _, k in ipairs(sorted_keys(tree.o or {})) do
    local inner = render(tree.o[k], depth - 1, false)
    parts[#parts + 1] = inner and (k .. ':' .. inner) or k
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- The shortest faithful text within CAP: three levels, then two, then one; at one level the keys that
-- fit, then `…`.
function M.render(tree, cap)
  cap = cap or M.CAP
  if tree == nil then return nil end
  for depth = M.DEPTH, 1, -1 do
    local text = render(tree, depth, true)
    if #text <= cap then return text end
  end
  if type(tree) ~= 'table' or not tree.o then return (render(tree, 0, true)) end
  local parts, used = {}, 2
  for _, k in ipairs(sorted_keys(tree.o)) do
    local inner = render(tree.o[k], 0, false)
    local piece = inner and (k .. ':' .. inner) or k
    if used + #piece + 4 > cap then parts[#parts + 1] = '…'; break end
    parts[#parts + 1] = piece; used = used + #piece + 1
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- ------------------------------------------------------------------ the learned store (memory.meta)

local function meta_read()
  local ok, raw = pcall(host.sql_query, 'SELECT value FROM meta WHERE key=?', json.encode({ M.KEY }))
  if not ok then return {} end
  local rows_ok, rows = pcall(json.decode, raw or '[]')
  local value = rows_ok and type(rows) == 'table' and rows[1] and rows[1].value
  if type(value) ~= 'string' then return {} end
  local decoded_ok, store = pcall(json.decode, value)
  return decoded_ok and type(store) == 'table' and store or {}
end

local function meta_write(store)
  return pcall(host.sql_exec, 'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    json.encode({ M.KEY, json.encode(store) }))
end

function M.load() return meta_read() end

function M.schema_hash(parameters)
  return host.sha256(json.encode(type(parameters) == 'table' and parameters or {}))
end

-- What this process last wrote or read, per tool, so an unchanged answer costs no SQL at all.
local seen = {}

local static_cache
local function static_returns(name)
  if static_cache == nil then
    local ok, module = pcall(dofile, 'lua/core/whatsapp.lua')
    static_cache = ok and type(module) == 'table' and module or false
  end
  if not static_cache then return nil end
  local tool = static_cache.tool(name)
  return tool and tool.returns or nil
end

--- Record one settled answer. `name` is the dispatched tool, `parameters` its argument schema, `value`
--- what the script received. Returns true when the stored shape changed. Never raises.
function M.learn(name, parameters, value)
  local ok, changed = pcall(function()
    if type(name) ~= 'string' or static_returns(name) then return false end
    -- A handle is not the answer: `{state:"pending", op}` is what a call that outlived its wait gives.
    if type(value) == 'table' and value.state == 'pending' then return false end
    local hash = M.schema_hash(parameters)
    local fresh = M.tree(value)
    local memo = seen[name]
    if memo and memo.h == hash then
      local merged = merge(memo.t, fresh)
      if json.encode(merged) == memo.text then return false end
    end
    local store = meta_read()
    local entry = store[name]
    local old = type(entry) == 'table' and entry.h == hash and entry.t or nil
    local merged = merge(old, fresh)
    local text = json.encode(merged)
    if old ~= nil and json.encode(old) == text then
      seen[name] = { h = hash, t = merged, text = text }
      return false
    end
    store[name] = { h = hash, t = merged }
    local names = sorted_keys(store)
    for i = 1, #names - M.MAX_TOOLS do if names[i] ~= name then store[names[i]] = nil end end
    if not meta_write(store) then return false end
    seen[name] = { h = hash, t = merged, text = text }
    return true
  end)
  return ok and changed or false
end

--- The ` → shape` an index line ends with, or '' when this node knows none. `declared` is the
--- name → outputSchema map, `learned` the store as `M.load` returns it.
function M.suffix(f, declared, learned)
  local name = type(f) == 'table' and f.name
  if type(name) ~= 'string' then return '' end
  local text = static_returns(name)
  if not text and type(declared) == 'table' and type(declared[name]) == 'table' then
    text = M.render(M.from_schema(declared[name]))
  end
  if not text and type(learned) == 'table' then
    local entry = learned[name]
    if type(entry) == 'table' and entry.t ~= nil and entry.h == M.schema_hash(f.parameters) then text = M.render(entry.t) end
  end
  if not text or text == '' then return '' end
  return ' → ' .. text
end

return M
