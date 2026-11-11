-- Path safety: a recursive delete may not take a root, a home, or anything that contains one.
--
-- This exists because on 11/11 `scripts/test-update-banner.lua` took its scratch from
-- `WASM_AGENT_HOME` and ran `rm -rf` on it. Inside `wa`, `WASM_AGENT_HOME` is the user's home, so the
-- pre-clean deleted `C:/Users/Victor` - documents, keys, the repo, the install dir. The test was
-- wrong; the harness let it be fatal. This is the harness half: every delete that goes through
-- `host.exec` (and the bash tool, which is the same call with a model on top) is checked first, and a
-- protected target is refused by name.
--
-- The rule, from the operator: never delete what you did not create in this run; tests use their own
-- scratch, never a path from the environment. The guard cannot know who created a path, so it refuses
-- the paths whose loss is unrecoverable and lets the rest through: a refused caller must pass its own
-- `mktemp -d` instead of the environment's answer.
--
-- Protected means: the target *is* one of these, or is an ancestor of one (so `/`, `/home`,
-- `C:/Users` are refused because they contain a home). Symlinks, `.`/`..`, repeated separators,
-- backslashes and (on Windows) case are resolved before the comparison; a path that cannot be
-- resolved is refused, not allowed.
local M = {}

local function env(name)
  local ok, value = pcall(host.getenv, name)
  if ok and type(value) == 'string' and value ~= '' then return value end
  return nil
end

local function canonical_lua()
  -- The Lua tree this node is running from: a checkout during development, `<install>/lua-core` on an
  -- installed node. Deleting it mid-run is the same class of mistake.
  local ok, value = pcall(host.getenv, 'WASM_AGENT_LUA_ROOT')
  if ok and type(value) == 'string' and value ~= '' then return value end
  return nil
end

function M.windows()
  local os_name = env('OS')
  if os_name and tostring(os_name):lower():find('windows', 1, true) then return true end
  local ok, name = pcall(function() return dofile('lua/core/platform.lua').os() end)
  return ok and tostring(name):lower():find('windows', 1, true) ~= nil
end

M.WINDOWS = M.windows()

