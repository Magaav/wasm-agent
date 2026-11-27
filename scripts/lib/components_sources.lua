-- The source side of a component pin: which files reach a component's bytes, and one digest of them.
--
-- Why content and not commits (mission fix-components-lock-email-whatsapp, measured): on 26/11 `33f1eeec`
-- changed `rust/wa-queue` (linked by BOTH wa-email and wa-whatsapp) and the WhatsApp sources without
-- repinning, and the merge that wrote the wa-whatsapp pin line took it from the other side - so the pin
-- looked NEWER than its sources while describing older bytes. A guard built on commit times passes that
-- tree; this one does not, because it hashes the files the pin is supposed to describe.
--
-- The digest is over every file of the component's closure (its own crate, plus every crate it path-depends
-- on, transitively), as sorted `path\t<file sha256>` lines. Nothing else is in it: a comment or a test does
-- count, because it is in the crate the wasm is built from, and a rule with an exception list is a rule
-- nobody can apply.
local json = dofile('lua/vendor/json.lua')
local M = {}

-- Directories a build never reads: a target tree, or a bundled artifact directory.
local SKIP = { target = true, build = true, ['node_modules'] = true, ['.git'] = true }

local function read(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local text = file:read('a')
  file:close()
  return text
end

local function list_dir(path)
  -- `host.list` when the interpreter has it; `ls` otherwise. Sorted, so the digest does not depend on order.
  local entries = {}
  if type(host.list) == 'function' then
    local ok, answer = pcall(host.list, path)
    if ok and type(answer) == 'table' then
      for _, entry in ipairs(answer) do
        entries[#entries + 1] = type(entry) == 'table' and tostring(entry.name or '') or tostring(entry)
      end
    end
  end
  if #entries == 0 then
    local out = host.exec("ls -1 " .. string.format('%q', path) .. ' 2>/dev/null', '', 60)
    local decoded = type(out) == 'string' and json.decode(out) or out
    local stdout = type(decoded) == 'table' and tostring(decoded.stdout or '') or ''
    for line in stdout:gmatch('[^\n]+') do entries[#entries + 1] = line end
  end
  table.sort(entries)
  return entries
end

local function is_dir(path)
  local out = host.exec('[ -d ' .. string.format('%q', path) .. ' ] && echo yes || echo no', '', 30)
  local decoded = type(out) == 'string' and json.decode(out) or out
  local stdout = type(decoded) == 'table' and tostring(decoded.stdout or '') or ''
  return stdout:find('yes', 1, true) ~= nil
end

-- Every file under `dir`, recursively, as paths relative to the repository root.
function M.files(dir)
  local found = {}
  local function walk(rel)
    for _, entry in ipairs(list_dir(rel)) do
      if entry ~= '' and not SKIP[entry] then
        local path = rel .. '/' .. entry
        if is_dir(path) then walk(path) else found[#found + 1] = path end
      end
    end
  end
  walk(dir)
  table.sort(found)
  return found
end

-- A component's closure: its own crate, plus every crate it path-depends on, transitively. A component lives
-- at `rust/components/<name>`; a path dependency names a crate, which resolves to `rust/<crate>`.
function M.closure(name)
  local dirs, seen, queue = {}, {}, { 'rust/components/' .. name }
  while #queue > 0 do
    local dir = table.remove(queue, 1)
    if not seen[dir] then
      seen[dir] = true
      local manifest = read(dir .. '/Cargo.toml')
      if manifest then
        dirs[#dirs + 1] = dir
        for target in manifest:gmatch('path%s*=%s*"([^"]+)"') do
          local crate = target:match('([%w_%-]+)$')
          if crate and crate:match('^wa%-') then queue[#queue + 1] = 'rust/' .. crate end
        end
      end
    end
  end
  return dirs
end

-- The one digest a pin's `# SOURCES` line carries, and the files it was taken over.
function M.digest(name)
  local Dirs = M.closure(name)
  if #Dirs == 0 then return nil, {} end
  local lines, files = {}, {}
  for _, dir in ipairs(Dirs) do
    for _, path in ipairs(M.files(dir)) do
      local text = read(path)
      if text then
        files[#files + 1] = path
        lines[#lines + 1] = path .. '\t' .. tostring(host.sha256(text))
      end
    end
  end
  table.sort(lines)
  return host.sha256(table.concat(lines, '\n')), files
end

-- The pins in a lock file, with the line each one sits on.
function M.pins(lock_text)
  local pins = {}
  local number = 0
  for line in lock_text:gmatch('[^\n]+') do
    number = number + 1
    local name, sha = line:match('^(%S+)%s+(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)')
    if name and sha then pins[#pins + 1] = { name = name, sha = sha, line = number } end
  end
  return pins
end

-- The `# SOURCES <name> <digest>` promises a lock currently makes, by component name.
function M.promises(lock_text)
  local promises = {}
  for line in lock_text:gmatch('[^\n]+') do
    local name, digest = line:match('^#%s*SOURCES%s+(%S+)%s+(%x+)')
    if name then promises[name] = digest end
  end
  return promises
end

return M

