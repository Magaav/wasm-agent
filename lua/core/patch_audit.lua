-- Patch impact audit. This is a review-lead generator, never a correctness gate.
local json = dofile("lua/vendor/json.lua")
local changeset = dofile("lua/core/changeset.lua")
local telemetry = dofile("lua/core/telemetry.lua")
local redact = dofile("lua/core/redact.lua")
local M = {}
-- Phase 4 adds bounded orientation, patch reachability, and visible resolution
-- provenance. Earlier phases remain frozen so telemetry cannot blur contracts.
M.PHASE = "phase_4"
M.LEGACY_PHASE = "phase_1"

local function failure(context, source, reason)
  if context then telemetry.event(context.session_id,context.run_id,"",
    "graph_patch_audit","end",{ok=false,source=source,error=reason,ms=0,
      trial_phase=M.PHASE}) end
  return {error=reason,source=source,worthy="unproven"}
end

function M.enabled()
  return host.getenv and host.getenv("WA_GRAPH_PATCH_AUDIT") == "1"
end

-- One root for the patch and index. A missing required binding must not silently
-- audit canonical/runtime source. Explicit cwd is read-only scope, not a write grant.
function M.workspace_root(memory, context, cwd)
  local binding
  if memory and context and context.session_id then
    if memory.session_workspace then
      local ok, workspace=pcall(memory.session_workspace,context.session_id)
      if not ok then return nil,"graph_workspace_lookup_failed" end
      if workspace and workspace.required and (workspace.state~="allocated"
          or not workspace.worktree or workspace.worktree=="") then
        return nil,"session_workspace_unavailable"
      end
      binding=workspace and workspace.worktree
    elseif memory.session_worktree then
      local ok, worktree=pcall(memory.session_worktree,context.session_id)
      if not ok then return nil,"graph_workspace_lookup_failed" end
      binding=worktree
    end
  end
  local root=type(cwd)=="string" and cwd~="" and cwd or binding
  if not root or root=="" then return nil end -- legacy unbound runtime default
  if type(root)~="string" then return nil,"graph_workspace_invalid" end
  local normalized=root:gsub("\\", "/")
  if normalized:sub(1,1)~="/" and not normalized:match("^%a:/") and binding and binding~="" then
    root=binding:gsub("[/\\]+$","").."/"..root
  end
  if not host.canonical_path then return nil,"graph_root_resolution_unavailable" end
  local real=host.canonical_path(root)
  if not real then return nil,"graph_root_unavailable:"..root end
  return real
end

