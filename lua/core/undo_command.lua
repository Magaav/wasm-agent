-- `/undo`: the chat's door to the undo that already exists.
--
-- The undo itself is not here and is not new. `wa_diff` (`lua/core/server.lua`) answers "can this turn be
-- undone?" and "do it" for a topic the reader clicked, and it requires a master's browser session; the
-- CLI has neither. This module makes the SAME two calls on the newest recorded turn of this session -
-- `changeset.check` then `changeset.undo` - so the window and the chat cannot disagree about what undo
-- does or why it refuses. Nothing here writes a file, decides a version or repairs a change.
--
-- The reason this file exists at all is that the promise was ahead of the product: the `remote` tool's
-- own description told the model "the change is recorded here, so /undo restores that file there", and a
-- chat had no /undo (measured 23/11: typing it answered "unknown or incomplete command").
--
-- A file that lives on a PEER is verified and restored through the transport the route installs
-- (`lua/core/remote_files.lua`): the chat process never loads the server, so it installs the same one
-- itself. The restore is therefore the same fenced remote write the route performs, and the version it
-- checks is the peer's own read answer.
local M = {}

-- Named refusals. `changeset` refuses in words - `changed_since_turn:<path>` - and those words are the
-- useful part for whoever has to act (which file moved, on which node, and how). The NAME is what a
-- reader can decide on, so this is the one place that classifies a reason, and a reason nobody has
-- classified stays `refused` with its own text: unknown is never a pass.
local CATEGORIES = {
  { name = "nothing_to_undo", why = "this session has recorded no file change" },
  { name = "version_moved", why = "the file is not what that turn left there" },
  { name = "node_unreachable", why = "the node that holds the file could not be read" },
  { name = "not_recorded", why = "that change was not recorded well enough to put back" },
  { name = "write_failed", why = "the write that would put it back failed" },
  { name = "restore_unverified", why = "the file did not hold the previous text after the restore" },
}

