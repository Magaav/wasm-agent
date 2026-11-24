-- `/mcp`'s list: two groups, a mark, a name and a tool count - and `wa mcp list` prints the same rows.
--
-- Victor, 24/11: "we should list wasm-agent built-in MCPs and User MCPs and simplificate just list how many
-- tools it has." This row measures the two halves of that sentence:
--
--   1. WHAT A ROW IS, on the fixture every balloon snapshot is taken from: the two groups in order, one row
--      per connector on this node, a name that is a name (bounded, never a description), a count or the
--      state in at most two words, the same connector on another node folded away, a retired entry folded
--      away, nothing numbered, and no row cut at 80 or at 120 columns.
--   2. THAT THE SAME ROWS COME OUT OF A REAL STORE: a scratch node whose registry is written through
--      `mcp.control` and whose connectors are real local programs (`scripts/fixtures/mcp-peer.mjs`, the same
--      one scripts/test-mcp.lua probes) - one healthy, one whose far end refused a credential - plus a peer
--      connector and a retired entry; and `wa mcp list` prints exactly what `/mcp` draws.
--
-- The store is the node's own: `memory.setup()` applies `lua/core/schema.sql` (which is where `meta` comes
-- from), the registry is written by `mcp.control` and read by `mcp.inventory`, and every write goes through
-- the product's own CAS. Nothing here creates a table by hand, and the row REFUSES to run against the
-- operator's real store (`scripts/lib/scratch-home.lua`).
local json = dofile('lua/vendor/json.lua')

local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-mcp-list.lua')
if why_home then print('REFUSED test-mcp-list: ' .. why_home); os.exit(2) end

local checks, failed = 0, 0
local function ok(value, label)
  checks = checks + 1
  if not value then failed = failed + 1; print('FAIL ' .. label) end
