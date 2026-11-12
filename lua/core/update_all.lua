-- `wa update --all`: one table of what an update would install, per node, and what each node says it runs.
--
-- READ-ONLY, and that is the whole contract. It fetches this node's `origin` (the local check does, and
-- that is the one network write-free call it makes), asks each peer one signed read
-- (`remote_update.inspect` -> the peer's own `check`, which gathers facts and writes nothing), and prints.
-- It never queues a deploy, never writes a request, never asks a peer to install anything: `wa update
-- <node>` is the call that does that, one node at a time, under that node's own Sentinel.
--
-- WHY THE STATES ARE SHAPED THIS WAY. `behind` is a fact about this node because its tree holds the
-- history (`update.check` counts `installed..origin/main`). A peer's history is not here, so the only
-- honest comparison of a peer's installed commit with the candidate is `current` (the same commit) or
-- `differs` - and `differs` says exactly that, rather than pretending to know which side is newer. A node
-- that could not be read is `unknown` with the reason, never a blank cell and never "up to date".
--
-- The columns are the ring's own vocabulary (docs/TORUS.md, ring 1): what is installed, what the candidate
-- is, and the verdict a reader can act on.
local M = {}

local trim = function(text, limit)
  text = tostring(text or ""):gsub("[\r\n]+", " ")
  if limit and #text > limit then return text:sub(1, limit - 1) .. "…" end
  return text
end

local short = function(sha)
  sha = tostring(sha or "")
  if sha == "" then return "" end
  return sha:sub(1, 12)
end

M.COLUMNS = { "node", "where", "installed", "candidate", "state", "detail" }

-- How wide a cell may be rendered before it is clipped. `detail` is the explanation, so it gets the most
-- room; everything else is an identifier or a short word.
local CLIP = { detail = 160, node = 40, where = 8, installed = 16, candidate = 16, state = 12 }

-- One row for the local node, from `update.check`'s report (the same report `wa update --check` prints).
local function local_row(report)
  report = type(report) == "table" and report or {}
  local state = tostring(report.status or "unknown")
  -- `no_runtime_tree` and `source_fetch_failed` are reasons, not verdicts: a reader must not see either as
  -- a state of the install.
  if state == "no_runtime_tree" or state == "source_fetch_failed" then state = "unknown" end
  return {
    node = "this node",
    where = "local",
    installed = short(report.installed),
    candidate = short(report.target),
    state = state,
    detail = trim(report.message or report.error or ""),
  }
end

-- One row per peer. `reply` is `remote_update.inspect`'s answer: the peer's own facts, read only.
local function peer_row(row, reply, candidate)
  local name = tostring(row.name or row.node_id or row.id or "?")
  local out = { node = name, where = "peer", installed = "", candidate = short(candidate), state = "unknown", detail = "" }
  if row.online == false then
    out.detail = "offline (the rendezvous does not report it online)"
    return out
  end
  if type(reply) ~= "table" then
    out.detail = "no answer from the peer"
    return out
  end
  if reply.error then
    out.detail = trim(tostring(reply.error) .. (reply.observed and (" (" .. trim(reply.observed) .. ")") or ""), 96)
    return out
  end
  local installed = short(reply.installed_commit)
  out.installed = installed
  -- The peer's own warnings are read BEFORE the "no commit" return below: a node that names no commit and
  -- has no watcher is two facts, and reporting only the first would hide the one that explains why.
  local notes = {}
  if reply.dirty and tonumber(reply.dirty) and tonumber(reply.dirty) > 0 then
    notes[#notes + 1] = "tree dirty"
  end
  if reply.watcher == false then notes[#notes + 1] = "no watcher running" end
  if type(reply.pending_deploys) == "table" and #reply.pending_deploys > 0 then
    notes[#notes + 1] = tostring(#reply.pending_deploys) .. " deploy pending"
  end
  if installed == "" then
    notes[#notes + 1] = "the peer names no installed commit"
    out.detail = trim(table.concat(notes, "; "), 160)
    return out
  end
  if candidate == "" then
    notes[#notes + 1] = "this node has no candidate to compare with"
  elseif installed == short(candidate) or reply.installed_commit == candidate then
    out.state = "current"
  else
    out.state = "differs"
    -- The reason comes first: it is the sentence that keeps a reader from reading `differs` as "behind".
    table.insert(notes, 1, "which side is newer needs that node's history (peer_history_unavailable)")
  end
  out.detail = trim(table.concat(notes, "; "), 160)
  return out
end

-- <opts> nodes? local_report? inspect? candidate? -> array of rows (local first, then peers by name).
function M.rows(opts)
  opts = type(opts) == "table" and opts or {}
  local nodeslib = dofile("lua/core/nodes.lua")
  local list = opts.nodes
  if type(list) ~= "table" then
    local ok, value = pcall(nodeslib.list, {})
    list = ok and type(value) == "table" and value or {}
  end
  local local_report = opts.local_report
  if type(local_report) ~= "table" then
    local update = dofile("lua/core/update.lua")
    local ok, value = pcall(update.check, {})
    local_report = ok and type(value) == "table" and value or { status = "unknown", message = "the local check did not answer" }
  end
  local candidate = opts.candidate or (type(local_report) == "table" and local_report.target) or ""
  local inspect = opts.inspect
  if type(inspect) ~= "function" then
    local remote = dofile("lua/core/remote_update.lua")
    inspect = function(name) return remote.inspect(nodeslib.remote_call, name) end
  end
  local rows, peers = {}, {}
  local saw_local = false
  for _, node in ipairs(list) do
    if node.local_node or node.kind == "host" then
      saw_local = true
      rows[#rows + 1] = local_row(local_report)
    else
      local ok, reply = pcall(inspect, node.name or node.node_id or node.id)
      peers[#peers + 1] = peer_row(node, ok and reply or nil, candidate)
    end
  end
  -- A list that carries no local row (a fixture, or a node that could not read its own record) still gets
  -- one: the local node is the row this command is most able to answer, and dropping it silently would be
  -- the same "nobody looked" this table exists to prevent.
  if not saw_local then table.insert(rows, 1, local_row(local_report)) end
  table.sort(peers, function(a, b) return tostring(a.node) < tostring(b.node) end)
  for _, row in ipairs(peers) do rows[#rows + 1] = row end
  return rows
end

-- The counts a reader needs before the table: never a claim about the rows it could not read.
function M.summary(rows)
  local counts, total = {}, 0
  for _, row in ipairs(rows or {}) do
    total = total + 1
    counts[row.state] = (counts[row.state] or 0) + 1
  end
  local parts = {}
  for _, state in ipairs({ "current", "behind", "differs", "unknown", "ahead" }) do
    if counts[state] then parts[#parts + 1] = tostring(counts[state]) .. " " .. state end
  end
  for state, count in pairs(counts) do
    if state ~= "current" and state ~= "behind" and state ~= "differs" and state ~= "unknown" and state ~= "ahead" then
      parts[#parts + 1] = tostring(count) .. " " .. tostring(state)
    end
  end
  return string.format("%d node(s): %s", total, #parts > 0 and table.concat(parts, ", ") or "nothing to say")
end

function M.render(rows, opts)
  opts = type(opts) == "table" and opts or {}
  rows = rows or {}
  local widths = {}
  for _, column in ipairs(M.COLUMNS) do widths[column] = #column end
  for _, row in ipairs(rows) do
    for _, column in ipairs(M.COLUMNS) do
      widths[column] = math.max(widths[column], #trim(row[column] or "", CLIP[column]))
    end
  end
  -- `detail` is the last column, so it is not padded: a trailing width there is only whitespace. Every
  -- cell is clipped first, whatever the caller put in it: a row with a 400-character detail must not turn
  -- the table into a paragraph, and a table is the one thing a reader has to be able to scan.
  local function line(cells)
    local parts = {}
    for index, column in ipairs(M.COLUMNS) do
      local text = trim(cells[column] or "", CLIP[column])
      if index == #M.COLUMNS then parts[#parts + 1] = text
      else parts[#parts + 1] = text .. string.rep(" ", widths[column] - #text) end
    end
    return table.concat(parts, "  ")
  end
  local out = { line({ node = "node", where = "where", installed = "installed", candidate = "candidate", state = "state", detail = "detail" }) }
  for _, row in ipairs(rows) do out[#out + 1] = line(row) end
  out[#out + 1] = M.summary(rows)
  out[#out + 1] = "read-only: this table installs nothing; `wa update <node>` asks one node to update itself."
  if opts.note and opts.note ~= "" then out[#out + 1] = tostring(opts.note) end
  return table.concat(out, "\n")
end

function M.run(opts)
  local rows = M.rows(opts)
  return M.render(rows, opts)
end

return M