-- Lexical resolution: backslashes to slashes, `.` dropped, `..` popped, repeats collapsed, a drive
-- letter kept, trailing separators removed. Case folded on Windows, because NTFS is.
function M.normalise(path)
  if type(path) ~= 'string' then return nil end
  local text = path:gsub('\\', '/')
  if text == '' then return nil end
  -- A drive letter is kept separately: `C:/a` must not become `C:/C:/a`, and `C:a` means `C:/a`.
  local drive = text:match('^(%a:)')
  if drive then text = text:sub(3) end
  if drive and text:sub(1, 1) ~= '/' then text = '/' .. text end
  local absolute = drive ~= nil or text:sub(1, 1) == '/'
  local parts = {}
  for piece in text:gmatch('[^/]+') do
    if piece == '.' then -- nothing
    elseif piece == '..' then
      if #parts > 0 and parts[#parts] ~= '..' then table.remove(parts)
      elseif not absolute then parts[#parts + 1] = '..' end
    else parts[#parts + 1] = piece end
  end
  local joined = table.concat(parts, '/')
  local out
  if drive then out = drive .. '/' .. joined
  elseif absolute then out = '/' .. joined
  else out = joined end
  if out == '' then out = absolute and '/' or '.' end
  if #out > 1 then out = out:gsub('/+$', '') end
  -- A drive-lettered path is Windows-shaped wherever this runs, so it is compared case-insensitively
  -- even on a case-sensitive filesystem: `C:/Users/Victor` and `c:/users/victor` are one profile.
  if drive or M.windows() then out = out:lower() end
  return out
end

-- Expand a shell-level `~` before resolving: `rm -rf ~/.wasm-agent` must be seen as the home.
local function expand(path)
  local text = tostring(path or '')
  if text == '~' or text:sub(1, 2) == '~/' or text:sub(1, 2) == '~\\' then
    local home = env('HOME') or env('USERPROFILE') or ''
    return home .. text:sub(2)
  end
  return text
end

-- Every protected root, and every ancestor of one. Recomputed per call: an environment that changes
-- between calls (a test setting its own home) must be judged by what it says now.
function M.protected()
  local roots, seen = {}, {}
  local function add(path)
    if type(path) ~= 'string' or path == '' then return end
    local resolved = M.normalise(expand(path))
    if resolved and not seen[resolved] then seen[resolved] = true; roots[#roots + 1] = resolved end
  end
  add('/')
  add(env('HOME'))
  add(env('USERPROFILE'))
  -- The node's default state directory, whether or not this run overrode WASM_AGENT_HOME: `rm -rf
  -- ~/.wasm-agent` is the loss of every key, ledger and install record, and it is the shape an operator
  -- typed at us on 11/11.
  if env('HOME') then add(env('HOME') .. '/.wasm-agent') end
  if env('USERPROFILE') then add(env('USERPROFILE') .. '/.wasm-agent') end
  add(env('WASM_AGENT_HOME'))
  add(env('WA_INSTALL_DIR'))
  add(env('WASM_AGENT_INSTALL_DIR'))
  add(canonical_lua())
  -- `<home>/.wasm-agent` itself: the node's own state, keys and ledger.
  local ok, paths = pcall(function() return dofile('lua/core/paths.lua') end)
  if ok and paths then
    local ok_home, home = pcall(paths.home)
    if ok_home then add(home) end
  end
  -- Ancestors: `/`, `/home`, `C:/Users` are protected because they contain a home.
  local all, added = {}, {}
  for _, root in ipairs(roots) do
    local walk = root
    while true do
      if not added[walk] then added[walk] = true; all[#all + 1] = walk end
      local parent = walk:gsub('/[^/]+$', '')
      if parent == '' or parent == walk then break end
      walk = parent
    end
  end
  return all
end

-- Why `path` may not be deleted, or nil. The message names the guard and the path, because a refusal
-- a caller cannot read is a refusal that gets worked around.
function M.refusal(path)
  local resolved = M.normalise(expand(path))
  if not resolved then return 'path_guard: refusing a delete of an empty or unresolvable path' end
  if resolved == '.' or resolved == '' then return 'path_guard: refusing a delete of the working directory (' .. tostring(path) .. ')' end
  if resolved:find('%.%.$') then return 'path_guard: refusing a delete of a relative path that leaves its root: ' .. tostring(path) end
  -- A user profile by shape, on any platform: `C:/Users/<name>` (or `C:/Documents and Settings/<name>`) is
  -- someone's whole home wherever the guard is running, and that is the path the 11/11 loss took.
  if resolved:match('^%a:/users/[^/]+$') or resolved:match('^%a:/users$')
    or resolved:match('^%a:/users/[^/]+/[^/]+$')
    or resolved:match('^%a:/documents and settings/[^/]+$')
    or resolved:match('^%a:/documents and settings$') then
    return 'path_guard: refusing to delete ' .. tostring(path) .. ': it is a Windows user profile (' .. resolved
      .. '), which is somebody\'s home. Never delete what you did not create in this run.'
  end
  for _, root in ipairs(M.protected()) do
    if resolved == root then
      return 'path_guard: refusing to delete ' .. tostring(path) .. ': it resolves to protected path ' .. root
        .. '. Never delete what you did not create in this run; a test uses its own mktemp scratch, never a path from the environment.'
    end
  end
  return nil
end

-- --- reading a shell command for recursive deletes ------------------------------------------------
-- Deliberately narrow: only forms that delete a tree. `rm -f one-file` is not guarded (a file the
-- caller named is their own business); `rm -rf`, `rm -r`, `rmdir`, `Remove-Item -Recurse`, `del /s`
-- and `rd /s` are.
local function tokens(segment)
  local out, i, length = {}, 1, #segment
  while i <= length do
    local char = segment:sub(i, i)
    if char:match('%s') then i = i + 1
    elseif char == "'" then
      local stop = segment:find("'", i + 1, true)
      if not stop then return nil end
      out[#out + 1] = segment:sub(i + 1, stop - 1); i = stop + 1
    elseif char == '"' then
      local stop = segment:find('"', i + 1, true)
      if not stop then return nil end
      out[#out + 1] = segment:sub(i + 1, stop - 1); i = stop + 1
    else
      local stop = segment:find('[%s]', i) or (length + 1)
      out[#out + 1] = segment:sub(i, stop - 1); i = stop
    end
  end
  return out
end

local function is_recursive_flag(word)
  local lowered = tostring(word):lower()
  return lowered == '--recursive' or lowered == '-recurse' or lowered == '/s'
    or lowered:match('^%-[a-z]*r[a-z]*$') ~= nil -- -r, -rf, -fr, -Rf
    or lowered:match('^%-%-recursive') ~= nil
end

-- Every target of a recursive delete in this command (one shell segment at a time).
function M.targets(command)
  local text = tostring(command or '')
  local found = {}
  for segment in (text .. '\n'):gmatch('([^;|&\n]+)') do
    local words = tokens(segment)
    if words and #words > 0 then
      local head = tostring(words[1]):gsub('^.*/', '') -- /bin/rm -> rm
      local lowered = head:lower()
      local recursive, start = false, 2
      if lowered == 'rm' or lowered == 'rm.exe' then
        for index = 2, #words do
          if words[index]:sub(1, 1) == '-' then recursive = recursive or is_recursive_flag(words[index])
          else break end
        end
        if recursive then
          for index = 2, #words do
            if words[index]:sub(1, 1) ~= '-' then found[#found + 1] = words[index] end
          end
        end
      elseif lowered == 'rmdir' or lowered == 'rd' or lowered == 'rd.exe' or lowered == 'rmdir.exe' then
        local forced = false
        for index = 2, #words do
          local word = tostring(words[index]):lower()
          if word:sub(1, 1) == '-' or word:sub(1, 1) == '/' then forced = forced or word == '/s' or word:match('^%-%-recursive')
          else found[#found + 1] = words[index] end
        end
        -- rmdir without /s or -r only removes an empty directory; still check, it costs nothing.
        local _ = forced
      elseif lowered == 'remove-item' or lowered == 'remove-item.exe' or lowered == 'ri' then
        local recurse = false
        local paths = {}
        for index = 2, #words do
          local word = tostring(words[index]):lower()
          if word == '-recurse' or word:match('^%-recurse') then recurse = true
          elseif word:sub(1, 1) ~= '-' then paths[#paths + 1] = words[index] end
        end
        if recurse then for _, path in ipairs(paths) do found[#found + 1] = path end end
      elseif lowered == 'del' or lowered == 'del.exe' or lowered == 'erase' then
        local recurse = false
        local paths = {}
        for index = 2, #words do
          local word = tostring(words[index]):lower()
          if word == '/s' or word == '/f' then recurse = recurse or (word == '/s')
          elseif word:sub(1, 1) ~= '-' and word:sub(1, 1) ~= '/' then paths[#paths + 1] = words[index] end
        end
        if recurse then for _, path in ipairs(paths) do found[#found + 1] = path end end
      end
      local _ = start
    end
  end
  return found
end

-- ok, reason. A command whose targets cannot be read is refused (fail closed).
function M.command(command, cwd)
  local text = tostring(command or '')
  if text == '' then return true end
  -- `$(...)`, backticks and `$VAR` inside a delete target cannot be resolved statically: the shell
  -- would expand them after this check. Refuse a recursive delete whose target is one of those.
  for _, target in ipairs(M.targets(text)) do
    if target:find('%$') or target:find('`') then
      return nil, 'path_guard: refusing a recursive delete whose target is computed by the shell ('
        .. target .. '); name a path this run created, or use a mktemp directory'
    end
    local relative = target
    if relative:sub(1, 1) ~= '/' and relative:sub(1, 1) ~= '~' and not relative:match('^%a:') and cwd and cwd ~= '' then
      relative = tostring(cwd) .. '/' .. relative
    end
    local why = M.refusal(relative)
    if why then return nil, why end
  end
  return true
end

-- The refusal as the JSON an operation returns, so a blocked call reads like a failed command rather
-- than a crash.
function M.refusal_json(reason)
  local json = dofile('lua/vendor/json.lua')
  return json.encode({ok = false, code = 126, blocked_by = 'path_guard', error = reason,
    stdout = '', stderr = reason, effect = 'none'})
end

-- Wrap `host.exec` once. Every module that runs a command - the bash tool, the deploy helper, a test -
-- goes through this, so the check cannot be forgotten by a new call site. Idempotent: a second install
-- is a no-op, and the marker survives a module reload inside one process.
function M.install(target)
  local host_table = target or host
  if type(host_table) ~= 'table' or type(host_table.exec) ~= 'function' then return false end
  if host_table.__path_guard_installed then return true end
  local raw = host_table.exec
  host_table.exec = function(command, cwd, ...)
    local ok, reason = M.command(command, cwd)
    if not ok then return M.refusal_json(reason) end
    return raw(command, cwd, ...)
  end
  host_table.__path_guard_installed = true
  return true
end

return M
