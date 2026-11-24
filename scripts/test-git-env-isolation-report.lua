-- ONE NODE, TWO SPAWNS, ONE LINE: the node says out loud that it withheld a git name, and says it once.
--
-- Part of scripts/test-git-env-isolation.sh: that wrapper starts this row as a THIRD real node, with
-- GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE in its environment (the shape a git hook leaves), keeps its stderr,
-- and checks the line there - this row cannot read the stderr of its own process, which is exactly why the
-- assertion lives in the wrapper and this file only makes the two spawns happen.
--
-- Hermetic: it makes no commits, writes nothing outside its own scratch home, and refuses the real
-- ~/.wasm-agent.
local paths = dofile('lua/core/paths.lua')
local data = tostring(paths.data())
local home = tostring(host.getenv and host.getenv('HOME') or '')
assert(not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true)
  or data:find('wa%-test'), 'this row starts tool children; it refused to run in ' .. data)

local checks = 0
local function check(condition, text) assert(condition, text); checks = checks + 1 end

-- TWO children of this node, through the same boundary the `bash` tool crosses.
for i = 1, 2 do
  local ran, raw = pcall(host.exec, 'printenv GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE', '', 60)
  check(ran, 'child ' .. i .. ' of the node could not be started: ' .. tostring(raw))
  local row = dofile('lua/vendor/json.lua').decode(raw) or {}
  local seen = tostring(row.stdout or ''):gsub('%s+$', '')
  check(seen == '', 'child ' .. i .. ' inherited a git name that can choose a repository: ' .. seen)
end

print(string.format('git env report ok (%d checks, two spawns, no git name in either child)', checks))
