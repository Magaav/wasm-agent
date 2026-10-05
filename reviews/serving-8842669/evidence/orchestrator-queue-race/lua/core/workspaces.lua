-- Per-session git worktrees for conversations that are independently writable.
-- The allocator records intent before invoking git and never maps a required-but-unbound
-- session back to the node cwd. Shell remains an operator-authorized capability, not a sandbox.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
local resources = dofile("lua/core/resources.lua")
local M = {}

local function quote(value)
  value = tostring(value or "")
  local shell = tostring(platform.shell_name() or ""):lower()
  if shell:find("cmd", 1, true) then
    if value:find('[&|<>^%%!"\r\n]') then return nil, "workspace_path_unsafe_for_cmd" end
    return '"' .. value:gsub("/", "\\") .. '"'
  elseif shell:find("powershell", 1, true) then
    return "'" .. value:gsub("'", "''") .. "'"
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run(command, cwd)
  local ok, raw = pcall(host.exec, command, cwd or "", 120)
  if not ok then return nil, "workspace_exec_failed: " .. tostring(raw) end
  local decoded_ok, result = pcall(json.decode, raw)
  if not decoded_ok or type(result) ~= "table" then return nil, "workspace_exec_invalid_result" end
  -- A command that exited non-zero is a failure, and the first return value says so. It used to
  -- return the result table either way, which made every `if not x` below unreachable and let a
  -- failed `git worktree add` be followed by reads answering with empty stdout - measured: a
  -- destination where the branch already existed reported `workspace_binding_branch_mismatch`
  -- instead of git's own `a branch named ... already exists`, the same refusal described wrongly.
  if tonumber(result.code) ~= 0 then
    local detail = tostring(result.stderr or result.error or result.stdout or "git command failed")
    return nil, "workspace_git_failed: " .. detail:sub(1, 1000)
  end
  return result
end

