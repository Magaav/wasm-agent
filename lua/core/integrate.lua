-- Worker-owned ordinary Git integration; cooperative repository claim serializes main.
-- No installer/Sentinel entrypoint. Conflicts refuse before canonical mutation.
local json=dofile('lua/vendor/json.lua')
local resources=dofile('lua/core/resources.lua')
local platform=dofile('lua/core/platform.lua')
local paths=dofile('lua/core/paths.lua')
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
  local function git(root,args)
    local result=json.decode(host.exec('git -C '..quote(root)..' '..args,own,120))
    if tonumber(result.code)~=0 or result.ok==false then error('git_failed: '..tostring(result.stderr or result.error or result.stdout)) end
    return tostring(result.stdout or ''):gsub('%s+$','')
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
    local common=git(own,'rev-parse --path-format=absolute --git-common-dir')
    local main=git(own,'worktree list --porcelain'):match('^worktree ([^\r\n]+)')
    if not main or git(main,'branch --show-current')~='main' then return {error='canonical_main_unavailable',effect='none'} end
    if git(main,'rev-parse --path-format=absolute --git-common-dir')~=common then return {error='canonical_repository_mismatch',effect='none'} end
    if git(main,'status --porcelain')~='' then return {error='integration_dirty_main',effect='none'} end
    git(own,'fetch origin')
    local base=git(own,'rev-parse origin/main')
    -- A worker resolves conflicts itself in its owned branch and re-runs focused checks.
    local proof=json.decode(host.exec('git -C '..quote(own)..' merge-tree --write-tree '..base..' '..tip,own,120))
    if tonumber(proof.code)~=0 then return {error='integration_conflict',detail=proof.stdout,effect='none',next='Sync/refactor in your worktree, self-review, recheck and recommit; never resolve inside canonical main.'} end
    if git(main,'rev-parse HEAD')~=base then return {error='canonical_main_not_current',effect='none'} end
    local claim=resources.claim(lockctx,{'shared:integration:'..host.sha256(platform.os()=='windows' and common:lower() or common)})
    if not claim.ok then return {error='integration_busy_or_uncertain',claim=claim,effect='none'} end
    held=true
    -- Recheck the exact candidate after exclusion, before touching canonical main.
    if git(main,'rev-parse HEAD')~=base or git(main,'status --porcelain')~='' or git(own,'rev-parse HEAD')~=tip then
      return {error='integration_candidate_changed',effect='none'}
    end
    local journal=paths.data()..'/integration-'..host.uuid()..'.json'
    assert(host.write_file(journal,json.encode({state='admitted',own=own,main=main,tip=tip,base=base,session_id=ctx.session_id})),'integration_journal_write_failed')
    memory.meta_set(effect_key,journal)
    started=true
    git(main,'merge --no-ff '..tip..' -m '..quote('merge('..branch..'): worker-owned task')..' -m '..quote('Self-review and focused checks by task owner; no independent review or full release claim.')..' -m '..quote('Agent: wasm-agent role=child session='..ctx.session_id))
    local landed=git(main,'rev-parse HEAD')
    if git(main,'rev-parse HEAD^{tree}')~=(proof.stdout or ''):match('^(%x+)') then error('integration_tree_changed') end
    if git(main,'status --porcelain')~='' then error('canonical_dirty_after_merge') end
    assert(host.write_file(journal,json.encode({state='merged',own=own,main=main,tip=tip,landed=landed,session_id=ctx.session_id})),'integration_journal_write_failed')
    git(main,'push origin main')
    local remote=git(main,'ls-remote origin refs/heads/main'):match('^(%x+)')
    if remote~=landed then error('remote_main_mismatch') end
    git(own,'merge --ff-only origin/main')
    if git(own,'status --porcelain')~='' then error('worker_dirty_after_integration') end
    local receipt={ok=true,tip=tip,landed=landed,remote_verified=true,clean=true,journal=journal,installed=false,gate_verified=false,release_verified=false}
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
