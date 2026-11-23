-- The diff block a reader follows a file change by (change/tui-diff-view, Victor 20/11).
--
-- What is asserted is the DISPLAY decision, which is the part that can be wrong without a model: the
-- path and the +N -M counts, real line numbers on each row, a removed row showing the number it HAD
-- (and no number in the new column), a created file, the fold that states what it hid, the frame a
-- fence draws (so rust/wa-term keeps it whole at any width), the plain rendering with no escape at
-- all, and a change the run could not record saying so instead of drawing an empty diff.
--
-- It goes through the view's own event path (cli_view:event), not the renderer directly, because that
-- is how real use reaches it: lua/core/chat.lua hands the view a change event, and the view draws it.
-- A test of diff_view.rows alone would pass with the event unwired.
--
-- Under a bare `lua` there is no node, so the shared contract fake stands in: the SAME file is then
-- both the checkout's test and the gate's (the gate runs it through the binary). It is the one host
-- fake this repository keeps (scripts/lib/contract-host.lua), judged against the real host by
-- scripts/test-contract-host.lua - never a stub written here, and it refuses an unknown capability
-- exactly as the real host does.
local standalone = rawget(_G, "host") == nil
if standalone then
  local root = os.tmpname()
  os.remove(root)
  assert(os.execute("mkdir -p " .. string.format("%q", root)) == true or true)
  _G.host = dofile("scripts/lib/contract-host.lua").new({ root = root,
    -- The real host's shape: home is the scratch home and temp is NOT under it, so the test's own
    -- scratch guard is exercised by the fake's answer rather than assumed.
    paths = { home = root, config = root .. "/config", data = root .. "/data",
      cache = root .. "/cache", temp = "/tmp" },
    env = { TMPDIR = "/tmp" } })
  _G.WA_TEST_SCRATCH_ROOT = root
