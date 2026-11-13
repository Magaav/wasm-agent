-- `Balloon`: the ONE overlay every `wa chat` command draws in.
--
-- Before this file the overlay was a host primitive with a different private dialect per command:
-- `/nodes` walked its own `while true do io.panel(...) end` loop, `/model` and `/reasoning` theirs,
-- `/login` built four ad-hoc panels inside `provider_management.lua` and answered them by index, `/mcp`
-- printed a wall of text, and `/help`, `/status`, `/hooks`, `/wakes`, `/memories` printed lines under
-- the prompt. The host renderer (`host.panel`, `wa_term::terminal_editor::Panel`) was already one
-- component; what was missing was one *caller* - so every command that shows something looked slightly
-- different, and four of them had a redraw loop of its own that could get the keys wrong.
--
-- This file is that caller, and the only one. A command builds **pages** and hands them here; nothing
-- else in `lua/core` draws an overlay, and `scripts/test-cli-balloon.lua` fails when one tries.
--
-- Three things it does with a page stack, and nothing else:
--
--   `show(pages, opts)`   the balloon as an overlay: open, move, open a page, come back, close. Blocks
--                         until the reader is done, exactly like the `/login` panel always has.
--   `text(pages)`         the same pages as plain text: what a pipe (no raw editor) gets, and what the
--                         snapshots in `tests/snapshots/balloon/` are taken from.
--   `publish`             file the same pages with the host (`host.local_view`) so the console reader
--                         can draw them while a run is in flight, when this interpreter is blocked in
--                         the model call and cannot open anything at all (`lua/core/local_views.lua`).
--
-- A page is:
--
--   { title = "...", lines = { "..." },
--     options = { { label = "...", hint = "...", page = n, back = true,
--                   run = "/mcp whatsapp off", act = function(choice) ... end } },
--     input = "text" | "secret", placeholder = "...", hint = "...", selected = 1 }
--
-- `page` opens another page of the same stack (`views[i]`, 1-based, root is 1), `back` returns,
-- `run` is a line the *interpreter* executes after this turn - the client only queues it, because a
-- client has no registry, no provider and no business changing state - and `act` is a Lua callback for a
-- flow whose next page depends on what the reader chose (`/login` asks for a key and then offers the
-- switch). One of the three per option; the reader-facing hint says which.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- The name the code, the tests and the snapshot directory use. One name, everywhere.
M.NAME = "Balloon"