local function run_request(request, reviewed, context, source)
  if context and not request.root then
    local root,err=M.workspace_root(dofile("lua/core/memory.lua"),context,context.root)
    if err then return failure(context,source,err) end
    request.root=root
  end
  if not host.graph_patch_audit then return failure(context,source,"graph_patch_audit_unavailable") end
  request.reviewed={}
  for path, seen in pairs(reviewed or {}) do
    if seen then request.reviewed[#request.reviewed + 1] = path end
  end
  table.sort(request.reviewed)
  local span = context and telemetry.start(context, "graph_patch_audit", {
    changed_files=#request.changes, reviewed_files=#request.reviewed, source=source,
    trial_phase=M.PHASE})
  local ok, raw = pcall(host.graph_patch_audit, json.encode(request))
  local result
  if not ok then result={error=tostring(raw)}
  else
    local decoded_ok, decoded = pcall(json.decode, raw or "")
    result=decoded_ok and type(decoded)=="table" and decoded or {error="graph_patch_audit_decode_failed"}
  end
  -- `worthy` is intentionally not inferred from a lead count. A useful lead must be
  -- confirmed by a subsequent inspection and a real patch/test outcome.
  result.worthy="unproven"
  result.source=source
  if span then telemetry.finish(span, {ok=not result.error, verdict=result.verdict,
    lead_count=result.lead_count or 0, mapped_lines=result.mapped_lines or 0,
    ignored_lines=result.ignored_lines or 0,
    changed_lines=result.changed_lines or 0, gap_count=result.gap_count or #(result.gaps or {}),
    db_bytes=result.db_bytes, source=source, trial_phase=M.PHASE,
    error=result.error}) end
  return result
end

function M.run(changes, reviewed, context)
  local request, err=M.native_changes(changes)
  if not request then return {error=err} end
  request.root=context and context.root
  return run_request(request,reviewed,context,"native_changeset")
end

function M.native_changes(changes)
  if changeset.empty(changes) then return nil,"no_recorded_patch" end
  local request={changes={}}
  for _, file in ipairs(changes.files) do
    local lines, reason = changeset.changed_lines(file)
    request.changes[#request.changes + 1] = {path=file.path, lines=lines, gap=reason}
  end
  return request
end

local function git(command, cwd)
  if not host.exec then return nil,"git_diff_unavailable" end
  local ok, raw=pcall(host.exec,command,cwd or "",30)
  if not ok then return nil,tostring(raw) end
  local decoded_ok, result=pcall(json.decode,raw or "")
  if not decoded_ok or type(result)~="table" then return nil,"git_diff_decode_failed" end
  if result.error or tonumber(result.code)~=0 then
    return nil,"git_diff_failed:"..tostring(result.error or result.stderr or result.code):sub(1,200)
  end
  -- exec previews can be a truncated TAIL, containing no diff headers at all.
  -- Consume the retained original, never interpret a preview as a complete patch.
  if result.output_complete==false or result.output_streams_closed==false then
    return nil,"git_output_not_complete:"..tostring(result.operation_id)
  end
  local output=result.stdout
  if result.stdout_path and host.read_file then
    output=host.read_file(result.stdout_path)
    if output==nil then return nil,"git_output_non_utf8_or_unreadable:"..tostring(result.operation_id) end
  elseif result.output_truncated or result.stdout_truncated then
    return nil,"git_output_incomplete:"..tostring(result.operation_id)
  end
  if type(output)~="string" then return nil,"git_output_missing" end
  if #output>16*1024*1024 then return nil,"git_output_too_large" end
  return output
end

-- Separate HEAD->index and index->worktree; a net HEAD diff loses cancelled index edits.
-- All commands are read-only. Paths come from NUL manifests, never diff header guesses.
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
local function source_for(root,path)
  local full=root.."/"..path
  local canonical=host.canonical_path and host.canonical_path(full)
  local normalize=function(p) p=p:gsub('\\','/');if p:match('^//%?/[%a]:/') or p:match('^[%a]:/') then p=p:lower() end;return p end
  if canonical and normalize(canonical)~=normalize(full) then return nil,"symlink_or_redirected_source" end
  return host.read_file and host.read_file(full)
end
function M.git_changes(cwd)
  local top,err=git("git rev-parse --show-toplevel",cwd)
  if not top then return nil,err end
  top=top:gsub("[\r\n]+$","")
  if top=="" or top:find("[\r\n]") then return nil,"git_root_invalid" end
  if not host.canonical_path then return nil,"graph_root_resolution_unavailable" end
  cwd=host.canonical_path(top)
  if not cwd then return nil,"git_root_unavailable" end
  local base="git -c core.quotePath=false -c diff.external= diff --no-ext-diff --no-textconv --no-color "
  local index_identity,identity_err=git(base.."--cached --raw --abbrev=40 -z --no-renames --",cwd)
  if not index_identity then return nil,identity_err end
  local staged,e=git(base.."--cached --name-status -z --find-renames --",cwd)
  if not staged then return nil,e end
  local unstaged,u=git(base.."--name-status -z --find-renames --",cwd)
  if not unstaged then return nil,u end
  local untracked,v=git("git ls-files --others --exclude-standard -z --",cwd)
  if not untracked then return nil,v end
  local fingerprint={cwd,staged,unstaged,untracked}
  local changes={}
  local function capture(manifest,stage,flags)
    local tokens={};for s in manifest:gmatch("([^%z]+)%z") do tokens[#tokens+1]=s end
    local i=1
    while i<=#tokens do
      local status=tokens[i];local path=tokens[i+1];i=i+2
      if not path then return nil,"git_status_unparsed" end
      local old
      if status:sub(1,1)=="R" or status:sub(1,1)=="C" then old=path;path=tokens[i];i=i+1 end
      if not path then return nil,"git_rename_unparsed" end
      local diff,de=git(base..flags.." --no-renames --unified=0 -- "..quote(path),cwd)
      if not diff then return nil,de end
      fingerprint[#fingerprint+1]=diff
      local change={path=path,stage=stage,status=status,old_path=old,lines={},added_lines=0,removed_lines=0,removed_only_lines=0}
      local marked={}
      for line in diff:gmatch("[^\n]+") do
        if line:sub(1,2)=="@@" then
          local os,oc,ns,nc=line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
          if not ns then return nil,"git_diff_unparsed_hunk" end
          oc,nc=tonumber(oc) or 1,tonumber(nc) or 1;ns=tonumber(ns)
          change.added_lines=change.added_lines+nc;change.removed_lines=change.removed_lines+oc
          if nc==0 then change.removed_only_lines=change.removed_only_lines+oc
          elseif nc>4096 then change.gap="large_patch" else
            for n=ns,ns+nc-1 do marked[n]=true end
          end
        end
      end
      for n in pairs(marked) do change.lines[#change.lines+1]=n end
      table.sort(change.lines)
      change.changed_line_count=#change.lines+change.removed_only_lines
      if change.gap=="large_patch" then change.changed_line_count=change.added_lines end
      if diff:find("Binary files",1,true) or diff:find("GIT binary patch",1,true) then change.gap="binary_file" end
      if status=="D" then change.gap="deleted_file";change.changed_line_count=change.removed_lines end
      if #change.lines==0 and not change.gap then change.gap=change.removed_only_lines>0 and "deleted_lines_without_current_source" or "metadata_only_change" end
      if old then change.rename_source_coverage="old_path_not_mapped" end
      local source,source_gap=source_for(cwd,path)
      if source_gap then change.gap=source_gap end
      change.source_version=source and host.sha256(source) or nil
      if stage=="index" and status~="D" and not change.gap then
        local index,ie=git("git show "..quote(":"..path),cwd)
        if not index then return nil,ie end
        change.index_source_version=host.sha256(index)
        if not source or index~=source then change.gap="index_source_differs_from_worktree" end
      end
      changes[#changes+1]=change
      if #changes>16384 then return nil,"too_many_git_changes" end
    end
    return true
  end
  local ok,ce=capture(staged,"index","--cached");if not ok then return nil,ce end
  ok,ce=capture(unstaged,"worktree","");if not ok then return nil,ce end
  for path in untracked:gmatch("([^%z]+)%z") do
    local source,source_gap=source_for(cwd,path)
    local change={path=path,stage="untracked",status="?",lines={}}
    if source then
      if source:find("\0",1,true) then change.gap="binary_file" end
      local count=1;for _ in source:gmatch("\n") do count=count+1 end
      change.changed_line_count=count;change.source_version=host.sha256(source)
      if count>4096 then change.gap="large_patch" else for n=1,count do change.lines[#change.lines+1]=n end end
    else change.gap=source_gap or "untracked_non_utf8_or_unreadable" end
    changes[#changes+1]=change
    fingerprint[#fingerprint+1]=path..":"..tostring(change.source_version)
  end
  local index_after,after_err=git(base.."--cached --raw --abbrev=40 -z --no-renames --",cwd)
  if not index_after then return nil,after_err end
  if index_after~=index_identity then return nil,"git_index_changed_during_capture" end
  fingerprint[#fingerprint+1]=index_identity
  table.sort(changes,function(a,b) return a.path==b.path and a.stage<b.stage or a.path<b.path end)
  return {root=cwd,changes=changes,fingerprint=host.sha256(table.concat(fingerprint,"\0"))}
end

function M.git_audit(cwd, reviewed, context)
  local root,root_err=M.workspace_root(dofile("lua/core/memory.lua"),context,cwd)
  if root_err then return failure(context,"git_worktree",root_err) end
  local patch, err=M.git_changes(root)
  if not patch then return failure(context,"git_worktree",err) end
  if #patch.changes==0 then return {verdict="no_patch",lead_count=0,source="git_worktree",worthy="unproven"} end
  local report=run_request({root=patch.root,changes=patch.changes},reviewed,context,"git_worktree")
  report.patch_fingerprint=patch.fingerprint
  report.patch_source="git_worktree_not_run_attributed"
  return report
end

-- A model's qualitative assessment is useful trial evidence, but cannot certify a catch.
-- It belongs to the active audit step and is recorded once, separately from operator feedback.
function M.assess(args, context)
  local step=context and context.audit_step
  if not step or not step.id then return {error="no_active_audit_step"} end
  if step.assessed then return {error="audit_step_already_assessed"} end
  args=args or {}
  local grade=args.grade
  if type(grade)~="number" or grade%1~=0 or grade<0 or grade>3 then
    return {error="invalid_usefulness_grade"}
  end
  for _, key in ipairs({"reason","critique"}) do
    local value=args[key]
    if type(value)~="string" or #value<10 or #value>600 then
      return {error="invalid_audit_"..key}
    end
  end
  if args.evidence~=nil and (type(args.evidence)~="string" or #args.evidence>240) then
    return {error="invalid_audit_evidence"}
  end
  telemetry.event(context.session_id,context.run_id,"","graph_patch_assessment","end",{
    step_id=step.id,grade=grade,reason=redact.text(args.reason),
    critique=redact.text(args.critique),evidence=redact.text(args.evidence or ""),
    source=step.source,lead_count=step.lead_count,self_report=true,trial_phase=M.PHASE})
  step.assessed=true
  step.grade=grade
  return {recorded=true,grade=grade,self_report=true,worthy="unproven"}
end

-- The trial report is bounded by a time window, not by a background timer. Forty-eight hours
-- starts when the enabled node first writes an audit event; no event means no trial evidence.
function M.report(hours)
  hours=math.max(1, math.min(720, tonumber(hours) or 48))
  telemetry.setup()
  local raw=host.sql_query(
    "SELECT session_id,run_id,at,kind,payload FROM harness_events WHERE kind IN ('graph_patch_audit','graph_patch_value','graph_patch_feedback','graph_patch_assessment','graph_patch_step') AND phase='end' AND at>=? ORDER BY seq",
    json.encode({host.now()-hours*3600}))
  local rows=type(raw)=="string" and json.decode(raw) or raw
  if type(rows)~="table" or rows.error then return {error=rows and rows.error or "audit_report_failed"} end
  local first_raw=host.sql_query(
    "SELECT at,payload FROM harness_events WHERE kind='graph_patch_audit' AND phase='end' ORDER BY at",
    "[]")
  local first_rows=type(first_raw)=="string" and json.decode(first_raw) or first_raw
  if type(first_rows)~="table" or first_rows.error then
    return {error=first_rows and first_rows.error or "audit_start_lookup_failed"}
  end
  local first_at=first_rows[1] and tonumber(first_rows[1].at)
  local phase_starts={}
  for _, row in ipairs(first_rows) do
    local payload=json.decode(row.payload or "{}")
    local name=type(payload.trial_phase)=="string" and payload.trial_phase or M.LEGACY_PHASE
    local at=tonumber(row.at)
    if at and (not phase_starts[name] or at<phase_starts[name]) then phase_starts[name]=at end
  end
  local report={hours=hours, audits=0, errors=0, leads=0, lead_runs=0, gaps=0,
    mapped_lines=0, ignored_lines=0, changed_lines=0, audit_ms=0, continuation_ms=0,
    continuation_tokens=0, lead_reviewed=0, patch_changed_after_lead=0,
    continuation_usage_unknown=0, max_db_bytes=0,
    no_native_followup_observed=0, confirmed_catches=0, false_positives=0,
    sources={native_changeset=0,git_worktree=0},
    self_assessment={steps=0,recorded=0,missing=0,grades={["0"]=0,["1"]=0,["2"]=0,["3"]=0},examples={}},
    worthy="unproven", examples={}, trial_started_at=first_at,
    trial_elapsed_hours=first_at and math.max(0,(host.now()-first_at)/3600) or nil,
    current_phase=M.PHASE, phases={}, ready_for_review=false}
  local function phase_summary()
    return {audits=0,errors=0,leads=0,lead_runs=0,gaps=0,mapped_lines=0,
      ignored_lines=0,changed_lines=0,audit_ms=0,continuation_ms=0,
      continuation_tokens=0,continuation_usage_unknown=0,lead_reviewed=0,
      patch_changed_after_lead=0,no_native_followup_observed=0,
      confirmed_catches=0,false_positives=0,max_db_bytes=0,
      sources={native_changeset=0,git_worktree=0},
      self_assessment={steps=0,recorded=0,missing=0,
        grades={["0"]=0,["1"]=0,["2"]=0,["3"]=0}},worthy="unproven"}
  end
  report.phases[M.LEGACY_PHASE]=phase_summary()
  report.phases[M.PHASE]=phase_summary()
  for name, at in pairs(phase_starts) do
    if not report.phases[name] then report.phases[name]=phase_summary() end
    report.phases[name].started_at=at
  end
  local function phase_for(payload)
    local name=type(payload.trial_phase)=="string" and payload.trial_phase or M.LEGACY_PHASE
    if not report.phases[name] then report.phases[name]=phase_summary() end
    return report.phases[name],name
  end
  local feedback={}
  for _, row in ipairs(rows) do
    local payload=json.decode(row.payload or "{}")
    local phase,phase_name=phase_for(payload)
    if row.kind=="graph_patch_feedback" then
      feedback[row.run_id]={outcome=payload.outcome,phase=phase_name}
    elseif row.kind=="graph_patch_assessment" then
      local assessment=report.self_assessment
      assessment.recorded=assessment.recorded+1
      phase.self_assessment.recorded=phase.self_assessment.recorded+1
      local grade=tostring(payload.grade)
      if assessment.grades[grade]~=nil then assessment.grades[grade]=assessment.grades[grade]+1 end
      if phase.self_assessment.grades[grade]~=nil then
        phase.self_assessment.grades[grade]=phase.self_assessment.grades[grade]+1
      end
      if #assessment.examples<20 then assessment.examples[#assessment.examples+1]={
        session_id=row.session_id,run_id=row.run_id,at=row.at,grade=payload.grade,
        reason=payload.reason,critique=payload.critique,evidence=payload.evidence,
        source=payload.source,self_report=true} end
    elseif row.kind=="graph_patch_step" then
      local assessment=report.self_assessment
      assessment.steps=assessment.steps+1
      phase.self_assessment.steps=phase.self_assessment.steps+1
      if not payload.assessed then
        assessment.missing=assessment.missing+1
        phase.self_assessment.missing=phase.self_assessment.missing+1
      end
    elseif row.kind=="graph_patch_value" then
      report.continuation_ms=report.continuation_ms+(payload.continuation_ms or 0)
      report.continuation_tokens=report.continuation_tokens+(payload.continuation_tokens or 0)
      phase.continuation_ms=phase.continuation_ms+(payload.continuation_ms or 0)
      phase.continuation_tokens=phase.continuation_tokens+(payload.continuation_tokens or 0)
      if payload.continuation_usage_unknown then
        report.continuation_usage_unknown=report.continuation_usage_unknown+1
        phase.continuation_usage_unknown=phase.continuation_usage_unknown+1
      end
      if report[payload.flag]~=nil then report[payload.flag]=report[payload.flag]+1 end
      if phase[payload.flag]~=nil then phase[payload.flag]=phase[payload.flag]+1 end
    else
      report.audits=report.audits+1
      phase.audits=phase.audits+1
      phase.started_at=phase.started_at and math.min(phase.started_at,row.at) or row.at
      if report.sources[payload.source]~=nil then report.sources[payload.source]=report.sources[payload.source]+1 end
      if phase.sources[payload.source]~=nil then phase.sources[payload.source]=phase.sources[payload.source]+1 end
      if payload.ok==false then
        report.errors=report.errors+1
        phase.errors=phase.errors+1
      end
      report.leads=report.leads+(payload.lead_count or 0)
      phase.leads=phase.leads+(payload.lead_count or 0)
      report.gaps=report.gaps+(payload.gap_count or 0)
      phase.gaps=phase.gaps+(payload.gap_count or 0)
      report.mapped_lines=report.mapped_lines+(payload.mapped_lines or 0)
      phase.mapped_lines=phase.mapped_lines+(payload.mapped_lines or 0)
      report.ignored_lines=report.ignored_lines+(payload.ignored_lines or 0)
      phase.ignored_lines=phase.ignored_lines+(payload.ignored_lines or 0)
      report.changed_lines=report.changed_lines+(payload.changed_lines or 0)
      phase.changed_lines=phase.changed_lines+(payload.changed_lines or 0)
      report.audit_ms=report.audit_ms+(payload.ms or 0)
      phase.audit_ms=phase.audit_ms+(payload.ms or 0)
      report.max_db_bytes=math.max(report.max_db_bytes,payload.db_bytes or 0)
      phase.max_db_bytes=math.max(phase.max_db_bytes,payload.db_bytes or 0)
      if (payload.lead_count or 0)>0 then
        report.lead_runs=report.lead_runs+1
        phase.lead_runs=phase.lead_runs+1
        if #report.examples<20 then report.examples[#report.examples+1]={
          session_id=row.session_id,run_id=row.run_id,at=row.at,leads=payload.lead_count} end
      end
    end
  end
  for _, item in pairs(feedback) do
    local phase=report.phases[item.phase]
    if item.outcome=="confirmed_catch" then
      report.confirmed_catches=report.confirmed_catches+1
      phase.confirmed_catches=phase.confirmed_catches+1
    end
    if item.outcome=="false_positive" then
      report.false_positives=report.false_positives+1
      phase.false_positives=phase.false_positives+1
    end
  end
  if report.confirmed_catches>0 then report.worthy="confirmed_catch" end
  for _, phase in pairs(report.phases) do
    if phase.confirmed_catches>0 then phase.worthy="confirmed_catch" end
    phase.elapsed_hours=phase.started_at and math.max(0,(host.now()-phase.started_at)/3600) or nil
  end
  local current=report.phases[M.PHASE]
  report.current_phase_started_at=current.started_at
  report.current_phase_elapsed_hours=current.elapsed_hours
  report.ready_for_review=current.started_at and host.now()-current.started_at>=hours*3600 or false
  return report
end

-- Human-reviewed outcome only. A graph lead, an agent read, or a revised patch is not
-- evidence that the graph prevented a mistake; the operator has to review that run.
function M.feedback(run_id, outcome, commit, context)
  if type(run_id)~="string" or #run_id<1 or #run_id>128 then return {error="invalid_run_id"} end
  if outcome~="confirmed_catch" and outcome~="false_positive" and outcome~="unresolved" then
    return {error="invalid_audit_outcome"}
  end
  if commit~=nil and (type(commit)~="string" or #commit>64) then return {error="invalid_commit"} end
  telemetry.setup()
  local raw=host.sql_query(
    "SELECT payload FROM harness_events WHERE kind='graph_patch_audit' AND phase='end' AND run_id=?",
    json.encode({run_id}))
  local rows=type(raw)=="string" and json.decode(raw) or raw
  if type(rows)~="table" or rows.error then return {error=rows and rows.error or "audit_lookup_failed"} end
  local had_lead=false
  local audit_phase=M.LEGACY_PHASE
  for _, row in ipairs(rows) do
    local payload=json.decode(row.payload or "{}")
    if (payload.lead_count or 0)>0 then
      had_lead=true
      audit_phase=type(payload.trial_phase)=="string" and payload.trial_phase or M.LEGACY_PHASE
      break
    end
  end
  if not had_lead then return {error="run_has_no_graph_lead"} end
  telemetry.event(context and context.session_id or "graph-audit",run_id,"",
    "graph_patch_feedback","end",{outcome=outcome,commit=commit,trial_phase=audit_phase})
  return {ok=true,run_id=run_id,outcome=outcome}
end

return M
