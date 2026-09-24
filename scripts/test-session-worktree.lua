-- A session can own a checkout, and its tools resolve there - without moving the node.
--
-- The property that matters most is the default. A session that never set a worktree must behave
-- exactly as every session did before this existed: a relative path is left for the host to resolve
-- against the node's cwd. A feature that silently relocated every existing session's files would be
-- worse than no feature, so "unchanged by default" is the first thing asserted.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end

local function text(value)
  return tostring(value):gsub("\\", "/")
end

memory.setup()

local sid = memory.ensure_session("master", "", "worktree test")
ok(type(sid) == "string" and sid ~= "", "a session must be created")

-- Default: no worktree, and the column is present and empty.
ok(memory.session_worktree(sid) == "", "a fresh session has no worktree")
ok(memory.session(sid).worktree == "", "the worktree column must exist and default to empty")
ok(memory.session_worktree("no-such-session") == "", "an unknown session resolves to the node cwd, not an error")

-- A real directory to point at, with a marker file whose content proves which copy was read.
local base = text(host.paths().temp) .. "/wa-session-tree-" .. tostring(os.time())
host.exec("mkdir -p '" .. base .. "/sub'", '')
host.write_file(base .. "/marker.txt", "session-tree\n")

local ctx = { session_id = sid, changes = {} }

-- A relative read before a worktree is set must not be rewritten. Use a file the node cwd really
-- has, so a resolver that wrongly prefixed it would fail rather than pass by accident.
local before = tools.dispatch(memory, "read", { path = "README.md" }, "master", ctx)
ok(not before.error, "a relative read with no session worktree must still resolve against the node cwd, got "
  .. json.encode(before):sub(1, 200))

-- Point the session at its own tree.
local set = tools.dispatch(memory, "session_worktree", { action = "set", path = base }, "master", ctx)
ok(set.ok == true and set.worktree == base, "set must record the path, got " .. tostring(set.worktree))
ok(memory.session_worktree(sid) == base, "the recorded worktree must read back")

-- A relative read now resolves inside the session's tree. Reading the wrong copy of a file is the
-- failure this exists to prevent, so it is asserted on content, not just on a successful call.
local read = tools.dispatch(memory, "read", { path = "marker.txt" }, "master", ctx)
ok(not read.error, "a relative read in a session worktree must succeed, got " .. json.encode(read):sub(1, 200))
ok(text(read.content or ""):find("session%-tree") ~= nil,
  "a relative read must resolve inside the session worktree, got " .. json.encode(read):sub(1, 200))

-- An absolute path is never rewritten, in either direction.
local abs = tools.dispatch(memory, "read", { path = base .. "/marker.txt" }, "master", ctx)
ok(text(abs.content or ""):find("session%-tree") ~= nil, "an absolute path must be read as given")

-- bash starts in the session's tree. The probe writes a file and the test looks for it there,
-- which is portable across the shells a node may run (the platform shell is not always POSIX, and
-- `pwd` is not always a command). The tree is a temp dir, so a probe that landed in the node cwd
-- would be found in the wrong place rather than passing by accident.
local shell = tools.dispatch(memory, "bash", { command = "echo probe > .wa-cwd-probe" }, "master", ctx)
ok(shell.code == 0, "the bash probe must run, got " .. json.encode(shell):sub(1, 200))
ok(host.read_file(base .. "/.wa-cwd-probe") ~= nil,
  "bash must start in the session worktree: .wa-cwd-probe was not written there")

-- An explicit cwd still wins over the session's.
local explicit = tools.dispatch(memory, "bash", { command = "echo probe > .wa-cwd-probe", cwd = base .. "/sub" }, "master", ctx)
ok(explicit.code == 0, "the explicit-cwd probe must run, got " .. json.encode(explicit):sub(1, 200))
ok(host.read_file(base .. "/sub/.wa-cwd-probe") ~= nil,
  "an explicit cwd must win over the session worktree")

-- A path that is not a directory is refused: a typo must not silently point every tool at a
-- missing tree. `host.list_dir` reports failure as `{error=...}`, not nil, so this is what catches a
-- guard that trusted the pcall result for truthiness instead of reading it.
local bad = tools.dispatch(memory, "session_worktree", { action = "set", path = base .. "/does-not-exist" }, "master", ctx)
ok(bad.error == "worktree_not_a_directory", "a missing directory must be refused, got " .. json.encode(bad))

-- A guest must not be able to move a session's tools outside the tree it was scoped to.
local refused = tools.dispatch(memory, "session_worktree", { action = "set", path = base }, "guest", ctx)
ok(refused.error ~= nil and refused.error:find("forbidden_for_role", 1, true) ~= nil,
  "a guest must not set a worktree, got " .. json.encode(refused))

-- clear returns the session to the node's own cwd.
local cleared = tools.dispatch(memory, "session_worktree", { action = "clear" }, "master", ctx)
ok(cleared.worktree == "" and memory.session_worktree(sid) == "", "clear must return to the node cwd")

print("session worktree ok (" .. checks .. " checks)")