local function starts(reason, prefix)
  return reason:sub(1, #prefix) == prefix
end

-- Which category a reason belongs to. Order matters only in that the first match wins; every rule is a
-- positive match on a reason this tree produces, so a new reason falls through to `refused` and is
-- printed rather than guessed at.
function M.category(reason)
  reason = tostring(reason or "")
  if reason == "nothing_to_undo" or reason == "nothing_to_redo" then return "nothing_to_undo" end
  if starts(reason, "changed_since_turn:") or starts(reason, "missing_since_turn:")
    or starts(reason, "changed_since_undo:") then return "version_moved" end
  if starts(reason, "node_unreadable:") or starts(reason, "no_node_transport")
    or reason:find("node_no_answer", 1, true) or reason:find("remote_unreachable", 1, true)
    or reason:find("peer_offline", 1, true) then return "node_unreachable" end
  if starts(reason, "too_large_to_undo:") or starts(reason, "too_large_to_redo:")
    or starts(reason, "previous_text_missing:") or starts(reason, "recorded_text_missing:")
    or reason:find("peer_sent_no_change_text", 1, true) then return "not_recorded" end
  if reason:find("write_failed", 1, true) then return "write_failed" end
  if starts(reason, "restore_unverified:") then return "restore_unverified" end
  return "refused"
end

local function sentence_for(category)
  for _, row in ipairs(CATEGORIES) do
    if row.name == category then return row.why end
  end
  return "the undo did not run"
end

-- The refusal as the reader sees it: the name and the plain sentence on one row, the harness's own words
-- on the next. Two rows because a reason carries a path (`changed_since_turn:/a/long/path`), and a single
-- row is what a narrow terminal cuts in half - the half a reader needs to know which file moved on.
local function refused(reason)
  local category = M.category(reason)
  return { ok = false, reason = reason, category = category,
    lines = { string.format("  undo: refused (%s) - %s", category, sentence_for(category)),
      string.format("    %s", tostring(reason)) } }
end

M.refused = refused

-- What the file holds NOW, as a version: a peer is asked for its digest (one small call), a local file is
-- read and hashed. `nil` and the reason when it cannot be told - and that is a refusal, never a pass.
local function current_version(file, given)
  local remote_files = dofile("lua/core/remote_files.lua")
  if type(file.node) == "string" and file.node ~= "" then
    local transport = remote_files.transport(file.node, given)
    if type(transport) ~= "table" or type(transport.digest) ~= "function" then
      return nil, "no_node_transport:" .. tostring(file.path)
    end
    local digest, why = transport.digest(file.path)
    if digest == nil then return nil, "node_unreadable:" .. tostring(why or "unknown") .. ":" .. tostring(file.path) end
    return digest
  end
  if type(host.read_file) ~= "function" then return nil, "no_host:" .. tostring(file.path) end
  local text = host.read_file(file.path)
  if text == nil then return nil, "missing_since_turn:" .. tostring(file.path) end
  return host.sha256(text)
end

local function where(file)
  if type(file.node) == "string" and file.node ~= "" then return "on " .. file.node end
  return "this node"
end

-- Undo the last recorded change of this session.
--
--   opts.session_id  the session whose newest recorded change is put back (required)
--   opts.memory      the memory module (a test passes the one it seeded)
--   opts.changeset   the changeset module (a test passes the one its run recorded into)
--   opts.nodes       the nodes module to reach a peer with (default: this build's own)
--
-- Returns { ok, category, reason, lines }: `lines` are the sentences the chat prints, and nothing here
-- prints. The caller owns the terminal.
function M.run(opts)
  opts = opts or {}
  local session_id = tostring(opts.session_id or "")
  local memory = opts.memory or dofile("lua/core/memory.lua")
  local changeset = opts.changeset or dofile("lua/core/changeset.lua")
  local nodeslib = opts.nodes or dofile("lua/core/nodes.lua")
  local remote_files = dofile("lua/core/remote_files.lua")
  -- Installed on every call, and cheap: the route does the same, and a chat that never loaded the server
  -- has to reach the peer the change was made on.
  remote_files.install(changeset, nodeslib)

  if session_id == "" then return refused("nothing_to_undo") end
  local turn = memory.last_change_turn(session_id)
  if not turn then return refused("nothing_to_undo") end

  -- The ledger keeps one row per write and an older row may hold a path twice, so the entry is merged as
  -- it is read - exactly as the route does it, for the reason stated there: without the merge, undo would
  -- restore an intermediate state and call it success.
  local entry = changeset.normalize(turn.changes)
  local can, why = changeset.check(entry)
  if not can then return refused(why) end

  local done, undone_why = changeset.undo(entry)
  if not done then return refused(undone_why) end

  -- The restore is checked against the record rather than believed: every text in the store is addressed
  -- by its own sha256, so `file.before` IS the version the file has to hold now. A file whose version is
  -- something else is named, and the answer is a failure - a write that reported ok is not the effect.
  local lines = {}
  if #entry.files > 1 then
    lines[#lines + 1] = string.format("  undo: restored %d files from the last recorded change", #entry.files)
  end
  for _, file in ipairs(entry.files) do
    local now, cannot = current_version(file, nodeslib)
    if now == nil then return refused(cannot) end
    if now ~= file.before then
      return refused("restore_unverified:" .. tostring(file.path) .. ":" .. tostring(now))
    end
    if file.created then
      lines[#lines + 1] = string.format(
        "    %s (%s) - emptied: that turn created it, and undo restores text, it never deletes",
        tostring(file.path), where(file))
    else
      lines[#lines + 1] = string.format("    %s (%s) - version %s",
        tostring(file.path), where(file), tostring(now):sub(1, 12))
    end
  end
  if #entry.files == 1 then
    -- One file reads as one sentence, not as a heading and a row under it: the heading is noise when
    -- there is nothing to count.
    lines[1] = "  undo: " .. lines[1]:sub(5)
  end
  return { ok = true, category = "undone", lines = lines }
end

return M
