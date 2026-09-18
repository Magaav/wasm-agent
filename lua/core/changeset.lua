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

-- Split text into lines. A trailing newline does **not** create a final empty line: "one\ntwo\n"
-- is two lines, not three. The old `(text .. "\n"):gmatch("(.-)\n")` appended a newline to text
-- that already ended in one, so every file ending in a newline - which is most of them - was
-- counted as having an extra, empty last line, and a created file reported one line more than it
-- had.
local function split_lines(text)
  local lines = {}
  if not text or text == "" then return lines end
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      -- No more newlines: the tail is a line only if it is not empty (a trailing newline
      -- leaves an empty tail, and that is not a line).
      local tail = text:sub(start)
      if tail ~= "" then lines[#lines + 1] = tail end
      break
    end
    -- A line before the newline. An empty line *between* newlines is a real empty line and is
    -- kept; only the empty tail after the final newline is dropped.
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  return lines
end

-- Which lines differ, as a list in file order. Classic LCS table, then walk it: equal lines
-- are skipped, a line only in `after` is an add, a line only in `before` is a del. Bounded to
-- a window around the first difference so two large files cannot allocate a table of N*M.
local function diff_lines(before, after)
  local a, b = split_lines(before), split_lines(after)
  -- Trim the shared prefix and suffix first: they are equal by definition, and trimming them
  -- is what keeps the table small for the common case of a small edit in a big file.
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < (#a - head) and tail < (#b - head)
    and a[#a - tail] == b[#b - tail] do tail = tail + 1 end

  local mid_a, mid_b = {}, {}
  for i = head + 1, #a - tail do mid_a[#mid_a + 1] = a[i] end
  for i = head + 1, #b - tail do mid_b[#mid_b + 1] = b[i] end

  local n, m = #mid_a, #mid_b
  -- Beyond this the table is too big to be worth building; fall back to the block form
  -- (all removals then all additions), which is what the counts are based on anyway.
  if n * m > 250000 then
    local lines = {}
    for i = 1, n do lines[#lines + 1] = { kind = "del", text = mid_a[i] } end
    for i = 1, m do lines[#lines + 1] = { kind = "add", text = mid_b[i] } end
    return lines
  end

  local lcs = {}
  for i = 0, n do
    lcs[i] = {}
    for j = 0, m do lcs[i][j] = 0 end
  end
  for i = n - 1, 0, -1 do
    for j = m - 1, 0, -1 do
      if mid_a[i + 1] == mid_b[j + 1] then lcs[i][j] = lcs[i + 1][j + 1] + 1
      else lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1]) end
    end
  end

  local lines = {}
  local i, j = 0, 0
  while i < n and j < m do
    if mid_a[i + 1] == mid_b[j + 1] then i, j = i + 1, j + 1
    elseif lcs[i + 1][j] >= lcs[i][j + 1] then
      lines[#lines + 1] = { kind = "del", text = mid_a[i + 1] }
      i = i + 1
    else
      lines[#lines + 1] = { kind = "add", text = mid_b[j + 1] }
      j = j + 1
    end
  end
  while i < n do lines[#lines + 1] = { kind = "del", text = mid_a[i + 1] }; i = i + 1 end
  while j < m do lines[#lines + 1] = { kind = "add", text = mid_b[j + 1] }; j = j + 1 end
  return lines
end

-- The added and removed line counts, from the real diff. This is what `record` stores, so the
-- header and the hover preview describe the same change with the same definition.
function diff_counts(before, after)
  local added, removed = 0, 0
  for _, line in ipairs(diff_lines(before, after)) do
    if line.kind == "add" then added = added + 1 else removed = removed + 1 end
  end
  return added, removed
end

-- Exposed so the splitting rule can be asserted against fixed expectations. It is the one
-- thing a diff of lines rests on, and testing it only through `record` cannot catch a wrong
-- count: both sides of that comparison go through this function and a consistent error
-- cancels out.
function M.split_lines(text) return split_lines(text) end

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
  local added, removed = diff_counts(before, after)
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

-- The changed lines of one file, for a preview a reader can see.
--
-- The summary carries addresses rather than text (a transcript is no place for a file's
-- contents), so a preview has to load the two blobs back.
--
-- This is a real line diff, not a prefix/suffix count. A count only trims a
-- shared prefix and suffix, so changing a line near the top reports every later line as
-- changed - fine for "+4 -3", wrong for a preview that paints those lines green and red.
-- The reader would be told that untouched lines had changed, which is exactly the kind of
-- claim this feature exists to make honestly. A plain longest-common-subsequence over lines
-- is what says which lines actually differ.
--
-- Returns `{lines = {{kind="add"|"del", text=...}}, truncated = bool}` or nil and a reason:
-- an unrecorded or too-large change has no text to show, and saying so is better than an
-- empty balloon that looks like a broken one.
local PREVIEW_MAX = 60

function M.preview_file(file)
  if not file or file.recorded == false then return nil, "not_recorded" end
  local before, before_err = M.load(file.before)
  if not before then return nil, before_err or "no_before_text" end
  local after, after_err = M.load(file.after)
  if not after then return nil, after_err or "no_after_text" end

  local all = diff_lines(before, after)
  local lines, truncated = {}, false
  for _, line in ipairs(all) do
    if #lines >= PREVIEW_MAX then truncated = true break end
    lines[#lines + 1] = line
  end
  -- The counts come from the same walk as the lines, so the balloon and whatever it shows
  -- cannot disagree with each other.
  local added, removed = 0, 0
  for _, line in ipairs(all) do
    if line.kind == "add" then added = added + 1 else removed = removed + 1 end
  end
  return { lines = lines, truncated = truncated, added = added, removed = removed }
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