local function trimmed(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function wave_admission(root,phase)
  local lua_root=host.getenv('WASM_AGENT_LUA_ROOT')
  local entry=(lua_root and lua_root~='') and (lua_root..'/scripts/wave-entry.mjs') or (dofile('lua/core/update.lua').install_dir()..'/scripts/wave-entry.mjs')
  local ok,raw=pcall(host.exec,'node '..assert(quote(entry))..' check '..assert(quote(root))..' '..phase,root,120)
  if not ok then return false,'wave entrypoint unavailable: '..tostring(raw) end
  local envelope_ok,envelope=pcall(json.decode,raw)
  if not envelope_ok or type(envelope)~='table' then return false,'wave entrypoint unreadable' end
  -- The entrypoint encodes a refusal as JSON with an actionable reason even when it exits
  -- non-zero, so decode its verdict rather than collapsing it into 'unavailable'.
  local decoded_ok,decoded=pcall(json.decode,envelope.stdout or '{}')
  if not decoded_ok or type(decoded)~='table' then return false,'wave entrypoint wrote no verdict: '..tostring(envelope.stderr or ''):sub(1,200) end
  return decoded.ok==true,decoded.reason or decoded.mode or ('wave admission refused (exit '..tostring(envelope.code)..')')
end

local function mark(memory, id, current, state, error)
  current = current or {}
  current.required = true
  current.state = state
  current.error = error or ""
  return memory.set_session_workspace(id, current)
end

local function verify_binding(memory, id, workspace)
  local destination, quote_error = quote(workspace.worktree)
  if not destination then return nil, quote_error end
  local result, err = run("git -C " .. destination .. " rev-parse --show-toplevel", "")
  if not result then return nil, "workspace_binding_unavailable: " .. tostring(err) end
  local root = trimmed(result.stdout):gsub("\\", "/"):gsub("/$", "")
  local branch_result = run("git -C " .. destination .. " rev-parse --abbrev-ref HEAD", "")
  if not branch_result then return nil, "workspace_binding_branch_unavailable" end
  local branch = trimmed(branch_result.stdout)
  if branch ~= workspace.workspace_branch and workspace.workspace_branch ~= "" then
    return nil, "workspace_binding_branch_mismatch"
  end
  local saved = workspace.worktree:gsub("\\", "/"):gsub("/$", "")
  if platform.os() == "windows" then root, saved = root:lower(), saved:lower() end
  if root ~= saved then return nil, "workspace_binding_root_mismatch" end
  return { worktree = workspace.worktree, branch = branch, state = "allocated" }
end

local function directory_exists(path)
  if not host.list_dir then return nil end
  local ok, raw = pcall(host.list_dir, path)
  if not ok or type(raw) ~= "string" then return nil end
  local decoded_ok, listing = pcall(json.decode, raw)
  if not decoded_ok or type(listing) ~= "table" then return nil end
  return listing.error == nil
end

local function reconcile(memory, id, workspace)
  local verified, err = verify_binding(memory, id, workspace)
  if verified then
    workspace.worktree = verified.worktree
    workspace.branch = verified.branch
    workspace.required = true
    workspace.state = "allocated"
    workspace.error = ""
    return memory.set_session_workspace(id, workspace)
  end
  if directory_exists(workspace.worktree) then
    err = "workspace_allocation_uncertain: destination exists but is not the recorded worktree"
  else
    err = "workspace_allocation_uncertain: allocation was in progress at the last shutdown; inspect git worktree state before retry"
  end
  mark(memory, id, workspace, "unknown", err)
  return nil, err
end

-- Which checkout a new workspace may fork from, by reading only.
--
-- A placed child arrives at a node that has never seen its parent: the coordinator's session, and the
-- path that session recorded (`C:/Users/.../wasm_the_first`), belong to another machine and mean
-- nothing here. The only source this node can honestly use is the tree its own node runs from -
-- which is also what a local child gets. Two things are therefore never a source: a path recorded by
-- a session of *another* node (one path on two machines is two different repositories, so even a path
-- that exists here means something else), and a path that names nothing on this machine. An empty
-- source, or an incoming path that is gone, falls through to this node's own checkout instead of
-- refusing a child that could still run; a path that IS here and is not a checkout is refused
-- visibly, because that is the caller's to fix and not ours to silently replace.
--
-- Reading only, so the same rule runs as a preflight *before* the child's session row exists: a
-- destination that refuses must not be left holding a session shell it will only retire.
local function inspect_tree(path)
  local result, err = run("git rev-parse --show-toplevel", path)
  if not result then return nil, "workspace_source_not_git: " .. tostring(err) end
  local root = trimmed(result.stdout)
  if root == "" then return nil, "workspace_source_root_missing" end
  local head_result, head_error = run("git rev-parse HEAD", path)
  local branch_result, branch_error = run("git rev-parse --abbrev-ref HEAD", path)
  local status_result, status_error = run("git status --porcelain --untracked-files=all", path)
  if not head_result or not branch_result or not status_result then
    return nil, "workspace_source_inspection_failed: " .. tostring(head_error or branch_error or status_error)
  end
  return {
    path = path, root = root, head = trimmed(head_result.stdout),
    branch = trimmed(branch_result.stdout), status = tostring(status_result.stdout or ""),
  }
end

local update_module = nil
local function own_update()
  if not update_module then update_module = dofile("lua/core/update.lua") end
  return update_module
end

-- `runtime-worktree.txt` written at install time, else the working directory when that really is a
-- checkout - the same resolver `/update` and `deploy.sh` use, so "the tree this node runs from"
-- cannot mean two different things on one machine.
local function own_tree()
  local ok, update = pcall(own_update)
  if not ok or type(update) ~= "table" or type(update.runtime_tree) ~= "function" then return nil, nil, "" end
  local install = update.install_dir()
  local tree, source = update.runtime_tree(install)
  return tree, source, install
end

-- The provenance is recorded, not implied: `origin` says which tree was used, `requested` repeats
-- what the incoming session named, and `fallback` is the reason it was not used (empty when it was).
local function inspect_source(memory, user_id, node_id, source_session_id)
  source_session_id = tostring(source_session_id or "")
  local source = source_session_id ~= "" and memory.session(source_session_id) or nil
  -- Another account's session is never a source, whatever its path says.
  if source and tostring(source.user_id or "") ~= tostring(user_id or "") then
    return nil, "workspace_owner_mismatch"
  end
  local usable = source ~= nil and tostring(source.node_id or "") == tostring(node_id or "")
  local requested, why_not = "", ""
  if source ~= nil then requested = tostring(memory.session_worktree(source_session_id) or "") end
  if source == nil then
    why_not = "workspace_source_session_not_found: session " .. source_session_id ..
      " is not on this node (a placed child's parent session lives on the node that dispatched it)"
  elseif not usable then
    why_not = "workspace_source_foreign_node: session " .. source_session_id .. " belongs to node " ..
      tostring(source.node_id or "") .. ", not " .. tostring(node_id or "")
  else
    local source_workspace = memory.session_workspace(source_session_id)
    if source_workspace and source_workspace.required
        and (source_workspace.state ~= "allocated" or tostring(source_workspace.worktree or "") == "") then
      return nil, "workspace_source_unavailable: source session requires an allocated isolated workspace"
    end
  end
  -- Read whether or not it will be used: what the incoming session named is provenance a reader
  -- needs (`C:/Users/.../wasm_the_first` is the whole reason this path exists), while *using* it is
  -- reserved for a session of this node.
  if requested == "" and usable and why_not == "" then
    why_not = "workspace_source_empty: session " .. source_session_id .. " names no checkout"
  end
  if usable and requested ~= "" then
    local inspected, tree_error = inspect_tree(requested)
    if inspected then
      inspected.requested, inspected.origin, inspected.fallback = requested, "source-session", ""
      return inspected
    end
    if directory_exists(requested) == false then
      why_not = "workspace_source_path_missing: " .. requested .. " does not exist on this machine"
    else
      -- It is here and it is not a checkout, or we cannot tell that it is gone: say so rather than
      -- quietly forking somewhere else.
      return nil, tree_error
    end
  end
  local tree, tree_source, install = own_tree()
  if tree then
    local inspected, own_error = inspect_tree(tree)
    if inspected then
      inspected.requested, inspected.origin, inspected.fallback = requested, tostring(tree_source or ""), why_not
      return inspected
    end
    return nil, "workspace_destination_source_missing: " .. tostring(tree_source or "runtime-worktree.txt") ..
      " names " .. tostring(tree) .. ", which is not a usable checkout (" .. tostring(own_error) ..
      "); the incoming source was unusable: " .. (why_not ~= "" and why_not or "workspace_source_empty")
  end
  return nil, "workspace_destination_source_missing: this node has no checkout of its own to fork from: " ..
    "runtime-worktree.txt is absent from " .. tostring(install) .. " and the working directory " ..
    tostring(platform.cwd()) .. " is not a checkout; the incoming source was unusable: " ..
    (why_not ~= "" and why_not or "workspace_source_empty")
end

-- The same decision `ensure` makes, taken before this node creates the child's session.
function M.preflight_source(memory, source_session_id, user_id, node_id)
  return inspect_source(memory, user_id, node_id, source_session_id)
end

-- A refusal sentence and its code are one string: everything before the first colon names what
-- happened, and that code is what a caller branches on - the coordinator's spill rule has to tell
-- "this destination cannot allocate at all" from "the source is dirty and a retry here will work".
function M.refusal_code(detail, fallback)
  local code = tostring(detail or ""):match("^([%w_]+)")
  if not code or code == "" then return fallback or "workspace_allocation_failed" end
  return code
end

-- Allocate one linked worktree from the source session's exact clean HEAD. Uncommitted
-- state is recorded and refused (not copied, stashed, or silently ignored). If a process
-- dies during git worktree add, the persisted 'allocating' record is reconciled, never
-- blindly replayed. source_session_id must be owned by the same principal; its checkout is
-- only used when that session is a session of this node (see inspect_source).
function M.ensure(memory, session_id, source_session_id, options)
  local session = memory.session(session_id)
  if not session then return nil, "workspace_session_not_found" end
  local current=memory.session_workspace(session_id)
  local root_recovery=options and options.root_recovery==true
  local is_root=tostring(session.parent_session_id or '')=='' and tostring(session.fork_parent_id or '')==''
  if root_recovery and (not is_root or source_session_id~=session_id) then
    return nil,'workspace_root_recovery_forbidden: explicit recovery is only for the owned root session'
  end
  local root_source=nil
  if is_root and source_session_id==session_id and current
      and (current.state=='unbound' or current.state=='pending' or current.state=='failed') then
    if not root_recovery then
      return nil,'workspace_root_recovery_required: the session owner must explicitly allocate or recover from the node runtime source'
    end
    if tostring(current.worktree or '')~='' then
      return nil,'workspace_root_recovery_existing_binding: inspect the recorded worktree; it is never replaced by a runtime fallback'
    end
    -- Resolve a trusted source before making a legacy root required. Otherwise
    -- its own source check would refuse the binding it is trying to create.
    local problem
    root_source,problem=inspect_source(memory,session.user_id,session.node_id,'')
    if not root_source then return nil,problem end
    if tostring(root_source.status or '')~='' then
      return nil,'workspace_source_dirty: root allocation refused before requiring an unbound session'
    end
    root_source.fallback='explicit owned root bootstrap'
    local saved=memory.transaction(function()
      local latest=memory.session_workspace(session_id)
      if not latest or latest.state~=current.state or latest.worktree~=current.worktree
          or latest.source_path~=current.source_path or latest.base_commit~=current.base_commit then
        return {error='workspace_root_recovery_changed: binding changed during source inspection; reconcile before retry'}
      end
      latest.source_path=root_source.path
      latest.base_commit=root_source.head
      latest.required,latest.state=true,'pending'
      latest.start_state={source_root=root_source.root,source_path=root_source.path,
        source_origin=root_source.origin,source_requested='',source_fallback=root_source.fallback,
        base_commit=root_source.head,source_dirty=false,uncommitted_policy='refuse',inspected_at=host.now()}
      return {workspace=memory.set_session_workspace(session_id,latest)}
    end)
    if saved.error then return nil,saved.error end
  end
  local workspace = memory.require_session_workspace(session_id)
  if not workspace then return nil, "workspace_requirement_failed" end
  if workspace.state=="released" or workspace.state=="releasing" or workspace.state=="release_unknown" or workspace.state=="parked" or workspace.state=="parking" or workspace.state=="park_unknown" then
    return nil,"workspace_released_or_release_unresolved"
  end
  if workspace.state == "allocated" then
    local admitted,why=wave_admission(workspace.start_state.source_root,'produce')
    if not admitted then return nil,'workspace_wave_admission_refused:'..tostring(why) end
    local valid, err = verify_binding(memory, session_id, workspace)
    if valid then return workspace end
    mark(memory, session_id, workspace, "failed", err)
    return nil, err
  end
  if workspace.state == "allocating" or workspace.state == "unknown" then
    return reconcile(memory, session_id, workspace)
  end

  -- From here on every refusal is recorded on the child's own workspace record: a required
  -- workspace that stays `pending` while the reason sits in a return value nobody persisted is
  -- exactly the state a retrying dispatcher reads as "not finished yet".
  local inspected, inspection_error = root_source,nil
  if not inspected then inspected,inspection_error=inspect_source(memory, session.user_id, session.node_id, source_session_id) end
  if not inspected then
    mark(memory, session_id, workspace, "failed", inspection_error)
    return nil, inspection_error
  end
  local root = inspected.root
  -- New allocations participate in the same shared-repository wave admission
  -- used by producer/merge public entrypoints. No arbitrary alternate store.
  local admitted,admission_why=wave_admission(root,'allocate')
  if not admitted then
    local why='workspace_wave_admission_refused:'..tostring(admission_why)
    mark(memory,session_id,workspace,'failed',why)
    return nil,why
  end
  local dirty = tostring(inspected.status or "")
  local start_state = {
    executor=json.decode(host.operation('identity','{}')),
    source_root = root, source_path = inspected.path,
    -- Where the tree actually came from, and why anything else was left alone.
    source_origin = inspected.origin, source_requested = inspected.requested,
    source_fallback = inspected.fallback,
    source_branch = inspected.branch, base_commit = inspected.head,
    source_status = dirty:sub(1, 16000), source_status_truncated = #dirty > 16000,
    source_dirty = dirty ~= "", uncommitted_policy = "refuse",
    inspected_at = host.now(),
  }
  workspace.source_path = inspected.path
  workspace.base_commit = start_state.base_commit
  workspace.start_state = start_state
  if dirty ~= "" then
    local why = "workspace_source_dirty: commit or clean the source checkout before allocating; uncommitted changes are not copied"
    mark(memory, session_id, workspace, "failed", why)
    return nil, why, { start_state = start_state }
  end

  local clean_id = tostring(session_id):gsub("[^%w-]", "")
  local branch = "change/wa-session-" .. clean_id
  local destination = paths.data() .. "/wa-worktree-" .. clean_id
  local q_destination, quote_error = quote(destination)
  local q_branch = quote(branch)
  local q_head = quote(start_state.base_commit)
  if not q_destination or not q_branch or not q_head then
    local why = quote_error or "workspace_argument_unsafe"
    mark(memory, session_id, workspace, "failed", why)
    return nil, why
  end
  if directory_exists(destination) then
    local why = "workspace_destination_exists: refusing to reuse an unverified directory"
    workspace.worktree, workspace.branch = destination, branch
    mark(memory, session_id, workspace, "failed", why)
    return nil, why
  end
  workspace.worktree = destination
  workspace.branch = branch
  workspace.state = "allocating"
  workspace.error = ""
  memory.set_session_workspace(session_id, workspace)

  local added, add_error = run("git worktree add -b " .. q_branch .. " " .. q_destination .. " " .. q_head, root)
  if not added then
    -- git may report failure after registering the worktree. Inspect first; a lost receipt
    -- is reconciled from git's own registry and is never an excuse for a duplicate branch.
    workspace = memory.session_workspace(session_id) or workspace
    local recovered, recover_error = reconcile(memory, session_id, workspace)
    if recovered then return recovered end
    return nil, "workspace_allocation_failed: " .. tostring(add_error) .. "; " .. tostring(recover_error)
  end
  workspace = memory.session_workspace(session_id) or workspace
  local verified, verify_error = verify_binding(memory, session_id, workspace)
  if not verified then
    mark(memory, session_id, workspace, "failed", "workspace_verification_failed: " .. tostring(verify_error))
    return nil, "workspace_verification_failed: " .. tostring(verify_error)
  end
  workspace.state = "allocated"
  workspace.error = ""
  return memory.set_session_workspace(session_id, workspace)
end
-- Read-only ownership/action hint for a failed root, including legacy broken
-- records. It does not silently allocate or redirect any execution context.
function M.recovery_hint(memory,session_id)
  local session,workspace=memory.session(session_id),memory.session_workspace(session_id)
  if session and workspace and workspace.required
      and (workspace.state=='unbound' or workspace.state=='pending' or workspace.state=='failed')
      and tostring(workspace.worktree or '')==''
      and tostring(session.parent_session_id or '')=='' and tostring(session.fork_parent_id or '')=='' then
    return {actor='session owner (master)',action='recover',session_id=session_id,
      source='node-owned runtime checkout, inspected read-only',detail=workspace.error,
      effect='allocate an isolated worktree; never write through an unavailable binding'}
  end
  return nil
end

function M.requires_write_tools(allowed)
  for _, name in ipairs(allowed or {}) do
    if name == "write" or name == "edit" or name == "bash" or name == "shell"
        or name == "client" or name == "remote" or name == "operation" or name == "spell_run" then return true end
  end
  return false
end

-- The artifact half of a settlement review: which checkout a finished session worked in, what
-- branch it is on, whether that branch is pushed, how its HEAD stands against `origin/main`, and
-- how many files are modified or untracked. Read-only: it runs git and writes nothing, takes no
-- claim and touches no live node, so it can be assembled the moment a child settles.
--
-- Every value is *measured* or named absent. A probe that could not be read leaves its key out of
-- the table and records itself in `unmeasured` with a reason code, because a zero here would read
-- as "clean and pushed" for a checkout nobody could read - the one mistake this block exists to
-- prevent. `managed=false` is the honest answer for a session that owns no worktree (nothing was
-- changed in a checkout of ours), not "dirty=0".
function M.review_facts(memory, session_id)
  if not memory or session_id == nil or session_id == "" then return nil, "session_required" end
  local workspace = memory.session_workspace(session_id)
  if not workspace then return nil, "workspace_record_unavailable" end
  if tostring(workspace.worktree or "") == "" then
    return { managed = false, state = tostring(workspace.state or "unbound") }
  end
  local destination, quote_error = quote(workspace.worktree)
  if not destination then return nil, quote_error end
  local facts = { managed = true, state = tostring(workspace.state or ""),
    worktree = workspace.worktree, recorded_branch = tostring(workspace.branch or "") }
  local unmeasured = {}
  local function absent(key, reason)
    unmeasured[#unmeasured + 1] = key .. ":" .. tostring(reason)
  end
  local function exec_git(args)
    local result = run("git -C " .. destination .. " " .. args, "")
    if not result then return false, nil end
    return tonumber(result.code) == 0, trimmed(result.stdout)
  end
  -- `--verify --quiet` exits non-zero for an absent ref, which is an answer, not a failure: the
  -- caller reads the boolean and decides. Anything else that fails is named in `unmeasured`.
  local function probe(key, args)
    local ok, value = exec_git(args)
    if not ok or value == "" then absent(key, "not_reported_by_git"); return nil end
    facts[key] = value
    return value
  end

  local branch = probe("branch", "rev-parse --abbrev-ref HEAD")
  probe("head", "rev-parse HEAD")
  -- Both counts are taken against `origin/main` as the branch was fetched, and a repository
  -- without that ref (no remote, never fetched) says so instead of reporting a confident 0.
  if probe("origin_main", "rev-parse --verify --quiet refs/remotes/origin/main") then
    local ok, ahead = exec_git("rev-list --count origin/main..HEAD")
    if ok and ahead ~= "" then facts.ahead = tonumber(ahead) else absent("ahead", "not_reported_by_git") end
    local behind_ok, behind = exec_git("rev-list --count HEAD..origin/main")
    if behind_ok and behind ~= "" then facts.behind = tonumber(behind) else absent("behind", "not_reported_by_git") end
  end
  -- "Pushed" is the question a coordinator actually asks: is the ref this branch would push to
  -- present on the remote, and does it already contain HEAD? An absent remote ref is a definite
  -- `false` (the branch has never been published), not an unmeasured value.
  if branch and branch ~= "HEAD" then
    local ref, ref_error = quote("refs/remotes/origin/" .. branch)
    if not ref then
      absent("pushed", ref_error)
    else
      local exists = exec_git("rev-parse --verify --quiet " .. ref)
      if exists then
        local contained = exec_git("merge-base --is-ancestor HEAD " .. ref)
        if contained then facts.pushed = true
        else absent("pushed", "remote_containment_unreadable") end
      else
        facts.pushed = false
        facts.pushed_remote = "origin/" .. branch .. " absent"
      end
    end
  else
    absent("pushed", branch and "detached_head" or "branch_unknown")
  end
  -- One `status` read gives both counts, because the two are one measurement of the tree.
  local status_ok, porcelain = exec_git("status --porcelain --untracked-files=all")
  if status_ok then
    local dirty, untracked = 0, 0
    for line in tostring(porcelain or ""):gmatch("[^\r\n]+") do
      if line:sub(1, 2) == "??" then untracked = untracked + 1 else dirty = dirty + 1 end
    end
    facts.dirty, facts.untracked = dirty, untracked
  else
    absent("dirty", "not_reported_by_git")
    absent("untracked", "not_reported_by_git")
  end
  if #unmeasured > 0 then facts.unmeasured = unmeasured end
  return facts
end

local function normalized(path)
  local value=tostring(path or ''):gsub('\\','/'):gsub('/$','')
  if platform.os()=='windows' then value=value:lower() end
  return value
end

-- Release is explicit, fenced against participating runs, and never forced.
-- The branch and transcript survive. Unknown process effects block cleanup.
function M.release(memory,id,user_id,expected_head)
  local session=memory.session(id)
  if not session then return nil,'unknown_session' end
  if session.user_id~=user_id then return nil,'forbidden' end
  local workspace=memory.session_workspace(id)
  if not workspace or not workspace.required then return nil,'workspace_not_managed' end
  if workspace.state=='released' then return workspace end
  if not host.canonical_path then return nil,'workspace_canonical_path_unavailable' end
  local ctx={user_id=user_id,session_id=id..':release',run_id=host.uuid()}
  local claimed=resources.claim(ctx,{'session:'..id})
  if not claimed.ok then return nil,claimed.error,claimed end
  local function release_body()
    local clean_id=tostring(id):gsub('[^%w-]','')
    local expected=paths.data()..'/wa-worktree-'..clean_id
    local branch_name=workspace.branch~='' and workspace.branch or workspace.start_state.parked_branch
    if clean_id=='' or normalized(workspace.worktree)~=normalized(expected)
        or branch_name~='change/wa-session-'..clean_id then
      return nil,'workspace_release_binding_mismatch'
    end
    local source=workspace.start_state.source_root
    if not source or source=='' then return nil,'workspace_release_source_missing' end
    local listing,list_error=run('git worktree list --porcelain',source)
    if not listing or listing.code~=0 then return nil,'workspace_release_registry_unavailable: '..tostring(list_error) end
    local registered=false
    for path in tostring(listing.stdout):gmatch('worktree ([^\r\n]+)') do
      if normalized(path)==normalized(expected) then registered=true end
    end
    local canonical=host.canonical_path(expected)
    if not canonical and not registered and (workspace.state=='releasing' or workspace.state=='release_unknown') then
      -- Do not settle missing-tree effects before the operation/ref fences below.
      -- The explicit reconciliation path reacquires this session after our fence
      -- is released and verifies filesystem/registry absence and exact ancestry.
      return nil,'workspace_release_missing_requires_reconciliation'
    end
    local root=host.canonical_path(paths.data())
    if not canonical or not root or normalized(canonical)~=normalized(root..'/wa-worktree-'..clean_id) or not registered then
      return nil,'workspace_release_path_unverified'
    end
    if workspace.state=='parked' then
      local detached=json.decode(host.exec('git symbolic-ref --quiet HEAD',expected,120))
      if tonumber(detached.code)~=1 then return nil,'workspace_park_not_detached_or_unverifiable' end
      expected_head=expected_head or (workspace.start_state.park_reconciliation or {}).head
      if not expected_head then return nil,'workspace_park_head_unverifiable' end
    else
      local verified,why=verify_binding(memory,id,workspace)
      if not verified then return nil,why end
    end
    local status,status_error=run('git status --porcelain --untracked-files=all --ignored',expected)
    if not status or status.code~=0 then return nil,'workspace_release_status_failed: '..tostring(status_error) end
    if tostring(status.stdout or '')~='' then return nil,'workspace_release_dirty_or_ignored_files' end
    local head,head_error=run('git rev-parse HEAD',expected)
    if not head or head.code~=0 then return nil,'workspace_release_head_failed: '..tostring(head_error) end
    if expected_head and trimmed(head.stdout)~=expected_head then return nil,'workspace_release_expected_head_moved' end
    if trimmed(head.stdout)~=workspace.base_commit then
      local merged=run('git merge-base --is-ancestor HEAD refs/remotes/origin/main',expected)
      if not merged or merged.code~=0 then return nil,'workspace_release_unmerged_commits' end
    end
    -- The supervisor indexes admission before spawn and settlement afterwards.
    -- Only unresolved operations relevant to the actual canonical cwd are read;
    -- unknown legacy attribution remains a blocker, never a cleanup exemption.
    if not host.operation then return nil,'workspace_release_operations_unavailable' end
    local lookup_ok,raw=pcall(host.operation,'relevant',json.encode({cwd=canonical,limit=1}))
    local decoded_ok,operations=pcall(json.decode,raw or '')
    if not lookup_ok or not decoded_ok or type(operations)~='table' or operations.ok~=true then
      return nil,'workspace_release_operations_unavailable:'..tostring(type(operations)=='table' and operations.error or raw)
    end
    if type(operations.operations)~='table' then return nil,'workspace_release_operations_unavailable' end
    if #operations.operations>0 then
      return nil,'workspace_release_operation_unresolved:'..tostring(operations.operations[1].operation_id)
    end
    if operations.truncated then return nil,'workspace_release_operations_incomplete' end
    workspace.start_state.release_head=trimmed(head.stdout)
    workspace.state,workspace.error='releasing',''
    memory.set_session_workspace(id,workspace)
    local removed,remove_error=run('git worktree remove '..assert(quote(expected)),source)
    if not removed or removed.code~=0 then
      workspace.state,workspace.error='release_unknown',tostring(remove_error)
      memory.set_session_workspace(id,workspace)
      return nil,'workspace_release_failed: '..tostring(remove_error)
    end
    workspace.state,workspace.error='released',''
    return memory.set_session_workspace(id,workspace)
  end
  local ok,result,why,detail=pcall(release_body)
  local released=resources.finish(ctx)
  if not released.ok then return nil,'workspace_release_claim_failed',released end
  if not ok then return nil,'workspace_release_exception: '..tostring(result) end
  if why=='workspace_release_missing_requires_reconciliation' then
    return M.reconcile_release(memory,id,user_id,'Release receipt recovery: filesystem and Git registration were absent; rechecking all fences')
  end
  return result,why,detail
end

-- A missing directory is an observation, not proof that its operation effects
-- or branch were settled. This explicit path reconciles a lost removal receipt
-- only after the same session fence, operation index and ancestry proof pass.
function M.reconcile_release(memory,id,user_id,evidence)
  if type(evidence)~='string' or evidence:match('^%s*$') then return nil,'workspace_reconcile_evidence_required' end
  local session=memory.session(id)
  if not session then return nil,'unknown_session' end
  if session.user_id~=user_id then return nil,'forbidden' end
  local workspace=memory.session_workspace(id)
  if not workspace or not workspace.required then return nil,'workspace_not_managed' end
  if workspace.state=='released' then return workspace end
  local clean_id=tostring(id):gsub('[^%w-]','')
  local expected=paths.data()..'/wa-worktree-'..clean_id
  local branch_name=workspace.branch~='' and workspace.branch or workspace.start_state.parked_branch
  if clean_id=='' or normalized(workspace.worktree)~=normalized(expected) or branch_name~='change/wa-session-'..clean_id then
    return nil,'workspace_release_binding_mismatch'
  end
  local ctx={user_id=user_id,session_id=id..':reconcile-release',run_id=host.uuid()}
  local claimed=resources.claim(ctx,{'session:'..id})
  if not claimed.ok then return nil,claimed.error,claimed end
  local function body()
    if not host.canonical_path or host.canonical_path(expected) then return nil,'workspace_reconcile_tree_present_or_unverifiable' end
    local parent=json.decode(host.list_dir(paths.data()))
    if type(parent)~='table' or parent.error or type(parent.entries)~='table' then return nil,'workspace_reconcile_parent_unverifiable' end
    for _,entry in ipairs(parent.entries) do
      if entry.name=='wa-worktree-'..clean_id then return nil,'workspace_reconcile_tree_present_or_unverifiable' end
    end
    local source=workspace.start_state.source_root
    if not source or source=='' then return nil,'workspace_release_source_missing' end
    local listing,why=run('git worktree list --porcelain',source)
    if not listing then return nil,'workspace_release_registry_unavailable:'..tostring(why) end
    for path in tostring(listing.stdout):gmatch('worktree ([^\r\n]+)') do
      if normalized(path)==normalized(expected) then return nil,'workspace_reconcile_still_registered' end
    end
    local branch=run('git show-ref --verify --hash '..assert(quote('refs/heads/'..branch_name)),source)
    if branch then
      local merged=run('git merge-base --is-ancestor '..assert(quote(trimmed(branch.stdout)))..' refs/remotes/origin/main',source)
      if not merged then return nil,'workspace_release_unmerged_commits' end
    else
      -- Only Git's exact missing-ref exit code is absence; storage/ref failures
      -- must not be mistaken for a branch that has safely disappeared.
      local probe=host.exec('git show-ref --verify --quiet '..assert(quote('refs/heads/'..branch_name)),source,120)
      local state=json.decode(probe)
      if tonumber(state.code)~=1 then return nil,'workspace_reconcile_ref_unverifiable' end
      local pinned=workspace.start_state.release_head or (workspace.start_state.park_reconciliation or {}).head
      if not pinned then return nil,'workspace_reconcile_missing_ref_without_pinned_tip' end
      if not run('git merge-base --is-ancestor '..assert(quote(pinned))..' refs/remotes/origin/main',source) then return nil,'workspace_release_unmerged_commits' end
    end
    local lookup=json.decode(host.operation('relevant',json.encode({cwd=expected,limit=1})))
    if type(lookup)~='table' or lookup.ok~=true or type(lookup.operations)~='table' then return nil,'workspace_release_operations_unavailable' end
    if #lookup.operations>0 then return nil,'workspace_release_operation_unresolved:'..tostring(lookup.operations[1].operation_id) end
    if lookup.truncated then return nil,'workspace_release_operations_incomplete' end
    workspace.state,workspace.error='released',''
    workspace.start_state.release_reconciliation={evidence=evidence,at=host.now(),executor=host.runtime_info and host.runtime_info() or {}}
    return memory.set_session_workspace(id,workspace)
  end
  local ok,result,why=pcall(body)
  local finished=resources.finish(ctx)
  if not finished.ok then return nil,'workspace_release_claim_failed',finished end
  if not ok then return nil,'workspace_release_exception:'..tostring(result) end
  return result,why
end

function M.reconcile_park(memory,id,user_id,expected_head,evidence,perform_detach)
  if type(evidence)~='string' or evidence:match('^%s*$') or type(expected_head)~='string' or not expected_head:match('^%x+$') then
    return nil,'workspace_park_exact_head_and_evidence_required'
  end
  local session=memory.session(id)
  if not session then return nil,'unknown_session' end
  if session.user_id~=user_id then return nil,'forbidden' end
  local workspace=memory.session_workspace(id)
  if not workspace or not workspace.required then return nil,'workspace_not_managed' end
  local clean_id=tostring(id):gsub('[^%w-]','')
  local expected=paths.data()..'/wa-worktree-'..clean_id
  if clean_id=='' or normalized(workspace.worktree)~=normalized(expected) then return nil,'workspace_release_binding_mismatch' end
  if workspace.state~='parked' and workspace.branch~='change/wa-session-'..clean_id then return nil,'workspace_release_binding_mismatch' end
  local ctx={user_id=user_id,session_id=id..':reconcile-park',run_id=host.uuid()}
  local claimed=resources.claim(ctx,{'session:'..id})
  if not claimed.ok then return nil,claimed.error,claimed end
  local function body()
    local canonical=host.canonical_path and host.canonical_path(expected)
    local root=host.canonical_path and host.canonical_path(paths.data())
    if not canonical or not root or normalized(canonical)~=normalized(root..'/wa-worktree-'..clean_id) then return nil,'workspace_release_path_unverified' end
    local status=run('git status --porcelain --untracked-files=all --ignored',expected)
    if not status or tostring(status.stdout or '')~='' then return nil,'workspace_release_dirty_or_ignored_files' end
    local head=run('git rev-parse HEAD',expected)
    if not head or trimmed(head.stdout)~=expected_head then return nil,'workspace_park_head_moved' end
    if perform_detach then
      local valid,why=verify_binding(memory,id,workspace)
      if not valid then return nil,why end
      if not run('git merge-base --is-ancestor '..assert(quote(expected_head))..' refs/remotes/origin/main',expected) then return nil,'workspace_release_unmerged_commits' end
      local active=json.decode(host.operation('relevant',json.encode({cwd=canonical,limit=1})))
      if type(active)~='table' or active.ok~=true or type(active.operations)~='table' or active.truncated then return nil,'workspace_release_operations_unavailable' end
      if #active.operations>0 then return nil,'workspace_release_operation_unresolved:'..tostring(active.operations[1].operation_id) end
      workspace.state='parking';memory.set_session_workspace(id,workspace)
      if not run('git switch --detach '..assert(quote(expected_head)),expected) then
        workspace.state,workspace.error='park_unknown','detach outcome requires reconciliation';memory.set_session_workspace(id,workspace)
        resources.uncertain(ctx)
        return nil,'workspace_park_effect_unknown'
      end
    end
    local detached=json.decode(host.exec('git symbolic-ref --quiet HEAD',expected,120))
    if tonumber(detached.code)~=1 then return nil,'workspace_park_not_detached_or_unverifiable' end
    head=run('git rev-parse HEAD',expected)
    if not head or trimmed(head.stdout)~=expected_head then return nil,'workspace_park_head_moved' end
    local merged=run('git merge-base --is-ancestor '..assert(quote(expected_head))..' refs/remotes/origin/main',expected)
    if not merged then return nil,'workspace_release_unmerged_commits' end
    local lookup=json.decode(host.operation('relevant',json.encode({cwd=canonical,limit=1})))
    if type(lookup)~='table' or lookup.ok~=true or type(lookup.operations)~='table' then return nil,'workspace_release_operations_unavailable' end
    if #lookup.operations>0 then return nil,'workspace_release_operation_unresolved:'..tostring(lookup.operations[1].operation_id) end
    if lookup.truncated then return nil,'workspace_release_operations_incomplete' end
    workspace.start_state.parked_branch=workspace.start_state.parked_branch or workspace.branch
    workspace.start_state.park_reconciliation={evidence=evidence,head=expected_head,at=host.now(),executor=host.runtime_info and host.runtime_info() or {}}
    workspace.state,workspace.branch,workspace.error='parked','',''
    return memory.set_session_workspace(id,workspace)
  end
  local ok,result,why=pcall(body)
  local finished=resources.finish(ctx)
  if not finished.ok then return nil,'workspace_release_claim_failed',finished end
  if not ok then return nil,'workspace_release_exception:'..tostring(result) end
  return result,why
end

return M
