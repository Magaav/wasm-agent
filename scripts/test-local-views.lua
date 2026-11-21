-- A local view that crosses to the client fits the client's limits, and a builder that forgets does
-- not cost the reader the panel.
--
-- The finding (Victor, 21/11): every run printed
--   ! the run view failed: local views: /nodes was not published: line_too_long views[2].lines[3]:
--   3030 characters
-- and there was no node page at all. `lua/core/nodes_cli.lua⟫ joined all of a node's capabilities on
-- one "Tools: ..." line (143 names on a work node) and its endpoints on another;
-- `rust/wa-cli-views/src/spec.rs⟫ refuses a WHOLE view whose line passes MAX_LINE_CHARS (400
-- characters). The limit is the client's, so the wrap lives in `lua/core/view_lines.lua⟫ and every
-- builder that can produce a long line uses it - and `balloon.publish⟫ wraps every page as the last
-- resort, so a builder that forgets is a test failure here instead of a blank panel at run time.
--
-- What this holds:
--   * the reported node (143 capabilities, three endpoints) publishes through the REAL host channel
--     (`host.local_view⟫, so the actual Rust check runs - not a stub that would accept anything);
--   * a line over the limit is wrapped by the channel, never refused;
--   * every builder that can produce a long line - `/nodes⟫, `/mcp⟫, `/help⟫, `/keybindings⟫,
--     `/login⟫ - has no line over the limit, and no title or option label over the client's own caps;
--   * the wrap counts CHARACTERS, the number the client counts, and loses no fact.
--
-- Hermetic: no rendezvous, no model, no network (`/mcp⟫ is built from a synthetic connector, `/nodes⟫
-- from a synthetic node), and it refuses the real ~/.wasm-agent before it reads anything.
local function refuse(why) print("REFUSED test-local-views: " .. why); os.exit(2) end
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-local-views")
if why_home then refuse(why_home) end

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

local view_lines = dofile("lua/core/view_lines.lua")
local balloon = dofile("lua/core/balloon.lua")
local nodes_cli = dofile("lua/core/nodes_cli.lua")
local local_views = dofile("lua/core/local_views.lua")
local mcp_command = dofile("lua/core/mcp_command.lua")

-- The node from the report: a work node with its two MCP servers, 143 tools in all.
local TOOLS = {}
for index = 1, 143 do TOOLS[index] = string.format("mcp_google_imap_get_message_%03d", index) end
local function big_node()
  return {
    node_id = "bfad4f8fbe59a1b2", name = "work", role = "worker", local_node = false, online = true,
    endpoints = { { url = "http://10.0.0.4:8787" }, { url = "http://10.0.0.4:8788" },
      { url = "quic://10.0.0.4:4433" } },
    capabilities = TOOLS,
  }
end

local function widest(lines)
  local most = 0
  for _, line in ipairs(lines or {}) do most = math.max(most, view_lines.count(line)) end
  return most
end

-- ---- the one module that knows the limit -------------------------------------------------------
local wrapped = view_lines.list("Tools: ", TOOLS)
ok(#wrapped > 1, "143 tool names are more than one line (got " .. #wrapped .. ")")
ok(widest(wrapped) <= view_lines.MAX,
  "and every line is inside the client's " .. view_lines.MAX .. " (widest " .. widest(wrapped) .. ")")
ok(wrapped[1]:sub(1, 7) == "Tools: ", "the first line keeps the row's label: " .. tostring(wrapped[1]:sub(1, 20)))
ok(wrapped[2]:sub(1, 2) == "  ", "a continuation line is indented, so the row still reads as one row")
local rejoined = table.concat(wrapped, " ")
local missing
for _, name in ipairs(TOOLS) do if not rejoined:find(name, 1, true) then missing = name end end
ok(missing == nil, "no tool name is lost by the wrap (missing " .. tostring(missing) .. ")")
local hard = view_lines.wrap_line(string.rep("x", 900))
ok(#hard == 3 and widest(hard) <= view_lines.MAX,
  "a line with no separator to break at is cut, never refused (got " .. #hard .. " lines)")
local wide = view_lines.wrap_line(string.rep("\195\161", 500))
ok(widest(wide) <= view_lines.MAX and view_lines.count(wide[1]) == view_lines.MAX,
  "a multi-byte line is counted in characters, as the client counts them (first line "
    .. view_lines.count(wide[1]) .. ")")

-- ---- the reported case, through the real client check ------------------------------------------
ok(local_views.available(), "this binary has the local-view channel, so the real check runs")
local function page(title, lines, options)
  return { title = title, lines = lines, options = options or {}, selected = 1 }
end
local stack = {
  page("Nodes", { "Cluster: none - this node is not bound (/bind to join one)", "1 peer" },
    { { label = "work", hint = "worker \194\183 local \194\183 bfad4f8f", view = 2 } }),
  page("work", nodes_cli.details(big_node()), { { label = "Back", pop = true } }),
}
local done, why = local_views.publish("/nodes", { command = "/nodes", captured_at = host.now(), views = stack })
ok(done, "a node with 143 tools publishes instead of being refused: " .. tostring(why))
ok(widest(nodes_cli.details(big_node())) <= view_lines.MAX,
  "its Tools row is inside the limit (widest " .. widest(nodes_cli.details(big_node())) .. ")")

-- A builder that composes a long line itself still hands the reader a panel: the channel wraps, it
-- does not refuse. This is the property that keeps a cosmetic bug from costing a page.
local netted, net_why = local_views.publish("/help", { command = "/help", captured_at = host.now(),
  views = { page("Help", { string.rep("a", 900) }) } })
ok(netted, "a builder line over the limit is wrapped by the channel: " .. tostring(net_why))

-- ---- every builder that can produce a long line ------------------------------------------------
-- The client's caps, from rust/wa-cli-views/src/spec.rs: a line is 400 characters, a title 120 and an
-- option's label 200. A page that passes here cannot be refused for its length.
local function scan(label, pages)
  local count, over, titles, labels = 0, 0, 0, 0
  for _, entry in ipairs(pages or {}) do
    count = count + 1
    if widest(entry.lines) > view_lines.MAX then over = over + 1 end
    if view_lines.count(entry.title or "") > 120 then titles = titles + 1 end
    for _, option in ipairs(entry.options or {}) do
      if view_lines.count(option.label or "") > 200 then labels = labels + 1 end
    end
  end
  ok(count > 0, label .. " builds at least one page")
  ok(over == 0, label .. ": no line over " .. view_lines.MAX .. " (over: " .. over .. ")")
  ok(titles == 0, label .. ": no title over the client's 120 (over: " .. titles .. ")")
  ok(labels == 0, label .. ": no option label over the client's 200 (over: " .. labels .. ")")
  return pages
end

-- `/mcp⟫: a tool whose input is wide enough to fill a line, and a note longer than one. The schema is
-- the shape the report's connector really carries (many fields), not an empty fixture.
local fields = {}
for index = 1, 60 do fields[string.format("field_%02d", index)] = { type = "string" } end
local connectors = {
  { key = "colmeio-cloud", where = "work", type = "MCP", scope = "local", enabled = true,
    transport = "http", node_phrase = "on work", approval = "approved", tool_count = 2,
    approved = 2, discovered = 2,
    note = string.rep("a connector note that is longer than one line of the panel ", 12),
    tools = {
      { tool = "colmeio.cloud.bills.create", approval = "approved", published = true,
        note = string.rep("note ", 200), schema = { properties = fields } },
    } },
}
local mcp_ok, mcp_pages = pcall(mcp_command.views, { connectors = connectors,
  counts = { services = 1, built_in = 0, mcp = 1, enabled = 1, tools = 2 } })
