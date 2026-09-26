-- Per-session git worktrees for conversations that are independently writable.
-- The allocator records intent before invoking git and never maps a required-but-unbound
-- session back to the node cwd. Shell remains an operator-authorized capability, not a sandbox.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")
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
  if tonumber(result.code) ~= 0 then
    local detail = tostring(result.stderr or result.error or result.stdout or "git command failed")
    return result, "workspace_git_failed: " .. detail:sub(1, 1000)
  end
  return result
end

local function trimmed(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

-- Allocate one linked worktree from the source session's exact clean HEAD. Uncommitted
-- state is recorded and refused (not copied, stashed, or silently ignored). If a process
-- dies during git worktree add, the persisted 'allocating' record is reconciled, never
-- blindly replayed. source_session_id must be owned by the same principal and node.
function M.ensure(memory, session_id, source_session_id)
  local session = memory.session(session_id)
  local source = memory.session(source_session_id)
  if not session or not source then return nil, "workspace_session_not_found" end
  if session.user_id ~= source.user_id or session.node_id ~= source.node_id then
    return nil, "workspace_owner_mismatch"
  end
  local workspace = memory.require_session_workspace(session_id)
  if not workspace then return nil, "workspace_requirement_failed" end
  if workspace.state == "allocated" then
    local valid, err = verify_binding(memory, session_id, workspace)
    if valid then return workspace end
    mark(memory, session_id, workspace, "failed", err)
    return nil, err
  end
  if workspace.state == "allocating" or workspace.state == "unknown" then
    return reconcile(memory, session_id, workspace)
  end

  local source_workspace = memory.session_workspace(source_session_id)
  if source_workspace and source_workspace.required
      and (source_workspace.state ~= "allocated" or source_workspace.worktree == "") then
    local why = "workspace_source_unavailable: source session requires an allocated isolated workspace"
    mark(memory, session_id, workspace, "failed", why)
    return nil, why
  end
  local source_path = memory.session_worktree(source_session_id)
  if source_path == "" then source_path = platform.cwd() end
  local result, err = run("git rev-parse --show-toplevel", source_path)
  if not result then
    mark(memory, session_id, workspace, "failed", "workspace_source_not_git: " .. tostring(err))
    return nil, "workspace_source_not_git: " .. tostring(err)
  end
  local root = trimmed(result.stdout)
  if root == "" then
    mark(memory, session_id, workspace, "failed", "workspace_source_root_missing")
    return nil, "workspace_source_root_missing"
  end
  local head_result, head_error = run("git rev-parse HEAD", source_path)
  local branch_result, branch_error = run("git rev-parse --abbrev-ref HEAD", source_path)
  local status_result, status_error = run("git status --porcelain --untracked-files=all", source_path)
  if not head_result or not branch_result or not status_result then
    local why = "workspace_source_inspection_failed: " .. tostring(head_error or branch_error or status_error)
    mark(memory, session_id, workspace, "failed", why)
    return nil, why
  end
  local dirty = tostring(status_result.stdout or "")
  local start_state = {
    source_root = root, source_path = source_path,
    source_branch = trimmed(branch_result.stdout), base_commit = trimmed(head_result.stdout),
    source_status = dirty:sub(1, 16000), source_status_truncated = #dirty > 16000,
    source_dirty = dirty ~= "", uncommitted_policy = "refuse",
    inspected_at = host.now(),
  }
  workspace.source_path = source_path
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

function M.requires_write_tools(allowed)
  for _, name in ipairs(allowed or {}) do
    if name == "write" or name == "edit" or name == "bash" or name == "shell"
        or name == "client" or name == "remote" or name == "operation" or name == "spell_run" then return true end
  end
  return false
end

return M
