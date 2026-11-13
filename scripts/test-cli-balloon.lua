-- `Balloon`: the one overlay every `wa chat` command draws in.
--
-- What is tested here, and why each part can only be tested here or in Rust:
--
--  * the component itself - keys (a scripted panel), the stack (Enter opens, Esc/Back returns, Esc at the
--    root closes), a field's submit, a `run` option, `start`, a resize and a narrow terminal - with a fake
--    panel, because a real one needs a console;
--  * `text`, the same pages for a pipe, and that nothing it renders is wider than the terminal it was
--    rendered for;
--  * the mid-run channel: `publish` hands the host the pages with 0-based `view` links and the `run` lines
--    the client may queue, and never an `act` it could not run. The client's own side (route/answer, the
--    queue) is `rust/wa-cli-views/tests/console_reader.rs`: it runs on the reader thread, in another
--    process from this one;
--  * the snapshots of `/mcp` and `/login` at 80x24, so a change to what a reader sees is a diff in
--    `tests/snapshots/balloon/` and nowhere else;
--  * the structural rule the mission rests on: a command that draws outside the component fails a test.
--    `lua/core/chat.lua`'s command block is scanned for a bare `print(`, `host.panel` or `io.write`.
--
-- Hermetic: no node, no model, no network, no registry - the fixture in `scripts/lib/balloon-fixture.lua`.
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function has(text, needle)
  return type(text) == "string" and text:find(needle, 1, true) ~= nil
end
local function lines_of(text)
  local rows = {}
  for row in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
  return rows
end
-- Characters, not bytes: an ellipsis is one column and three bytes.
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

