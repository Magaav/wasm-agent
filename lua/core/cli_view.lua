-- The live view `wa chat` prints: what the agent is doing right now, and what each
-- tool call actually did.
--
-- Why this exists. `wa chat` runs in a terminal (or in an orchestrator reading one),
-- and before this module a run printed `· <tool>` followed by 120 characters of
-- redacted JSON. Two properties of a CLI run made that unreadable rather than merely
-- plain, and both are worth stating because they are what the view is shaped around:
--
--   * The answer is never streamed here. Content deltas are written to the node's SSE
--     sink (`rust/wa-host/src/host.rs`, `serve::write_event`), and a CLI run has no
--     sink, so the terminal shows tool noise for as long as the run lasts and the
--     reply only when it ends.
--   * A model call spends most of its time thinking, and nothing was printed for it
--     at all, so a run that is thinking and a run that is hung looked identical.
--
-- So the view keeps one thing on screen for as long as a run is in flight - what it is
-- doing, for how long, and which step - and prints one line per tool call that says
-- what was run and what came back, plus a footer with the numbers.
--
-- Two renderings of the same information, chosen once (`M.wants_live`):
--
--   live  - the status line is rewritten in place (`\r` + erase-line), colour marks the
--           phases, a spinner frame advances with each event, and the terminal title
--           carries the same word, so a reader watching another tab can still see it
--           running.
--   plain - one line per event, no escape sequences: an orchestrator, a pipe or a test
--           capturing this output must stay readable, and a line rewritten in place is
--           not a transcript.
--
-- What keeps the line moving cannot live in this process: Lua is blocked inside the model
-- call and inside a tool, so nothing here can repaint while one is in flight - a slow call
-- showed a frozen frame and a clock that had stopped, which is exactly what a hung run looks
-- like. The timer is therefore in the host (`host.ticker`, rust/wa-host/src/host.rs), which
-- draws the same line between events: this module hands it the line and takes it back before
-- printing anything else. One limit does remain, and it is a different one - the *answer* is
-- not streamed here, because content deltas go to the node's SSE sink and a CLI run has no
-- sink.

local json = dofile("lua/vendor/json.lua")
-- The answer is markdown, and a terminal has to be told so: headings, bullets, fences and
-- inline code all arrive as punctuation without it. The renderer is its own module because
-- its wrapping rule - measure the plain text, paint last - is the whole of its design, and
-- because that rule is worth a test that needs no terminal.
local markdown = dofile("lua/core/markdown.lua")

local M = {}

-- ---- styling -------------------------------------------------------------------

