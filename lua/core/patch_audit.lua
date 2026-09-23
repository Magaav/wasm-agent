-- Patch impact audit. This is a review-lead generator, never a correctness gate.
local json = dofile("lua/vendor/json.lua")
local changeset = dofile("lua/core/changeset.lua")
local telemetry = dofile("lua/core/telemetry.lua")
local M = {}

local function failure(context, source, reason)
  if context then telemetry.event(context.session_id,context.run_id,"",
    "graph_patch_audit","end",{ok=false,source=source,error=reason,ms=0}) end
  return {error=reason,worthy="unproven"}
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
    changed_files=#request.changes, reviewed_files=#request.reviewed, source=source})
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
  if span then telemetry.finish(span, {ok=not result.error, verdict=result.verdict,
    lead_count=result.lead_count or 0, mapped_lines=result.mapped_lines or 0,
    changed_lines=result.changed_lines or 0, gap_count=result.gap_count or #(result.gaps or {}),
    db_bytes=result.db_bytes, source=source,
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
  if #patch.changes==0 then return {verdict="no_patch",lead_count=0,worthy="unproven"} end
  local report=run_request({changes=patch.changes},reviewed,context,"git_worktree")
  report.patch_fingerprint=patch.fingerprint
  report.patch_source="git_worktree_not_run_attributed"
  return report
end

-- The trial report is bounded by a time window, not by a background timer. Forty-eight hours
-- starts when the enabled node first writes an audit event; no event means no trial evidence.
function M.report(hours)
  hours=math.max(1, math.min(720, tonumber(hours) or 48))
  telemetry.setup()
  local raw=host.sql_query(
    "SELECT session_id,run_id,at,kind,payload FROM harness_events WHERE kind IN ('graph_patch_audit','graph_patch_value','graph_patch_feedback') AND phase='end' AND at>=? ORDER BY seq",
    json.encode({host.now()-hours*3600}))
  local rows=type(raw)=="string" and json.decode(raw) or raw
  if type(rows)~="table" or rows.error then return {error=rows and rows.error or "audit_report_failed"} end
  local first_raw=host.sql_query(
    "SELECT MIN(at) AS first_at FROM harness_events WHERE kind='graph_patch_audit' AND phase='end'",
    "[]")
  local first_rows=type(first_raw)=="string" and json.decode(first_raw) or first_raw
  if type(first_rows)~="table" or first_rows.error then
    return {error=first_rows and first_rows.error or "audit_start_lookup_failed"}
  end
  local first_at=first_rows[1] and tonumber(first_rows[1].first_at)
  local report={hours=hours, audits=0, errors=0, leads=0, lead_runs=0, gaps=0,
    mapped_lines=0, changed_lines=0, audit_ms=0, continuation_ms=0,
    continuation_tokens=0, lead_reviewed=0, patch_changed_after_lead=0,
    continuation_usage_unknown=0, max_db_bytes=0,
    no_native_followup_observed=0, confirmed_catches=0, false_positives=0,
    sources={native_changeset=0,git_worktree=0},
    worthy="unproven", examples={}, trial_started_at=first_at,
    trial_elapsed_hours=first_at and math.max(0,(host.now()-first_at)/3600) or nil,
    ready_for_review=first_at and host.now()-first_at>=hours*3600 or false}
  local feedback={}
  for _, row in ipairs(rows) do
    local payload=json.decode(row.payload or "{}")
    if row.kind=="graph_patch_feedback" then
      feedback[row.run_id]=payload.outcome
    elseif row.kind=="graph_patch_value" then
      report.continuation_ms=report.continuation_ms+(payload.continuation_ms or 0)
      report.continuation_tokens=report.continuation_tokens+(payload.continuation_tokens or 0)
      if payload.continuation_usage_unknown then report.continuation_usage_unknown=report.continuation_usage_unknown+1 end
      if report[payload.flag]~=nil then report[payload.flag]=report[payload.flag]+1 end
    else
      report.audits=report.audits+1
      if report.sources[payload.source]~=nil then report.sources[payload.source]=report.sources[payload.source]+1 end
      if payload.ok==false then report.errors=report.errors+1 end
      report.leads=report.leads+(payload.lead_count or 0)
      report.gaps=report.gaps+(payload.gap_count or 0)
      report.mapped_lines=report.mapped_lines+(payload.mapped_lines or 0)
      report.changed_lines=report.changed_lines+(payload.changed_lines or 0)
      report.audit_ms=report.audit_ms+(payload.ms or 0)
      report.max_db_bytes=math.max(report.max_db_bytes,payload.db_bytes or 0)
      if (payload.lead_count or 0)>0 then
        report.lead_runs=report.lead_runs+1
        if #report.examples<20 then report.examples[#report.examples+1]={
          session_id=row.session_id,run_id=row.run_id,at=row.at,leads=payload.lead_count} end
      end
    end
  end
  for _, outcome in pairs(feedback) do
    if outcome=="confirmed_catch" then report.confirmed_catches=report.confirmed_catches+1 end
    if outcome=="false_positive" then report.false_positives=report.false_positives+1 end
  end
  if report.confirmed_catches>0 then report.worthy="confirmed_catch" end
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
  for _, row in ipairs(rows) do
    local payload=json.decode(row.payload or "{}")
    if (payload.lead_count or 0)>0 then had_lead=true break end
  end
  if not had_lead then return {error="run_has_no_graph_lead"} end
  telemetry.event(context and context.session_id or "graph-audit",run_id,"",
    "graph_patch_feedback","end",{outcome=outcome,commit=commit})
  return {ok=true,run_id=run_id,outcome=outcome}
end

return M