end
local function has(text, needle) return tostring(text or ''):find(needle, 1, true) ~= nil end
local function lines_of(text)
  local rows = {}
  for row in (tostring(text or '') .. '\n'):gmatch('([^\n]*)\n') do rows[#rows + 1] = row end
  return rows
end
local function width_of(text)
  local count = 0
  for _ in utf8.codes(tostring(text)) do count = count + 1 end
  return count
end
local function widest(text)
  local most = 0
  for _, row in ipairs(lines_of(text)) do most = math.max(most, width_of(row)) end
  return most
end

local balloon = dofile('lua/core/balloon.lua')
local mcp_list = dofile('lua/core/mcp_list.lua')
local command = dofile('lua/core/mcp_command.lua')

-- ============================================================== 1. what a row is (the fixture)
local fixture = dofile('scripts/lib/balloon-fixture.lua')
do
  local plan = mcp_list.plan(fixture.mcp_view(), { state_label = command.state_label })
  ok(plan.title == 'MCP servers', 'the list is titled MCP servers: ' .. tostring(plan.title))
  ok(plan.lines[1] == '5 servers', 'under it, how many servers it lists: ' .. tostring(plan.lines[1]))
  ok(#plan.sections == 2, 'two groups, no more: ' .. #plan.sections)
  ok(plan.sections[1].heading == 'wasm-agent built-in MCPs' and plan.sections[2].heading == 'User MCPs',
    'in this order: ' .. tostring(plan.sections[1].heading) .. ' | ' .. tostring(plan.sections[2].heading))
  -- The keys, by group: the built-in service and the shipped connector first, the operator's own after.
  local function keys_of(section)
    local keys = {}
    for _, row in ipairs(section.rows) do keys[#keys + 1] = row.key end
    table.sort(keys)
    return table.concat(keys, ',')
  end
  ok(keys_of(plan.sections[1]) == 'mcp-mail,whatsapp',
    'the built-in group holds the service and the connector this agent ships: ' .. keys_of(plan.sections[1]))
  ok(keys_of(plan.sections[2]) == 'gated,native_reads,reports',
    'the user group holds what was added on this node: ' .. keys_of(plan.sections[2]))
  -- One row per connector ON THIS NODE, and the mark of its state.
  local function row_of(key, section)
    for _, row in ipairs(section.rows) do if row.key == key then return row end end
    return nil
  end
  local whatsapp = row_of('whatsapp', plan.sections[1])
  ok(whatsapp and whatsapp.label == '\u{2714} WhatsApp', 'a healthy row is a mark and its name: '
    .. tostring(whatsapp and whatsapp.label))
  ok(whatsapp and whatsapp.hint == '3 tools', 'and how many tools it gives: ' .. tostring(whatsapp and whatsapp.hint))
  local gated = row_of('gated', plan.sections[2])
  ok(gated and gated.label == '! Gated reports', 'an unhealthy row carries the warning mark: '
    .. tostring(gated and gated.label))
  ok(gated and gated.hint == 'needs token', 'and the state in two words, instead of the count: '
    .. tostring(gated and gated.hint))
  ok(row_of('native_reads', plan.sections[2]).hint == 'not reachable', 'a failing connector: '
    .. tostring(row_of('native_reads', plan.sections[2]).hint))
  -- A state word says what is MISSING (Fable, 24/11): the built-in surface with no node holding the account
  -- says `no account`; a registry connector that reported a state nothing recognises keeps its own word,
  -- because its problem is not a missing account.
  ok(mcp_list.state_word('unknown', { key = 'whatsapp', scope = 'built-in', state_label = 'unknown' }) == 'no account',
    'the built-in surface with no account node says what is missing')
  ok(mcp_list.state_word('unknown', { key = 'x', scope = 'local' }) == 'unknown',
    'a registry connector with an unrecognised state keeps its own word')
  ok(mcp_list.tools_phrase(0) == 'no tools', 'a connector with no tool says "no tools": ' .. mcp_list.tools_phrase(0))
  -- A name is a name.
  local long = row_of('reports', plan.sections[2])
  ok(long and width_of(long.name) <= mcp_list.NAME_LIMIT,
    'a name longer than the limit is cut to ' .. mcp_list.NAME_LIMIT .. ': ' .. tostring(long and long.name))
  ok(long and has(long.name, '\u{2026}'), 'and marked as cut, not silently truncated: ' .. tostring(long and long.name))
  ok(not has(long.label, 'MCP reports /'), 'no description ever appears in a row')
  -- The folds: what is not a row of this node.
  local folds = {}
  for _, fold in ipairs(plan.folded) do folds[fold.kind] = fold end
  ok(folds.peers and folds.peers.label == 'On other nodes - 2 hidden', 'the peer connectors are one folded row: '
    .. tostring(folds.peers and folds.peers.label))
  local peer_labels = {}
  for _, row in ipairs(folds.peers.rows) do peer_labels[#peer_labels + 1] = row.name end
  table.sort(peer_labels)
  ok(table.concat(peer_labels, ',') == 'whatsapp_native on mail,whatsapp_native on openclaw',
    'and its page names the connector AND the node: ' .. table.concat(peer_labels, ','))
  ok(folds.retired and folds.retired.label == '1 retired', 'a retired entry is folded too: '
    .. tostring(folds.retired and folds.retired.label))
  ok(folds.retired and #folds.retired.lines == 1 and has(folds.retired.lines[1], 'no longer offered'),
    'and its page says why: ' .. tostring(folds.retired and folds.retired.lines[1]))
end

-- The rendered list at both widths the brief names: nothing numbered, nothing cut.
do
  local set = command.views(fixture.mcp_view())
  local root = set.views[1]
  ok(root.numbered == false, 'the list is not a numbered menu')
  for _, width in ipairs({ 80, 120 }) do
    local text = balloon.text({ root }, width)
    ok(widest(text) <= width, 'at ' .. width .. ' columns no row is cut: widest ' .. widest(text))
    ok(not has(text, '\u{276f}  1.'), 'at ' .. width .. ' nothing is numbered')
    local _, whatsapps = text:gsub('WhatsApp', '')
    ok(whatsapps == 1, 'at ' .. width .. ' WhatsApp is listed once: ' .. whatsapps)
    ok(has(text, 'wasm-agent built-in MCPs') and has(text, 'User MCPs'),
      'at ' .. width .. ' both headings are there')
    for _, gone in ipairs({ 'built-in \u{b7} ', 'MCP \u{b7} ', 'callable now', 'on this node', 'services \u{b7} ' }) do
      ok(not has(text, gone), 'at ' .. width .. ' the row no longer says: ' .. gone)
    end
  end
  -- A heading belongs to the page, not to a row: it never becomes a choice.
  local spec = balloon.panel_spec(root, 1)
  ok(spec.numbered == false, 'the panel is told the list is unnumbered')
  ok(spec.options[1].heading == 'wasm-agent built-in MCPs', 'and carries the heading of the group it starts')
end

-- ============================================================== 2. the same rows, out of a real store
local json_ok, memory = pcall(dofile, 'lua/core/memory.lua')
if not json_ok then print('REFUSED test-mcp-list: the node has no memory module to set its store up with'); os.exit(2) end
memory.setup()
local meta = json.decode(host.sql_query("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'", '[]'))
if not (type(meta) == 'table' and type(meta[1]) == 'table') then
  -- Unknown is not yes: without the product's own table this row cannot prove anything about a real store.
  print('REFUSED test-mcp-list: memory.setup did not create the meta table; this store is not the node\'s')
  os.exit(2)
end
local mcp = dofile('lua/core/mcp.lua')
local federation = dofile('lua/core/federation.lua')
local ctx = { role = 'master', user_id = 'cli', operator = true, session_id = 'mcp-list-fixture' }
local function control(action, extra)
  local args = extra or {}
  args.action = action
  args.expected_revision = mcp.inventory().revision
  return mcp.control(args, ctx)
end
-- Where this tree's scripts are: the fixture server is a real program, launched by the registry's own probe.
local root_dir = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
-- WHICH node runs the fixture: WA_NODE when the environment names one (a deploy exports it), and otherwise the
-- one the resolver in scripts/lib/node-runtime.sh would pick - PATH first, then the places a user's own
-- install lives. A machine with no Node at all gets a REFUSAL by name, never a half-proved row.
local function node_program_path()
  local named = host.getenv('WA_NODE')
  if type(named) == 'string' and named ~= '' and host.path_kind(named) == 'file' then return named end
  local dirs = {}
  for dir in tostring(host.getenv('PATH') or ''):gmatch('[^:]+') do dirs[#dirs + 1] = dir end
  local home = host.getenv('HOME') or ''
  for _, extra in ipairs({ home .. '/.local/bin/node/bin', home .. '/.local/share/mise/shims',
    home .. '/.volta/bin', home .. '/.asdf/shims', '/usr/local/bin', '/usr/bin', '/bin' }) do dirs[#dirs + 1] = extra end
  for _, dir in ipairs(dirs) do
    for _, name in ipairs({ '/node', '/nodejs' }) do
      if host.path_kind(dir .. name) == 'file' then return dir .. name end
    end
  end
  return nil
end
local node_program = node_program_path()
if type(node_program) ~= 'string' or node_program == '' then
  print('REFUSED test-mcp-list: no node runtime was found (WA_NODE, PATH and the usual installs), so no real '
    .. 'probe can run and nothing about a real store would be proved')
  os.exit(2)
end
print('node runtime: ' .. node_program)
local peer_fixture = root_dir .. '/scripts/fixtures/mcp-peer.mjs'
ok(host.read_file and host.read_file(peer_fixture) ~= nil, 'the fixture server is on disk: ' .. peer_fixture)
local put = control('put', { definition = { id = 'healthy', name = 'Healthy', transport = 'stdio',
  program = node_program, args = { peer_fixture }, tools = { echo = 'read' }, timeout_seconds = 30 } })
ok(put.ok == true, 'a real connector is registered through mcp.control: ' .. json.encode(put))
ok(control('probe', { id = 'healthy' }).ok == true, 'and probed by the registry')
ok(control('enable', { id = 'healthy' }).ok == true, 'and turned on, the way the operator turns one on')
local refused = control('put', { definition = { id = 'needs-token', name = 'Bills', transport = 'stdio',
  program = node_program, args = { peer_fixture, 'refuse_token' }, tools = { echo = 'read' }, timeout_seconds = 30 } })
ok(refused.ok == true, 'a second connector is registered: ' .. json.encode(refused))
local probed = control('probe', { id = 'needs-token' })
ok(probed.ok == false or probed.error ~= nil, 'its probe is refused by the far end: ' .. json.encode({ ok = probed.ok, error = probed.error }))
-- A retired row: the registry entry the WhatsApp family leaves behind (its program is gone, the row is not).
ok(control('put', { definition = { id = 'whatsapp_go', name = 'WhatsApp Go connector', transport = 'stdio',
  program = 'wa-whatsapp', args = { 'serve' }, tools = { read_newest = 'read' } } }).ok == true,
  'the retired WhatsApp Go row is in the registry')
-- A peer's answer, kept where `federation.refresh` keeps one. The peer's own code composes it
-- (`federation.connectors`), and there is no seam to inject a transport into a refresh: the wire is
-- unchanged by this mission and is proven by scripts/test-federation.lua and scripts/test-two-node-images.lua.
local exported = federation.connectors()
ok(type(exported) == 'table', 'the peer-side catalogue builder answers')
-- ONE connector on the peer node, which is the capture the brief asks for: the peer exports this node's own
-- 'healthy' connector under its own name, exactly as `federation.connectors` composes it.
local on_the_peer = {}
for _, connector in ipairs(exported) do if connector.id == 'healthy' then on_the_peer[1] = connector end end
ok(#on_the_peer == 1, 'the peer-side catalogue carries the one connector this row puts on a peer node')
local cache = { at = host.now(), peers = { ['peer-mail'] = { name = 'mail', node_id = 'peer-mail', at = host.now(),
  tools = {}, connectors = on_the_peer } } }
local saved = json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
  json.encode({ 'federation.catalog.v2', json.encode(cache) })))
ok(saved.ok == true, 'the catalogue a peer answered is kept where the refresh keeps it: ' .. json.encode(saved))

local view = command.list(ctx, { cache_only = true, counts = false })
ok(view.ok == true, 'the real registry answers a list')
local set = command.views(view)
local root = set.views[1]
local text80 = balloon.text({ root }, 80)
local text120 = balloon.text({ root }, 120)
print('---- capture: wa mcp list at 80 ----')
print(text80)
print('---- capture: the same list at 120 ----')
print(text120)
ok(widest(text80) <= 80, 'the real list fits 80 columns: ' .. widest(text80))
ok(widest(text120) <= 120, 'and 120: ' .. widest(text120))
ok(has(text80, 'MCP servers'), 'the title line is there')
ok(has(text80, 'wasm-agent built-in MCPs'), 'the built-in heading is there')
ok(has(text80, 'User MCPs'), 'the user heading is there')
ok(has(text80, '\u{2714} Healthy'), 'the healthy connector is a check and its name: '
  .. tostring(text80:match('[^\n]*Healthy[^\n]*')))
ok(has(text80, 'needs token'), 'the connector whose far end refused the token says so in two words: '
  .. tostring(text80:match('[^\n]*needs token[^\n]*')))
ok(has(text80, 'On other nodes - '), 'the peer connectors are folded into one row: '
  .. tostring(text80:match('[^\n]*On other nodes[^\n]*')))
ok(has(text80, '1 retired'), 'and the retired entry is folded too: ' .. tostring(text80:match('[^\n]*retired[^\n]*')))
ok(not has(text80, 'WhatsApp Go'), 'the retired row is not one of the two groups')
-- ONE WhatsApp row: the built-in service, and the peer's connector is behind the fold, not beside it.
local _, whatsapps = text80:gsub('WhatsApp', '')
ok(whatsapps <= 1, 'WhatsApp appears at most once in the list: ' .. whatsapps)
-- The rows the page holds are the connectors of this node, each opening its own page.
local detail_titles = {}
for index, page in ipairs(set.views) do detail_titles[index] = page.title end
local rows_opened, rows_total = 0, 0
for _, option in ipairs(root.options) do
  if option.page then
    rows_total = rows_total + 1
    local title = tostring(detail_titles[option.page] or '')
    if title ~= 'On other nodes' and title ~= 'Retired' and title ~= 'Not classified' then rows_opened = rows_opened + 1 end
  end
end
-- One row per connector on this node: the built-in service, the healthy connector and the one whose far
-- end refused its token. The retired entry and the peer's connectors are behind the folds.
local here = 0
for _, entry in ipairs(view.connectors) do
  if entry.scope ~= 'peer' and entry.state ~= 'retired' then here = here + 1 end
end
ok(rows_opened == here, 'one row per connector on this node: ' .. rows_opened .. ' of ' .. here
  .. ' (' .. rows_total .. ' rows with a page, the folds included)')

-- `wa mcp list` is the same list, character for character: one builder, two renderers.
do
  local printed = {}
  local answer = dofile('lua/core/mcp_cli.lua').run_cli({ 'list' }, { print = function(line) printed[#printed + 1] = line end,
    ctx = ctx, list_options = { cache_only = true, counts = false } })
  ok(answer.ok == true, 'wa mcp list answers: ' .. json.encode({ ok = answer.ok, error = answer.error }))
  ok(table.concat(printed, '\n') == text80, 'wa mcp list prints exactly what /mcp draws')
  -- `all` is declared on its own line: a closure created inside the declaration that defines it captures
  -- the global, not the local (the first version of this row did exactly that and indexed nil).
  local all = {}
  local all_answer = dofile('lua/core/mcp_cli.lua').run_cli({ 'list', '--all' },
    { print = function(line) all[#all + 1] = line end, ctx = ctx, list_options = { cache_only = true, counts = false } })
  ok(all_answer.ok == true, 'wa mcp list --all answers')
  ok(has(table.concat(all, '\n'), 'On other nodes') and has(table.concat(all, '\n'), 'retired'),
    'and it prints the pages a pipe cannot open')
  local refused_flag = {}
  local bad = dofile('lua/core/mcp_cli.lua').run_cli({ 'list', '--everything' },
    { print = function(line) refused_flag[#refused_flag + 1] = line end, ctx = ctx })
  ok(bad.ok == false and bad.error == 'mcp_usage' and bad.exit == 2,
    'an argument nothing knows is refused by name: ' .. json.encode(bad))
end

if failed > 0 then
  print('mcp list: ' .. failed .. ' failed of ' .. checks .. ' checks')
  os.exit(1)
end
print('mcp list ok (' .. checks .. ' checks)')
