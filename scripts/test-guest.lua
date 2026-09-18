-- A guest is not a smaller master; it is a different thing.
--
-- A guest cannot edit files on its own initiative - it carries out a master's wish on the
-- machine it runs on. That has two consequences this pins down, because both were wrong in a
-- way that is invisible if you only look at the result:
--
--   1. A guest owns no worktree. It used to be named after whatever directory it happened to
--      be running in, which reads as "this is a checkout you can hand off" - and it is not.
--      A rename on a guest used to move a *branch*, an operation on a workspace it does not
--      have.
--
--   2. The author of a master's call is the master. A peer call used to run as a user called
--      "node", so a master's instruction to a guest was filed in the ledger under the guest's
--      name. The work belonged to whoever asked; the record said otherwise.
--
-- `author_of` is the gate the peer path now uses, and it is checked here directly: the
-- end-to-end path needs two registered nodes and a signature, which is a different test.
--
-- Run from the repo root with a sandboxed home:
--   WASM_AGENT_HOME=/tmp/guest-home WA_SCRIPT=scripts/test-guest.lua wa --db /tmp/x.db
local nodes = dofile("lua/core/nodes.lua")
local paths = dofile("lua/core/paths.lua")
local host = _G.host

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local function set_role(value)
  local wrote = host.write_file(nodes.role_file(), value .. "\n")
  if wrote == false then error("could not write the role file at " .. nodes.role_file()) end
  return nodes.role()
end

-- 1. The default can work. A node with nothing said about it is the master's own node: an
-- unrecognised or missing role must not quietly demote it.
local stored = host.read_file(nodes.role_file())
ok(stored == nil, "the role file starts absent (sandboxed home)", tostring(stored))
ok(nodes.role() == "master", "a node with no role is a master", nodes.role())
ok(nodes.is_master() == true, "is_master agrees with role")
ok(nodes.role() ~= "guest", "the default is not the restricted one")

-- 2. The role file is read, and the safe direction is taken for nonsense.
ok(set_role("guest") == "guest", "the role file is honoured")
ok(set_role("GUEST") == "guest", "case does not matter", nodes.role())
ok(set_role("mumble") == "master", "an unrecognised role is a master, not a silent guest")
ok(nodes.role_file():sub(-10) == "/node.role", "the role sits beside the name", nodes.role_file())

-- 3. A master is named after its worktree; a guest is not. Same directory, two answers.
local worktree = nodes.worktree()
ok(worktree ~= "", "the test must run inside a named checkout", worktree)
set_role("master")
ok(nodes.node_name() == worktree, "a master is named after its worktree", nodes.node_name())
set_role("guest")
ok(nodes.node_name() ~= worktree, "a guest is not named after a worktree", nodes.node_name())
ok(nodes.role() == "guest", "and it still knows it is a guest")

-- 4. A guest owns no branch, so a branch rename is refused rather than half-done.
local renamed, why = nodes.rename_branch(nodes.node_name(), "guest-branch-test")
ok(renamed == nil, "a guest cannot rename a branch", tostring(renamed))
ok(why == "guest_has_no_branch", "and it says why", tostring(why))

-- 5. A guest's own capabilities are read-only. It can read, and it edits when a master asks -
-- which is a different code path with the master's name on it.
local list = nodes.list()
local local_node = nil
for _, node in ipairs(list) do
  if node.local_node then local_node = node end
end
ok(local_node ~= nil, "the node lists itself")
ok(local_node.role == "guest", "the list reports the role", tostring(local_node.role))
ok(local_node.worktree == "", "a guest reports no worktree", tostring(local_node.worktree))
local has = {}
for _, name in ipairs(local_node.capabilities or {}) do has[name] = true end
ok(has.read == true, "a guest may read")
ok(has.write ~= true, "a guest may not write on its own initiative")
ok(has.edit ~= true, "a guest may not edit on its own initiative")
ok(has.bash ~= true, "a guest may not run a shell on its own initiative")
set_role("master")
local master_node = nil
for _, node in ipairs(nodes.list()) do
  if node.local_node then master_node = node end
end
ok(master_node.role == "master", "a master reports itself as one")
ok(master_node.worktree ~= "", "a master reports its worktree")
local master_has = {}
for _, name in ipairs(master_node.capabilities or {}) do master_has[name] = true end
ok(master_has.write == true and master_has.bash == true, "a master keeps the write tools")
-- Back to guest, and stay there: everything below must run as a guest, because a master's
-- rename moves a real branch. A test that can move the repository it is testing is a test that
-- will eventually move it, so the role is pinned here and asserted again where it matters.
set_role("guest")

-- 6. The author of a call is the caller: a master's name, never the guest's.
ok(nodes.author_of({ name = "desk", role = "master" }) == "desk", "a master's call is authored by the master")
ok(nodes.author_of({ node_id = "abc123", role = "master" }) == "abc123", "the node id is the fallback")
ok(nodes.author_of({ name = "admin-node", role = "admin" }) == "admin-node", "the legacy alias still counts")
ok(nodes.author_of({ name = "somebody", role = "guest" }) == nil, "a guest cannot author a master's wish")
ok(nodes.author_of({ name = "anonymous" }) == nil, "a caller with no role is not a master")
ok(nodes.author_of(nil) == nil, "and neither is nothing at all")

-- 7. An unverified caller never reaches the author gate at all: the signature and the
-- rendezvous are checked first, so a stranger cannot claim a master's name.
ok(nodes.verify_caller("node-that-is-not-registered", "made-up-key") == nil,
  "an unregistered caller is refused before anything else")
ok(nodes.author_of(nodes.verify_caller("node-that-is-not-registered", "made-up-key")) == nil,
  "and it cannot become an author")

-- 8. Finally, a guest takes a name without touching a branch - and the name is real.
ok(nodes.role() == "guest", "the rename check must run as a guest, or it would move a branch")
local branch_before = nodes.branch()
local name = nodes.set_name("guest-node-test")
ok(name == "guest-node-test", "a guest takes a name", tostring(name))
ok(host.read_file(nodes.name_file()):gsub("%s", "") == "guest-node-test", "and the name is stored")
ok(nodes.branch() == branch_before, "and no branch moved",
  tostring(branch_before) .. " -> " .. tostring(nodes.branch()))
local stored_name = host.read_file(nodes.name_file())
ok(stored_name ~= nil and stored_name:find("guest%-node%-test") ~= nil, "the stored name round-trips")

print("guest ok (" .. checks .. " checks)")
