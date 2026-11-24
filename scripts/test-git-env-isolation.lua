-- GIT ENVIRONMENT ISOLATION (G blocker, 24/11): a session's commit lands in ITS OWN worktree.
--
-- WHAT HAPPENED: 24/11 11:49:31Z a commit by the deploy-hold worker (783ae80c) landed in a DIFFERENT live
-- session's worktree (~/Work/missions/whatsapp-read-is-consistent/wt): it took that worktree's staged
-- components.lock and moved its HEAD. The command itself said
--   `cd <deploy-hold's own wt> && git add -A lua scripts && git commit -q -F m.txt`
-- An explicit `cd` beats any working directory, so only git's own environment can do that:
-- GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE in the environment of the bash that ran.
--
-- THE MECHANISM (file:line): rust/wa-operation/src/process.rs:76 is the one place every tool child is
-- spawned, and it removed only the names in rust/wa-operation/src/lib.rs:36 - not one git name. `Command`
-- hands the node's own environment on, so a `GIT_*` the node carries reached every session's bash. Git
-- exports GIT_DIR and GIT_INDEX_FILE to every hook it runs, so a node started from under a git hook hands
-- one repository's identity to every session it serves, in every worktree at once.
--
-- THE ROW (the other half): scripts/test-git-env-isolation.sh starts TWO real nodes, each with its own
-- home and database, from a parent that carries those three names, and has each of them commit 50 times
-- into its own worktree of ONE repository at the same moment. This file is one of those sessions; it
-- reaches git through `host.exec`, the same child the `bash` tool runs (lua/core/tools.lua:1426 ->
-- host.exec -> wa_operations::foreground -> wa_operation::Process::spawn), never by a direct dispatch.
--
-- Hermetic: scratch home, scratch database, scratch repository; it refuses the real ~/.wasm-agent.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local data = tostring(paths.data())
local home = tostring(host.getenv and host.getenv('HOME') or '')
assert(not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true)
  or data:find('wa%-test'), 'this row makes real commits; it refused to run in ' .. data)

local own = tostring(host.getenv and host.getenv('WA_TEST_GIT_WT') or '')
local other = tostring(host.getenv and host.getenv('WA_TEST_GIT_OTHER_WT') or '')
local label = tostring(host.getenv and host.getenv('WA_TEST_GIT_LABEL') or '')
local scratch = tostring(host.getenv and host.getenv('WA_TEST_GIT_SCRATCH') or '')
assert(own ~= '' and other ~= '' and label ~= '' and scratch ~= '' and own ~= other,
  'the wrapper did not name the two worktrees this session owns and does not own')

local checks = 0
local function check(condition, text) assert(condition, text); checks = checks + 1 end
local function trim(text) return (tostring(text or ''):gsub('%s+$', ''):gsub('^%s+', '')) end
local SELF = 'session ' .. label .. ' (' .. own .. ')'

-- Every git call in this row is that child. Nothing here runs git on the node's own behalf.
local function sh(command, cwd)
  local ran, raw = pcall(host.exec, command, cwd or '', 120)
  check(ran, SELF .. ': host.exec refused ' .. command .. ': ' .. tostring(raw))
  local row = json.decode(raw) or {}
  return tostring(row.stdout or ''), tostring(row.stderr or ''), tonumber(row.code) or -1
end

-- ---- 50 commits of this session's own, into this session's own worktree -------------------
for i = 1, 50 do
  local subject = label .. '-' .. string.format('%03d', i)
  local _, err, code = sh('echo ' .. i .. ' > ' .. subject .. '.txt && git add -A && git commit -q -m ' .. subject, own)
  check(code == 0, SELF .. ': commit ' .. subject .. ' failed: ' .. err)
  local top = trim((sh('git rev-parse --show-toplevel', own)))
  check(top == own, SELF .. ': the commit ran in my own worktree, not in ' .. top)
  local got = trim((sh('git log -1 --format=%s', own)))
  check(got == subject,
    SELF .. ': the top of my own worktree is my commit - wanted ' .. subject .. ', found ' .. got)
end

-- ---- the boundary itself ----------------------------------------------------------------
-- The NODE keeps what it was started with: the fix is a removal at the child's spawn, not a mutation of
-- the process (a set_var of a GIT_* name would race every other session's spawn on the same node).
for _, name in ipairs({ 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE' }) do
  check(tostring(host.getenv(name) or '') ~= '',
    SELF .. ': the node itself still carries ' .. name .. ' - the wrapper must export it for this row to test anything')
end
-- ... and the child has none of them.
local seen = trim((sh('printenv GIT_DIR', own)))
check(seen == '', SELF .. ': its bash child inherits NO GIT_DIR, it saw: ' .. seen)
local seen_all = trim((sh('printenv GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY', own)))
check(seen_all == '', SELF .. ': no git name that can choose a repository reaches the child, it saw: ' .. seen_all)
-- The keep list still arrives, so a child is not stripped of a hermetic config or a non-prompting git:
local kept = trim((sh('printenv GIT_TERMINAL_PROMPT', own)))
check(kept == '0', SELF .. ': GIT_TERMINAL_PROMPT still reaches the child (kept): ' .. kept)

local function wait_for(path, seconds)
  local _, err, code = sh(string.format(
    'i=0; while [ $i -lt %d ]; do [ -f %q ] && exit 0; i=$((i+1)); sleep 0.2; done; exit 1',
    seconds * 5, path))
  check(code == 0, SELF .. ': waited ' .. seconds .. 's for ' .. path .. ' and it never appeared: ' .. err)
end

-- ---- a staged file is not another session's to commit -------------------------------------
-- This is the half of the incident that cost the most: the commit swallowed whatsapp-read's staged
-- components.lock. One session stages and does NOT commit; the other commits; the staged file must still
-- be staged, in its own worktree's index, and absent from the other session's commit.
if label == 'a' then
  local _, err, code = sh('echo mine > a-staged-only.txt && git add a-staged-only.txt', own)
  check(code == 0, SELF .. ': could not stage its own file: ' .. err)
  check(trim((sh('git diff --cached --name-only', own))) == 'a-staged-only.txt',
    SELF .. ': a-staged-only.txt is staged in my own worktree')
  sh('touch ' .. scratch .. '/staged.ready')
  wait_for(scratch .. '/final.done', 180)
  local staged = trim((sh('git diff --cached --name-only', own)))
  check(staged == 'a-staged-only.txt',
    SELF .. ': my staged file is STILL staged after the other session committed: ' .. staged)
  local head = trim((sh('git log -1 --format=%s', own)))
  check(head == 'a-050', SELF .. ': the other session\'s commit did not land on top of mine: ' .. head)
else
  wait_for(scratch .. '/staged.ready', 180)
  local _, err, code = sh('echo b > b-final.txt && git add -A && git commit -q -m b-final', own)
  check(code == 0, SELF .. ': its final commit failed: ' .. err)
  check(trim((sh('git log -1 --format=%s', own))) == 'b-final',
    SELF .. ': its final commit is in its own worktree')
  sh('touch ' .. scratch .. '/final.done')
end

print(string.format('%s: git env isolation ok (%d checks) in %s', label, checks, own))
