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
local paths = dofile("lua/core/paths.lua")
local M = {}

-- Where the reversible text lives: content-addressed files under the data directory,
-- exactly like attachments/ (memory.lua, "images"), and for the same three reasons - the
-- transcript is not a place for a file's contents, identical text is stored once, and the
-- path is stable so a replay can resolve it. Refusing to invent a second storage scheme is
-- the point: one rule, one place to look when something is missing.
local function store_dir()
  return paths.data() .. "/changes"
end

-- Write one text and return its content address, or nil and a reason. "" is a legal
-- address (an emptied file), but a *missing* file is not text at all, so `nil` never
-- reaches here - callers pass "" for "did not exist".
function M.store(text)
  if type(text) ~= "string" then return nil, "not_text" end
  local digest = host.sha256(text)
  local path = store_dir() .. "/" .. digest:sub(1, 2) .. "/" .. digest
  if not (host.read_file and host.read_file(path)) then
    if not (host.write_file and host.write_file(path, text)) then
      return nil, "store_write_failed:" .. path
    end
  end
  return digest
end

-- Read one back by address. A missing blob returns nil *and says so*: undo must be able to
-- report "the previous text is gone" rather than restoring an empty file over a real one.
function M.load(digest)
  if type(digest) ~= "string" or digest == "" then return nil, "no_address" end
  local path = store_dir() .. "/" .. digest:sub(1, 2) .. "/" .. digest
  local text = host.read_file and host.read_file(path)
  if text == nil then return nil, "blob_missing" end
  return text
end

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

-- Record one file's change. `before` is the previous text, `""` when the file did not
-- exist (a create). Both are in hand at the call site, which is the point - and both go to
-- the content-addressed store rather than into the entry, so the entry stays small enough
-- to carry in a transcript.
function M.record(entry, path, before, after)
  local recorded = true
  if type(before) == "string" and #before > RECORD_CAP then recorded = false end
  if type(after) == "string" and #after > RECORD_CAP then recorded = false end
  local before_id, after_id
  if recorded then
    before_id = M.store(before or "")
    after_id = M.store(after or "")
    -- A store failure is not silent: the entry is marked unrecorded so the topic says
    -- "cannot be undone" instead of offering a button whose blob is not there.
    if not before_id or not after_id then recorded = false end
  end
  local added, removed = line_delta(before, after)
  entry.files[#entry.files + 1] = {
    path = path, before = before_id, after = after_id,
    added = added, removed = removed, recorded = recorded,
    -- A create is "no text before", recorded rather than re-derived: loading the blob to
    -- ask would be a second source of truth for the same fact, and they could disagree.
    created = (before or "") == "",
  }
  entry.added = entry.added + added
  entry.removed = entry.removed + removed
  return entry
end

-- True when there is nothing a reader would call a change.
function M.empty(entry)
  return not entry or #entry.files == 0
end

-- The turn's changed files, as the UI wants them: no file bodies, just the counts and the
-- *addresses* of the reversible text. An address is a sha256, not the file, so it is safe
-- to carry in a transcript - and it is what lets undo reach the previous text long after
-- the turn ended, from the ledger alone.
function M.summary(entry)
  if M.empty(entry) then return nil end
  local files = {}
  for _, file in ipairs(entry.files) do
    files[#files + 1] = {
      path = file.path, added = file.added, removed = file.removed,
      created = file.created == true,
      before = file.before, after = file.after,
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
-- Can this entry be undone right now? Loads everything undo needs and compares each file
-- to what the turn left, without writing anything.
--
-- Split out so the *check* and the *action* cannot disagree: `undo` calls this first, and
-- the route that answers "can I undo this?" calls it too. If they were two implementations,
-- a button would eventually be offered for something the handler then refuses.
function M.check(entry)
  if M.empty(entry) then return nil, "nothing_to_undo" end
  for _, file in ipairs(entry.files) do
    if not file.recorded then return nil, "too_large_to_undo:" .. file.path end
  end
  for _, file in ipairs(entry.files) do
    local before, why = M.load(file.before)
    if before == nil then return nil, "previous_text_missing:" .. file.path end
    local left = M.load(file.after)
    if left == nil then return nil, "recorded_text_missing:" .. file.path end
    local now = host.read_file and host.read_file(file.path)
    if now ~= nil and now ~= left then return nil, "changed_since_turn:" .. file.path end
    if now == nil and left ~= "" then return nil, "missing_since_turn:" .. file.path end
  end
  return true, "undoable"
end

-- Put the files back, and refuse rather than clobber.
--
-- Undo is all-or-nothing by design: a half-restored edit is worse than none, so the guards
-- run before the first write. The check above is that guard - this function only adds the
-- writes, which is why the two cannot drift apart.
function M.undo(entry)
  local can, why = M.check(entry)
  if not can then return nil, why end
  local host_write = host.write_file
  -- Loaded before the first write, so a missing blob is a refusal and not a half-applied
  -- edit. The loads in `check` prove they are there; this reads them again to write them.
  local wanted = {}
  for index, file in ipairs(entry.files) do
    local text = M.load(file.before)
    wanted[index] = text
  end
  for index, file in ipairs(entry.files) do
    if not host_write or not host_write(file.path, wanted[index]) then
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
  local wanted = {}
  for index, file in ipairs(entry.files) do
    local text, why = M.load(file.after)
    if text == nil then return nil, "recorded_text_missing:" .. file.path end
    wanted[index] = text
  end
  local back = {}
  for index, file in ipairs(entry.files) do
    local text, why = M.load(file.before)
    if text == nil then return nil, "previous_text_missing:" .. file.path end
    back[index] = text
  end
  for index, file in ipairs(entry.files) do
    local now = host.read_file and host.read_file(file.path)
    if now ~= nil and now ~= back[index] then
      return nil, "changed_since_undo:" .. file.path
    end
  end
  for index, file in ipairs(entry.files) do
    if not host_write or not host_write(file.path, wanted[index]) then
      return nil, "write_failed:" .. file.path
    end
  end
  return true, "redone"
end

return M