ok(mcp_ok, "/mcp builds its pages: " .. tostring(mcp_pages))
-- `M.views` answers the whole set (`{command, captured_at, views}`), which is what the channel is
-- handed: the pages are its `views`.
if mcp_ok then scan("/mcp", mcp_pages.views) end

-- `/nodes⟫: the reported node's own page, as the builder makes it.
scan("/nodes", { page("work", nodes_cli.details(big_node())) })

-- `/help⟫: the command registry, page by page.
local help_ok, help_rows = pcall(function() return dofile("lua/core/commands.lua").help() end)
ok(help_ok and type(help_rows) == "string", "/help has rows to page")
if help_ok and type(help_rows) == "string" then
  local rows = {}
  for row in (help_rows .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
  scan("/help", balloon.paged("Help", rows, { per = 14, nowrap = true }))
end

-- `/keybindings⟫: the key table the console dispatches on.
local keys = dofile("lua/core/keybindings.lua")
local key_ok, key_rows = pcall(keys.rows)
if key_ok and key_rows then
  local built, key_pages = pcall(keys.view, key_rows)
  ok(built, "/keybindings builds its pages: " .. tostring(key_pages))
  if built then scan("/keybindings", key_pages) end
else
  -- Not a skip: the rows come from `host.keybindings⟫, which this binary has. A missing table is the
  -- same failure as a page that does not build, and saying so is the difference between a check and a
  -- hope.
  ok(false, "/keybindings has rows to page (got " .. tostring(key_rows) .. ")")
end

-- `/login⟫: one page per provider the node knows, plus the list.
local manager = dofile("lua/core/provider_management.lua")
local login_ok, login_pages = pcall(manager.login_views, manager.state("local-operator"), {})
ok(login_ok, "/login builds its pages: " .. tostring(login_pages))
if login_ok and type(login_pages) == "table" then scan("/login", login_pages) end

if failed > 0 then print("local views: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("local views ok (" .. checks .. " checks)")
