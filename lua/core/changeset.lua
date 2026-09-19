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

-- Lines of a text, where a trailing newline ends the last line rather than starting an empty
-- one. The previous version appended a newline before splitting, so "a\nb\n" was three lines
-- - the third empty - and the phantom cancelled out only while *both* sides had it. For a create
-- the before side is empty and has no phantom, so every created file reported one added line too
-- many: a file written with two lines claimed +3. The counts are what the topic's header shows,
-- so the bug was visible in the product, not just in the test.
local function split_lines(text)
  local lines = {}
  if not text or text == "" then return lines end
  local start = 1
  while true do
    local at = text:find("\n", start, true)
    if not at then
      if start <= #text then lines[#lines + 1] = text:sub(start) end
      break
    end
    lines[#lines + 1] = text:sub(start, at - 1)
    start = at + 1
  end
  return lines
end

-- Exported for the tests, which check the splitting rule directly against fixed expectations. It
-- cannot be verified through `record`, because both sides of that comparison go through this same
-- function - so a consistently wrong count cancels out and every count assertion still passes. That
-- is how a phantom trailing line survived a suite that looked like it covered this.
function M.split_lines(text) return split_lines(text) end

-- The changed lines, as an ordered list of {kind="add"|"del", text=...}.
--
-- This is what a diff topic shows, so it must agree with the counts the header prints - and the way
-- to guarantee that is for both to come from *one* walk, which is why `preview_file` below counts
-- what this returns rather than counting for itself. Two definitions of "changed" in one topic is
-- how the header came to say +4 -3 for a one-line edit while the balloon painted untouched lines red.
local function diff_lines(before, after)
  local a, b = split_lines(before), split_lines(after)
  -- Trim the shared prefix and suffix first: they are equal by definition, and trimming them keeps
  -- the table small for the common case of a small edit in a big file.
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < (#a - head) and tail < (#b - head)
    and a[#a - tail] == b[#b - tail] do tail = tail + 1 end

  local mid_a, mid_b = {}, {}
  for i = head + 1, #a - tail do mid_a[#mid_a + 1] = a[i] end
  for i = head + 1, #b - tail do mid_b[#mid_b + 1] = b[i] end

  local n, m = #mid_a, #mid_b
  -- Beyond this the table is too big to be worth building; fall back to the block form (all
  -- removals then all additions), which is what the counts are based on anyway.
  if n * m > 250000 then
    local lines = {}
    for i = 1, n do lines[#lines + 1] = { kind = "del", text = mid_a[i] } end
    for i = 1, m do lines[#lines + 1] = { kind = "add", text = mid_b[i] } end
    return lines
  end

  -- Longest common subsequence, then walk it back into a line list. n*m is bounded above, so the
  -- table is safe to allocate.
  local lcs = {}
  for i = 0, n do
    lcs[i] = {}
    for j = 0, m do lcs[i][j] = 0 end
  end
  for i = n - 1, 0, -1 do
    for j = m - 1, 0, -1 do
      if mid_a[i + 1] == mid_b[j + 1] then
        lcs[i][j] = lcs[i + 1][j + 1] + 1
      else
        lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1])
      end
    end
  end
  local lines = {}
  local i, j = 0, 0
  while i < n and j < m do
    if mid_a[i + 1] == mid_b[j + 1] then
      i, j = i + 1, j + 1
    elseif lcs[i + 1][j] >= lcs[i][j + 1] then
      lines[#lines + 1] = { kind = "del", text = mid_a[i + 1] }
      i = i + 1
    else
      lines[#lines + 1] = { kind = "add", text = mid_b[j + 1] }
      j = j + 1
    end
  end
  while i < n do
    lines[#lines + 1] = { kind = "del", text = mid_a[i + 1] }
    i = i + 1
  end
  while j < m do
    lines[#lines + 1] = { kind = "add", text = mid_b[j + 1] }
    j = j + 1
  end
  return lines
end

-- How many changed lines a preview will carry before it says so. A balloon is for glancing at, so a
-- rewritten file shows the first of it with `truncated` set rather than a thousand rows.
local PREVIEW_MAX = 400

-- The lines a diff topic shows for one file, with the counts that go with them.
--
-- Restored: this was lost when `record` was rewritten (5ed8d4e) and nothing caught it, because the
-- test that exercises it landed in the same session and the gate was not re-run afterwards. It is
-- called out here because the way it went missing - a rewrite that quietly dropped a function a test
-- depended on - is the reason `scripts/test.sh` runs every tests/*.lua rather than the ones somebody
-- remembers.
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
  -- Counted from the same walk that produced the lines above, so the balloon and the header cannot
  -- disagree - which is the invariant this function exists to keep.
  local added, removed = 0, 0
  for _, line in ipairs(all) do
    if line.kind == "add" then added = added + 1 else removed = removed + 1 end
  end
  return { lines = lines, truncated = truncated, added = added, removed = removed }
end

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
--
-- The same path recorded twice in one turn is *one* change, not two lines in the topic. A turn
-- that writes a file, then edits it again, has done one thing to that file, and the reader means
-- the whole of it. So the entry keeps the first `before` - the turn's starting point, which is
-- what undo has to restore - and takes the newest `after`. v8 arrived at the same rule from the
-- other side: it kept `first_preimage` so that a later reread could not replace the session's
-- baseline with a partial window.
function M.record(entry, path, before, after)
  local existing
  for _, file in ipairs(entry.files) do
    if file.path == path then existing = file break end
  end
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
  if existing then
    -- The delta is measured from where the turn started, not from the previous edit, so the
    -- counts describe the turn rather than the last keystroke. The original text is loaded back
    -- from the store for that; if it is not there the current call's `before` is the honest
    -- fallback, because a wrong count is worse than a narrower one.
    local origin = before
    if existing.before then
      local text = M.load(existing.before)
      if type(text) == "string" then origin = text end
    end
    local added, removed = line_delta(origin, after)
    existing.after = after_id
    existing.added = added
    existing.removed = removed
    -- Stricter wins: a change that could not be recorded once cannot be undone later just
    -- because a smaller edit followed it.
    existing.recorded = existing.recorded and recorded
    -- `created` is left as first seen: a file that existed when the turn started was not
    -- created by the turn's second write to it.
  else
    local added, removed = line_delta(before, after)
    entry.files[#entry.files + 1] = {
      path = path, before = before_id, after = after_id,
      added = added, removed = removed, recorded = recorded,
      -- A create is "no text before", recorded rather than re-derived: loading the blob to
      -- ask would be a second source of truth for the same fact, and they could disagree.
      created = (before or "") == "",
    }
  end
  -- Totals are summed from the files rather than accumulated as we go: with one path recorded
  -- twice, an accumulator would add the first edit's counts twice and the header would lie.
  entry.added, entry.removed = 0, 0
  for _, file in ipairs(entry.files) do
    entry.added = entry.added + (file.added or 0)
    entry.removed = entry.removed + (file.removed or 0)
  end
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

-- A unified diff of one recorded file, built when it is asked for.
--
-- The transcript carries addresses, not contents, so the patch cannot be stored with the turn - and it
-- should not be: a diff topic that carried every file's body twice would be the largest thing in the
-- transcript. It is built here from the two blobs instead, which is the whole reason the blobs are
-- content-addressed and reachable from the ledger alone.
--
-- The algorithm is a plain LCS over lines rather than Myers. The job is to show a reader what changed in
-- one file, and the sizes a change topic covers are small; past DIFF_CAP lines on either side it says so
-- instead of building a table large enough to be the problem it was meant to describe.
local DIFF_CAP = 1200
local CONTEXT = 3

local function common_table(a, b)
  local dp = {}
  for i = #a + 1, 0, -1 do
    dp[i] = {}
    for j = #b + 1, 0, -1 do
      if i > #a or j > #b then
        dp[i][j] = 0
      elseif a[i] == b[j] then
        dp[i][j] = 1 + dp[i + 1][j + 1]
      else
        dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
      end
    end
  end
  return dp
end

-- A list of { kind = " "|"-"|"+", text = line }.
local function edit_script(a, b)
  local dp = common_table(a, b)
  local ops, i, j = {}, 1, 1
  while i <= #a or j <= #b do
    if i <= #a and j <= #b and a[i] == b[j] then
      ops[#ops + 1] = { kind = " ", text = a[i] }
      i, j = i + 1, j + 1
    elseif j <= #b and (i > #a or dp[i][j + 1] >= dp[i + 1][j]) then
      ops[#ops + 1] = { kind = "+", text = b[j] }
      j = j + 1
    else
      ops[#ops + 1] = { kind = "-", text = a[i] }
      i = i + 1
    end
  end
  return ops
end

-- Group an edit script into hunks with CONTEXT unchanged lines around each change, the way a
-- unified diff does, so a one-line edit in a large file does not print the whole file.
local function hunks(ops)
  local changed = {}
  for index, op in ipairs(ops) do
    if op.kind ~= " " then changed[#changed + 1] = index end
  end
  local groups = {}
  for _, index in ipairs(changed) do
    local last = groups[#groups]
    if last and index - last[#last] <= CONTEXT * 2 + 1 then
      last[#last + 1] = index
    else
      groups[#groups + 1] = { index }
    end
  end
  local out = {}
  for _, group in ipairs(groups) do
    local from = math.max(1, group[1] - CONTEXT)
    local to = math.min(#ops, group[#group] + CONTEXT)
    out[#out + 1] = { from = from, to = to }
  end
  return out
end

local function render_patch(path, a, b, ops)
  local lines = { "--- before/" .. path, "+++ after/" .. path }
  for _, hunk in ipairs(hunks(ops)) do
    -- The hunk header counts lines on each side, which is what makes the patch readable by
    -- anything that parses unified diffs - and what makes a wrong count visible rather than silent.
    local start_a, count_a, start_b, count_b = 0, 0, 0, 0
    local seen_a, seen_b = 0, 0
    for index = 1, hunk.from - 1 do
      if ops[index].kind ~= "+" then seen_a = seen_a + 1 end
      if ops[index].kind ~= "-" then seen_b = seen_b + 1 end
    end
    start_a, start_b = seen_a + 1, seen_b + 1
    for index = hunk.from, hunk.to do
      local op = ops[index]
      if op.kind ~= "+" then count_a = count_a + 1 end
      if op.kind ~= "-" then count_b = count_b + 1 end
    end
    lines[#lines + 1] = string.format("@@ -%d,%d +%d,%d @@", start_a, count_a, start_b, count_b)
    for index = hunk.from, hunk.to do
      lines[#lines + 1] = ops[index].kind .. ops[index].text
    end
  end
  return table.concat(lines, "\n")
end

-- { path, patch, truncated, added, removed, created } or nil and a reason a reader can act on.
function M.patch(entry, path)
  if type(path) ~= "string" or path == "" then return nil, "path_required" end
  local file
  for _, candidate in ipairs((entry and entry.files) or {}) do
    if candidate.path == path then file = candidate break end
  end
  if not file then return nil, "unknown_path" end
  if file.recorded == false then return nil, "not_recorded" end
  local before, why_before = M.load(file.before)
  if before == nil then return nil, "previous_text_missing" end
  local after, why_after = M.load(file.after)
  if after == nil then return nil, "recorded_text_missing" end
  local a, b = split_lines(before), split_lines(after)
  local truncated = false
  if #a > DIFF_CAP or #b > DIFF_CAP then
    -- Honest rather than enormous: the reader gets the counts and the first DIFF_CAP lines of each
    -- side, and is told the rest is not shown.
    truncated = true
    a, b = { unpack(a, 1, math.min(#a, DIFF_CAP)) }, { unpack(b, 1, math.min(#b, DIFF_CAP)) }
  end
  local ops = edit_script(a, b)
  return {
    path = path,
    patch = render_patch(path, a, b, ops),
    truncated = truncated,
    added = file.added or 0,
    removed = file.removed or 0,
    created = file.created == true,
    recorded = file.recorded ~= false,
  }
end

-- Merge repeated paths in an entry that was read back from the ledger.
--
-- Turns recorded before `record` merged them hold one entry per write, and the *second* entry's `before`
-- is the text the turn itself had just written. Undo restores `before`, so undoing such a turn would put
-- the file back to an intermediate state and report success - which is precisely the failure the merge
-- exists to prevent, and it is worse than a refusal because nothing says anything went wrong.
--
-- Those rows are not rewritten. The ledger is append-only and history that edits itself is not history,
-- so the merge happens when the entry is read: first `before`, newest `after`, the stricter `recorded`,
-- and the delta measured from where the turn started rather than from the previous keystroke.
function M.normalize(entry)
  if not entry or type(entry.files) ~= "table" then return entry end
  local merged, order = {}, {}
  for _, file in ipairs(entry.files) do
    local seen = merged[file.path]
    if not seen then
      merged[file.path] = {
        path = file.path, before = file.before, after = file.after,
        added = file.added or 0, removed = file.removed or 0,
        recorded = file.recorded ~= false, created = file.created == true,
        writes = 1,
      }
      order[#order + 1] = file.path
    else
      seen.after = file.after
      seen.recorded = seen.recorded and (file.recorded ~= false)
      seen.writes = seen.writes + 1
      local origin = seen.before and M.load(seen.before)
      local final = file.after and M.load(file.after)
      if type(origin) == "string" and type(final) == "string" then
        seen.added, seen.removed = line_delta(origin, final)
      else
        -- The blobs are gone: sum what the ledger holds rather than inventing a number.
        seen.added = seen.added + (file.added or 0)
        seen.removed = seen.removed + (file.removed or 0)
      end
    end
  end
  local files, added, removed = {}, 0, 0
  for _, path in ipairs(order) do
    local file = merged[path]
    files[#files + 1] = file
    added, removed = added + file.added, removed + file.removed
  end
  return { files = files, added = added, removed = removed }
end

return M