-- pi's dark theme, role for role. The names are pi's own
-- (`@earendil-works/pi-coding-agent/dist/modes/interactive/theme/dark.json`), so a component
-- here is coloured by what it *is* rather than by a literal at the call site: a tool that
-- succeeded is `success` on both surfaces, and a reader who knows pi's colours already knows
-- where to look in this one. The hex values are pi's, unchanged.
--
-- Truecolor is the point: these roles are 24-bit colours, and the terminals this runs in
-- (Windows Terminal, Orca's terminal, xterm-256color) render them. A terminal that does not
-- understand `38;2;r;g;b` ignores the sequence, so the degradation is uncoloured text -
-- visible, and not a garbled line. `NO_COLOR` still wins over all of it, and
-- `WASM_AGENT_CLI_VIEW=plain` turns colour off for a captured transcript.
local RESET = "\27[0m"
local PALETTE = {
  accent = "8abeb7", border = "5f87ff", borderAccent = "00d7ff", borderMuted = "505050",
  success = "b5bd68", error = "cc6666", warning = "ffff00", muted = "808080",
  dim = "666666", text = "d4d4d4", thinkingText = "808080",
  mdHeading = "f0c674", mdLink = "81a2be", mdLinkUrl = "666666", mdCode = "8abeb7",
  mdCodeBlock = "b5bd68", mdCodeBlockBorder = "808080", mdQuote = "808080",
  mdQuoteBorder = "808080", mdHr = "808080", mdListBullet = "8abeb7",
  toolDiffAdded = "b5bd68", toolDiffRemoved = "cc6666", toolDiffContext = "808080",
  syntaxComment = "6a9955", syntaxKeyword = "569cd6", syntaxFunction = "dcdcaa",
  syntaxString = "ce9178", syntaxNumber = "b5cea8", syntaxType = "4ec9b0",
  -- The reasoning ramp, darkest to brightest: how much thinking the model was asked for.
  thinkingOff = "505050", thinkingMinimal = "6e6e6e", thinkingLow = "5f87af",
  thinkingMedium = "81a2be", thinkingHigh = "b294bb", thinkingXhigh = "d183e8",
  thinkingMax = "ff5fff",
}

local function fg(hex)
  return string.format("\27[38;2;%d;%d;%dm",
    tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end

local STYLE = { bold = "\27[1m", italic = "\27[3m", faint = "\27[2m" }
for role, hex in pairs(PALETTE) do STYLE[role] = fg(hex) end
-- The names the earlier view used, kept because callers and tests use them: each is now a
-- role rather than a literal, so `green` and `success` cannot drift apart.
STYLE.red = STYLE.error
STYLE.green = STYLE.success
STYLE.yellow = STYLE.warning
STYLE.cyan = STYLE.borderAccent
M.PALETTE = PALETTE
M.style = function(role) return STYLE[role] end

-- Colour is a rendering decision, never a fact: every caller passes `live`, and the plain
-- rendering is the same text without it. A style is one role or a list of them
-- (`{ "bold", "mdHeading" }`), which is how a heading is both at once.
local function paint(text, style, live)
  if not live or not style then return text end
  local codes = ""
  if type(style) == "table" then
    for _, name in ipairs(style) do codes = codes .. (STYLE[name] or "") end
  else
    codes = STYLE[style] or ""
  end
  if codes == "" then return text end
  return codes .. text .. RESET
end
M.paint = paint

-- Braille, the same frames pi uses. Only ever emitted in the live rendering.
local SPINNER = { "\226\160\139", "\226\160\153", "\226\160\185", "\226\160\184",
                  "\226\160\188", "\226\160\180", "\226\160\166", "\226\160\167",
                  "\226\160\135", "\226\160\143" }

function M.spinner(frame)
  return SPINNER[(math.max(0, math.floor(frame or 0)) % #SPINNER) + 1]
end

-- The marks the animated line cycles, each carrying the space that separates it from the
-- phase. They travel to the host rather than being rebuilt there, so the frames on screen are
-- the same characters in the same order as the ones this module prints for itself.
function M.marks()
  local list = {}
  for index = 1, #SPINNER do list[index] = SPINNER[index] .. " " end
  return list
end

-- ---- text ----------------------------------------------------------------------

-- One line, clipped to what a terminal can show. The count is *columns*, not bytes:
-- `·` is two bytes and one column, `↑` three and one, so a byte limit makes a line that
-- fits look like it does not - and it is also what keeps a cut from landing inside a
-- character, which is a rendering bug rather than a cosmetic one.
local function columns(text)
  local count, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    index = index + ((byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1)
    count = count + 1
  end
  return count
end
M.columns = columns

local function clip(text, limit)
  text = tostring(text or ""):gsub("%s+", " ")
  if not limit or limit <= 0 or columns(text) <= limit then return text end
  local index, kept = 1, 0
  while index <= #text and kept < limit - 1 do
    local byte = text:byte(index)
    index = index + ((byte >= 240 and 4) or (byte >= 224 and 3) or (byte >= 192 and 2) or 1)
    kept = kept + 1
  end
  return text:sub(1, index - 1) .. "\226\128\166"   -- …
end
M.clip = clip

function M.tokens(count)
  local n = tonumber(count) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return string.format("%d", math.floor(n))
end

function M.duration(seconds)
  local s = tonumber(seconds) or 0
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60))
end

-- How long a step took: milliseconds below a second, seconds above it. The unit is
-- carried because "0.2s" and "200ms" are the same number and only one of them is how
-- a person reads a fast call.
function M.elapsed(ms)
  local value = tonumber(ms)
  if not value or value < 0 then return "" end
  if value < 1000 then return string.format("%dms", math.floor(value)) end
  return string.format("%.1fs", value / 1000)
end

-- ---- what a call is ------------------------------------------------------------

-- The verb in the status line, so "running" is not the only word the reader ever sees.
local PHASE = {
  bash = "Running", shell = "Running", read = "Reading", write = "Writing",
  edit = "Editing", grep = "Searching", ls = "Listing", recall = "Recalling",
  remember = "Remembering", memories = "Reading memory", forget = "Forgetting",
  search_messages = "Searching the ledger", conversation = "Reading a conversation",
  list_conversations = "Listing conversations", skill = "Loading a skill",
  subagent = "Waiting on a subagent", nodes = "Asking the fabric", remote = "Asking a peer",
  spell_run = "Running a spell", spell_save = "Saving a spell", operation = "Supervising an operation",
  client = "Driving the machine", diagnose = "Diagnosing", graph = "Walking the graph",
  capabilities = "Listing capabilities",
}

function M.phase(name)
  if not name or name == "" then return "Thinking" end
  return (PHASE[name] or "Working:") .. " " .. name
end

-- What the call was given. The words are the web UI's (`toolTitle` in `ui/app.js`) so
-- the two surfaces describe the same call the same way.
function M.call_line(name, args, limit)
  local a = (type(args) == "table") and args or {}
  local path = tostring(a.path or a.file_path or "")
  limit = limit or 96
  if name == "bash" or name == "shell" then
    return "$ " .. clip(a.command or "", limit)
  elseif name == "read" then
    local range = (a.offset or a.limit)
      and string.format(" (lines %d-%s)", a.offset or 1,
        a.limit and (math.floor(tonumber(a.offset) or 1) + math.floor(tonumber(a.limit)) - 1) or "")
      or ""
    return clip(path .. range, limit)
  elseif name == "write" or name == "edit" then
    return clip(path, limit)
  elseif name == "grep" then
    return clip("/" .. tostring(a.pattern or "") .. "/" .. (a.path and (" in " .. tostring(a.path)) or ""), limit)
  elseif name == "ls" then
    return clip(path ~= "" and path or ".", limit)
  elseif name == "recall" or name == "search_messages" or name == "search" then
    return clip(a.query or "", limit)
  elseif name == "remember" then
    return clip(a.content or a.text or "", limit)
  elseif name == "skill" then
    return clip(a.name or "", limit)
  elseif name == "subagent" then
    return clip(a.prompt or a.task or "", limit)
  elseif name == "forget" then
    return clip(a.id or "", limit)
  elseif name == "remote" or name == "client" or name == "operation" then
    return clip((a.action or a.capability or "") .. (a.node and (" " .. a.node) or ""), limit)
  end
  -- Unknown tool (a plugin, a new capability): show its first scalar arguments rather
  -- than nothing, because a name alone does not say what was asked for.
  local parts = {}
  for key, value in pairs(a) do
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      parts[#parts + 1] = key .. "=" .. tostring(value)
    end
    if #parts >= 3 then break end
  end
  table.sort(parts)
  return clip(table.concat(parts, " "), limit)
end

-- Whether the call worked, in the caller's terms: `ok` is false when the tool returned
-- an error or a non-zero exit code, and the second value is what to say about it.
function M.outcome(name, result)
  local r = (type(result) == "table") and result or {}
  if r.error then return false, clip(r.error, 80) end
  if name == "read" then
    local lines = select(2, tostring(r.content or ""):gsub("\n", ""))
    return true, string.format("%d lines", lines)
  elseif name == "bash" or name == "shell" then
    local code = r.code
    return code == 0 or code == nil, string.format("exit %s", code == nil and "?" or tostring(code))
  elseif name == "grep" then
    local count = tonumber(r.count) or 0
    return true, string.format("%d match%s", count, count == 1 and "" or "es")
  elseif name == "ls" then
    return true, string.format("%d entries", #(type(r.entries) == "table" and r.entries or {}))
  elseif name == "write" or name == "edit" then
    return true, "written"
  elseif name == "remember" then
    return true, "stored"
  elseif name == "forget" then
    return r.forgotten and true or false, r.forgotten and "removed" or "not found"
  elseif name == "recall" or name == "memories" then
    return true, string.format("%d memories", type(r) == "table" and #r or 0)
  elseif name == "search_messages" then
    local matches = type(r) == "table" and (r.matches or r) or {}
    return true, string.format("%d messages", #(type(matches) == "table" and matches or {}))
  elseif name == "skill" then
    return true, "loaded"
  elseif name == "subagent" then
    return r.ok ~= false, tostring(r.status or r.outcome or "finished")
  elseif name == "operation" then
    return r.ok ~= false, tostring(r.state or "observed")
  end
  if type(result) == "string" then return true, clip(result, 60) end
  if r.ok == false then return false, "failed" end
  return true, ""
end

-- The lines worth showing under a result. Only where output *is* the answer: a command's
-- own words, or why it failed. A file's contents, a memory, a page of grep matches are
-- not repeated here - they are in the transcript, and repeating them is how a terminal
-- becomes a wall.
function M.preview(name, result, lines)
  local r = (type(result) == "table") and result or {}
  local text = ""
  if name == "bash" or name == "shell" then
    text = tostring(r.stdout or "")
    if text:gsub("%s", "") == "" then text = tostring(r.stderr or "") end
  elseif r.error then
    text = tostring(r.error)
  end
  local out, kept = {}, 0
  for line in tostring(text):gmatch("[^\r\n]+") do
    if line:gsub("%s", "") ~= "" then
      out[#out + 1] = line
      kept = kept + 1
      if kept >= (lines or 2) then break end
    end
  end
  return out
end

-- ---- the footer -----------------------------------------------------------------

-- The window the footer divides by is the *model's*, resolved where compaction and the
-- window's balloon resolve it (`provider.budget`, over `model_window`) - never the global
-- `WASM_AGENT_LLM_CONTEXT` read directly. The global is the last resort in that chain, and
-- a footer that reads it shows a number no model has: this deployment's model has a
-- 1,000,000-token window and the global says 128000, so the same context read as eight
-- times fuller than it was.
--
-- `resolve` is passed in rather than required here, so the decision is testable without a
-- model: a resolver that fails, or that answers "unknown", falls back to the global rather
-- than printing a guess - unknown is visible, a guess is not.
function M.window(model, resolve)
  local ok, budget = pcall(resolve, model)
  local context = ok and type(budget) == "table" and tonumber(budget.context) or nil
  if context and context > 0 then return context end
  return tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) or 0
end

-- The run's own numbers, the way pi keeps them in its footer: what it cost, what it
-- used, and how full the window is. The model and its reasoning level are in the banner
-- instead - they do not change between runs, and a line that has to hold both is a line
-- that gets clipped on a narrow terminal.
-- `run` is this turn's usage (the caller diffs the session totals), `ctx` the
-- process-wide facts that do not change per turn.
function M.footer(run, ctx)
  run, ctx = run or {}, ctx or {}
  local parts = {}
  if run.rounds then parts[#parts + 1] = run.rounds .. (run.rounds == 1 and " round" or " rounds") end
  if run.tools then parts[#parts + 1] = run.tools .. (run.tools == 1 and " tool" or " tools") end
  if run.seconds then parts[#parts + 1] = M.duration(run.seconds) end
  if run.prompt or run.completion then
    parts[#parts + 1] = string.format("\226\134\145%s \226\134\147%s", M.tokens(run.prompt), M.tokens(run.completion))
  end
  if run.cached and run.cached > 0 and run.prompt and run.prompt > 0 then
    parts[#parts + 1] = string.format("CH%.1f%%", 100 * run.cached / run.prompt)
  end
  if run.cost and run.cost > 0 then parts[#parts + 1] = string.format("$%.4f", run.cost) end
  if ctx.context and ctx.context > 0 and ctx.budget and ctx.budget > 0 then
    parts[#parts + 1] = string.format("ctx %.1f%%/%s", 100 * ctx.context / ctx.budget, M.tokens(ctx.budget))
  end
  return table.concat(parts, " \194\183 ")   -- ·
end

-- ---- is this a terminal? --------------------------------------------------------

-- There is no tty check in the host (`host.*` exposes no isatty), so this is a
-- heuristic, and it is stated as one: every terminal this runs in sets one of these,
-- and a pipe, a file or a test does not. NO_COLOR always wins, and the explicit
-- override exists because a guess needs a way to be overruled.
function M.wants_live(getenv)
  getenv = getenv or function(name) return host.getenv(name) end
  local explicit = getenv("WASM_AGENT_CLI_VIEW") or ""
  if explicit == "plain" or explicit == "off" or explicit == "0" then return false end
  if explicit == "live" or explicit == "on" or explicit == "1" then return true end
  if (getenv("NO_COLOR") or "") ~= "" then return false end
  local term = getenv("TERM") or ""
  if term == "dumb" then return false end
  return term ~= "" or (getenv("COLORTERM") or "") ~= ""
    or (getenv("WT_SESSION") or "") ~= "" or (getenv("ORCA_TERMINAL_HANDLE") or "") ~= ""
end

-- ---- where this is running -----------------------------------------------------

-- The workspace as a reader recognises it: the home directory abbreviated, the rest
-- as-is, with forward slashes - the way the same tree is named everywhere else here.
function M.workspace(path, home)
  if not path or path == "" then return "" end
  local clean = tostring(path):gsub("\\", "/")
  if home and home ~= "" then
    local short_home = tostring(home):gsub("\\", "/")
    if clean:sub(1, #short_home) == short_home then return "~" .. clean:sub(#short_home + 1) end
  end
  return clean
end

-- The branch this worktree is on, read from `.git` rather than by running `git`: a
-- banner must not fail, or take a lock, because of a PATH or a repository state. In a
-- linked worktree `.git` is a *file* naming the real git directory, which is the case
-- this project's own checkouts are always in.
--
-- The line endings matter: `.git` is written with the platform's, and a branch name with
-- a carriage return in it is a path that cannot be opened and a label nobody wants.
function M.branch(root, read)
  if not root or root == "" then return "" end
  read = read or function(path)
    local ok, text = pcall(host.read_file, path)
    if not ok or type(text) ~= "string" then return nil end
    return text
  end
  local pointer = read(root .. "/.git")
  local head
  -- A linked worktree has a `.git` *file* naming the real git directory; a plain checkout
  -- has a `.git` directory, and reading a directory as a file fails - so a failed read
  -- here is not "not a repository", it is "look one level down".
  local gitdir = type(pointer) == "string" and pointer:match("^gitdir:%s*(.-)%s*$") or nil
  if gitdir then
    gitdir = gitdir:gsub("\\", "/")
    if gitdir:sub(1, 1) ~= "/" and not gitdir:match("^%a:") then gitdir = root .. "/" .. gitdir end
    head = read(gitdir .. "/HEAD")
  else
    head = read(root .. "/.git/HEAD")
  end
  if type(head) ~= "string" then return "" end
  return head:match("^ref:%s*refs/heads/(.-)%s*$") or head:sub(1, 8)
end

-- ---- the view -------------------------------------------------------------------

local METHODS = {}
METHODS.__index = METHODS

-- `opts`: out (write text), live (nil = decide), now (clock), limit (columns),
-- title (terminal title), workspace/branch/budget (the banner and the footer).
function M.new(opts)
  opts = opts or {}
  -- `opts.live == false` must mean plain: `x = opts.live or default` would silently
  -- fall through to the terminal guess, and a caller asking for a transcript would get
  -- escape sequences in it.
  local live = opts.live
  if live == nil then live = M.wants_live(opts.getenv) end
  -- The host's ticker draws on the process's own stdout and nowhere else, so a view whose
  -- output goes somewhere else (a buffer, a captured transcript) must not have a second
  -- writer appear on the terminal behind it. The default `out` *is* stdout, which is why this
  -- is derived from it; `opts.stdout` overrules the guess, the way `opts.live` does.
  local stdout = opts.stdout
  if stdout == nil then stdout = (opts.out == nil) end
  local view = {
    out = opts.out or function(text) io.write(text); io.flush() end,
    live = live and true or false,
    stdout = stdout and true or false,
    animating = false,
    now = opts.now or function() return host.now() end,
    limit = opts.limit or 80,
    title = opts.title or "",
    workspace = opts.workspace or "",
    branch = opts.branch or "",
    budget = opts.budget or 0,
    context = 0,
    frame = 0, phase = "", round = 0, pending = nil,
    shown = nil, logged = "", turn = nil, totals = nil, deltas = 0, warned = nil,
  }
  return setmetatable(view, METHODS)
end

function METHODS:write(text)
  self.out(text)
end

function METHODS:line(text)
  self:clear()
  self:write(tostring(text or "") .. "\n")
end

-- The status line with its two moving parts left as tokens: `{m}` is the spinner mark and
-- `{t}` the clock. One layout, two renderers - this module fills them for a line it prints
-- itself, and `host.ticker` fills them on a timer while this process is blocked. The second
-- value is when the timed thing started, which is what the clock counts from either way.
function METHODS:status_template()
  local phase = self.pending and M.phase(self.pending.name) or self.phase
  local started = self.pending and self.pending.started or (self.turn and self.turn.started or nil)
  local function compose(shown)
    local line = "  {m}" .. shown
    if self.pending then
      local bound = self.pending.bound and (" of " .. M.duration(self.pending.bound)) or ""
      return line .. " \194\183 {t}" .. bound
    end
    if not self.turn then return line end
    local round = (self.round and self.round > 0) and (" \194\183 round " .. self.round) or ""
    return line .. " \194\183 {t}" .. round
  end
  local plain = compose(phase)
  -- The phase word carries the colour and nothing else does: the host's ticker draws this
  -- same line, and the mark and the clock are its own. A terminal too narrow for the plain
  -- line gets the plain line, because `clip` counts columns and an escape sequence is not
  -- one - a coloured line clipped by width loses its reset and bleeds into the next line.
  if columns(plain) > math.min(self.limit, 100) then return plain, started end
  return compose(paint(phase, "accent", self.live)), started
end

-- The status line, and the only thing on screen that is rewritten. `with_spinner` is
-- false for the captured rendering: a spinner frame is a moving picture, and a
-- transcript is not one.
function METHODS:status_text(with_spinner)
  local template, started = self:status_template()
  local mark = with_spinner and (M.spinner(self.frame) .. " ") or ""
  -- Through a function, so a mark or a clock containing a `%` is inserted as itself.
  local text = template:gsub("{m}", function() return mark end)
  if started then
    local elapsed = M.duration(self.now() - started)
    text = text:gsub("{t}", function() return elapsed end)
  end
  return text
end

-- Hand the line to the host, which keeps drawing it while this process cannot.
--
-- `started` is when the timed thing began rather than "now": the clock has to be continuous
-- across the events that redraw the line, and `frame` is where the mark cycle continues from,
-- so a redraw does not send the spinner back to its first frame. A failure here is silent on
-- purpose - it is one frame of decoration, and the run it describes must not die of it.
function METHODS:animate()
  if not self.live or not self.stdout then return end
  if not (host and host.ticker) then return end
  local template, started = self:status_template()
  if not started then return end
  local ok = pcall(host.ticker, json.encode({
    line = template, marks = M.marks(), started = started, frame = self.frame,
  }))
  if not ok then return end
  self.animating = true
end

-- Take the line back. Called before this module writes anything at all: two writers on one
-- line is how a status line becomes two half-lines. Stopping is cheap and immediate - the
-- host wakes its own thread rather than waiting out a tick.
function METHODS:unanimate()
  if not self.animating then return end
  self.animating = false
  if host and host.ticker then pcall(host.ticker, nil) end
end

-- Called on every event: a new frame, and a repaint. In the plain rendering the line is
-- only printed when the *phase* changes - a log line per spinner frame would be noise,
-- and there is nothing here a reader could not get from the tool lines.
function METHODS:paint(force)
  -- The console draws every event as its own line, so a line rewritten in place has nothing
  -- to say and would fight it for the cursor.
  if self.console then return end
  self.frame = self.frame + 1
  local line = clip(self:status_text(self.live), math.min(self.limit, 100))
  if self.live then
    -- The host may be drawing this line at this instant: take it back before writing on it,
    -- then hand it over again, because this process is about to block.
    self:unanimate()
    if line ~= self.shown then
      self:write("\r\27[2K" .. line)
      self.shown = line
    end
    self:animate()
    return
  end
  if force or self.phase ~= self.logged then
    self.logged = self.phase
    self:write(line .. "\n")
    self.shown = line
  end
end

function METHODS:clear()
  -- Never wipe a line the host is still drawing: stopping waits for its last frame to land.
  self:unanimate()
  if self.live and self.shown then self:write("\r\27[2K") end
  self.shown = nil
end

-- The terminal title carries the same word as the status line, which is how a reader
-- looking at another tab still knows the run is alive (pi does the same).
function METHODS:title_text()
  local name = self.title ~= "" and self.title or "wa"
  if self.pending then return M.spinner(self.frame) .. " " .. name .. " \194\183 " .. self.phase end
  if self.turn then return M.spinner(self.frame) .. " " .. name .. " \194\183 " .. self.phase end
  return name
end

function METHODS:set_title()
  if not self.live then return end
  self:write("\27]2;" .. self:title_text() .. "\7")
end

-- ---- the events ----------------------------------------------------------------

function METHODS:run_started()
  self.frame = 0
  self.phase = "Thinking"
  self.pending = nil
  self.round = 0
  self.deltas = 0
  self.warned = nil
  -- The usage event carries the *session's* running totals, so a run's own numbers are
  -- the difference across it. The first run's baseline is zero, not nil: a footer with
  -- no numbers on the first turn is a footer that looks broken.
  self.turn = {
    started = self.now(), rounds = 0, tools = 0,
    baseline = self.totals or { prompt = 0, completion = 0, cached = 0, cost = 0 },
  }
  self:set_title()
  self:paint(true)
end

function METHODS:run_finished()
  self:clear()
  local run, baseline = nil, self.turn and self.turn.baseline
  if self.turn then
    run = {
      rounds = self.turn.rounds, tools = self.turn.tools,
      seconds = math.max(0, self.now() - self.turn.started),
    }
    if self.totals and baseline then
      run.prompt = (self.totals.prompt or 0) - (baseline.prompt or 0)
      run.completion = (self.totals.completion or 0) - (baseline.completion or 0)
      run.cached = (self.totals.cached or 0) - (baseline.cached or 0)
      run.cost = (self.totals.cost or 0) - (baseline.cost or 0)
    end
    run.cost = run.cost or (self.totals and self.totals.cost) or 0
  end
  local text = M.footer(run, { context = self.context, budget = self.budget })
  if text ~= "" then
    -- One line, clipped to the width: a footer that wraps puts its own tail at column
    -- zero, which reads as a second, unrelated line. The workspace and the branch are in
    -- the banner, where there is room for them.
    self:line(paint("  " .. clip(text, math.max(20, self.limit - 2)), "dim", self.live))
  end
  self.turn = nil
  self.pending = nil
  self.phase = ""
  self:set_title()
end

-- The answer, then the numbers for the run that produced it. A reply that already
-- streamed (a peer or a window run reaching this printer) is not printed twice.
function METHODS:answered(reply)
  self:clear()
  if self.deltas == 0 and reply and tostring(reply) ~= "" then
    -- After a page of tool lines the answer has to be findable, and the reader's eye is
    -- what has to find it.
    if self.turn and (self.turn.tools or 0) > 0 then self:write("\n") end
    local text = tostring(reply)
    -- Markdown, because that is what the model wrote: a heading is a heading, a fence is a
    -- block, and the width is the terminal's rather than the line's.
    local rendered = markdown.render(text, {
      paint = function(plain, style) return paint(plain, style, self.live) end,
      width = self.limit,
      indent = "  ",
    })
    -- The renderer is the nicer rendering, never the only one: a reply it produces nothing
    -- for is printed raw. A view that swallowed an answer because its parser did not
    -- recognise it would be the worst bug in this file.
    if rendered ~= "" then text = rendered end
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    self:write(text)
  end
  self:run_finished()
end

function METHODS:failed(problem)
  self:clear()
  self:line(paint("  ! " .. tostring(problem or "error"), "red", self.live))
  self:run_finished()
end

-- A bug in this renderer must not kill the run it is describing: the transcript belongs
-- to the node, not to the view. Say so once, visibly, and let the run continue - a view
-- that silently swallowed its own failure would be the same defect it exists to remove.
function METHODS:warn(problem)
  if self.warned then return end
  self.warned = true
  self:clear()
  self:line(paint("  ! the run view failed: " .. tostring(problem), "red", self.live))
end

-- What the model thought before it acted. A CLI run has no SSE sink, so nothing else in this
-- process can show it: the reasoning is in the transcript, and until now it was only there.
-- pi gives it its own colour and so does this.
--
-- It is not folded. The reason to show reasoning is to read it, and a view that summarised it
-- would be the thing it exists to fix; `WASM_AGENT_CLI_THINKING=off` is how a reader who does
-- not want it turns it off. Nothing else hides it, and nothing here shortens it.
function METHODS:reasoning_block(text)
  local body = tostring(text or "")
  if body:gsub("%s", "") == "" then return end
  if (host.getenv("WASM_AGENT_CLI_THINKING") or ""):lower() == "off" then return end
  self:clear()
  local mark = paint("\226\156\187 thinking", "thinkingText", self.live)
  self:write("  " .. mark .. "\n")
  self:write(markdown.wrap(body, {
    paint = function(plain, style) return paint(plain, style, self.live) end,
    width = self.limit,
    indent = "      ",
    style = "thinkingText",
  }) .. "\n")
  self:paint(true)
end

-- ---- the console ------------------------------------------------------------------

-- Every event as it arrived, and a tool's output as it came back. The formatted view answers
-- "what is it doing"; this answers "what actually happened", which is the question a one-line
-- summary cannot. It is a toggle (`/console`) rather than the default because it is a
-- firehose: nothing here is clipped, folded or summarised.
function METHODS:set_console(on)
  self.console = on and true or false
  if self.console then self:unanimate() end
  return self.console
end

function METHODS:console_on()
  return self.console and true or false
end

function METHODS:console_event(event)
  local kind = tostring(event.type or "?")
  local since = self.turn and self.turn.started or self.now()
  local head = "  " .. paint(M.duration(math.max(0, self.now() - since)), "dim", self.live)
    .. " " .. paint(kind, "accent", self.live)
  self:clear()
  if kind == "tool_result" then
    local result = type(event.result) == "table" and event.result or { value = event.result }
    self:write(head .. " " .. tostring(event.name or "?") .. "\n")
    local shown = false
    -- The tool's own words, whole: this is the view a reader turns on precisely because the
    -- two-line summary cut something off.
    for _, key in ipairs({ "stdout", "stderr", "error" }) do
      local text = result[key]
      if type(text) == "string" and text ~= "" then
        shown = true
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          self:write("      " .. line .. "\n")
        end
      end
    end
    if not shown then
      for line in (json.encode(result) .. "\n"):gmatch("([^\n]*)\n") do
        self:write("      " .. line .. "\n")
      end
    end
  else
    self:write(head .. " " .. json.encode(event) .. "\n")
  end
end

function METHODS:event(event)
  local kind = event.type
  if self.console then
    -- The console is what draws, but the numbers are still kept: switching it off mid-run
    -- must not leave the footer counting a run it never saw.
    if kind == "usage" then
      self.totals = event.total or self.totals
      self.context = tonumber(event.prompt) or self.context
    end
    return self:console_event(event)
  end
  if kind == "status" then
    local text = tostring(event.text or "")
    if text == "thinking" or text == "model" then
      self.phase = "Thinking"
      self.pending = nil
      self:paint()
    elseif text ~= "" then
      -- Compaction, recovery, a guard, a storage failure: not a phase, and worth a line
      -- of its own - these are exactly the events that used to be invisible here.
      self:line(paint("  ! " .. M.clip(text, self.limit), "yellow", self.live))
    end
  elseif kind == "round" then
    self.round = tonumber(event.n) or (self.round + 1)
    if self.turn then self.turn.rounds = self.round end
    self:paint()
  elseif kind == "tool" then
    self.pending = { name = event.name or "?", started = self.now() }
    if event.timeout_ms then self.pending.bound = tonumber(event.timeout_ms) / 1000 end
    self.phase = M.phase(self.pending.name)
    if self.turn then self.turn.tools = self.turn.tools + 1 end
    self:line("  " .. paint("\226\151\143", "accent", self.live) .. " " .. paint(self.pending.name or "?", "bold", self.live)
      .. "  " .. paint(M.call_line(event.name, event.arguments, self.limit - 12), "dim", self.live))
    self:paint(true)
  elseif kind == "tool_result" then
    local name = event.name or (self.pending and self.pending.name) or "?"
    local ms = self.pending and ((self.now() - self.pending.started) * 1000) or nil
    local ok, note = M.outcome(name, event.result)
    local marks = {}
    marks[#marks + 1] = paint(ok and "ok" or "failed", ok and "green" or "red", self.live)
    if note ~= "" then marks[#marks + 1] = note end
    if ms then marks[#marks + 1] = M.elapsed(ms) end
    self:line("  " .. paint("\226\148\148", "dim", self.live) .. " " .. table.concat(marks, " \194\183 "))
    for _, text in ipairs(M.preview(name, event.result, 2)) do
      -- A diff line reads as a diff: added, removed, context - pi's three diff roles.
      local style = "dim"
      if text:sub(1, 1) == "+" then style = "toolDiffAdded"
      elseif text:sub(1, 1) == "-" then style = "toolDiffRemoved"
      elseif text:sub(1, 2) == "@@" then style = "toolDiffContext" end
      self:write("      " .. paint(M.clip(text, self.limit - 6), style, self.live) .. "\n")
    end
    self.pending = nil
    self.phase = "Thinking"
    self:paint(true)
  elseif kind == "reasoning" then
    self:reasoning_block(event.text)
  elseif kind == "usage" then
    self.totals = event.total or self.totals
    -- The context in use is the last model call's prompt, measured by the provider;
    -- `total.prompt` is the session's running sum and would grow without bound.
    self.context = tonumber(event.prompt) or self.context
  elseif kind == "compact" then
    self:line(paint("  ! compacted through seq " .. tostring(event.through or "?"), "dim", self.live))
  elseif kind == "delta" then
    -- A CLI run has no sink, so this normally never fires; if it does (a peer or a window
    -- run printing here) the text is already the answer and must not be swallowed.
    self:clear()
    self.deltas = self.deltas + 1
    self:write(event.text or "")
  elseif kind == "error" then
    self:clear()
    self:line(paint("  ! " .. tostring(event.error or "error"), "red", self.live))
  end
end

-- The startup lines: where this is running and what it is running with. pi puts the
-- workspace and the branch in front of the reader, and so does this - a chat in the
-- wrong worktree is a mistake that costs an hour to notice otherwise.
function M.banner(opts)
  opts = opts or {}
  local lines = {}
  lines[#lines + 1] = string.format("  %s %s",
    paint("wasm-agent", { "bold", "accent" }, opts.live), opts.version or "")
  lines[#lines + 1] = string.format("  %s %s",
    paint("model     ", "muted", opts.live), opts.model or "local mode (no model configured)")
  lines[#lines + 1] = string.format("  %s %s",
    paint("memory    ", "muted", opts.live), opts.database or "")
  lines[#lines + 1] = string.format("  %s %s%s",
    paint("session   ", "muted", opts.live), opts.session or "",
    opts.continued and "  (continued)" or "")
  if opts.workspace and opts.workspace ~= "" then
    lines[#lines + 1] = string.format("  %s %s%s", paint("workspace ", "muted", opts.live),
      opts.workspace,
      opts.branch and opts.branch ~= "" and ("  (" .. opts.branch .. ")") or "")
  end
  if opts.unfinished then
    lines[#lines + 1] = paint("  !          unfinished " .. opts.unfinished, "warning", opts.live)
    lines[#lines + 1] = "             recovering: wa resume --session " .. tostring(opts.session or "")
  end
  lines[#lines + 1] = string.format("  %s", paint("the status line shows what a run is doing while it runs",
    "dim", opts.live))
  lines[#lines + 1] = string.format("  %s", paint("/help for commands, /exit to quit", "dim", opts.live))
  return table.concat(lines, "\n")
end

return M
