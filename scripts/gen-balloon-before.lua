-- Regenerate `tests/snapshots/balloon/before-*.txt`: what `/mcp` and `/login` showed BEFORE this change,
-- rendered by the same text renderer so the two can be compared line for line.
--
--   WA_BEFORE=<base sha> lua5.4 scripts/gen-balloon-before.lua
--
-- The old code is not kept in the tree (that is the point), so it is taken from git: the two files whose
-- *drawing* was replaced are read out of the base commit into a scratch directory and called with the same
-- fixture the after snapshots use. `/mcp` printed through `mcp_command.text`/`detail_text`; `/login` built
-- a panel spec per step, so the old `login_cli` is driven with a capturing `io.panel` and its FIRST spec is
-- rendered - the list the reader saw when they typed `/login`.
local base = os.getenv('WA_BEFORE')
if not base or base == '' then error('WA_BEFORE=<base commit> is required') end
local root = os.getenv('WA_ROOT') or '.'
if type(host) ~= 'table' then host = { now = function() return 1762700000 end } end

local scratch = os.tmpname() .. '-balloon-before'
os.execute('mkdir -p ' .. scratch)
local function from_git(path)
  local out = scratch .. '/' .. (path:gsub('.*/', ''))
  local ok = os.execute(string.format("git -C %s show '%s:%s' > %s", root, base, path, out))
  if ok ~= 0 and ok ~= true then error('git show failed for ' .. path) end
  return out
end

local balloon = dofile(root .. '/lua/core/balloon.lua')
local fixture = dofile(root .. '/scripts/lib/balloon-fixture.lua')
local width = 80
local dir = root .. '/tests/snapshots/balloon'
local files = {}

-- ---- BEFORE: /mcp's printed table and its prose detail ------------------------------------------------
local old_mcp = dofile(from_git('lua/core/mcp_command.lua'))
files[#files + 1] = { name = 'before-mcp-list-80x24.txt', text = old_mcp.text(fixture.mcp_view()) }
files[#files + 1] = { name = 'before-mcp-detail-80x24.txt', text = old_mcp.detail_text(fixture.mcp_view().connectors[1]) }
files[#files + 1] = { name = 'before-mcp-needs-login-80x24.txt',
  text = old_mcp.detail_text(fixture.mcp_view().connectors[4]) }

-- ---- BEFORE: /login's first panel ----------------------------------------------------------------------
local old_providers = dofile(from_git('lua/core/provider_management.lua'))
-- The one thing that changes: where the provider rows come from. The drawing code below it is the old one.
old_providers.state = function() return fixture.provider_state() end
local captured
old_providers.login_cli({ print = function() end, paint = function(text) return text end,
  ask = function() return nil end,
  panel = function(spec) captured = captured or spec; return { action = 'cancel' } end })
local written = 0
if captured then
  -- One provider page too, which is what the old code opened when the reader chose a row.
  files[#files + 1] = { name = 'before-login-list-80x24.txt', text = balloon.text({ balloon.page(captured) }, width) }
  local pages = {}
  local ok = pcall(function()
    old_providers.login_cli({ print = function() end, panel = function(spec)
      pages[#pages + 1] = spec
      if #pages == 1 then return { action = 'select', index = 1 } end
      return { action = 'cancel' }
    end })
  end)
  if ok and pages[2] then
    files[#files + 1] = { name = 'before-login-provider-80x24.txt', text = balloon.text({ balloon.page(pages[2]) }, width) }
  end
end

for _, file in ipairs(files) do
  local handle = io.open(dir .. '/' .. file.name, 'wb')
  if not handle then error('cannot write ' .. dir .. '/' .. file.name) end
  handle:write((tostring(file.text):gsub('%s+$', '')) .. '\n')
  handle:close()
  written = written + 1
end
os.execute('rm -rf ' .. scratch)
io.write(string.format('%d before snapshots from %s in %s\n', written, base:sub(1, 8), dir))
