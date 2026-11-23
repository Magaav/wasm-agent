-- The walker: every INTERNAL call site with a LITERAL args table, judged against the tool's own schema
-- (mission tool-args-honest-and-same-on-peers, STEP 2 item 3).
--
-- The catalogue parity row covers what the MODEL can call. The fields that went red on main came from the
-- other direction: `lua/core` calling `tools.dispatch` / `M.dispatch` / `wa_peer_dispatch` with a table
-- literal nobody had compared with the schema (`wake{now}`, `operation{control}`, the managed-list gate).
-- A field sent that way is dropped exactly as silently as a model's, so it is measured the same way.
--
-- What it does: reads every `lua/core/*.lua`, finds each dispatch call whose target is a string literal and
-- whose arguments are a table literal, and checks every TOP-LEVEL key of that literal against
-- `tools.parameters` (the declared names) plus the validator's two allow-lists. A key the tool does not
-- declare is a FAILURE with file:line, the tool, and the key - the fix is to declare the field where the
-- tool really takes it, or to stop sending it.
--
-- What it cannot see, and says so in its own output: a call whose target or arguments are variables (counted,
-- not guessed at), and a key built by a function call.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local validator = dofile('lua/core/tool_arguments.lua')
local root = (os.getenv('WA_WALKER_ROOT') or (host.getenv and host.getenv('WA_WALKER_ROOT')) or '.')
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end

-- The literal keys of the table that starts at `open` (1-based index of its `{`), at depth 1 only.
local function literal_keys(text, open)
  local keys, depth, index = {}, 0, open
  local length = #text
  while index <= length do
    local char = text:sub(index, index)
    if char == '{' then
      depth = depth + 1
    elseif char == '}' then
      depth = depth - 1
      if depth == 0 then return keys, index end
    elseif depth == 1 and char:match('[%w_]') and (index == open + 1 or not text:sub(index - 1, index - 1):match('[%w_]')) then
      local key = text:match('^([%w_]+)%s*=', index)
      if key then keys[#keys + 1] = key end
    elseif char == '"' or char == "'" then
      -- Skip a quoted string so a `{` or `=` inside it cannot be read as structure.
      local quote, at = char, index + 1
      while at <= length do
        local inside = text:sub(at, at)
        if inside == '\\' then at = at + 2
        elseif inside == quote then break
        else at = at + 1 end
      end
      index = at
    end
    index = index + 1
  end
  return keys, length
end

local PATTERNS = {
  -- tools.dispatch(memory, "name", { ... }), M.dispatch(memory, "name", { ... })
  { "dispatch%(%s*[%w_%.%[%]]+,%s*[\"']([%w_%.%-]+)[\"']%s*,%s*{", "dispatch(memory, name, {" },
  -- dispatch(nil, "name", { ... })
  { "dispatch%(%s*nil,%s*[\"']([%w_%.%-]+)[\"']%s*,%s*{", "dispatch(nil, name, {" },
  -- wa_peer_dispatch("name", { ... })
  { "wa_peer_dispatch%(%s*[\"']([%w_%.%-]+)[\"']%s*,%s*{", "wa_peer_dispatch(name, {" },
  -- dispatch(dispatch, "name", { ... }) (the pending layer's reserved form)
  { "dispatch%(%s*dispatch,%s*[\"']([%w_%.%-]+)[\"']%s*,%s*{", "dispatch(dispatch, name, {" },
}

local scanned, sites, keys_checked, unresolved, skipped = 0, 0, 0, 0, 0
local unknown = {}
local listing_ok, listing = pcall(host.list_dir, root .. '/lua/core')
check(listing_ok and listing ~= nil, 'lua/core is readable: ' .. tostring(host.paths().home))
for _, entry in ipairs((listing and json.decode(listing).entries) or {}) do
  if entry.kind == 'file' and entry.name:match('%.lua$') then
    scanned = scanned + 1
    local text = host.read_file(root .. '/lua/core/' .. entry.name) or ''
    for _, pattern in ipairs(PATTERNS) do
      local from = 1
      while true do
        local name_start, name_end, target = text:find(pattern[1], from)
        if not name_start then break end
        -- The pattern ends with the args table's own `{`, so the match's last character IS the opening
        -- brace. (Searching forward for "the next {" was measured reading a much later table - 150 false
        -- findings from one call site.)
        local open = name_end
        if text:sub(open, open) ~= '{' then from = name_end; break end
        -- ONE LINE ONLY. A literal that spans lines is skipped and counted, not guessed at: the first
        -- version of this walker tried to brace-match a multi-line table and read a much later table's keys
        -- (150 false findings from one call site). What it cannot see, it says it cannot see.
        local close = text:find('}', open, true)
        local line_end = text:find('\n', open, true) or (#text + 1)
        if not close or close > line_end then skipped = skipped + 1; from = name_end; goto continue end
        local keys = literal_keys(text, open)
        sites = sites + 1
        local parameters = tools.parameters(target, 'master')
        for _, key in ipairs(keys) do
          keys_checked = keys_checked + 1
          if parameters == nil then
            unresolved = unresolved + 1
            break
          elseif validator.undeclared(target, { [key] = true }, parameters) then
            local line = 1
            for _ in text:sub(1, name_start):gmatch('\n') do line = line + 1 end
            unknown[#unknown + 1] = entry.name .. ':' .. line .. ' ' .. target .. '.' .. key
          end
        end
        from = name_end
        ::continue::
      end
    end
  end
end
check(scanned > 50, 'the walker read the tree: ' .. scanned .. ' files in lua/core')
check(sites >= 15, 'and found the dispatch call sites: ' .. sites)
check(keys_checked >= 30, 'with literal argument tables: ' .. keys_checked .. ' keys judged')
if skipped > 0 then
  print('note: ' .. skipped .. ' call sites carry an args literal that spans lines: skipped, not guessed at')
end
if unresolved > 0 then
  print('note: ' .. unresolved .. ' call sites name a tool this node has no schema for (a component or a peer tool): not guessed at')
end
for _, finding in ipairs(unknown) do
  check(false, 'an internal call sends a field its tool does not declare: ' .. finding)
end
if #unknown == 0 then print('walker: every literal key an internal call sends is declared or is a runtime field') end

print(('tool args walker: %d check(s), %d failed, %d files, %d call sites'):format(checks, failed, scanned, sites))
if failed > 0 then os.exit(1) end
