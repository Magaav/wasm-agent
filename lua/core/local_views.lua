-- The read-only `/` commands the *client* can answer while a run is in flight.
--
-- Why this exists. `wa chat` runs a turn synchronously: from the reader's Enter until the last token,
-- this interpreter is blocked inside the model call, and nothing on this side can draw. The host kept
-- reading the reader's typing anyway (`host.input_start`, rust/wa-capabilities/src/host.rs), so a
-- `/nodes` typed during a run was read, queued, and opened after the turn - which for a long turn is
-- "nothing happened". `/status` never had that problem: the spec the host needs was published before
-- the run (`host.status_snapshot`) and the reader thread draws it itself when `/status` is submitted.
--
-- This is that channel for views with more than one panel. A view publishes its whole stack of panel
-- specs through `host.local_view` at the moments this side *is* running - a turn's start, and a model
-- round boundary - and the client walks the stack: Enter opens a node's page, Esc or Back returns,
-- Esc at the list closes. The specs are the ones `lua/core/nodes_cli.lua` draws with `host.panel`
-- (`M.views`), so the two surfaces cannot drift: one builder, two renderers.
--
-- What a stale snapshot may say is the point of `captured_at`: the panel is drawn with its age
-- ("snapshot 2m ago") instead of pretending the roster was read a second ago. Nothing here waits.
--
-- Absent capability (`host.local_view` is not in this binary - an older build, or a test): `refresh`
-- publishes nothing, answers 0, and `/nodes` behaves exactly as it always has. This file can be
-- landed before the host side and changes nothing until it arrives.
local M = {}

-- How old a published snapshot may be before the next free moment rebuilds it. A node's roster moves
-- on the scale of minutes; a rebuild costs one panel's worth of formatting, or nothing when the
-- roster cache is still warm (`nodes.list({cached = true})`).
M.MAX_AGE = 60
-- The client's cap on one stack (rust/wa-cli-views/src/spec.rs, MAX_VIEWS).
M.MAX_PANELS = 64

