-- The file changes a turn made, and the way back.
--
-- A diff topic the reader can undo is only honest if the undo is real: it has to put
-- the *files* back, not fold the topic shut. So the change is recorded where it happens
-- - `write`/`edit` already hold the previous text in their hand - as an inverse operation
-- (path, before, after), and the pair is what the UI renders and what undo replays.
--
-- Recorded per turn, not per process: the record belongs to the turn that made it, so a
-- node that restarts can still undo what its last turn did (the ledger survives, and so
-- does this). It is deliberately *not* a git patch: `git diff` cannot say what the turn
-- did versus what was already dirty, and it cannot restore a file whose later edits have
-- moved on - which is exactly the case where a naive undo destroys newer work.
--
-- Only *content* changes are recorded. A file the turn created and a file it emptied are
-- the same record (before = ""), because the host has no remove_file: undo therefore
-- never deletes, it restores text. That is a real limit, so it is stated here and shown in
-- the topic ("created" is not a case this can undo) rather than hidden behind a button
-- that would fail.
--
-- Restoring is guarded: undo refuses to clobber a file that no longer looks like what the
-- turn left, and says why. A silent revert that eats someone's newer edit is the failure
-- this guard exists to prevent.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- Cap a single recorded file's text. A diff topic is a summary, and a megabyte of
-- before/after per file would put the whole file in the transcript twice. Beyond the cap
-- the change is recorded as `recorded = false`, so the topic can say "too large to undo"
-- instead of offering a button that cannot work.
local RECORD_CAP = 262144

local function split_lines(text)
  local lines = {}
  if not text or text == "" then return lines end
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end

-- Lines added and removed between two texts. Deliberately a simple count rather than a
-- text diff: the number is what the header shows ("+12 -3"), and the exact interleaving
-- is the topic's business, not the counter's. Counting a shared prefix and suffix is
-- what makes a one-line edit read as +1 -1 instead of +2000 -2000 on a large file.
local function line_delta(before, after)
  local a, b = split_lines(before), split_lines(after)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < (#a - head) and tail < (#b - head)
    and a[#a - tail] == b[#b - tail] do tail = tail + 1 end
  return (#b - head - tail), (#a - head - tail)
end

function M.new()
  return { files = {}, added = 0, removed = 0 }
end

-- Record one file's change. `before` nil means the file did not exist (a create);
-- `after` nil means it was removed. Both in hand at the call site, which is the point.
function M.record(entry, path, before, after)
  local recorded = true
  if type(before) == "string" and #before > RECORD_CAP then recorded = false end
  if type(after) == "string" and #after > RECORD_CAP then recorded = false end
  local added, removed = line_delta(before, after)
  entry.files[#entry.files + 1] = {
    path = path, before = before, after = after,
    added = added, removed = removed, recorded = recorded,
  }
  entry.added = entry.added + added
  entry.removed = entry.removed + removed
  return entry
end

-- True when there is nothing a reader would call a change.
function M.empty(entry)
  return not entry or #entry.files == 0
end

-- The turn's changed files, as the UI wants them: no file bodies, just the shape and the
-- counts. The bodies stay on the server, where undo can reach them.
function M.summary(entry)
  if M.empty(entry) then return nil end
  local files = {}
  for _, file in ipairs(entry.files) do
    files[#files + 1] = {
      path = file.path, added = file.added, removed = file.removed,
      created = file.before == "",
      recorded = file.recorded,
    }
  end
  return { files = files, added = entry.added, removed = entry.removed }
end

-- Put the files back, newest change first, and refuse rather than clobber.
--
-- Undo is all-or-nothing by design: a half-restored edit is worse than none, so the
-- guards all run before the first write. The check is "does the file still look like what
-- the turn left?", compared on the whole text rather than a region, because the record
-- already holds the whole text and a partial comparison would have to guess where the
-- edit was. A file that moved on is *refused*, never merged: guessing at intent here is
-- how newer work gets eaten.
function M.undo(entry)
  if M.empty(entry) then return nil, "nothing_to_undo" end
  for _, file in ipairs(entry.files) do
    if not file.recorded then return nil, "too_large_to_undo:" .. file.path end
  end
  local host_write = host.write_file
  -- Guard first, write second: nothing has been touched when a refusal is returned.
  for _, file in ipairs(entry.files) do
    local now = host.read_file and host.read_file(file.path)
    if now ~= nil and now ~= file.after then
      -- The refusal says which file, so the reader knows what to reconcile.
      return nil, "changed_since_turn:" .. file.path
    end
    if now == nil and file.after ~= nil then
      -- The file is gone. Restoring is not a revert of this turn, it is recreating
      -- something someone removed - refused, and named.
      return nil, "missing_since_turn:" .. file.path
    end
  end
  for _, file in ipairs(entry.files) do
    if not host_write or not host_write(file.path, file.before or "") then
      return nil, "write_failed:" .. file.path
    end
  end
  return true, "undone"
end

-- Apply the change again, after an undo. Same guards, same all-or-nothing rule: a redo
-- that cannot run must say so rather than leave half the files forward and half back.
function M.redo(entry)
  if M.empty(entry) then return nil, "nothing_to_redo" end
  for _, file in ipairs(entry.files) do
    if not file.recorded then return nil, "too_large_to_redo:" .. file.path end
  end
  local host_write = host.write_file
  for _, file in ipairs(entry.files) do
    local now = host.read_file and host.read_file(file.path)
    if now ~= nil and now ~= file.before then
      return nil, "changed_since_undo:" .. file.path
    end
  end
  for _, file in ipairs(entry.files) do
    if not host_write or not host_write(file.path, file.after or "") then
      return nil, "write_failed:" .. file.path
    end
  end
  return true, "redone"
end

return M
