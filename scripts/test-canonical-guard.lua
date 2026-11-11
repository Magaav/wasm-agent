-- The canonical checkout's tool-layer guard (lua/core/canonical_guard.lua).
--
-- Measured three times on wasm_the_first, 2026-11-10 (sessions e0fc6da6, 3e9b0fa6, 42801f80): sessions edited
-- the canonical checkout directly, a dirty canonical tree refused a landing, and once blocked a deploy for
-- about seven minutes. The queue refuses the *next* lander; this guard refuses the edit itself, naming the
-- rule and the worktree to use.
--
-- The decision is pure, so this test needs no repository, no node and no filesystem.
--
-- Run from the repo root:
--   WA_SCRIPT=scripts/test-canonical-guard.lua wa --db /tmp/canonical-guard.db
local guard = dofile("lua/core/canonical_guard.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local CANONICAL = "C:/Users/Victor/orca/projects/wasm-agent"
local WORKTREE = "C:/Users/Victor/wa-build/wt-w4"
local SESSION = "11111111-2222-3333-4444-555555555555"
local OTHER = "22222222-3333-4444-5555-666666666666"

local function facts(overrides)
  local value = {canonical = CANONICAL, worktree = WORKTREE, session = SESSION}
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

-- 1. A write into the canonical checkout is refused, and the refusal is actionable.
local refused = guard.decide(facts({tool = "write", path = CANONICAL .. "/lua/core/server.lua"}))
ok(refused ~= nil, "a write into the canonical checkout is refused")
ok(refused.error == "canonical_checkout_protected", "the refusal is named", refused.error)
ok(refused.effect == "none", "a refusal never claims an effect", refused.effect)
ok(tostring(refused.detail):find("write of a file inside the canonical checkout", 1, true) ~= nil,
  "it says what was about to happen", refused.detail)
ok(tostring(refused.next):find(WORKTREE, 1, true) ~= nil, "it names the worktree to use instead", refused.next)
ok(tostring(refused.next):find("landing-queue.mjs land", 1, true) ~= nil,
  "and the way work reaches the tree (the queue), not a hand edit", refused.next)

-- 2. The lease holder may write there: that is what a landing is.
ok(guard.decide(facts({tool = "write", path = CANONICAL .. "/lua/core/server.lua",
  holder = {owner = SESSION, id = 7, kind = "landing", branch = "change/x"}})) == nil,
  "the landing lease holder may write into the canonical checkout")
local held = guard.decide(facts({tool = "edit", path = CANONICAL .. "/docs/A.md",
  holder = {owner = OTHER, id = 8, kind = "landing", branch = "change/y"}}))
ok(held ~= nil, "another session's lease does not authorise this session")
ok(tostring(held.next):find("held by " .. OTHER, 1, true) ~= nil,
  "and the refusal names the holder, so the edit cannot land someone else's merge unnoticed", held.next)

-- 3. The same write in a lane worktree is ordinary work.
ok(guard.decide(facts({tool = "write", path = WORKTREE .. "/lua/core/server.lua"})) == nil,
  "a write in the session's own worktree is allowed")
ok(guard.decide(facts({tool = "edit", path = "C:/Users/Victor/wa-build/wt-w4/AGENTS.md"})) == nil,
  "an edit in a worktree is allowed")

-- 4. Path spelling must not defeat the boundary (Windows separators, case, trailing slash).
ok(guard.decide(facts({tool = "write", path = "C:\\Users\\Victor\\orca\\projects\\wasm-agent\\lua\\x.lua"})) ~= nil,
  "a backslash spelling of the canonical path is still the canonical checkout")
ok(guard.decide(facts({tool = "write", path = "c:/users/victor/orca/projects/wasm-agent/lua/x.lua"})) ~= nil,
  "a lower-case spelling is still the canonical checkout")
ok(guard.decide(facts({tool = "write", path = CANONICAL .. "-other/lua/x.lua"})) == nil,
  "a directory whose name merely starts with the checkout's is not inside it")
ok(guard.inside(CANONICAL, CANONICAL) and not guard.inside(CANONICAL .. "x", CANONICAL),
  "inside() is a path boundary, not a prefix match")

-- 5. bash: reads are allowed, writes are not, and the verb is named.
ok(guard.decide(facts({tool = "bash", command = "git -C " .. CANONICAL .. " status --porcelain"})) == nil,
  "git status in the canonical checkout is a read")
ok(guard.decide(facts({tool = "bash", command = "cat " .. CANONICAL .. "/AGENTS.md"})) == nil,
  "cat of a canonical file is a read")
ok(guard.decide(facts({tool = "bash", command = "rg -n node_state " .. CANONICAL .. "/lua"})) == nil,
  "rg over the canonical tree is a read")
local merged = guard.decide(facts({tool = "bash", command = "git -C " .. CANONICAL .. " merge change/x"}))
ok(merged ~= nil, "git merge in the canonical checkout is refused")
ok(tostring(merged.detail):find("git merge", 1, true) ~= nil, "and the verb is named", merged.detail)
ok(guard.decide(facts({tool = "bash", command = "cd " .. CANONICAL .. " && git commit -am wip"})) ~= nil,
  "a commit after cd into the canonical checkout is refused")
ok(guard.decide(facts({tool = "bash", command = "echo x > " .. CANONICAL .. "/lua/core/x.lua"})) ~= nil,
  "a redirection into the canonical checkout is refused")
local appended = guard.decide(facts({tool = "bash",
  command = "echo x >> " .. CANONICAL .. "/lua/core/x.lua"}))
ok(appended ~= nil and tostring(appended.detail):find("redirection", 1, true) ~= nil,
  "an append is a redirection too")
ok(guard.decide(facts({tool = "bash", command = "git -C " .. WORKTREE .. " commit -am wip"})) == nil,
  "a commit in the session's own worktree is allowed")
ok(guard.decide(facts({tool = "bash", command = "ls /tmp"})) == nil,
  "a command that does not name the canonical checkout is not this guard's business")

-- 6. `operation start` runs a shell, so it takes the same rule; other operation actions do not.
ok(guard.decide(facts({tool = "operation", command = "git -C " .. CANONICAL .. " reset --hard"})) ~= nil,
  "operation start of a mutating command in the canonical checkout is refused")

print(string.format("canonical guard: %d checks passed", checks))