-- The views by the command that opens them. Each builder returns
-- `{command, captured_at, views = {{title, lines, options}, ...}}` - `views[1]` the root, and
-- `options[i].page` (or the older `view`) the page an option opens (`back`/`pop` is the way back).
--
-- Every builder is the SAME builder its command uses between runs, in `lua/core/balloon.lua`'s page shape:
-- `/nodes` (nodes_cli.views), `/mcp` (mcp_command.views - the list, a connector, its tools), `/login`
-- (provider_management.login_views) and `/help` (the command registry). One builder, two renderers; there
-- is no second copy of a label that can drift while the run is in flight.
local builders = {
  ["/nodes"] = function(opts) return dofile("lua/core/nodes_cli.lua").views(opts) end,
  ["/mcp"] = function(opts)
    local command = dofile("lua/core/mcp_command.lua")
    -- Mid-run the peer half comes from the federation cache and nothing waits on the network: a
    -- snapshot is allowed to be a minute old and to say so (`captured_at`), never to stall a turn.
    local ctx = opts.ctx or { user_id = "master", role = "master", session_id = opts.session_id }
    local view = command.list(ctx, { cache_only = true })
    if type(view) ~= "table" or view.ok == false then return nil end
    return command.views(view, { max_pages = M.MAX_PANELS })
  end,
  ["/login"] = function(opts)
    local manager = dofile("lua/core/provider_management.lua")
    local pages = manager.login_views(manager.state("local-operator"), {})
    return { command = "/login", captured_at = host.now(), views = pages }
  end,
  -- `/stats` and `/memories` are NOT here, and `/wakes`/`/hooks` are not either: their modules answer
  -- through a pinned component and print a note into the transcript when it is absent - a snapshot taken for
  -- a reader must never write into the chat it is drawing over. They keep their arm, and between runs they
  -- are balloons like everything else; during a run they answer when the turn ends, and the host says so on
  -- its queue row ("Queued - after the run: /stats").
  -- The keys, mid-run and in the window: the same rows, from the same table, laid out by the same
  -- module the REPL's arm uses (lua/core/keybindings.lua). Nothing is read from the terminal, so a
  -- snapshot taken while a turn is in flight is exactly as true as one taken at the prompt.
  ["/keybindings"] = function()
    local keys = dofile("lua/core/keybindings.lua")
    local rows = keys.rows()
    if not rows then return nil end
    return { command = "/keybindings", captured_at = host.now(), views = keys.view(rows) }
  end,
  ["/help"] = function(opts)
    local balloon = dofile("lua/core/balloon.lua")
    local help = dofile("lua/core/commands.lua").help()
    local rows = {}
    for row in (help .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
    return { command = "/help", captured_at = host.now(), views = balloon.paged("Help", rows, { per = 14, nowrap = true }) }
  end,
}

-- When each view was last published (`host.now` seconds), so a refresh knows what is already there. In
-- the core's store rather than in a table here (docs/HOTRELOAD.md): a reload of this file mid-run used
-- to forget which views the reader already has, and the next model round republished them all over a
-- reader who was reading one.
local reload = dofile("lua/core/reload.lua")
local published = reload.state("local_views")
if type(published.at) ~= "table" then published.at = {} end
local published_at = published.at
-- Which views have already said, in the node's log, that they could not be handed to the client. In the
-- same store for the same reason: a reload of this file must not make the node log the same refusal
-- twice.
if type(published.reported) ~= "table" then published.reported = {} end
local reported = published.reported

-- Whether this binary has the channel at all. False is an ordinary condition, not an error.
function M.available()
  return type(host) == "table" and type(host.local_view) == "function"
end

-- Which commands this file publishes, in a stable order (the help lists them; a test reads them).
function M.names()
  local names = {}
  for name in pairs(builders) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- Hand one view's stack to the client. Only what the client draws is sent: the builder also carries
-- the raw node list for the printed fallback, and the roster's resources and endpoints have no
-- business crossing to the reader thread twice.
-- Hand a view stack that was ALREADY converted (the idle prefetch's child process, lua/core/idle_reads.lua)
-- to the client. The spec is the one balloon.spec produces - the exact shape balloon.publish sends - so
-- this is the same send M.publish makes once its conversion is done; the two differ only in WHICH process
-- built the pages. Published-and-reported bookkeeping is the caller's (M.refresh), as it is for M.publish.
function M.publish_spec(name, spec)
  if not M.available() then return false, "unavailable" end
  if type(spec) ~= "table" or type(spec.views) ~= "table" then return false, "spec_unreadable" end
  local balloon = dofile("lua/core/balloon.lua")
  local done, problem = balloon.publish_spec(name, spec)
  if done then published_at[name] = math.floor(tonumber(spec.captured_at) or host.now()) end
  return done, problem
end
function M.publish(name, set)
  if not M.available() then return false, "unavailable" end
  local spec = { command = set.command or name, captured_at = math.floor(tonumber(set.captured_at) or tonumber(host.now()) or 0), views = set.views or {} }
  -- The page links are converted in ONE place (`lua/core/balloon.lua`'s `publish`): a page is 1-based here
  -- and its published `view` is 0-based, and two conversions would be two chances to disagree.
  local balloon = dofile("lua/core/balloon.lua")
  local done, problem = balloon.publish(set.command or name, spec.views, spec.captured_at)
  if done then published_at[name] = spec.captured_at; return true end
  if problem == "unavailable" then return false, "unavailable" end
  return false, tostring(problem)
end

-- A view that could not be published, said ONCE per view and ONLY where a bug is read.
--
-- The transcript belongs to the run, and a panel the reader did not ask for is not a failure of it:
-- `/nodes` printed `! the run view failed: local views: /nodes was not published: line_too_long
-- views[2].lines[3]: 3030 characters` in red, in the middle of the conversation, on every run (Victor,
-- 21/11). The fact is still recorded, in the `[lua] ...` channel the rest of the node logs to, once per
-- view rather than once per model round; nothing is written to the transcript, and the run continues
-- with whatever snapshot the client already has.
--
-- Returns whether this call wrote the line (a test asserts the once).
function M.report(name, problem)
  name = tostring(name or "?")
  if reported[name] then return false end
  reported[name] = true
  local text = string.format("local view %s was not published: %s", name, tostring(problem))
  if type(host) == "table" and type(host.log) == "function" then
    -- Redacted: the node's log carries no message text (AGENTS.md), and a Lua error can quote one.
    local ok, redact = pcall(dofile, "lua/core/redact.lua")
    pcall(host.log, ok and redact.text and redact.text(text) or text)
  end
  return true
end

-- What the chat's publish step is: hand the client the views it is missing, and report a refusal only to
-- the log. A panel needs the raw editor (the same condition `/status`'s snapshot has), so a console
-- without one publishes nothing. Returns how many views went out, and NOTHING for a caller to print -
-- that is the whole point (see `M.report`).
function M.publish_all(view, opts)
  if not (view and view.editor and view.stdout) then return 0 end
  return (M.refresh(opts))
end

-- Build - NEVER publish - the views that are missing or older than opts.max_age, in M.names() order.
--
-- Each entry is {name = "/nodes", set = <the builder's table>, problem = <why it could not be built>}: a
-- view that failed keeps its place in the order and names its reason, so the caller can apply exactly the
-- rules M.refresh applies (below) in exactly the order it used to apply them. ONE builder for the two
-- callers: this process (M.refresh) and the idle prefetch's child (lua/core/idle_reads.lua), which builds
-- the same panels somewhere else so a blocking read cannot hold the reader's Enter.
function M.collect(opts)
  opts = opts or {}
  local entries = {}
  if not M.available() then return entries end
  local now = host.now()
  local max_age = tonumber(opts.max_age) or M.MAX_AGE
  for _, name in ipairs(M.names()) do
    local at = published_at[name]
    if not at or (now - at) >= max_age then
      local built, set = pcall(builders[name], opts)
      if not built then
        entries[#entries + 1] = { name = name,
          problem = string.format("%s could not be built: %s", name, tostring(set)) }
      elseif type(set) ~= "table" then
        -- Nothing to show (no data yet, or a builder that declined): not a failure, and not worth a line on
        -- the reader's screen. It is tried again at the next boundary.
        M.forget(name)
        entries[#entries + 1] = { name = name }
      else
        entries[#entries + 1] = { name = name, set = set }
      end
    end
  end
  return entries
end

-- Rebuild and publish the views that are missing or older than opts.max_age.
--
-- Called where this side is not blocked: at a turn's start (opts.cached unset - every read comes from
-- what this process already has) and, since 22/11, by the idle prefetch's CHILD (lua/core/idle_reads.lua)
-- whose answer this process publishes on a later tick. Returns how many were published, and the first
-- problem, which the caller reports *once* rather than on every round: a snapshot that never lands is a
-- fact worth saying, not worth repeating.
function M.refresh(opts)
  opts = opts or {}
  if not M.available() then return 0, nil end
  local now = host.now()
  local count, problem = 0, nil
  for _, entry in ipairs(M.collect(opts)) do
    if entry.problem then
      -- One view that cannot be built must not cost the others their snapshot: /login on a node with no
      -- provider state used to stop /nodes publishing, and the reader lost a view that worked.
      problem = problem or entry.problem
      M.report(entry.name, entry.problem)
      -- Tried: wait max_age like a success. A failure retried at every round boundary paid the whole build
      -- each round (17/11, work: /mcp refused, rebuilt every round, ~2 s per round).
      published_at[entry.name] = now
    elseif entry.set == nil then
      -- Declined (M.collect already forgot it): nothing was published and nothing is reported.
    else
      local done, why = M.publish(entry.name, entry.set)
      if not done then
        problem = problem or string.format("%s was not published: %s", entry.name, tostring(why))
        M.report(entry.name, tostring(why))
        published_at[entry.name] = now
      else
        count = count + 1
      end
    end
  end
  return count, problem
end

-- Forget what has been published. For tests and for a view whose data must be re-read (a rebind).
function M.forget(name)
  if name then published_at[name] = nil; reported[name] = nil else
    for key in pairs(published_at) do published_at[key] = nil end
    for key in pairs(reported) do reported[key] = nil end
  end
end

return M
