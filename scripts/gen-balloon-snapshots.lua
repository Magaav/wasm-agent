-- Regenerate `tests/snapshots/balloon/`: the screen `/mcp` and `/login` show at 80x24, as text.
--
--   lua5.4 scripts/gen-balloon-snapshots.lua          (or: wa scripts/gen-balloon-snapshots.lua)
--
-- The snapshots are compared by `scripts/test-cli-balloon.lua`, so a change to what a reader sees is a diff
-- in this directory and nowhere else. `nowrap`/width are pinned at 80 because that is the terminal the
-- operator asked for; a narrower terminal is covered by the fitting tests, not by a second snapshot of every
-- screen.
-- The clock and nothing else: a snapshot may not depend on when it was taken. Inside the binary `host`
-- exists already; under plain `lua5.4` it has to be stood up for `host.now`.
local root = os.getenv('WA_ROOT') or '.'
if type(host) ~= 'table' then host = { now = function() return 1762700000 end } end
local function load(path) return dofile(root .. '/' .. path) end

local balloon = load('lua/core/balloon.lua')
local fixture = load('scripts/lib/balloon-fixture.lua')
local mcp = load('lua/core/mcp_command.lua')
local providers = load('lua/core/provider_management.lua')

local WIDTH = 80
local dir = root .. '/tests/snapshots/balloon'

local files = {}
local function snapshot(name, text)
  files[#files + 1] = { name = name, text = (text:gsub('%s+$', '')) .. '\n' }
end

-- ---- /mcp, AFTER: the balloon the reader walks (one screen, then a connector, then its tools) ----------
local set = mcp.views(fixture.mcp_view())
snapshot('mcp-list-80x24.txt', balloon.text({ set.views[1] }, WIDTH))
-- The connector that is connected, with its actions underneath.
local whatsapp = 2
snapshot('mcp-detail-80x24.txt', balloon.text({ set.views[whatsapp] }, WIDTH))
snapshot('mcp-tools-80x24.txt', balloon.text({ set.views[whatsapp + 1] }, WIDTH))
-- The connector that needs a credential: the state word, the error in full, the sign-in action.
for index, page in ipairs(set.views) do
  if page.title:sub(1, 5) == 'gated' then snapshot('mcp-needs-login-80x24.txt', balloon.text({ page }, WIDTH)) end
end

-- ---- /login, AFTER: the provider list, then one provider -----------------------------------------------
local login = providers.login_views(fixture.provider_state(), {})
snapshot('login-list-80x24.txt', balloon.text({ login[1] }, WIDTH))
snapshot('login-provider-80x24.txt', balloon.text({ login[2] }, WIDTH))

-- ---- write --------------------------------------------------------------------------------------------
local written = 0
for _, file in ipairs(files) do
  local handle = io.open(dir .. '/' .. file.name, 'wb')
  if not handle then error('cannot write ' .. dir .. '/' .. file.name) end
  handle:write(file.text)
  handle:close()
  written = written + 1
  io.write(string.format('%-32s %d rows\n', file.name, select(2, file.text:gsub('\n', ''))))
end
io.write(string.format('%d snapshots in %s\n', written, dir))
