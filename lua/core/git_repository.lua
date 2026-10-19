-- Repository identity, and the canonical main worktree that identity names.
--
-- Why this module exists: the integrator and the wave closure each derived canonical main from the
-- FIRST line of `git worktree list --porcelain`. That listing is unbounded - 26 KB and 145
-- worktrees on this repository - while `host.exec` hands back a bounded view, so with enough
-- worktrees the first line was clipped, the parse returned nil, and a perfectly healthy
-- repository was refused with `canonical_main_unavailable` / `wave_canonical_main_missing`.
--
-- The bounded fact is `git rev-parse --path-format=absolute --git-common-dir`: one line, no
-- listing, nothing to clip. The canonical main worktree is that common directory without its
-- trailing `/.git`, which is the same answer `worktree list` puts on its first line. Every
-- original requirement stays with the caller (branch is main, same common dir, clean tree, base
-- is current); only how the path is obtained changed.
local platform=dofile('lua/core/platform.lua')
local output=dofile('lua/core/command_output.lua')
local M={}
M.TRUNCATED=output.TRUNCATED
local function quote(value) value=tostring(value or '') return "'"..value:gsub("'","'\\''").."'" end
-- Path comparison is case-insensitive on Windows; a repository key must match the way the
-- resource claim compares it, or two spellings of one repository look like two.
local function normalize(value) return platform.os()=='windows' and tostring(value):lower() or tostring(value) end

local function require_result(result,why,what)
  if not result then error('git_result_unavailable: '..tostring(what)..': '..tostring(why),0) end
  return result
end

-- The decoded result of one read-only git command. A truncated view is NOT refused here: the
-- caller says whether it needs the beginning (`fact`) or all of it (`output`).
function M.result(root,args,seconds)
  return require_result(output.run('git -C '..quote(root)..' '..args,root,seconds or 120),'exec', 'git '..args)
end

-- A one-token answer (rev-parse, branch --show-current, ls-remote of one ref). Refuses when the
-- view was clipped, because a token read out of a clipped stream is a guess: no such answer can
-- legitimately exceed the retained head, and `output_truncated_requires_bounded_command` is the
-- honest refusal when one does.
function M.fact(root,args,what)
  local result=M.result(root,args)
  if output.truncated(result) then
    error(M.TRUNCATED..': '..tostring(what or ('git '..args))..' answered more than the view retains, so its first line cannot be read as the whole answer',0)
  end
  return (output.preview(result):gsub('%s+$',''))
end

-- A whole listing, path list or manifest. Complete by construction: the retained original is
-- read when the view was clipped, so absence in the answer means absence from the output.
function M.output(root,args,what)
  return output.complete(M.result(root,args),what or ('git '..args))
end

-- The absolute common git dir of the repository `root` belongs to. This is the bounded fact.
function M.common_dir(root)
  local common=M.fact(root,'rev-parse --path-format=absolute --git-common-dir','git common dir')
  if common=='' then error('git_repository_unidentified: git reported no common directory for '..tostring(root),0) end
  return common
end

-- The canonical main worktree of the repository `root` belongs to, derived from the common dir.
-- Returns nil when no path can be derived (a common dir that is not inside a `/.git` directory),
-- so a caller keeps its own refusal for that case instead of being handed `""`.
function M.canonical_main(root)
  local common=M.common_dir(root)
  local main=common:gsub('[/\\]%.git[/\\]?$','')
  if main=='' or main==common then return nil,common end
  return main,common
end

-- Identity of the repository `root` belongs to: the common dir, the canonical main worktree
-- derived from it, and the comparison key. Raises `not_a_git_repository` when git cannot answer.
function M.identity(root)
  local main,common=M.canonical_main(root)
  if not main then error('git_repository_main_worktree_underivable: '..tostring(common),0) end
  return {common=common,main=main,key=normalize(common)}
end

-- The branch checked out at `path`, or '' when it is not a checkout.
function M.branch(path) return M.fact(path,'branch --show-current','git branch --show-current') end

-- True when both roots live in one repository, compared the way the resource claim compares it.
function M.same_repository(a,b)
  local left=M.common_dir(a)
  local right=M.common_dir(b)
  return normalize(left)==normalize(right),left,right
end

return M
