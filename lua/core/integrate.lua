-- Worker-owned ordinary Git integration; cooperative repository claim serializes main.
-- No installer/Sentinel entrypoint. Conflicts refuse before canonical mutation.
local json=dofile('lua/vendor/json.lua')
local resources=dofile('lua/core/resources.lua')
local platform=dofile('lua/core/platform.lua')
local paths=dofile('lua/core/paths.lua')
local command_output=dofile('lua/core/command_output.lua')
local git_repository=dofile('lua/core/git_repository.lua')
local M={}
local function quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
function M.run(memory,ctx)
  if not ctx.subagent or ctx.subagent.id~='orchestration-worker' or not ctx.run_id or ctx.run_id=='' then return {error='integration_worker_only',effect='none'} end
  local workspace=memory.session_workspace(ctx.session_id)
  if not workspace or not workspace.required or workspace.state~='allocated' then return {error='session_workspace_unavailable',effect='none'} end
  local own=workspace.worktree
  local effect_key='integration-effect:'..ctx.session_id..':'..ctx.run_id
  local prior=memory.meta_get(effect_key)
  if prior then
    local raw=host.read_file(prior)
    local ok,receipt=pcall(json.decode,raw or '')
    if ok and type(receipt)=='table' and receipt.ok==true then receipt.replayed=false;receipt.observation_only=true;return receipt end
    return {error='integration_effect_already_recorded',effect='unknown',journal=prior,next='Inspect original journal and actual Git/remote; do not replay.'}
  end
  local function git_result(root,args)
    local result=git_repository.result(root,args)
    if tonumber(result.code)~=0 or result.ok==false then error('git_failed: '..tostring(result.stderr or result.error or result.stdout)) end
    return result
  end
  -- Every answer read below is a token, an emptiness check or a commit trailer: all of them live
  -- in the two ends the bounded exec view always keeps (first 8 KiB, last 16 KiB).
  local function git(root,args) return (command_output.preview(git_result(root,args)):gsub('%s+$','')) end
  -- A fact that must be the WHOLE answer. If the host clipped the view, the refusal names the
  -- clipping (`output_truncated_requires_bounded_command`) instead of blaming the repository.
  local function git_fact(root,args,what)
    local result=git_result(root,args)
    if command_output.truncated(result) then error(git_repository.TRUNCATED..': '..what..' output was clipped by the bounded exec view',0) end
    return (command_output.preview(result):gsub('%s+$',''))
  end
  local started,held=false,false
  local lockctx={user_id=ctx.user_id,session_id=ctx.session_id,run_id=ctx.run_id..':integration'}
  local ok,result=pcall(function()
    if git(own,'status --porcelain')~='' then return {error='integration_dirty_worker',effect='none'} end
    local tip=git(own,'rev-parse HEAD')
    local branch=git(own,'branch --show-current')
    if branch~=workspace.branch then return {error='integration_binding_branch_mismatch',effect='none'} end
    local message=git(own,'show -s --format=%B HEAD')
    if not message:find('Agent:',1,true) or not message:find('session='..ctx.session_id,1,true) then
      return {error='integration_provenance_missing',effect='none'}
    end
    -- Canonical main is derived from the common git dir, never from the first line of
    -- `worktree list`: that listing is unbounded (26 KB, 145 worktrees here) while host.exec
    -- returns a bounded view, so its first line can be clipped away and a perfectly good
    -- repository refused (measured twice in one day). The checks that follow are unchanged;
    -- only the way the path is obtained changed. A clipped input refuses by name.
    local ok_repository,repository=pcall(git_repository.identity,own)
    if not ok_repository then
      local why=tostring(repository)
      if why:find(git_repository.TRUNCATED,1,true) then return {error=git_repository.TRUNCATED,detail=why,effect='none'} end
      return {error='canonical_main_unavailable',detail=why,effect='none'}
    end
    local common,main=repository.common,repository.main
    if git_fact(main,'branch --show-current','canonical main branch')~='main' then return {error='canonical_main_unavailable',effect='none'} end
    if git_fact(main,'rev-parse --path-format=absolute --git-common-dir','canonical main common dir')~=common then return {error='canonical_repository_mismatch',effect='none'} end
    if git(main,'status --porcelain')~='' then return {error='integration_dirty_main',effect='none'} end
    git(own,'fetch origin')
    local base=git(own,'rev-parse origin/main')
    -- A worker resolves conflicts itself in its owned branch and re-runs focused checks.
    local proof=git_repository.result(own,'merge-tree --write-tree '..base..' '..tip)
    if tonumber(proof.code)~=0 then return {error='integration_conflict',detail=proof.stdout,effect='none',next='Sync/refactor in your worktree, self-review, recheck and recommit; never resolve inside canonical main.'} end
    -- The predicted tree is the FIRST line, and a merge with thousands of changed paths prints
    -- them after it. The bounded view keeps the beginning, so the first line is present; if the
    -- view was still clipped the answer is refused by name BEFORE canonical main is touched,
    -- never misreported afterwards as `integration_tree_changed`.
    local predicted=command_output.preview(proof):match('^(%x+)')
    if not predicted then
      if command_output.truncated(proof) then return {error=git_repository.TRUNCATED,detail='git merge-tree --write-tree output was clipped by the bounded exec view',effect='none'} end
      return {error='integration_merge_tree_unreadable',effect='none',next='Inspect `git merge-tree --write-tree <base> <tip>` in the worktree; canonical main was not touched.'}
    end
    if git(main,'rev-parse HEAD')~=base then return {error='canonical_main_not_current',effect='none'} end
    local claim=resources.claim(lockctx,{'shared:integration:'..host.sha256(platform.os()=='windows' and common:lower() or common)})
    if not claim.ok then return {error='integration_busy_or_uncertain',claim=claim,effect='none'} end
    held=true
    -- Recheck the exact candidate after exclusion, before touching canonical main.
    if git(main,'rev-parse HEAD')~=base or git(main,'status --porcelain')~='' or git(own,'rev-parse HEAD')~=tip then
      return {error='integration_candidate_changed',effect='none'}
    end
    local impact=dofile('lua/core/wave_autoflush.lua').capture(memory,ctx,own,tip,base)
    local journal=paths.data()..'/integration-'..host.uuid()..'.json'
    assert(host.write_file(journal,json.encode({state='admitted',own=own,main=main,tip=tip,base=base,session_id=ctx.session_id})),'integration_journal_write_failed')
    memory.meta_set(effect_key,journal)
    started=true
    git(main,'merge --no-ff '..tip..' -m '..quote('merge('..branch..'): worker-owned task')..' -m '..quote('Self-review and focused checks by task owner; no independent review or full release claim.')..' -m '..quote('Agent: wasm-agent role=child session='..ctx.session_id))
    local landed=git(main,'rev-parse HEAD')
    if git_fact(main,'rev-parse HEAD^{tree}','canonical main tree')~=predicted then error('integration_tree_changed') end
    if git(main,'status --porcelain')~='' then error('canonical_dirty_after_merge') end
    assert(host.write_file(journal,json.encode({state='merged',own=own,main=main,tip=tip,landed=landed,session_id=ctx.session_id})),'integration_journal_write_failed')
    git(main,'push origin main')
    local remote=git(main,'ls-remote origin refs/heads/main'):match('^(%x+)')
    if remote~=landed then error('remote_main_mismatch') end
    git(own,'merge --ff-only origin/main')
    if git(own,'status --porcelain')~='' then error('worker_dirty_after_integration') end
    local receipt={ok=true,tip=tip,impact=impact,landed=landed,remote_verified=true,clean=true,journal=journal,installed=false,gate_verified=false,release_verified=false}
    assert(host.write_file(journal,json.encode(receipt)),'integration_receipt_write_failed');return receipt
  end)
  if held then
    if not ok and started then resources.uncertain(lockctx);resources.finish(lockctx) -- Retain unknown claim, end this lock owner's execution.
    else
      local released=resources.finish(lockctx)
      if not released.ok then return {error='integration_lock_release_failed',detail=released,effect='unknown'} end
    end
  end
  if ok then return result end
  return {error='integration_failed',detail=tostring(result),effect=started and 'unknown' or 'none',next='Inspect actual Git/remote/journal state before any further effect; never replay an uncertain merge/push.'}
end
return M
