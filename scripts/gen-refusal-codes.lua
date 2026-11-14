-- The inventory of refusal codes the model's tools can reach, generated from the source.
--
--   lua5.4 scripts/gen-refusal-codes.lua --write  # rewrite lua/core/refusal_codes.lua
--   lua5.4 scripts/gen-refusal-codes.lua --check  # exit 1 when the file is stale
--
-- Why it exists: a refusal's `message` has to name where it came from, and asking every `error = ...`
-- site to repeat the module it sits in is the per-site copy this change removes. The map is generated
-- from `dofile` reachability instead - the closure of `tools.lua`, `codemode.lua` and `agent.lua`, the
-- three entry points a model call goes through - and the gate test recomputes it, so a code added in
-- one of those modules without regenerating is a red test rather than a message that says "this node".
--
-- The set is an over-approximation on purpose: a module reachable from the loop can be reached by a
-- tool, so a code in it may reach a result. Over-approximating costs one table row; under-approximating
-- costs the model the call the map exists to save.
local ROOTS = { 'lua/core/tools.lua', 'lua/core/codemode.lua', 'lua/core/agent.lua' }
local OUT = 'lua/core/refusal_codes.lua'

local function read(path)
  local handle = io.open(path, 'rb')
  if not handle then return nil end
  local text = handle:read('a')
  handle:close()
  return text
end

local function walk(path, seen, order)
  if seen[path] then return end
  local text = read(path)
  if not text then return end
  seen[path] = true
  order[#order + 1] = path
  for dep in text:gmatch("dofile%s*%(%s*['\"]([%w%._/%-]+)['\"]") do
    local module = dep
    if not module:find('/', 1, true) then module = 'lua/core/' .. module end
    if not module:match('%.lua$') then module = module .. '.lua' end
    walk(module, seen, order)
  end
end

-- Codes are the literal right-hand side of an `error` field: a quoted name, or a quoted prefix that is
-- concatenated (`'unknown_node:' .. name`). A code built entirely from variables has no literal and no
-- contract to keep, so it is not in the map.
local function codes_of(text)
  local found = {}
  for code in text:gmatch("error%s*=%s*['\"]([%w_%.]*[%w_])['\"]") do found[code] = true end
  for code in text:gmatch("error%s*=%s*['\"]([%w_%.:]*)['\"]%s*%.%.") do found[code] = true end
  return found
end

-- The host raises refusals too. `rust/wa-capabilities` answers a plugin call with an `anyhow!` string
-- that becomes the Lua tool result's `error` verbatim (`plugin_not_found:voice` reached a model's
-- transcript this way, 13/11), so its codes are in the inventory as well. The rule is narrow on
-- purpose: a lowercase code followed by a colon, on a line that CONSTRUCTS an error. A Rust string like
-- `"peer:{node}"` is an id, not a code, and is not in the set.
local RUST_DIR = 'rust/wa-capabilities/src'
local function rust_codes()
  local found = {}
  local names = {}
  local listing = io.popen and io.popen('ls ' .. RUST_DIR .. ' ' .. RUST_DIR .. '/* 2>/dev/null')
  if listing then
    for name in listing:lines() do if name:match('%.rs$') then names[#names + 1] = true end end
    listing:close()
  end
  -- `ls` prints a subdirectory's contents without its path; ask for the file list per directory instead.
  local dirs = { RUST_DIR }
  for _, dir in ipairs(dirs) do
    local handle = io.popen and io.popen('ls ' .. dir .. ' 2>/dev/null')
    if handle then
      for name in handle:lines() do
        if name:match('%.rs$') then
          local path = dir .. '/' .. name
          local text = read(path) or ''
          for line in text:gmatch('[^\n]+') do
            if line:find('anyhow!', 1, true) or line:find('bail!', 1, true) then
              for code in line:gmatch('"([a-z][a-z0-9_]*):') do found[code] = path end
            end
          end
        end
      end
      handle:close()
    end
  end
  return found
end

local function build()
  local seen, order = {}, {}
  for _, root in ipairs(ROOTS) do walk(root, seen, order) end
  local map, origin = {}, {}
  for _, path in ipairs(order) do
    local text = read(path) or ''
    local short = path:gsub('^lua/core/', '')
    for code in pairs(codes_of(text)) do
      map[code] = map[code] or {}
      map[code][short] = true
    end
  end
  local codes = {}
  for code in pairs(map) do codes[#codes + 1] = code end
  table.sort(codes)
  for _, code in ipairs(codes) do
    local places = {}
    for place in pairs(map[code]) do places[#places + 1] = place end
    table.sort(places)
    -- A code raised in more than one module keeps its name there, all of them: `path_required` is
    -- raised by `read`, by `write` and by a capture, and a message that named only the first would
    -- send a model to a module it never called.
    origin[code] = table.concat(places, ', ')
  end
  local rust = rust_codes()
  for code, path in pairs(rust) do
    if origin[code] == nil then origin[code] = path end
  end
  return origin, #order
end

local function render(origin)
  local codes = {}
  for code in pairs(origin) do codes[#codes + 1] = code end
  table.sort(codes)
  local lines = {
    '-- GENERATED by scripts/gen-refusal-codes.lua - do not edit by hand.',
    '--',
    '-- Every refusal code a model call can reach, and the module that raises it, taken from the dofile',
    '-- closure of tools.lua, codemode.lua and agent.lua. `lua/core/refusal.lua` reads this so a refusal can',
    '-- say where it came from; scripts/test-refusal-contract.lua recomputes it, so it cannot drift.',
    'return {',
  }
  for _, code in ipairs(codes) do
    lines[#lines + 1] = string.format("  ['%s']='%s',", code, origin[code])
  end
  lines[#lines + 1] = '}'
  lines[#lines + 1] = ''
  return table.concat(lines, '\n')
end

local origin, modules = build()

local function count_of(table_value)
  local count = 0
  for _ in pairs(table_value) do count = count + 1 end
  return count
end

local function main()
  local text = render(origin)
  if arg and arg[1] == '--check' then
    local current = read(OUT)
    if current == text then
      print(string.format('refusal codes: %d codes from %d reachable modules, up to date', count_of(origin), modules))
      os.exit(0)
    end
    print('refusal codes: lua/core/refusal_codes.lua is STALE - run lua5.4 scripts/gen-refusal-codes.lua --write')
    os.exit(1)
  end
  local handle = assert(io.open(OUT, 'wb'))
  handle:write(text)
  handle:close()
  print(string.format('refusal codes: wrote %s - %d codes from %d reachable modules', OUT, count_of(origin), modules))
end

-- Loadable by scripts/test-refusal-contract.lua: ONE scan, used by the generator and the gate test, so
-- "the inventory is stale" and "the inventory is right" can never be two different rules. The CLI runs
-- only for its own explicit flags: a test row started by the node carries `--db <path>` in `arg`, and a
-- generator that rewrote a tracked file as a side effect of being loaded would be a trap.
local M = { build = build, render = render, codes_of = codes_of, roots = ROOTS, out = OUT, main = main,
  count = function() return count_of(origin), modules end }
if arg and arg[1] and (arg[1] == '--write' or arg[1] == '--check') then M.main() end
return M
