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
local json = dofile("lua/vendor/json.lua")

local M = {}

-- How old a published snapshot may be before the next free moment rebuilds it. A node's roster moves
-- on the scale of minutes; a rebuild costs one panel's worth of formatting, or nothing when the
-- roster cache is still warm (`nodes.list({cached = true})`).
M.MAX_AGE = 60

-- The views by the command that opens them. Each builder returns
-- `{command, captured_at, views = {{title, lines, options}, ...}}` - `views[1]` the root, and
-- `options[i].view` the index of the panel an option opens (`pop = true` is the way back).
local builders = {
  ["/nodes"] = function(opts) return dofile("lua/core/nodes_cli.lua").views(opts) end,
}

-- When each view was last published (`host.now` seconds), so a refresh knows what is already there.
local published_at = {}

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
function M.publish(name, set)
  if not M.available() then return false, "unavailable" end
  local spec = { command = set.command or name, captured_at = set.captured_at or host.now(), views = set.views or {} }
  local sent, raw = pcall(host.local_view, name, json.encode(spec))
  if not sent then return false, tostring(raw) end
  local decoded_ok, answer = pcall(json.decode, raw)
  if not decoded_ok or type(answer) ~= "table" then return false, "unreadable answer" end
  if answer.ok ~= true then return false, tostring(answer.error or "refused") .. (answer.detail and (" " .. tostring(answer.detail)) or "") end
  published_at[name] = spec.captured_at
  return true
end

-- Rebuild and publish the views that are missing or older than `opts.max_age`.
--
-- Called where this side is not blocked: at a turn's start (`opts.cached` unset - a live roster read
-- is what the reader asked for) and at a model-round boundary (`opts.cached = true` - the run is
-- still going, so the roster comes from the cache and the rendezvous is not asked). Returns how many
-- were published, and the first problem, which the caller reports *once* rather than on every round:
-- a snapshot that never lands is a fact worth saying, not worth repeating.
function M.refresh(opts)
  opts = opts or {}
  if not M.available() then return 0, nil end
  local now = host.now()
  local max_age = tonumber(opts.max_age) or M.MAX_AGE
  local count = 0
  for _, name in ipairs(M.names()) do
    local at = published_at[name]
    if not at or (now - at) >= max_age then
      local built, set = pcall(builders[name], opts)
      if not built or type(set) ~= "table" then
        return count, string.format("%s could not be built: %s", name, tostring(set))
      end
      local done, problem = M.publish(name, set)
      if not done then return count, string.format("%s was not published: %s", name, tostring(problem)) end
      count = count + 1
    end
  end
  return count, nil
end

-- Forget what has been published. For tests and for a view whose data must be re-read (a rebind).
function M.forget()
  published_at = {}
end

return M
