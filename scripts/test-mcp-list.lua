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
    -- THE RIGHT COLUMN IS ONE COLUMN (24/11). The check mark is three bytes and ONE cell; the plain renderer
    -- used to pad a label with string.format("%-27s"), which pads by BYTES, so a check row's hint started two
    -- cells to the left of a warning row's (measured on the 80-column capture: head chars 28 vs 30).
    -- Measured on the drawn rows: each row's own hint is found in the text, and the column it starts in is
    -- counted in characters to its left. A hint that ends a row of the list is a right column.
    local columns, rendered = {}, lines_of(text)
    for _, option in ipairs(root.options) do
      local hint = tostring(option.hint or '')
      if hint ~= '' then
        for _, row in ipairs(rendered) do
          local at = row:find(hint, 1, true)
          if at and at > 1 and row:sub(-#hint) == hint then
            columns[#columns + 1] = width_of(row:sub(1, at - 1)) + 1
            break
          end
        end
      end
    end
    local same = true
    for _, column in ipairs(columns) do if column ~= columns[1] then same = false end end
    ok(#columns >= 2 and same, 'at ' .. width .. ' columns every right column starts in the same cell: '
      .. table.concat(columns, ','))
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
  -- ONE LIST, TWO RENDERERS, still character for character (25/11). Two lines belong to the SURFACE and not
  -- to the list: the age line names the verb that surface answers to ("/mcp refresh" in a chat,
  -- "wa mcp list --refresh" in a pipe), and a pipe has no keys, so the panel's key hint row is not printed
  -- there. Every other row must be identical, in the same order - that is what this row proves instead of a
  -- whole-text comparison that the two deliberate lines would break.
  local function rows_without_surface_lines(text)
    local rows, age = {}, nil
    for _, row in ipairs(lines_of(text)) do
      if has(row, 're-reads them') then age = row
      elseif row ~= balloon.hint_for(root) then rows[#rows + 1] = row end
    end
    -- The hint is a block: a blank row and then the hint row. Removing the hint row leaves that blank
    -- behind in the chat's text and nowhere in the pipe's, so the trailing blank goes with it - both texts
    -- end on their last row.
    while #rows > 0 and rows[#rows] == '' do table.remove(rows) end
    return rows, age
  end
  local chat_rows, chat_age = rows_without_surface_lines(text80)
  local cli_rows, cli_age = rows_without_surface_lines(table.concat(printed, '\n'))
  ok(table.concat(cli_rows, '\n') == table.concat(chat_rows, '\n'),
    'wa mcp list prints the same rows as /mcp draws, in the same order')
  ok(has(chat_age or '', '/mcp refresh re-reads them'), 'the balloon names its own refresh verb: ' .. tostring(chat_age))
  ok(has(cli_age or '', 'wa mcp list --refresh re-reads them'), 'and the pipe names the one it can run: ' .. tostring(cli_age))
  ok(has(text80, 'Enter opens a connector \u{b7} Esc or \u{2190} closes'),
    'the panel keeps its key hint: a chat has a keyboard')
  ok(not has(table.concat(printed, '\n'), 'Esc or \u{2190}'), 'a pipe is not told about keys it does not have')
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

-- ================================================= 3. the list never asks another node (25/11)
--
-- The brief: "Budget: the local list in under 200 ms. Whatever needs another node is cached, or arrives
-- after; it never blocks the first paint." Measured before this section existed: "wa mcp list" 3.5 s and
-- 6.4 s on the laptop and 3.4 s here - the federation catalogue re-read whenever its ten-minute cache was
-- old, and the WhatsApp row asking the account node for its chat count on every run (2.3 s on avell).
--
-- Two things are proved here, and neither is a wall-clock guess:
--   * STRUCTURAL: with a catalogue that is an hour old, a read (the operator's own `wa mcp list`, no flags)
--     leaves that catalogue exactly as old as it found it - the rows come from the cache and no peer is
--     asked. Before this round the same call refreshed it (the age would reset), which is what makes this
--     row fail there.
--   * SAID OUT LOUD: the same output carries how old the peer half is and the verb that re-reads it, so a
--     cached answer is visible on the screen instead of implied by a fast one.
-- A wall-clock ceiling is asserted too, generous on purpose (this suite runs beside a build on a shared
-- machine): the measured figure is printed, and the failure that matters - waiting on a peer - is caught by
-- the catalogue's age, not by a stopwatch a loaded node can trip.
do
  local mcp_cli = dofile('lua/core/mcp_cli.lua')
  local federation_now = dofile('lua/core/federation.lua')
  -- An hour-old catalogue with the peer row section 2 kept, written where the refresh keeps it.
  local stale_at = (tonumber(host.now()) or 0) - 3600
  local aged = { at = stale_at, peers = { ['peer-mail'] = { name = 'mail', node_id = 'peer-mail', at = stale_at,
    tools = {}, connectors = on_the_peer } } }
  local wrote = json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
    json.encode({ 'federation.catalog.v2', json.encode(aged) })))
  ok(wrote.ok == true, 'an hour-old catalogue is in the store: ' .. json.encode(wrote))
  ok(math.abs((tonumber(federation_now.cached().at) or 0) - stale_at) < 1,
    'and it is what this node reads back: ' .. tostring(federation_now.cached().at))

  local lines = {}
  local started = host.now()
  -- NO list_options: this is the operator's own `wa mcp list`, the call whose default is being changed.
  local answer = mcp_cli.run_cli({ 'list' }, { print = function(line) lines[#lines + 1] = line end, ctx = ctx })
  local elapsed_ms = ((host.now()) - started) * 1000
  print(string.format('measured: wa mcp list with an hour-old catalogue %.0f ms', elapsed_ms))
  local text = table.concat(lines, '\n')
  ok(answer.ok == true, 'wa mcp list answers with no flags at all: ' .. json.encode({ ok = answer.ok, error = answer.error }))
  ok(math.abs((tonumber(federation_now.cached().at) or 0) - stale_at) < 1,
    'a read does not refresh the catalogue: read back ' .. tostring(federation_now.cached().at)
      .. ', wrote ' .. tostring(stale_at))
  ok(has(text, 'other nodes: read 1 h 0 min ago'), 'and it says how old the peer rows are: '
    .. tostring(text:match('[^\n]*other nodes[^\n]*')))
  ok(has(text, 'wa mcp list --refresh re-reads them'), 'with the verb that re-reads them: '
    .. tostring(text:match('[^\n]*re-reads[^\n]*')))
  ok(has(text, 'On other nodes - 1 hidden'), 'the peer rows are there, from the cache: '
    .. tostring(text:match('[^\n]*On other nodes[^\n]*')))
  ok(not has(text, 'Esc or \u{2190}'), 'and no key hint ends it: a pipe has no keys')
  ok(elapsed_ms < 1000, string.format('a read of a cached catalogue is under a second: %.0f ms', elapsed_ms))

  -- `/mcp` between runs is the same read: the chat already passes cache_only (chat.lua, 17/11), and the
  -- default is now the same for every caller - only `fresh = true` asks the fleet.
  local chatted = mcp_cli.run('', { ctx = ctx, print = function() end })
  -- `/mcp`'s view is the balloon stack (`mcp_command.views`: command, captured_at, views, view), the same
  -- shape `M.views` answers with - the view it was built from is the one that carries the age.
  local chat_view = type(chatted) == 'table' and chatted.view or nil
  ok(type(chat_view) == 'table' and chat_view.ok == true, '/mcp answers between runs: ' .. json.encode(chatted))
  ok(math.abs((tonumber(federation_now.cached().at) or 0) - stale_at) < 1,
    '/mcp does not refresh the catalogue either: read back ' .. tostring(federation_now.cached().at))
  ok(chat_view and chat_view.peers_age ~= nil, 'and its view carries the age of the peer rows: '
    .. tostring(chat_view and chat_view.peers_age))

  -- THE EXPLICIT VERB, in both spellings. It may wait, and it does the reading.
  local reread = {}
  local refreshed = mcp_cli.run_cli({ 'list', '--refresh' },
    { print = function(line) reread[#reread + 1] = line end, ctx = ctx })
  local refreshed_text = table.concat(reread, '\n')
  ok(refreshed.ok == true, 'wa mcp list --refresh answers: ' .. json.encode({ ok = refreshed.ok, error = refreshed.error }))
  ok(has(refreshed_text, 'catalogue re-read'), 'it says what it re-read: '
    .. tostring(refreshed_text:match('[^\n]*catalogue re-read[^\n]*')))
  ok((tonumber(federation_now.cached().at) or 0) > stale_at,
    'and the catalogue is new after it: ' .. tostring(federation_now.cached().at) .. ' > ' .. tostring(stale_at))

  local chat_lines = {}
  local chat_refresh = mcp_cli.run('refresh', { ctx = ctx,
    print = function(line) chat_lines[#chat_lines + 1] = line end })
  ok(chat_refresh.ok == true, '/mcp refresh answers: ' .. json.encode({ ok = chat_refresh.ok, error = chat_refresh.error }))
  ok(has(table.concat(chat_lines, '\n'), 'catalogue re-read'), 'and says what it re-read: '
    .. tostring(table.concat(chat_lines, '\n')))

  -- The usage names the verb, so a reader who only types `wa mcp list --help` learns it exists.
  local help = {}
  mcp_cli.run_cli({ '--help' }, { print = function(line) help[#help + 1] = line end })
  ok(has(table.concat(help, '\n'), '--refresh'), 'the usage names --refresh: ' .. table.concat(help, ' | '))

  -- An unknown flag is still refused by name (unknown is not yes) - and --refresh did not loosen that.
  local refused = {}
  local bad = mcp_cli.run_cli({ 'list', '--refreshing' },
    { print = function(line) refused[#refused + 1] = line end, ctx = ctx })
  ok(bad.ok == false and bad.error == 'mcp_usage' and bad.exit == 2,
    'a flag nothing knows is refused by name: ' .. json.encode(bad))

  -- NEVER READ IS NOT "NO PEER CONNECTORS" (25/11). A store with no catalogue at all is the state of a node
  -- bound a minute ago: an empty cache and a node with nothing on its peers look the SAME, so the page says
  -- which one it is. A guest's view carries no peer half at all (read_only), so only a master is told.
  local deleted = json.decode(host.sql_exec("DELETE FROM meta WHERE key='federation.catalog.v2'", '[]'))
  ok(deleted.ok == true or deleted.changes ~= nil, 'the catalogue is removed from this store: ' .. json.encode(deleted))
  ok(tonumber(federation_now.cached().at) == nil or tonumber(federation_now.cached().at) == 0,
    'and nothing is read back: ' .. tostring(federation_now.cached().at))
  local never = {}
  mcp_cli.run_cli({ 'list' }, { print = function(line) never[#never + 1] = line end, ctx = ctx })
  local never_text = table.concat(never, '\n')
  ok(has(never_text, 'other nodes: not read yet'), 'a node whose catalogue was never read says so: '
    .. tostring(never_text:match('[^\n]*other nodes[^\n]*')))
  ok(has(never_text, 'wa mcp list --refresh reads them'), 'and names the verb that reads it: '
    .. tostring(never_text:match('[^\n]*not read yet[^\n]*')))
  ok(not has(never_text, 'other nodes: read '), 'it does not pretend to an age it does not have')
  local guest = {}
  mcp_cli.run_cli({ 'list' }, { print = function(line) guest[#guest + 1] = line end,
    ctx = { role = 'guest', user_id = 'guest' } })
  ok(not has(table.concat(guest, '\n'), 'other nodes:'),
    'a guest is not told about a peer half its view does not show: '
      .. tostring(table.concat(guest, '\n'):match('[^\n]*other nodes[^\n]*')))
end

if failed > 0 then
  print('mcp list: ' .. failed .. ' failed of ' .. checks .. ' checks')
  os.exit(1)
end
print('mcp list ok (' .. checks .. ' checks)')
