-- Predetermined read-only steps. No shell, repair, retries, loops, effects or inferred authority.
local json=dofile('lua/vendor/json.lua')
local M={}
function M.run(steps,dispatch)
  if type(steps)~='table' or #steps<1 or #steps>8 then return {error='steps_required_1_to_8'} end
  for i,step in ipairs(steps) do
    if type(step)~='table' or (step.tool~='read' and step.tool~='grep') or type(step.args)~='table' then
      return {error='only_read_and_grep_steps',step=i}
    end
    if step.expect~=nil and type(step.expect)~='table' then return {error='invalid_expectation',step=i} end
    for key,value in pairs(step.expect or {}) do
      if key=='contains' then
        if type(value)~='string' then return {error='invalid_expectation',step=i} end
      elseif key=='min_matches' or key=='max_matches' then
        if step.tool~='grep' or type(value)~='number' or value<0 or value%1~=0 then return {error='invalid_expectation',step=i} end
      else return {error='unknown_expectation',step=i} end
    end
  end
  local result={ok=true,plan_hash=host.sha256(json.encode(steps)),results={},not_run=0}
  for i,step in ipairs(steps) do
    local ok,value=pcall(dispatch,step.tool,step.args)
    if not ok then value={error=tostring(value)} end
    local reason=value.error
    if value.ok==false then reason=reason or 'tool_failed' end
    if step.tool=='read' and not value.eof then reason=reason or 'read_incomplete' end
    if step.tool=='grep' and not value.complete then reason=reason or 'search_incomplete' end
    local expect=step.expect or {}
    if expect.contains and not tostring(value.content or ''):find(expect.contains,1,true) then reason=reason or 'expected_text_missing' end
    if expect.min_matches and (value.count or -1)<expect.min_matches then reason=reason or 'too_few_matches' end
    if expect.max_matches and (value.count or math.huge)>expect.max_matches then reason=reason or 'too_many_matches' end
    result.results[#result.results+1]={step=i,tool=step.tool,result=value,ok=not reason,error=reason}
    if reason then result.ok=false;result.stopped_at=i;result.not_run=#steps-i;break end
  end
  return result
end
return M