end
-- It writes into the change store, so it refuses unless its home is a scratch one.
local paths = dofile("lua/core/paths.lua")
local home = paths.home()
-- The store this test writes into must be a scratch one, and the oracle is the store the host
-- actually resolved (paths.home), not an environment variable: the host rewrites HOME to the data
-- directory, and a harness that passes only --db sets no WASM_AGENT_HOME at all (measured 20/11 in
-- scripts/test-discriminates.sh, where an env-var guard refused the gate's own scratch home and the
-- refusal was counted as a discriminating failure). A live store is the operator's own
-- ~/.wasm-agent and never lives under a temp directory.
local store = tostring(home)
local tmp = host.getenv("TMPDIR") or "/tmp"
if not (store:sub(1, #tmp + 1) == tmp .. "/" or store:match("^/tmp/") or store:match("^/var/folders/")) then
  print("FAIL diff-view needs a scratch store, this one is " .. store)
  os.exit(1)
end

local changeset = dofile("lua/core/changeset.lua")
local diff_view = dofile("lua/core/diff_view.lua")
local bash_changes = dofile("lua/core/bash_changes.lua")
local markdown = dofile("lua/core/markdown.lua")
local view_lib = dofile("lua/core/cli_view.lua")

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print("FAIL " .. label) failed = failed + 1 end
end
local function has(text, needle, label)
  checks = checks + 1
  if not tostring(text):find(needle, 1, true) then
    print("FAIL " .. label .. ": missing " .. string.format("%q", needle) .. " in:\n" .. tostring(text))
    failed = failed + 1
  end
end
local function visible(text) return (tostring(text):gsub("\27%[[%d;]*m", "")) end
local function cells(text)
  local n, i, s = 0, 1, visible(text)
  while i <= #s do
    local size, width = markdown.char_at(s, i)
    n, i = n + width, i + size
  end
  return n
end

-- A recorder, as scripts/test-cli-view.lua uses: the view writes through out, and the test reads it.
local function recorder()
  local buf = {}
  return {
    out = function(text) buf[#buf + 1] = text end,
    text = function() return table.concat(buf) end,
  }
end

-- One recorded change, exactly as the agent hands it over: the summary entry, which carries the two
-- content addresses. The texts reach the store through changeset.record, the real path.
local function record(before, after, path)
  local M = changeset.new()
  changeset.record(M, path or "/tmp/diff-view-target.lua", before, after)
  local file = M.files[1]
  return { type = "change", name = "edit", path = file.path, before = file.before,
    after = file.after, recorded = file.recorded, added = file.added, removed = file.removed }
end

local before = "local a = 1\nlocal b = 2\nlocal c = 3\n"
local after = "local a = 1\nlocal b = 20\nlocal d = 4\nlocal c = 3\n"

-- ---- a real change, drawn by the view ------------------------------------------
local rec = record(before, after)
local plain = recorder()
local view = view_lib.new({ out = plain.out, live = false, now = function() return 0 end, limit = 80 })
view:event(rec)
local text = plain.text()
has(text, "diff-view-target.lua", "the path is on the block")
has(text, "Update(/tmp/diff-view-target.lua)", "an existing file is named Update(path), as Claude Code names it")
has(text, "Added 2 lines, removed 1 line", "the counts are on the block, from the stored record")
ok(not text:find("removed 0 lines", 1, true), "and it never reports a change nobody made (removed 0 lines)")
has(text, "\226\151\143 Update(", "the heading carries the status bullet, as Claude Code's does")
-- ONE line-number column, Claude Code's (Victor 23/11): the number the line HAS, or had. The removed
-- line was line 2 of the file it came from, the two added lines are lines 2 and 3 of the file that
-- replaced it, and the context row "local c = 3" is line 4 of the NEW file (line 3 of the old one) -
-- so the row a reader opens is the one the number names.
has(visible(text), string.format("\226\148\130 %2d - local b = 2", 2),
  "a removed row carries the old line number")
has(visible(text), string.format("\226\148\130 %2d + local b = 20", 2),
  "an added row carries the new line number")
has(visible(text), string.format("\226\148\130 %2d   local c = 3", 4),
  "a context row carries the number the line has in the new file (3 in the old one)")
ok(not visible(text):find(string.format("\226\148\130 %2d %2s", 2, ""), 1, true),
  "and no row carries a second number column")
ok(not text:find("convenience view, not a review", 1, true),
  "the card carries no footnote: that sentence is documentation, not a row (Victor 23/11)")
has(text, "\226\148\148\226\148\128\n\n", "and one blank row follows the card, so nothing is glued to it")
has(text, "\226\148\140\226\148\128", "the block opens as a card, the way a fence does")
has(text, "\226\148\148\226\148\128", "and closes as one")
ok(not text:find("\27%[", 1), "a plain view writes no escape sequence at all (the NO_COLOR path)")
ok(view_lib.diff_block ~= nil, "the view exposes the block renderer")

-- The card's own opening row must be exactly the corner and its bar: rust/wa-term only opens a frame
-- on that shape, and a header on it would be read as prose and wrapped outside the border.
local first_row = plain.text():match("[^\n]*")
ok(visible(first_row) == "\226\148\140\226\148\128",
  "the opening row is the bare card corner, got " .. string.format("%q", visible(first_row)))

-- ---- context rows, and an ellipsis between hunks -------------------------------
local big_before = {}
for i = 1, 40 do big_before[i] = "line " .. i end
local big_after = { table.unpack(big_before) }
big_after[2], big_after[38] = "line two", "line thirty-eight"
local big = record(table.concat(big_before, "\n") .. "\n", table.concat(big_after, "\n") .. "\n",
  "/tmp/diff-view-hunks.lua")
local joined = table.concat(view_lib.diff_block({ path = big.path, before = big.before,
  after = big.after }, 80, false) or {}, "\n")
has(joined, "line 3", "context rows are shown around a change")
has(joined, "\226\139\174", "two distant changes are separated by the dim vertical ellipsis")
ok(not joined:find("\226\148\130 ...", 1, true), "and not by a row of dots in the middle of the code")

-- ---- a big change folds, and says how much it hid ------------------------------
local huge_before, huge_after = {}, {}
for i = 1, 200 do huge_before[i] = "old " .. i; huge_after[i] = "new " .. i end
local huge = record(table.concat(huge_before, "\n") .. "\n", table.concat(huge_after, "\n") .. "\n",
  "/tmp/diff-view-huge.lua")
local huge_rows = table.concat(view_lib.diff_block({ path = huge.path, before = huge.before,
  after = huge.after }, 80, false) or {}, "\n")
-- The RENDERER draws every line now: the bound a reader meets is the HOST's (CARD_ROWS in
-- rust/wa-term/src/transcript.rs), which folds the card and opens it on Ctrl+O or a press. A card the
-- host can hold is therefore never cut here.
ok(huge_rows:find("old 1", 1, true) ~= nil, "a 200-line rewrite is drawn from its first line")
ok(huge_rows:find("new 200", 1, true) ~= nil, "to its last: the whole diff belongs to the card")
ok(not huge_rows:find("/console shows all", 1, true), "and nothing is cut for a diff the host can hold")
-- The host's own ceiling is the one that DOES cut, and it says where the rest is read.
local cut_rows = diff_view.rows({ path = huge.path,
  before = table.concat(huge_before, "\n") .. "\n", after = table.concat(huge_after, "\n") .. "\n" },
  { width = 80, max_lines = 10 })
local cut_text = {}
for _, row in ipairs(cut_rows.rows) do cut_text[#cut_text + 1] = visible(row.code or "") end
local ceiling = table.concat(cut_text, "\n"):match("%+ ?(%d+) lines: /console shows all")
ok(ceiling ~= nil, "past the host's own ceiling the card says where the rest is read")
ok(tonumber(ceiling or "0") > 0, "and the number is not zero")
ok(cut_rows.body ~= nil and cut_rows.body.to >= cut_rows.body.from,
  "while the body span it hands the host still covers the lines it drew")

-- ---- a change the run could not record ---------------------------------------
local plain2 = recorder()
view_lib.new({ out = plain2.out, live = false, now = function() return 0 end, limit = 80 })
  :event({ type = "change", name = "edit", path = "/tmp/unrecorded.lua", recorded = false,
    before = "none", after = "none" })
has(plain2.text(), "no diff shown: not_recorded", "an unrecorded change says so instead of an empty diff")

-- ---- syntax colour inside the rows --------------------------------------------
-- A live view colours the tokens of a changed row from the same walker a fence uses (markdown.scan_code),
-- so a keyword in a .lua file is the syntax keyword role. The plain rendering must be the SAME rows with
-- no escape at all: colour is decoration, and a captured transcript with escape sequences in it is not
-- a transcript.
local coded = record("local x = 1\n", "local returnable = true\n", "/tmp/diff-view-syntax.lua")
local live_rows = table.concat(view_lib.diff_block({ path = coded.path, before = coded.before,
  after = coded.after }, 80, true) or {}, "\n")
ok(live_rows:find(view_lib.style("syntaxKeyword"), 1, true) ~= nil,
  "a live row colours a keyword with the syntax keyword role")
local plain_rows = table.concat(view_lib.diff_block({ path = coded.path, before = coded.before,
  after = coded.after }, 80, false) or {}, "\n")
ok(not plain_rows:find("\27%[", 1), "the plain rendering of the same rows carries no escape at all")
ok(plain_rows:find("returnable", 1, true) ~= nil, "and it still carries the code itself")
-- ---- narrow widths ------------------------------------------------------------
local narrow = record(before, after, "/tmp/diff-view-narrow.lua")
local narrow_rows = view_lib.diff_block({ path = narrow.path, before = narrow.before,
  after = narrow.after }, 32, false)
ok(narrow_rows ~= nil and #narrow_rows > 0, "a narrow view still renders the block")
local widest = 0
for _, row in ipairs(narrow_rows or {}) do widest = math.max(widest, cells(row)) end
ok(widest <= 32, "every row fits the width a narrow view has (widest " .. widest .. " of 32)")

-- ---- a resize re-renders, it does not clip -------------------------------------
-- The view reads its width at every frame (METHODS:refresh_limit), so the block is rendered at the
-- width the screen has NOW. Proved at the renderer's seam: the same change at two widths gives two
-- different row texts, each fitting its own width - not one wide rendering clipped to a narrow screen.
local resize = record(before, after, "/tmp/diff-view-resize.lua")
local wide_rows = view_lib.diff_block({ path = resize.path, before = resize.before, after = resize.after }, 100, false)
local slim_rows = view_lib.diff_block({ path = resize.path, before = resize.before, after = resize.after }, 40, false)
ok(table.concat(wide_rows or {}, "\n") ~= table.concat(slim_rows or {}, "\n"),
  "a narrower width renders different rows, not the same rows clipped")
local slim_widest = 0
for _, row in ipairs(slim_rows or {}) do slim_widest = math.max(slim_widest, cells(row)) end
ok(slim_widest <= 40, "and every row of the narrow rendering fits 40 cells (widest " .. slim_widest .. ")")

-- ---- a real repository, through the real host --------------------------------
-- The fake above pins the decisions; this pins that a REAL git answers the same way through the real
-- host. It writes into its own directory inside the scratch home, so it cannot see or touch the
-- repository this test runs in.
-- Beside the store, never inside it: the store is content-addressed files, and a git work
-- tree among them would be snapshot by a later run. A plain path, because git reports its own
-- resolved root and a dot-dot would make the two disagree.
local scratch_root = "/tmp/" .. (store:match("([^/]+)/*$") or "diff-view") .. "-git"
if host.exec and scratch_root:match("^/tmp/") then
  local function sh(command)
    local ok, raw = pcall(host.exec, command, scratch_root, 20,
      '{"tool":"bash"}')
    if not ok or type(raw) ~= "string" then return nil end
    local decoded = dofile("lua/vendor/json.lua").decode(raw)
    return type(decoded) == "table" and decoded or nil
  end
  -- The directory itself is made by the shell, the way a real command would leave it.
  -- Made directly, before any shell helper cds into it.
  os.execute("mkdir -p " .. string.format("%q", scratch_root))
  host.write_file(scratch_root .. "/seed.txt", "one\ntwo\n")
  sh("git init -q .")
  sh("git add seed.txt")
  sh("git -c user.email=t@t -c user.name=t commit -qm seed")
  local snap = bash_changes.before(scratch_root, false)
  ok(type(snap) == "table", "a real work tree takes a real snapshot")
  host.write_file(scratch_root .. "/seed.txt", "one\nTWO\n")
  local real_changed, real_refused = bash_changes.changed(snap)
  ok(#real_changed == 1 and real_changed[1].path == "seed.txt" and real_changed[1].before_text == "one\ntwo\n",
    "a real git reports the file, and its starting text comes from the index")
  ok(#real_refused == 0, "and nothing is refused when the index has the text")
  -- Its own directory goes away: a test that leaves a repository behind is a test that
  -- fills the gate home, and the next run would snapshot the previous one.
  sh("cd .. && rm -rf " .. scratch_root)
else
  -- No node here (a bare `lua` run with the contract fake, which refuses to stand in for a
  -- process): the real-git section is NOT judged, and it says so instead of failing or passing. The
  -- gate runs this same file through the binary, where host.exec exists and this section IS judged.
  print("SKIP real git: no host.exec in this run (the gate's binary run judges it)")
end
-- ---- a created file -----------------------------------------------------------
local created = record("", "one\ntwo\n", "/tmp/diff-view-new.lua")
local created_rows = table.concat(view_lib.diff_block({ path = created.path,
  before = created.before, after = created.after }, 80, false) or {}, "\n")
has(created_rows, "Create(/tmp/diff-view-new.lua)", "a new file is named Create(path)")
has(created_rows, "Added 2 lines", "a created file counts its two added lines")
ok(not created_rows:find("emoved", 1, true), "and says nothing about a removal it did not make")
-- A DELETE is its own name, and the caller's fact: the same two texts (a text and no text) draw an
-- Update of an emptied file unless the caller says the file is gone.
local deleted = record("one\ntwo\n", "", "/tmp/diff-view-gone.lua")
local deleted_rows = table.concat(view_lib.diff_block({ path = deleted.path, before = deleted.before,
  after = deleted.after, deleted = true }, 80, false) or {}, "\n")
has(deleted_rows, "Delete(/tmp/diff-view-gone.lua)", "a removed file is named Delete(path)")
has(deleted_rows, "Removed 2 lines", "and it counts the lines it took with it")
ok(not deleted_rows:find("Added", 1, true), "a delete does not report an addition it did not make")
has(visible(deleted_rows), string.format("\226\148\130 %2d - one", 1),
  "its rows are - rows carrying the numbers the lines had")
ok(visible(deleted_rows):find("+", 1, true) == nil, "and no + row, because nothing was written")


-- ---- the files a shell command changed ----------------------------------------
-- The snapshot and the diff of what a command changed, through lua/core/bash_changes.lua with a fake
-- shell (no real git, no real tree): BEFORE is clean, the command writes one file, and AFTER reports it
-- modified. The starting text comes from the index, so the block shows a real diff; a file that was
-- already modified is NAMED and its diff refused rather than guessed.
-- ---- the files a shell command changed ----------------------------------------
-- Through lua/core/bash_changes.lua with a fake git (no real tree): BEFORE is clean, the command writes
-- one tracked file and one new one, and a third file was already modified. The starting text comes from
-- the index at the repository ROOT, which is where git reports its paths from - a command run in a
-- subdirectory still reports root-relative paths (measured 20/11 on rust/ in this repo).
local fake = { root = "/repo",
  status_before = "",
  status_after = " M crate/src/changed.rs\n M crate/src/already.rs\n?? crate/src/new.rs\n",
  show = { ["crate/src/changed.rs"] = "one\ntwo\n" },
  files = { ["/repo/crate/src/changed.rs"] = "one\nTWO\n",
    ["/repo/crate/src/already.rs"] = "kept\n", ["/repo/crate/src/new.rs"] = "fresh\n" },
  phase = "before" }
local real_exec, real_read = host.exec, host.read_file
host.exec = function(command, cwd)
  if command:match("^git rev%-parse") then
    return '{"code":0,"stdout":"' .. fake.root .. '\\n","stderr":""}'
  end
  if command:match("^git status") then
    local text = fake.phase == "before" and fake.status_before or fake.status_after
    return '{"code":0,"stdout":"' .. text:gsub("\n", "\\n") .. '","stderr":""}'
  end
  local path = command:match("^git show :(.+)$")
  if path and fake.show[path] then
    return '{"code":0,"stdout":"' .. fake.show[path]:gsub("\n", "\\n") .. '","stderr":""}'
  end
  return '{"code":1,"stdout":"","stderr":"no such path"}'
end
host.read_file = function(path) return fake.files[path] end
-- The snapshot taken before the command; the same directory, a subdirectory of the tree.
local before = bash_changes.before("/repo/crate", false)
ok(type(before) == "table" and before.root == "/repo",
  "the snapshot resolves the repository root, not the command's directory")
ok(bash_changes.before("/repo/crate", true) == nil, "a command the caller says is read-only takes no snapshot")
fake.phase = "after"
-- A file that was already modified is not in the before snapshot: it is refused by name.
before.status["crate/src/already.rs"] = " M"
local changed, refused = bash_changes.changed(before)
ok(#changed == 2, "a command's own changes are found (got " .. #changed .. ")")
ok(#refused == 0, "a file modified before the command is not counted as this command's change")
local block = table.concat(view_lib.bash_changes_block({ files = changed, refused = refused }, 80, false)
  or {}, "\n")
has(block, "crate/src/changed.rs", "the changed file is named by its root-relative path")
has(block, "Added 1 line, removed 1 line", "and its own counts")
ok(block:find("\226\148\140\226\148\128", 1, true) ~= nil, "drawn as a card, the way a write is")
has(block, "crate/src/new.rs", "a new file is shown")
-- A REMOVAL is a change with a before side, not a missing one: the index still holds the text the file
-- had, and the removed file is drawn as a Delete with its own lines. The host is asked whether the path
-- is really gone (a nil read is also what a binary file answers).
local real_kind = host.path_kind
host.path_kind = function(path) return fake.files[path] == nil and "missing" or "file" end
fake.status_after = fake.status_after .. " D crate/src/gone.rs\n"
fake.show["crate/src/gone.rs"] = "kept\nthen\nremoved\n"
local gone_changed, gone_refused = bash_changes.changed(before)
host.path_kind = real_kind
local gone_row
for _, item in ipairs(gone_changed) do if item.path == "crate/src/gone.rs" then gone_row = item end end
ok(gone_row ~= nil, "a removed file is reported as a change, not as an unavailable one")
ok(gone_row and gone_row.deleted == true, "and it is marked deleted, which is what names the card")
ok(gone_row and gone_row.after_text == "", "with an empty after side: nothing is left")
local gone_block = table.concat(view_lib.bash_changes_block({ files = gone_changed, refused = gone_refused },
  80, false) or {}, "\n")
has(gone_block, "Delete(crate/src/gone.rs)", "the block draws it as a Delete card")
has(gone_block, "Removed 3 lines", "with the lines it took")
ok(not gone_block:find("Added 0", 1, true), "and no invented addition")
has(gone_block, "\226\148\148\226\148\128\n\n", "and one blank row after the card")
-- A file whose before-side is not in the index cannot be diffed, and the block says so in words.
fake.show = {}
local changed2, refused2 = bash_changes.changed(before)
ok(#refused2 >= 1, "a change whose starting text is unknown is refused, not guessed")
local block2 = table.concat(view_lib.bash_changes_block({ files = changed2, refused = refused2 }, 80, false)
  or {}, "\n")
has(block2, "index text unavailable", "and the refusal is said in words, not as an empty block")
host.exec, host.read_file = real_exec, real_read
-- ---- the heading names the change the way Claude Code does ----------------------
-- Victor 23/11: `Create(path)` with the bullet in the status colour, and the path as a reader names
-- it - relative inside the workdir, `~` inside home, absolute otherwise. A change made on ANOTHER node
-- says which node in the heading, not on a line after the card.
local function heading_of(rows)
  for _, row in ipairs(rows) do
    if row.parts then
      local text = {}
      for _, part in ipairs(row.parts) do text[#text + 1] = part.text end
      local joined = table.concat(text)
      if joined:find("Create(", 1, true) or joined:find("Update(", 1, true) then return joined end
    end
  end
  return nil
end
local inside = heading_of(diff_view.rows({ path = "/home/u/work/crate/x.py", before = "", after = "one\n" },
  { width = 80, cwd = "/home/u/work", home = "/home/u" }).rows)
ok(inside ~= nil and inside:find("\226\151\143 Create(crate/x.py)", 1, true) ~= nil,
  "a path inside the workdir is named relative to it, got " .. tostring(inside))
ok(diff_view.short_path("/home/u/other/y.py", { cwd = "/home/u/work", home = "/home/u" }) == "~/other/y.py",
  "a path outside the workdir but inside home is named with ~")
ok(diff_view.short_path("/etc/x.conf", { cwd = "/home/u/work", home = "/home/u" }) == "/etc/x.conf",
  "and a path outside both keeps its full name")
-- `~` means the READER's home, and the node's own state directory is not it. Encoded as one pure
-- function (`lua/core/cli_view.lua tilde_home`) so it is pinned by its rule rather than by whatever HOME
-- a runner happens to hand a row: main-health 23/11 drew
-- `Create(~/.wasm-agent/.wasm-agent/script-writes/demo.txt)` for a file that was in no home at all.
local tilde = view_lib.tilde_home
ok(tilde("/home/u", "/home/u/.wasm-agent", "/home/u/.wasm-agent") == "/home/u",
  "the operator's home is `~`, even with the node's state directory inside it")
ok(tilde("/home/u/.wasm-agent", "/home/u/.wasm-agent", "/home/u/.wasm-agent/.wasm-agent") == "",
  "the node's state directory itself is never `~`")
ok(tilde("/home/u/.wasm-agent/tmp", "/home/u/.wasm-agent", "/home/u/.wasm-agent") == "",
  "nor anything under it")
ok(tilde("/tmp/scratch/home", "/tmp/scratch/home", "/tmp/scratch/home/.wasm-agent") == "",
  "and a scratch home that IS the node's home is not `~` either (a test row's shape)")
ok(tilde("", "/home/u/.wasm-agent", "") == "", "no home at all shortens nothing")

local remote_heading = heading_of(diff_view.rows({ path = "/tmp/x.py", before = "", after = "one\n" },
  { width = 80, cwd = "/home/u/work", home = "/home/u", node = "nextcloud" }).rows)
ok(remote_heading ~= nil and remote_heading:find("Create(nextcloud:/tmp/x.py)", 1, true) ~= nil,
  "a change on another node names the node in the heading, got " .. tostring(remote_heading))

-- ---- the palette: a changed row is READABLE -------------------------------------
-- Victor 23/11 (screenshot): the one diff row on screen was near-invisible. Measured in a real pty: the
-- band role was painted as a FOREGROUND, so every changed row's TEXT was the band's own dark green
-- (38;2;18;48;28 on the terminal's black). A band paints the row BEHIND the text, and both changed
-- rows keep the contrast a reader needs at the default theme.
local function luminance(hex)
  local function channel(value)
    local c = value / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  local r = channel(tonumber(hex:sub(1, 2), 16))
  local g = channel(tonumber(hex:sub(3, 4), 16))
  local b = channel(tonumber(hex:sub(5, 6), 16))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end
local function contrast(one, two)
  local a, b = luminance(one), luminance(two)
  if a < b then a, b = b, a end
  return (a + 0.05) / (b + 0.05)
end
local palette = view_lib.PALETTE
ok(view_lib.style("toolDiffAddedBand"):sub(1, 4) == "\27[48", "the added band paints the BACKGROUND")
ok(view_lib.style("toolDiffRemovedBand"):sub(1, 4) == "\27[48", "the removed band paints the BACKGROUND")
local added_contrast = contrast(palette.toolDiffAdded, palette.toolDiffAddedBand)
local removed_contrast = contrast(palette.toolDiffRemoved, palette.toolDiffRemovedBand)
ok(added_contrast >= 4.5, string.format("an added line reads on its band (%.1f:1, WCAG AA needs 4.5)", added_contrast))
ok(removed_contrast >= 4.5, string.format("a removed line reads on its band (%.1f:1)", removed_contrast))
local live_changed = table.concat(view_lib.diff_block({ path = coded.path, before = coded.before,
  after = coded.after }, 80, true) or {}, "\n")
ok(live_changed:find("\27[48;2;18;48;28m", 1, true) ~= nil, "a live added row draws the band behind its code")
ok(not live_changed:find("\27[38;2;18;48;28m", 1, true),
  "and never paints its TEXT with the band's own colour (the unreadable row of the screenshot)")
ok(live_changed:find("\27[48;2;58;22;32m", 1, true) ~= nil, "a live removed row draws its own band behind its code")
ok(not live_changed:find("\27[38;2;58;22;32m", 1, true),
  "and never paints its text with the removed band's colour either")


if failed > 0 then
  print("FAILED " .. failed)
  os.exit(1)
end
print("diff view ok (" .. checks .. " checks)")