-- The clock and the host, stood up before the component loads: `host.now` and `host.panel` are what a real
-- run has, and `host.local_view` is what this binary may or may not have.
local clock = 1762700000
local published, panel_specs = {}, {}
local scripted = {}
-- The real host, with three fields taken over: the rest (getenv, paths, the clock the node runs on) is
-- what makes this a row inside the binary rather than a simulation of one.
local native_host = host
host = setmetatable({
  now = function() return clock end,
  monotonic_ms = function() return clock * 1000 end,
  panel = function(text)
    if text == nil then return json.encode({ action = "closed" }) end
    local spec = json.decode(text)
    panel_specs[#panel_specs + 1] = spec
    local answer = table.remove(scripted, 1) or { action = "cancel" }
    return json.encode(answer)
  end,
  local_view = function(name, text)
    published[#published + 1] = { name = name, spec = json.decode(text) }
    local spec = json.decode(text)
    return json.encode({ ok = true, command = name, views = #spec.views, captured_at = spec.captured_at })
  end,
}, { __index = native_host })

local balloon = dofile("lua/core/balloon.lua")
local fixture = dofile("scripts/lib/balloon-fixture.lua")
local mcp = dofile("lua/core/mcp_command.lua")
local providers = dofile("lua/core/provider_management.lua")

-- ---------------------------------------------------------------- the component, and the keys

ok(balloon.available(), "the host's panel is the component's renderer")
ok(balloon.publishing(), "the host can hold a published balloon")
ok(not balloon.interactive({ editor = true }), "an editor without a console is not interactive")

-- The pages one command shows: a list with two rows, each opening a page with its own actions.
local function pages()
  return {
    balloon.page({ title = "Servers", lines = { "2 servers" },
      options = { { label = "one", hint = "connected", page = 2 }, { label = "two", hint = "failed", page = 3 } } }),
    balloon.page({ title = "one", lines = { "where: this node" },
      options = { { label = "Tools", page = 3 }, { label = "Turn off", run = "/mcp one off" },
        { label = "Back", back = true } } }),
    balloon.page({ title = "two", lines = { "where: openclaw" },
      options = { { label = "Back", back = true } } }),
  }
end

-- Enter on the first row, then Esc: the page opened, and one Esc from it came back to the list.
scripted = { { action = "select", index = 1 }, { action = "cancel" }, { action = "cancel" } }
local answer = balloon.flow(pages())
ok(answer.action == "cancel", "Esc at the list closes the balloon: " .. tostring(answer.action))
ok(panel_specs[1] and panel_specs[1].title == "Servers", "the balloon opened on the list")
ok(panel_specs[2] and panel_specs[2].title == "one", "Enter opened the row's page")
ok(panel_specs[3] and panel_specs[3].title == "Servers", "Esc went back to the list, not out of it")
ok(panel_specs[3] and panel_specs[3].selected == 1, "Back landed on the row the reader left, not the top")

-- The `Back` option is the same way back as Esc.
panel_specs = {}
scripted = { { action = "select", index = 2 }, { action = "select", index = 1 }, { action = "cancel" } }
balloon.flow(pages())
ok(panel_specs[2].title == "two" and panel_specs[3].title == "Servers", "the Back option returns one level")

-- An action the client cannot take is returned as the line to queue - and the balloon closes on it.
panel_specs = {}
scripted = { { action = "select", index = 1 }, { action = "select", index = 2 } }
answer = balloon.flow(pages())
ok(answer.action == "run" and answer.line == "/mcp one off",
  "an action comes back as a line for the interpreter: " .. tostring(answer.line))
ok(#panel_specs == 2, "the action closed the balloon: two panels drawn, no third")

-- A number that names no option never closes the balloon on the reader.
scripted = { { action = "select", index = 9 }, { action = "cancel" }, { action = "cancel" } }
panel_specs = {}
ok(balloon.flow(pages()).action == "cancel", "a stray number does not close the balloon")

-- A field: what the reader typed comes back as the page's submit.
panel_specs = {}
scripted = { { action = "submit", text = "sk-test" } }
local field = { balloon.page({ title = "Key", input = "secret", placeholder = "sk-..." }) }
answer = balloon.flow(field)
ok(answer.action == "submit" and answer.text == "sk-test", "a field returns its text to the submit")
ok(panel_specs[1].input == "secret", "the field is a secret: the renderer shows bullets")

-- `start`: `/mcp <key>` opens at that connector, and Back closes because there is nothing behind it.
panel_specs = {}
scripted = { { action = "cancel" }, { action = "select", index = 1 } }
answer = balloon.flow(pages(), { start = 2 })
ok(panel_specs[1].title == "one", "start opens the page, not the root")
ok(answer.action == "cancel", "Back at a page opened by start closes rather than falling to the root")

-- A panel that cannot be opened at all (a pipe, an older binary) is reported, never drawn.
local unsupported = { open = function() return { action = "unsupported" } end, close = function() end }
ok(balloon.flow(pages(), unsupported).action == "unsupported", "no raw editor is an ordinary answer")

-- A resize: the same page at 80, 40 and 24 columns is never wider than the terminal, and a narrow one does
-- not lose the selection mark or the hint row.
for _, width in ipairs({ 80, 40, 24 }) do
  local text = balloon.text({ pages()[1] }, width)
  ok(widest(text) <= width, "at " .. width .. " columns nothing is wider: " .. widest(text))
  ok(has(text, "\u{276f}"), "at " .. width .. " columns the selection is still marked")
  -- A narrow row fits the hint rather than dropping it: "Enter" is the part that must survive.
  ok(has(text, "Enter"), "at " .. width .. " the hint row still says what Enter does")
end
-- The panel's own spec is what a real terminal draws: the width and height are the host's business, and the
-- content it is given is already fitted by `page_text`'s rules (a line is clipped by the renderer).
local spec = balloon.panel_spec(pages()[1], 2)
ok(spec.title == "Servers" and spec.selected == 2, "the renderer is given the page and the reader's row")
ok(#spec.options == 2 and spec.options[1].label == "one", "each row keeps its label and hint")

-- A very long word (a schema, a URL) is cut, never allowed to run off the row.
local long = balloon.page({ title = "x", lines = { string.rep("a", 200) } })
ok(widest(balloon.text({ long }, 40)) <= 40, "a 200-character word is fitted to 40 columns")

-- ---------------------------------------------------------------- the pages /mcp and /login publish mid-run

published = {}
local set = mcp.views(fixture.mcp_view())
ok(set.command == "/mcp", "the /mcp pages are filed under the command that opens them")
ok(#set.views >= 6, "the /mcp balloon has the list, a page per connector and their tools: " .. #set.views)
ok(set.views[1].title == "MCP connectors", "the root is the list")
ok(#set.views[1].options == 4, "one row per connector")

-- The links a client has to understand: a page link is 0-based in the spec, and the run options are the
-- only actions it may take.
local done = balloon.publish("/mcp", set.views, set.captured_at)
ok(done, "the /mcp stack is published")
local sent = published[#published]
ok(sent and sent.name == "/mcp" and sent.spec.captured_at == clock, "published under /mcp, with its age")
local root = sent.spec.views[1]
ok(root.options[1].view == 1, "the first connector's page is the 0-based index 1: " .. tostring(root.options[1].view))
local runs, saw_act = {}, false
for _, view in ipairs(sent.spec.views) do
  for _, option in ipairs(view.options or {}) do
    if option.run then runs[option.run] = true end
    if option.act then saw_act = true end
  end
end
ok(runs["/mcp whatsapp probe"], "a connector's Reconnect is published as the line it queues")
ok(runs["/mcp whatsapp off"], "so is Turn off: the client may queue it, and only the interpreter runs it")
ok(not saw_act, "no page carries an `act` the client could not run")

-- /login publishes the list and a page per provider, and no secret field: a client panel cannot type.
published = {}
local login = providers.login_views(fixture.provider_state(), {})
ok(#login == 4 and login[1].title == "Sign in to a provider", "the /login balloon is the list plus a provider page each")
balloon.publish("/login", login)
local login_spec = published[#published].spec
ok(login_spec.views[1].options[1].view == 1, "the first provider's page is linked")
local typed = false
for _, view in ipairs(login_spec.views) do if view.input then typed = true end end
ok(not typed, "no field is published: a credential is typed at this terminal, never on the client")

-- ---------------------------------------------------------------- the snapshots (80x24)

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local text = handle:read("a")
  handle:close()
  return text
end
local function snapshot(name, text)
  local stored = read_file("tests/snapshots/balloon/" .. name)
  if not stored then
    ok(false, "snapshot " .. name .. " is missing (run scripts/gen-balloon-snapshots.lua)")
    return
  end
  local want = (tostring(text):gsub("%s+$", "")) .. "\n"
  ok(stored == want, "the snapshot " .. name .. " matches what the balloon draws now")
  ok(widest(stored) <= 80, "the snapshot " .. name .. " is 80 columns wide or less: " .. widest(stored))
end

snapshot("mcp-list-80x24.txt", balloon.text({ set.views[1] }, 80))
snapshot("mcp-detail-80x24.txt", balloon.text({ set.views[2] }, 80))
snapshot("mcp-tools-80x24.txt", balloon.text({ set.views[3] }, 80))
for _, page in ipairs(set.views) do
  if page.title:sub(1, 5) == "gated" then snapshot("mcp-needs-login-80x24.txt", balloon.text({ page }, 80)) end
end
snapshot("login-list-80x24.txt", balloon.text({ login[1] }, 80))
snapshot("login-provider-80x24.txt", balloon.text({ login[2] }, 80))

-- What the snapshots say, in assertions a person reads: the words the operator asked for.
local list_text = balloon.text({ set.views[1] }, 80)
for _, word in ipairs({ "connected", "failed", "needs login", "3 tools", "1 tool" }) do
  ok(has(list_text, word), "the list names the state/tool count: " .. word)
end
local needs = nil
for _, page in ipairs(set.views) do if page.title:sub(1, 5) == "gated" then needs = balloon.text({ page }, 80) end end
ok(has(needs, "401 unauthorized: the access token was rejected"), "the detail carries the error in full")
ok(has(needs, "Sign in") and has(needs, "GATED_MCP_TOKEN"), "a refused credential offers the vault key that fixes it")
ok(not has(list_text, "schema"), "no page shows raw JSON")
local tools_text = balloon.text({ set.views[3] }, 80)
ok(has(tools_text, "mcp_whatsapp_read"), "the tools page lists the exact name the model is given")
ok(has(balloon.text({ set.views[4] }, 80), "input: chat, limit") or
  has(balloon.text({ set.views[4] }, 80), "input: limit, chat"), "a tool's input is its fields, not its JSON")
ok(has(balloon.text({ set.views[2] }, 80), "Reconnect"), "a local connector offers Reconnect")
ok(has(balloon.text({ set.views[2] }, 80), "Turn off"), "an enabled connector offers Turn off")

-- ---------------------------------------------------------------- the structural rule

-- Every slash command's arm draws through the component. A bare `print(`, a `host.panel` of its own or an
-- `io.write` inside the command block is exactly the ad-hoc drawing this change removed, so it fails here
-- by line number.
local chat = read_file("lua/core/chat.lua")
ok(chat ~= nil, "lua/core/chat.lua is readable")
local in_commands, checked_arms, offenders = false, 0, {}
if chat then
  for number, source in ipairs(lines_of(chat)) do
    if source:find('elseif line == "/exit"', 1, true) then in_commands = true end
    if in_commands and source:match("^    else%s*$") then in_commands = false end
    if in_commands then
      if source:match("^%s*elseif line") or source:match("^%s*elseif line:") then checked_arms = checked_arms + 1 end
      local bare = source:match("(^[^%-]*[^%w_.]print%s*%()")
      if bare and not source:find("ui.print", 1, true) and not source:find("= print", 1, true) then
        offenders[#offenders + 1] = number .. ": print("
      end
      if source:find("host.panel", 1, true) and not source:find("--", 1, true) then
        offenders[#offenders + 1] = number .. ": host.panel"
      end
      if source:find("io.write", 1, true) then offenders[#offenders + 1] = number .. ": io.write" end
    end
  end
end
ok(#offenders == 0, "no command arm draws outside the balloon: " .. table.concat(offenders, ", "))
ok(checked_arms >= 20, "the command block was actually found and walked: " .. checked_arms .. " arms")

-- And the positive half: the arms name no renderer of their own, and the balloon is the one they use.
ok(chat and has(chat, "local ui = balloon.for_view(view"), "chat.lua takes its writer from the balloon")
ok(chat and has(chat, 'ui.show(balloon.paged("Help"'), "even /help draws through the component")

if failed > 0 then
  print("cli balloon: " .. failed .. " failed of " .. checks .. " checks")
  os.exit(1)
end
print("cli balloon ok (" .. checks .. " checks)")