-- The width a snapshot is taken at and the width a pipe is rendered for when the console will not say:
-- 80 columns is what `wa chat` is expected to work in (Victor's 80x24), and a balloon that is wider than
-- the terminal is the one thing it must never be.
M.WIDTH = 80

-- The most options a page lists before it says how many are left; the host panel scrolls a longer list,
-- the plain rendering cannot, so the last row counts the rest.
M.OPTIONS = 10

-- ---------------------------------------------------------------- environment

-- Whether the host can draw an overlay at all. False is ordinary: a pipe, `WASM_AGENT_CLI_EDITOR=off`,
-- an older binary. Every command then gets `text` and says the same thing, once.
function M.available()
  return type(host) == "table" and type(host.panel) == "function"
end

-- Whether the host can draw a published balloon mid-run (`host.local_view`).
function M.publishing()
  return type(host) == "table" and type(host.local_view) == "function"
end

-- Whether *this* chat can show an overlay: the native editor owns the screen and there is a console to
-- draw on. `view` is the `cli_view` instance the REPL already has; nil/false means "print instead".
function M.interactive(view)
  if not view then return false end
  if not (view.editor and view.stdout) then return false end
  return M.available()
end

-- The console's columns, for wrapping: asked of the host, 80 when it will not answer.
function M.width(probe)
  if probe then
    local columns = tonumber(probe())
    if columns and columns > 0 then return math.floor(columns) end
  end
  local size = type(host) == "table" and host.terminal_size
  if size then
    local ok, raw = pcall(size)
    if ok and type(raw) == "string" then
      local decoded
      if pcall(function() decoded = json.decode(raw) end) and type(decoded) == "table" then
        local columns = tonumber(decoded.columns)
        if columns and columns > 0 then return math.floor(columns) end
      end
    end
  end
  return M.WIDTH
end

-- ---------------------------------------------------------------- fitting text

-- One UTF-8 character per entry, so widths are counted in characters and a cut never lands inside one.
-- The host renderer counts cells (a CJK glyph is two); this counts characters, which is what the plain
-- rendering has always done and never splits a sequence.
local function chars(text)
  local out = {}
  for _, code in utf8.codes(text) do out[#out + 1] = utf8.char(code) end
  return out
end

-- One line, never wider than `width` characters, with an ellipsis when it was cut. Every page goes
-- through this before it reaches a renderer, so "nothing wider than the terminal" is a property of the
-- data rather than of each command's arithmetic.
function M.fit(text, width)
  text = tostring(text or ""):gsub("\n", " ")
  width = math.max(4, tonumber(width) or M.WIDTH)
  local list = chars(text)
  if #list <= width then return text end
  return table.concat(list, "", 1, width - 1) .. "\u{2026}"
end

-- A paragraph as the lines it needs at `width`, breaking on spaces and never mid-word unless a single
-- word is wider than the row (a URL, a schema).
function M.wrap(text, width, indent)
  width = math.max(8, tonumber(width) or M.WIDTH)
  indent = indent or ""
  local room = math.max(4, width - #chars(indent))
  local lines = {}
  for paragraph in tostring(text or ""):gmatch("[^\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line == "" then
        line = word
      elseif #chars(line) + 1 + #chars(word) <= room then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  if #lines == 0 then lines[1] = "" end
  for index, line in ipairs(lines) do
    lines[index] = indent .. M.fit(line, width)
  end
  return lines
end

-- ---------------------------------------------------------------- pages

-- A page, with the fields a renderer reads, defaulted in one place.
function M.page(spec)
  spec = spec or {}
  return {
    title = tostring(spec.title or ""),
    lines = spec.lines or {},
    options = spec.options or {},
    input = spec.input,
    placeholder = spec.placeholder or "",
    hint = spec.hint,
    selected = spec.selected or 1,
    -- A field's own handler: what to do with the text, returning the page that says so. Only the
    -- interpreter can run one, which is why a published page never carries it.
    act = spec.act,
  }
end

-- ------------------------------------------------------------------ rendering, as text

-- One page as the panel would show it, without colour: the title, the body, the list with the selection
-- marked the way `Panel::render` marks it, and the hint row. This is the pipe's view and the snapshot's
-- view; the host draws the same fields with colour in a terminal.
function M.page_text(page, width, opts)
  opts = opts or {}
  width = math.max(20, tonumber(width) or M.WIDTH)
  page = M.page(page)
  local rows = { M.fit(page.title, width) }
  rows[#rows + 1] = ""
  for _, line in ipairs(page.lines) do rows[#rows + 1] = M.fit(line, width) end
  local selected = math.max(1, tonumber(page.selected) or 1)
  if page.input then
    rows[#rows + 1] = ""
    local placeholder = page.placeholder ~= "" and ("  " .. page.placeholder) or "  >"
    rows[#rows + 1] = M.fit(placeholder .. (page.input == "secret" and "  (hidden, Enter to save)" or ""), width)
  elseif #page.options > 0 then
    rows[#rows + 1] = ""
    local label_width = 0
    for _, option in ipairs(page.options) do label_width = math.max(label_width, #chars(tostring(option.label or ""))) end
    label_width = math.min(label_width + 2, math.max(8, width - 12))
    local shown = math.min(#page.options, M.OPTIONS)
    for index = 1, shown do
      local option = page.options[index]
      local mark = index == selected and "\u{276f}" or " "
      -- A fixed column for the labels, the way the panel renders a list: a hint that started at a
      -- different column on every row is what made the old printed table hard to scan.
      local pad = "%-" .. label_width .. "s"
      local head = string.format("%s %2d. ", mark, index) .. pad:format(M.fit(option.label or "", label_width))
      local hint = tostring(option.hint or "")
      local room = width - #chars(head) - 1
      local tail = hint ~= "" and room > 2 and (" " .. M.fit(hint, room)) or ""
      rows[#rows + 1] = (head .. tail):gsub("%s+$", "")
    end
    if #page.options > shown then
      rows[#rows + 1] = string.format("     %u more - the terminal list scrolls", #page.options - shown)
    end
  end
  rows[#rows + 1] = ""
  rows[#rows + 1] = M.fit(M.hint_for(page), width)
  return rows
end

-- The hint row a page shows when it did not name its own: what the keys do on this page, in words.
function M.hint_for(page)
  page = M.page(page)
  if page.hint then return page.hint end
  if page.input then return "Enter to save \u{b7} Esc to go back" end
  if #page.options > 0 then return "\u{2191}\u{2193} to move \u{b7} Enter to open \u{b7} Esc or \u{2190} to go back" end
  return "Esc or \u{2190} to go back"
end

-- The whole stack as text: the root page, then every page behind it with its heading, so a pipe gets the
-- same information the overlay would have let the reader walk to. `opts.page` renders one page only (a
-- snapshot of the detail view, which is what the doctor ordered for `/mcp <key>`).
function M.text(pages, width, opts)
  opts = opts or {}
  width = tonumber(width) or M.WIDTH
  pages = pages or {}
  local lines = {}
  for index, page in ipairs(pages) do
    if opts.page == nil or opts.page == index then
      if opts.page == nil and index > 1 and #pages > 1 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.rep("\u{2500}", math.min(width, 40))
      end
      for _, row in ipairs(M.page_text(page, width)) do lines[#lines + 1] = row end
    end
  end
  return table.concat(lines, "\n")
end

-- A long report as pages: `lines` split into screens of `per` rows, chained with Previous/Next, so a
-- report too tall for a 24-row terminal is read a screen at a time instead of being cut off by the
-- renderer. The last page says how many rows came before it, so a reader always knows where they are.
function M.paged(title, lines, opts)
  opts = opts or {}
  lines = lines or {}
  local per = math.max(3, tonumber(opts.per) or 12)
  local pages = {}
  local flat = {}
  -- `nowrap` keeps a column that was already laid out as one (`/help`'s usage/hint rows): fitting it is
  -- right, wrapping it is not, because a hint that moves to its own line stops being a column.
  for _, line in ipairs(lines) do
    if opts.nowrap then
      flat[#flat + 1] = M.fit(line, opts.width or M.WIDTH)
    else
      for _, part in ipairs(M.wrap(line, opts.width or M.WIDTH)) do flat[#flat + 1] = part end
    end
  end
  local count = math.max(1, math.ceil(#flat / per))
  for index = 1, count do
    local page = M.page({ title = count > 1 and string.format('%s (%d/%d)', tostring(title), index, count) or tostring(title) })
    for row = (index - 1) * per + 1, math.min(#flat, index * per) do page.lines[#page.lines + 1] = flat[row] end
    if count > 1 then
      -- Only the links that go somewhere: the first screen has no Previous and the last no Next. A
      -- "Previous" on the first screen would have to be a `back`, and a root page may not pop (the
      -- client refuses `root_pop`, and a report that fails to publish is a view that cannot open mid-run).
      if index > 1 then
        page.options[#page.options + 1] = { label = 'Previous', hint = 'the rows above', page = index - 1 }
      end
      if index < count then
        page.options[#page.options + 1] = { label = 'Next', hint = 'the rows below', page = index + 1 }
      end
    end
    pages[index] = page
  end
  return pages
end

-- ---------------------------------------------------------------- the overlay

local function raw_open(spec)
  local ok, answer = pcall(host.panel, json.encode(spec))
  if not ok or type(answer) ~= "string" then return { action = "unsupported" } end
  local decoded, value = pcall(json.decode, answer)
  if not decoded or type(value) ~= "table" then return { action = "unsupported" } end
  return value
end

local function raw_close()
  if M.available() then pcall(host.panel) end
end

-- The spec one page hands the renderer. `selected` is the option the reader was standing on when they
-- left this page, so Back lands where they were rather than at the top.
function M.panel_spec(page, selected, opts)
  page = M.page(page)
  local options = {}
  for _, option in ipairs(page.options) do
    options[#options + 1] = { label = tostring(option.label or ""), hint = tostring(option.hint or "") }
  end
  local spec = {
    title = page.title, lines = page.lines, options = options, selected = selected or page.selected or 1,
  }
  if page.input then
    spec.input = page.input
    spec.placeholder = page.placeholder
  end
  if page.hint then spec.hint = page.hint end
  if opts and opts.timeout_ms then spec.timeout_ms = opts.timeout_ms end
  return spec
end

-- Walk a page stack. `io` is `{open = fn, close = fn}` - the host by default, and a script of answers in
-- a test, which is how the component is exercised without a terminal.
--
-- Returns what the reader did, because a command decides what happens next:
--   { action = "cancel" }                         Esc on the root (or the panel timed out)
--   { action = "run", line = "/mcp x off" }       an option that queues a line for the interpreter
--   { action = "select", page = 2, index = 3 }    an option with no link: the caller owns it
--   { action = "submit", page = 1, text = "..." } a field was filled in
--   { action = "unsupported" }                    no raw editor: the caller prints `text` instead
function M.flow(pages, io)
  io = io or {}
  local open = io.open or raw_open
  local close = io.close or raw_close
  pages = pages or {}
  if #pages == 0 then return { action = "cancel" } end
  -- The stack is the pages the reader has walked through, oldest first; each level remembers the option
  -- the reader was on so coming back lands there. `io.start` opens a page other than the root (`/mcp <key>`
  -- opens at that connector) - Back then closes, because there is nothing behind it on the stack.
  local start = math.max(1, tonumber(io.start) or 1)
  local root = pages[start] or pages[1]
  local stack = { { index = pages[start] and start or 1, focus = root and root.selected or 1 } }
  local kept = pages
  local last
  while true do
    local frame = stack[#stack]
    local page = kept[frame.index]
    if not page then
      close()
      return { action = "cancel" }
    end
    local answer = open(M.panel_spec(page, frame.focus, io))
    if type(answer) ~= "table" then answer = { action = "cancel" } end
    if answer.action == "unsupported" then return { action = "unsupported" } end
    if answer.action == "timeout" then close(); return { action = "timeout" } end
    if answer.action == "cancel" then
      if #stack == 1 then close(); return { action = "cancel" } end
      table.remove(stack)
    elseif answer.action == "submit" then
      local text = tostring(answer.text or "")
      if page.act then
        local nxt = page.act(text)
        if type(nxt) == "table" then
          kept = { nxt }
          stack = { { index = 1, focus = nxt.selected or 1 } }
        else
          close()
          return { action = "submit", page = frame.index, text = text }
        end
      else
        close()
        return { action = "submit", page = frame.index, text = text }
      end
    elseif answer.action == "select" then
      local index = tonumber(answer.index) or 0
      local option = page.options[index]
      if not option then
        -- A number that names no option: never close on the reader for a keystroke they did not mean.
        if #stack == 1 then close(); return { action = "cancel" } end
        table.remove(stack)
      else
        frame.focus = index
        last = { action = "select", page = frame.index, index = index, option = option }
        if option.run then
          close()
          return { action = "run", line = option.run, page = frame.index, index = index, label = option.label }
        elseif option.back or option.pop then
          if #stack == 1 then close(); return { action = "cancel" } end
          table.remove(stack)
        elseif option.act then
          local nxt = option.act(index)
          if type(nxt) == "table" then
            kept = { nxt }
            stack = { { index = 1, focus = nxt.selected or 1 } }
          else
            close()
            return last
          end
        elseif option.page and kept[option.page] then
          stack[#stack + 1] = { index = option.page, focus = kept[option.page].selected or 1 }
        elseif option.view and kept[option.view] then
          -- The spelling `lua/core/nodes_cli.lua` already publishes (`view`, 1-based): one link shape for
          -- the two renderers, so a builder written before this component split did not have to change.
          stack[#stack + 1] = { index = option.view, focus = kept[option.view].selected or 1 }
        else
          close()
          return last
        end
      end
    else
      -- Anything else closes, the way the panel itself closes on an answer it did not expect.
      close()
      return { action = "cancel" }
    end
  end
end

-- ---------------------------------------------------------------- the writer a command holds

-- What every command arm draws with, and the only drawing it may do. `view` is the chat's `cli_view`.
--
--   io.say(lines)      acknowledgement and short output: the transcript, through the redactor
--   io.show(pages)     the balloon, blocking; the plain rendering when there is no raw editor
--   io.ask(page)       one page with a field, and the text the reader typed (nil when Esc)
--   io.publish(name, pages)  file the stack for the mid-run channel
--
-- `io.print` is the redacted transcript writer `say` uses; it exists so a command that already has a
-- `print` seam (`mcp_cli.run(io)`, `nodes_cli.run(io)`) keeps one name for it.
function M.for_view(view, opts)
  opts = opts or {}
  local writer = opts.print or print
  local redact = opts.redact
  local io = { view = view, interactive = M.interactive(view) }
  local function emit(text)
    text = tostring(text or "")
    if redact then text = redact.text(text) end
    writer(text)
  end
  io.print = emit
  io.say = function(lines)
    if type(lines) == "table" then
      for _, line in ipairs(lines) do emit(line) end
    else
      emit(lines)
    end
  end
  io.show = function(pages, opts)
    pages = pages or {}
    if io.interactive then
      local result = M.flow(pages, opts)
      if result.action ~= "unsupported" then return result end
    end
    emit(M.text(pages, (opts and opts.width) or M.width()))
    return { action = "printed" }
  end
  io.ask = function(page, opts)
    if io.interactive then
      local answer = (opts and opts.open or raw_open)(M.panel_spec(page, page.selected, opts))
      if type(answer) == "table" and answer.action == "submit" then return tostring(answer.text or "") end
      if type(answer) == "table" and answer.action ~= "unsupported" then return nil end
    end
    -- No overlay: say what is needed, once, and let the caller's fallback ask its own way.
    emit(M.text({ page }, (opts and opts.width) or M.width()))
    return nil
  end
  io.close = function() if io.interactive then raw_close() end end
  -- File a stack for the reader thread (`host.local_view`): what opens instantly mid-run.
  io.publish = function(name, pages, captured_at)
    if not io.interactive or not M.publishing() then return false, "unavailable" end
    return M.publish(name, pages, captured_at)
  end
  return io
end

-- Run a stack through whatever the caller brought: a balloon writer (`io.show`), a raw panel function
-- (`io.panel` - the older seam `/nodes` and `/model` were written against, kept so those places did not
-- have to change spelling), or nothing but a print (a pipe). One entry point, so a command never again
-- decides which of the three it has.
function M.drive(io, pages, opts)
  opts = opts or {}
  if io and io.show then return io.show(pages, opts) end
  if io and io.panel then
    return M.flow(pages, { open = io.panel, close = io.close or function() end, start = opts.start })
  end
  if io and io.print then io.print(M.text(pages, opts.width or M.WIDTH)) end
  return { action = "printed" }
end

-- ---------------------------------------------------------------- the mid-run channel

-- File one command's page stack with the host. The client walks the same stack with the same links, so
-- the balloon a run in flight shows is built by the same code as the one between runs - one builder,
-- two renderers, the way `lua/core/nodes_cli.lua` already did it for `/nodes`.
function M.publish(name, pages, captured_at)
  if not M.publishing() then return false, "unavailable" end
  local views = {}
  for index, page in ipairs(pages or {}) do
    page = M.page(page)
    local options = {}
    for _, option in ipairs(page.options) do
      -- A page link is 1-based here (`page = 2`, the root is 1) and 0-based in the published spec
      -- (`view`): the two renderers read the same links, spelled the way each already reads them.
      options[#options + 1] = {
        label = tostring(option.label or ""),
        hint = tostring(option.hint or (not option.page and not option.back and not option.pop and not option.run
          and "a change: run this between turns" or "")),
        -- A link is 1-based in a page (`page`, or the older `view` spelling nodes_cli publishes) and
        -- 0-based in the published spec: the client indexes the same array.
        view = (option.page and (option.page - 1)) or (option.view and (option.view - 1)) or nil,
        pop = option.back or option.pop or false, run = option.run,
      }
      -- An `act` option exists only as Lua: the client cannot run it, so it is published read-only -
      -- its hint says the change needs a turn, and Back still works.
    end
    views[#views + 1] = {
      title = page.title, lines = page.lines, options = options, selected = page.selected,
    }
  end
  -- `captured_at` is whole seconds: `host.now()` is a float in this build, and the client's spec is an
  -- i64 (`spec_unreadable: floating point ..., expected i64` was measured the first time this ran inside
  -- a live turn, which is the only place the client validates it).
  local at = math.floor(tonumber(captured_at) or tonumber(host.now()) or 0)
  local spec = { command = name, captured_at = at, views = views }
  local ok, raw = pcall(host.local_view, name, json.encode(spec))
  if not ok then return false, tostring(raw) end
  local decoded_ok, answer = pcall(json.decode, raw)
  if not decoded_ok or type(answer) ~= "table" then return false, "unreadable answer" end
  if answer.ok ~= true then
    return false, tostring(answer.error or "refused") .. (answer.detail and (" " .. tostring(answer.detail)) or "")
  end
  return true
end

return M
