-- A node with no tree: a binary request takes the release path, and a check names the record it found.
--
-- THE DEFECT THIS PINS (21/11, hand fix 4 of the node-7ddbfa98036a rollout). "wa update <node> --binary" on a
-- node installed from a release answered no_runtime_tree - a refusal about a TREE that the mode never wanted,
-- while the documented release path ("release: verified bundle") existed one line away and could only be
-- reached by knowing to ask for it under another name. And "wa update --check" on the same node said "there is
-- no tree or release record to compare with" while installed.txt held a stale hand rollback: the answer named
-- neither the record it had found nor the one command that moves such a node.
--
-- WHAT IS DRIVEN. The real lua/core/remote_update.lua and lua/core/update.lua, with facts pinned to a fixture
-- install that has no tree (the only way to be tree-less from inside a checkout, where the working directory
-- IS a tree). Nothing is queued and no sentinel is needed: the assertions are about the DECISION - which mode
-- is chosen, and what the check says about the record - so a request that stops at the next gate is still
-- evidence that the routing happened.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-update-treeless.lua wa --db <scratch>
--
-- Prints "update treeless ok"; a failed check raises.
local updater = dofile("lua/core/update.lua")
local remote = dofile("lua/core/remote_update.lua")

local failed, checks = 0, 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""))
  end
end
local function has(text, needle) return tostring(text or ""):find(needle, 1, true) ~= nil end

local home = host.paths().home
local install = home .. "/treeless-install"
local sentinel_dir = home .. "/treeless-sentinel"
pcall(host.exec, "mkdir -p '" .. install .. "' '" .. sentinel_dir .. "'", "")
-- THE STALE HAND ROLLBACK, in the shape an operator's own file has: a commit and nothing the release
-- updater recognises (no via=linux-bootstrap), because a hand rollback did not come from an installer.
local STALE = string.rep("a", 40)
assert(host.write_file(install .. "/installed.txt",
  "commit=" .. STALE .. "\nbranch=main\ndirty=0\nsource_provenance=hand-rollback\n") == true, "fixture write")
pcall(host.exec, "printf 'x' > '" .. install .. "/wa'", "")
pcall(host.exec, "chmod +x '" .. install .. "/wa'", "")

-- A NODE WITH NO TREE, FOR REAL. update.runtime_tree() answers runtime-worktree.txt first and then a cwd
-- holding rust/Cargo.toml, so this process runs from a scratch directory and the fixture install carries no
-- runtime-worktree.txt: facts.tree is nil because these facts ARE a tree-less node, not because a test said
-- so. Nothing below stubs the module.
local MASTER = { role = "master", node_id = "master-node-id", public_key = string.rep("cd", 32),
  name = "wasm_the_first", mesh = "roster", level = 0 }
local TARGET = string.rep("b", 40)

-- ---- (a) an ordinary tree deploy on a tree-less node is still refused, and now says what to do ----------
local tree_refusal = remote.admit({ action = "request", commit = TARGET, reason = "treeless tree deploy" }, MASTER)
ok(tree_refusal and tree_refusal.error == "no_runtime_tree", "an ordinary tree deploy on a tree-less node is refused by name",
  tree_refusal and tree_refusal.error)
ok(has(tree_refusal and tree_refusal.next, "release"),
  "and the refusal offers the release path by name instead of leaving the operator to guess",
  tree_refusal and tree_refusal.next)

-- ---- (b) --binary on that node takes the release path, and is not refused for a tree it never wanted ----
local binary = remote.admit({ action = "request", commit = TARGET, mode = "binary", reason = "treeless binary install" }, MASTER)
ok(binary == nil or binary.error ~= "no_runtime_tree",
  "a binary install on a tree-less node is no longer refused as no_runtime_tree (it routes to the release)",
  binary and (tostring(binary.error) .. " - " .. tostring(binary.observed)))
ok(binary ~= nil and (binary.routed_from == "binary" or binary.kind == "release"),
  "and the answer records that it was routed, so a reader is not guessing which path ran",
  binary and tostring(binary.routed_from) .. "/" .. tostring(binary.kind))

-- ---- (c) --check names the record it found, and the command that moves such a node ----------------------
local checked = updater.check({ install = install, sentinel_dir = sentinel_dir })
ok(checked and checked.error == "no_runtime_tree", "a check on a tree-less node still refuses, by name",
  checked and checked.error)
ok(has(checked and checked.observed, "commit=" .. STALE),
  "and it quotes the installed.txt it actually found, not a generic absence", checked and checked.observed)
ok(has(checked and checked.message, "installed.txt says"),
  "the message says what the file says", checked and checked.message)
ok(has(checked and checked.next, "--release"),
  "and names the release command that moves this node", checked and checked.next)
ok(not has(checked and checked.message, "no tree or release record to compare with"),
  "the sentence that named nothing is gone", checked and checked.message)

-- ---- (d) with no record at all the check still says so honestly -----------------------------------------
local empty = home .. "/empty-install"
pcall(host.exec, "mkdir -p '" .. empty .. "'", "")
local none = updater.check({ install = empty, sentinel_dir = sentinel_dir })
ok(none and has(none.observed, "names no commit"),
  "an install with no record at all is said to have none (not confused with a stale one)", none and none.observed)

updater.facts = real_facts
if failed > 0 then error(checks .. " checks, " .. failed .. " FAILED") end
print("update treeless ok (" .. checks .. " checks)")
