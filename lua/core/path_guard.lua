-- Path safety: a recursive delete may not take a root, a home, or the node's own state.
--
-- Why: on 11/11 `scripts/test-update-banner.lua` took its scratch from `WASM_AGENT_HOME` and ran
-- `rm -rf` on it. Inside `wa` that variable is the user's home, so the pre-clean deleted
-- `C:/Users/Victor`. The harness let one wrong test be fatal.
--
-- Two walls, and the second decides on the REAL path:
--
--   1. static - a literal target in the command is judged before the shell sees it, including the
--      directory a glob targets (`rm -rf ~/*` is the home's contents). Cheap; catches what is written.
--   2. runtime - a command that deletes gets a small shell prelude: `rm`, `rmdir`, `find -delete` and
--      (`command rm`) become functions that resolve every target *after* the shell expanded it
--      (`realpath -m`) and refuse only a protected one. A computed target is not refused for being
--      computed: `T=$(mktemp -d); rm -rf "$T"` is exactly what a test should do, and it passes.
--
-- What is refused is deliberately narrow - the paths whose loss is unrecoverable, and the ancestors
-- that contain them: `/`, HOME, USERPROFILE, WASM_AGENT_HOME, `<home>/.wasm-agent` and its contents,
-- the install dir, the Lua tree and the canonical checkout, and `C:/Users/<name>` by shape. A
-- subdirectory of a home is not refused: blocking every delete under a home blocks normal cleanup,
-- and 66 tests proved that cost on 11/11.
local M = {}

local SENTINEL = '__wa_path_guard'

local function env(name)
  local ok, value = pcall(host.getenv, name)
  if ok and type(value) == 'string' and value ~= '' then return value end
  return nil
end

function M.windows()
  local os_name = env('OS')
  if os_name and tostring(os_name):lower():find('windows', 1, true) then return true end
  local ok, name = pcall(function() return dofile('lua/core/platform.lua').os() end)
  return ok and tostring(name):lower():find('windows', 1, true) ~= nil
end

-- A POSIX shell gets the prelude. PowerShell/cmd cannot take a function of that shape, so there the
-- static wall is the only one - and it refuses literal protected paths, which is what it can see.
function M.shell()
  local ok, name = pcall(function() return dofile('lua/core/platform.lua').shell() end)
  local text = ok and tostring(name or ''):lower() or ''
  if text:find('powershell', 1, true) or text:find('pwsh', 1, true) then return 'powershell' end
  if text == 'cmd' or text:find('cmd.exe', 1, true) then return 'cmd' end
  return 'posix'
end

function M.normalise(path)
  if type(path) ~= 'string' then return nil end
  local text = path:gsub('\\', '/')
  if text == '' then return nil end
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
  if drive or M.windows() then out = out:lower() end
  return out
end

local function expand(path)
  local text = tostring(path or '')
  if text == '~' or text:sub(1, 2) == '~/' or text:sub(1, 2) == '~\\' then
    local home = env('HOME') or env('USERPROFILE') or ''
    return home .. text:sub(2)
  end
  return text
end

-- The roots to protect, and every ancestor of each (so `/`, `/home`, `C:/Users` are refused because
-- they contain a home).
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
  if env('HOME') then add(env('HOME') .. '/.wasm-agent') end
  if env('USERPROFILE') then add(env('USERPROFILE') .. '/.wasm-agent') end
  add(env('WASM_AGENT_HOME'))
  add(env('WA_INSTALL_DIR'))
  add(env('WASM_AGENT_INSTALL_DIR'))
  add(env('WA_CANONICAL'))
  add(env('WASM_AGENT_LUA_ROOT'))
  local ok, paths = pcall(function() return dofile('lua/core/paths.lua') end)
  if ok and paths then
    local ok_home, home = pcall(paths.home)
    if ok_home then add(home) end
  end
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

-- The node's own state subtree, which is refused as a whole: `~/.wasm-agent/tmp/x` is nobody's tree.
-- The node's own state subtree, refused as a whole: `<home>/.wasm-agent/tmp/x` is nobody's working
-- tree. WASM_AGENT_HOME is NOT listed here: a candidate node's scratch is exactly where tests create
-- and remove their own fixtures (`<home>/sqlite-busy-fixture`), and refusing that subtree refuses them.
-- The home itself is still protected as an exact root above.
function M.state_roots()
  local out = {}
  local function add(path)
    local resolved = M.normalise(expand(path))
    if resolved then out[#out + 1] = resolved end
  end
  if env('HOME') then add(env('HOME') .. '/.wasm-agent') end
  if env('USERPROFILE') then add(env('USERPROFILE') .. '/.wasm-agent') end
  return out
end

-- A Windows user profile is somebody's home by shape, on any platform: that is the path 11/11 took,
-- and it must be refused even where the guard runs on Linux with no USERPROFILE to compare to.
local function profile_shaped(resolved)
  return resolved:match('^%a:/users/[^/]+$') or resolved:match('^%a:/users$')
    or resolved:match('^%a:/documents and settings/[^/]+$') or resolved:match('^%a:/documents and settings$')
end

function M.refusal(path)
  local resolved = M.normalise(expand(path))
  if not resolved then return 'path_guard: refusing a delete of an empty or unresolvable path' end
  if resolved == '.' or resolved == '/' then
    return 'path_guard: refusing to delete ' .. tostring(path) .. ': it is a filesystem root or the working directory'
  end
  if resolved:find('%.%.$') then return 'path_guard: refusing a delete of a relative path that leaves its root: ' .. tostring(path) end
  if profile_shaped(resolved) then
    return 'path_guard: refusing to delete ' .. tostring(path) .. ': it is a Windows user profile (' .. resolved
      .. '), which is somebody\'s home.'
  end
  for _, root in ipairs(M.protected()) do
    if resolved == root then
      return 'path_guard: refusing to delete ' .. tostring(path) .. ': it resolves to protected path ' .. root
        .. '.'
    end
  end
  for _, root in ipairs(M.state_roots()) do
    if resolved:sub(1, #root + 1) == root .. '/' then
      return 'path_guard: refusing to delete ' .. tostring(path) .. ': it is inside the node state ' .. root
        .. '.'
    end
  end
  return nil
end

-- --- wall one: the text of the command ------------------------------------------------------------
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
    or lowered:match('^%-[a-z]*r[a-z]*$') ~= nil
    or lowered:match('^%-%-recursive') ~= nil
end

function M.targets(command)
  local text = tostring(command or '')
  local found = {}
  for segment in (text .. '\n'):gmatch('([^;|&\n]+)') do
    local words = tokens(segment)
    if words and #words > 0 then
      local head = tostring(words[1]):gsub('^.*/', '')
      local lowered = head:lower()
      if lowered == 'rm' or lowered == 'rm.exe' then
        local recursive = false
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
        for index = 2, #words do
          if tostring(words[index]):sub(1, 1) ~= '-' and tostring(words[index]):sub(1, 1) ~= '/' then
            found[#found + 1] = words[index]
          end
        end
      elseif lowered == 'remove-item' or lowered == 'remove-item.exe' or lowered == 'ri' then
        local recurse, paths = false, {}
        for index = 2, #words do
          local word = tostring(words[index]):lower()
          if word == '-recurse' or word:match('^%-recurse') then recurse = true
          elseif word:sub(1, 1) ~= '-' then paths[#paths + 1] = words[index] end
        end
        if recurse then for _, path in ipairs(paths) do found[#found + 1] = path end end
      elseif lowered == 'del' or lowered == 'del.exe' or lowered == 'erase' then
        local recurse, paths = false, {}
        for index = 2, #words do
          local word = tostring(words[index]):lower()
          if word == '/s' then recurse = true
          elseif word:sub(1, 1) ~= '-' and word:sub(1, 1) ~= '/' then paths[#paths + 1] = words[index] end
        end
        if recurse then for _, path in ipairs(paths) do found[#found + 1] = path end end
      end
    end
  end
  return found
end

-- ok, reason. Literal targets only: a target the shell computes is wall two's business.
-- ok, reason. Literal targets only: a target the shell computes is wall two's business. One exception:
-- `command rm` (and `\rm`) bypasses a shell function, and the POSIX shells on this fleet are not all
-- bash, so there is no builtin to intercept. A recursive `command rm` whose target is computed is
-- refused by name rather than silently unguarded.
function M.command(command, cwd)
  local text = tostring(command or '')
  if text == '' then return true end
  local bypass = text:find('%f[%w]command%s+rm[%s]') or text:find('\\rm[%s]')
  for _, target in ipairs(M.targets(text)) do
    local computed = target:find('%$') or target:find('`')
    if bypass and computed then
      return nil, 'path_guard: refusing `command rm`/`\\rm` of a computed target (' .. target
        .. '): it bypasses the runtime guard. Use plain `rm`, which is guarded.'
    end
    if not computed then
      local resolved = target
      if resolved:sub(1, 1) ~= '/' and resolved:sub(1, 1) ~= '~' and not resolved:match('^%a:') and cwd and cwd ~= '' then
        resolved = tostring(cwd) .. '/' .. resolved
      end
      -- A glob is judged by the directory it globs: `rm -rf ~/*` is the home's contents, and the
      -- runtime wall cannot see it because the shell expanded it before `rm` was called.
      local glob_at = resolved:find('[%*%?%[]')
      if glob_at then resolved = resolved:sub(1, glob_at - 1):gsub('/+$', '') end
      local why = M.refusal(resolved)
      if why then return nil, why end
    end
  end
  return true
end

-- --- wall two: the shell prelude ------------------------------------------------------------------
local function sh_quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

function M.prelude()
  local patterns, seen = {}, {}
  local function pattern(form)
    local quoted = sh_quote(form)
    if not seen[quoted] then seen[quoted] = true; patterns[#patterns + 1] = quoted end
  end
  for _, root in ipairs(M.protected()) do
    if root ~= '/' then pattern(root) end
  end
  -- The node's own state is refused as a subtree: nothing legitimate lives under it that a command
  -- should remove wholesale.
  for _, root in ipairs(M.state_roots()) do
    pattern(root)
    pattern(root .. '/*')
  end
  local case_patterns = table.concat(patterns, '|')
  local Z = SENTINEL
  return table.concat({
    -- `builtin command` so the helpers never re-enter the `command()` override defined below; without
    -- it `command rm` recursed until the operation deadline killed it (measured 11/11 on this branch).
    Z .. '_x() { if [ -n "${BASH_VERSION:-}" ]; then builtin command "$@"; else command "$@"; fi; }',
    'if ' .. Z .. '_x -v realpath >/dev/null 2>&1; then ' .. Z .. '_r() { ' .. Z .. '_x realpath -m -- "$1" 2>/dev/null || printf "%s" "$1"; }; '
      .. 'else ' .. Z .. '_r() { case "$1" in /*) printf "%s" "$1";; *) printf "%s/%s" "$PWD" "$1";; esac; }; fi',
    Z .. '_p() { ' .. Z .. '_t="$1"; ' .. Z .. '_v=$(' .. Z .. '_r "$' .. Z .. '_t"); '
      .. 'case "$' .. Z .. '_v" in ' .. case_patterns .. ') '
      .. 'printf "path_guard: refusing to delete %s: it is or contains a protected path.\\n" "$' .. Z .. '_t" >&2; return 1;; esac; return 0; }',
    Z .. '_rm() { ' .. Z .. '_c=0; for ' .. Z .. '_a in "$@"; do case "$' .. Z .. '_a" in -*) case "$' .. Z .. '_a" in *[rR]*) ' .. Z .. '_c=1;; esac;; esac; done; '
      .. 'if [ "$' .. Z .. '_c" = 1 ]; then for ' .. Z .. '_a in "$@"; do case "$' .. Z .. '_a" in -*) ;; *) ' .. Z .. '_p "$' .. Z .. '_a" || return 1;; esac; done; fi; '
      .. Z .. '_x rm "$@"; }',
    'rm() { ' .. Z .. '_rm "$@"; }',
    'rmdir() { for ' .. Z .. '_a in "$@"; do case "$' .. Z .. '_a" in -*) ;; *) ' .. Z .. '_p "$' .. Z .. '_a" || return 1;; esac; done; ' .. Z .. '_x rmdir "$@"; }',
    'find() { ' .. Z .. '_d=0; for ' .. Z .. '_a in "$@"; do [ "$' .. Z .. '_a" = "-delete" ] && ' .. Z .. '_d=1; done; '
      .. 'if [ "$' .. Z .. '_d" = 1 ]; then for ' .. Z .. '_a in "$@"; do case "$' .. Z .. '_a" in -*) break;; *) ' .. Z .. '_p "$' .. Z .. '_a" || return 1;; esac; done; fi; '
      .. Z .. '_x find "$@"; }',
    -- `command rm` walks past a function; in bash the builtin can be intercepted. In a plain POSIX sh it
    -- cannot, and the static wall is what remains.
    'if [ -n "${BASH_VERSION:-}" ]; then command() { if [ "$1" = "rm" ]; then shift; ' .. Z .. '_rm "$@"; '
      .. 'elif [ "$1" = "rmdir" ]; then shift; rmdir "$@"; else builtin command "$@"; fi; }; fi',
  }, '\n')
end

function M.deletes(command)
  local text = tostring(command or '')
  if text == '' then return false end
  return text:find('%f[%w]rm%f[%W]') ~= nil or text:find('%f[%w]rmdir%f[%W]') ~= nil
    or text:find('%-%-delete') ~= nil or text:find('Remove%-Item') ~= nil
    or text:find('%f[%w]del%f[%W]') ~= nil or text:find('%f[%w]rd%f[%W]') ~= nil
end

-- The command a POSIX shell should run: unchanged unless it deletes, and never wrapped twice.
function M.wrap(command)
  local text = tostring(command or '')
  if text == '' or text:find(SENTINEL, 1, true) then return text end
  if M.shell() ~= 'posix' then return text end
  if not M.deletes(text) then return text end
  return M.prelude() .. '\n' .. text
end

function M.refusal_json(reason)
  local json = dofile('lua/vendor/json.lua')
  return json.encode({ ok = false, code = 126, blocked_by = 'path_guard', error = reason,
    stdout = '', stderr = reason, effect = 'none' })
end

-- A refusal from wall two is the guard talking too, and it must answer in the same shape as wall one.
-- Wall one refuses the text it can read and returns `blocked_by=path_guard`; wall two refuses inside the
-- shell, so what comes back is an ordinary failed command whose stderr names the guard. A caller that
-- reads `blocked_by` (the bash tool, a test, an agent deciding whether to retry) then had to parse a
-- message for the one wall and not the other - and the shipped canary failed on exactly that: the delete
-- WAS refused, and the result did not say so. Naming it here, once, is what makes both walls one answer.
--
-- Narrowed to a command that deletes something, so a command that merely prints the prefix is not
-- relabelled; the real code, stderr and effect are kept, because part of a command may well have run.
local RUNTIME_REFUSAL = 'path_guard: refusing'

function M.blocked(command, result)
  if type(result) ~= 'string' or not M.deletes(command) then return result end
  if not result:find(RUNTIME_REFUSAL, 1, true) then return result end
  local json = dofile('lua/vendor/json.lua')
  local decoded_ok, decoded = pcall(json.decode, result)
  if not decoded_ok or type(decoded) ~= 'table' or decoded.blocked_by then return result end
  decoded.blocked_by = 'path_guard'
  decoded.blocked_reason = tostring(decoded.stderr or ''):match('path_guard:[^\n]*') or RUNTIME_REFUSAL
  return json.encode(decoded)
end

-- Wrap `host.exec` once: wall one on the text, wall two on the resolved targets.
function M.install(target)
  local host_table = target or host
  if type(host_table) ~= 'table' or type(host_table.exec) ~= 'function' then return false end
  if host_table.__path_guard_installed then return true end
  local raw = host_table.exec
  host_table.exec = function(command, cwd, ...)
    local ok, reason = M.command(command, cwd)
    if not ok then return M.refusal_json(reason) end
    return M.blocked(command, raw(M.wrap(command), cwd, ...))
  end
  host_table.__path_guard_installed = true
  return true
end

return M
