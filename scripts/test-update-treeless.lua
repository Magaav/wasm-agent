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

-- ---- (a2) ...AND IT IS ONE LINE THAT CARRIES THE COMMAND (mission release-node-updates, D1, 25/11) ------
-- Measured on a scratch peer installed from the published v0.1.1 bundle: "wa update peer011 --commit <sha>"
-- answered three lines of prose that named mode="release" and no command, so the fleet step - which asks for
-- an exact commit - was told what a release is and not what to type. The line below is what it answers now:
-- the command, with the caller's own commit in it.
local line = remote.summary(tree_refusal)
ok(tree_refusal and tree_refusal.one_line == true,
  "the refusal says it is a one-line answer", tree_refusal and tostring(tree_refusal.one_line))
ok(not has(line, string.char(10)) and line == tostring(tree_refusal.message),
  "the answer a person reads is ONE line, and it is the reply's own message", line)
ok(has(line, "wa update ") and has(line, "--release") and has(line, "--commit " .. TARGET),
  "and that one line is the exact command, with the commit the caller asked for", line)
ok(has(line, "installed from a release"),
  "it says why the tree door is not the one to use", line)
ok(remote.next_line(tree_refusal) == nil,
  "the fix is not printed twice: the line already carries it", tostring(remote.next_line(tree_refusal)))
ok(remote.next_line({ error = "any_other", observed = "x", summary = "peer any_other: x", next = "do the thing" }) == "do the thing",
  "a refusal that does NOT carry its fix on the line still gets its next: line")
ok(has(tree_refusal and tree_refusal.next, "--release --commit " .. TARGET),
  "reply.next still carries the command on its own, for a tool that reads fields and not sentences",
  tree_refusal and tree_refusal.next)
-- No commit named: the release door cannot be asked without one (release_commit_required), so the line asks
-- for a commit rather than ending in an empty "--commit".
local no_commit = remote.admit({ action = "request", reason = "treeless, no commit" }, MASTER)
ok(has(no_commit and no_commit.message, "--commit <40-hex>"),
  "with no commit to name, the line asks for one instead of printing an empty --commit",
  no_commit and no_commit.message)

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

-- ---- (f) THE COORDINATOR'S OWN ONE LINE, against the published v0.1.1 peer's verbatim refusal ---------
-- The node that most needs to say the right thing is the one that cannot be changed: a peer installed from the
-- published v0.1.1 bundle answers an ordinary commit request with the prose below (MEASURED 25/11 on a scratch
-- pair, ready-1). The fleet step runs on the COORDINATOR, so the one line has to be built there - from the
-- selector the operator used and the commit they asked for - and the peer's own words must survive in observed.
--
-- Nothing here reaches a node or a roster: host.http is stubbed to answer nothing, because the roster is not
-- what this row is about and a test must never call a live fleet.
local peer_http = host.http
host.http = function() return nil end
-- A FRESH TABLE PER CALL: the module annotates the reply it is handed, so one shared fixture table would carry
-- the first call's fields into the second and every row after it would assert the previous row's mutation.
local function v011_refusal(tweak)
  return {
    error = "no_runtime_tree", effect = "none",
    observed = "this node has no runtime-worktree.txt and does not run from a checkout, so there is no tree to move to a commit",
    next = 'this node is installed from a release: ask for it with mode="release" (wa update <node> --release), which fetches the published release and installs it as a neighbour process',
  }
end
local answer = remote.request(function() return v011_refusal() end, "peer011", { commit = TARGET, reason = "the fleet step" })
local answer_line = remote.summary(answer)
ok(answer and answer.error == "no_runtime_tree", "the refusal is still no_runtime_tree (the code every caller reads)", answer and answer.error)
ok(answer and answer.one_line == true, "the coordinator marks it as a one-line answer")
ok(not has(answer_line, string.char(10)) and answer_line == tostring(answer.message),
  "the answer a person reads is ONE line", answer_line)
ok(has(answer_line, "wa update peer011 --release --commit " .. TARGET),
  "and it is the exact command, named for the node the operator asked about, with their commit", answer_line)
ok(has(answer and answer.observed, "no runtime-worktree.txt"),
  "the peer's own observation is kept, not replaced by the coordinator's sentence", answer and answer.observed)
ok(not has(answer_line, 'mode="release"'),
  "and the prose that named a mode and no command is not what the operator reads", answer_line)
ok(remote.next_line(answer) == nil, "the command is not printed a second time under next:")
-- A caller that NAMED its door is not lectured about it.
local quiet = remote.request(function() return v011_refusal() end, "peer011", { commit = TARGET, mode = "release" })
ok(quiet and quiet.one_line == nil, "a --release request gets the peer's answer unchanged (it already named the door)",
  quiet and tostring(quiet.one_line))
host.http = peer_http

updater.facts = real_facts
if failed > 0 then error(checks .. " checks, " .. failed .. " FAILED") end
print("update treeless ok (" .. checks .. " checks)")
