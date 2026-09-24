-- Patch impact audit. This is a review-lead generator, never a correctness gate.
local json = dofile("lua/vendor/json.lua")
local changeset = dofile("lua/core/changeset.lua")
local telemetry = dofile("lua/core/telemetry.lua")
local redact = dofile("lua/core/redact.lua")
local M = {}
-- Phase 3 begins with source-returning symbol retrieval. Phase 2 remains the locator-only
-- baseline, so later reports cannot attribute a saved read to the older graph contract.
M.PHASE = "phase_3"
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

local function run_request(request, reviewed, context, source)
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
  if changeset.empty(changes) then return {error="no_recorded_patch"} end
  local request={changes={}}
  for _, file in ipairs(changes.files) do
    local lines, reason = changeset.changed_lines(file)
    request.changes[#request.changes + 1] = {path=file.path, lines=lines, gap=reason}
  end
  return run_request(request,reviewed,context,"native_changeset")
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
  return tostring(result.stdout or "")
end

-- A shell edit does not enter the reversible changeset. For a pre-commit check, derive
-- current-file line anchors from the actual Git working-tree patch (staged and unstaged).
-- This is workspace evidence, not attribution to one run.
function M.git_changes(cwd)
  local diff, err=git("git -c core.quotePath=false diff HEAD --no-ext-diff --no-renames --unified=0 --no-color --",cwd)
  if not diff then return nil,err end
  local untracked, untracked_err=git("git -c core.quotePath=false ls-files --others --exclude-standard --",cwd)
  if not untracked then return nil,untracked_err end
  local by_path, deleted, path, old_path={}, {}, nil, nil
  for line in diff:gmatch("[^\n]+") do
    line=line:gsub("\r$","")
    if line:sub(1,6)=="--- a/" then
      old_path=line:sub(7)
    elseif line=="+++ /dev/null" and old_path then
      deleted[old_path]=true
      path=nil
    elseif line:sub(1,6)=="+++ b/" then
      path=line:sub(7)
      by_path[path]=by_path[path] or {}
    elseif line:sub(1,2)=="@@" and path then
      local start,count=line:match("^@@ %-[%d,]+ %+(%d+),?(%d*) @@")
      if not start then return nil,"git_diff_unparsed_hunk" end
      start,count=tonumber(start),tonumber(count) or 1
      if count>4096 then return nil,"git_diff_hunk_too_large" end
      local last=count==0 and start or start+count-1
      for n=math.max(1,start),math.max(1,last) do by_path[path][n]=true end
    end
  end
  local code_ext={rs=true,lua=true,js=true,ts=true,tsx=true,jsx=true,
    sh=true,bash=true,ps1=true,psm1=true}
  for item in untracked:gmatch("[^\r\n]+") do
    local ext=item:match("%.([%w]+)$")
    if ext and code_ext[ext:lower()] then
      local full=(cwd and cwd~="") and (cwd.."/"..item) or item
      local source=host.read_file and host.read_file(full)
      if source==nil then return nil,"untracked_file_unreadable:"..item end
      local lines=1
      for _ in source:gmatch("\n") do lines=lines+1 end
      if lines>4096 then return nil,"untracked_file_too_large:"..item end
      by_path[item]=by_path[item] or {}
      for n=1,lines do by_path[item][n]=true end
    end
  end
  local changes={}
  for name, marked in pairs(by_path) do
    local lines={}
    for n in pairs(marked) do lines[#lines+1]=n end
    table.sort(lines)
    changes[#changes+1]={path=name,lines=lines}
  end
  for name in pairs(deleted) do
    changes[#changes+1]={path=name,gap="deleted_file"}
  end
  table.sort(changes,function(a,b) return a.path<b.path end)
  return {changes=changes, fingerprint=host.sha256(diff.."\0"..untracked)}
end

function M.git_audit(cwd, reviewed, context)
  local patch, err=M.git_changes(cwd)
  if not patch then return failure(context,"git_worktree",err) end
  if #patch.changes==0 then return {verdict="no_patch",lead_count=0,source="git_worktree",worthy="unproven"} end
  local report=run_request({changes=patch.changes},reviewed,context,"git_worktree")
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
