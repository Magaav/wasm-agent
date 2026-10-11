-- Bounded independent operations, never an autonomous workflow or a transaction.
local M = {MAX_ITEMS=8}

local function dense(value,minimum,maximum)
  if type(value)~='table' or #value<minimum or #value>maximum then return false end
  for key in pairs(value) do
    if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
  end
  for i=1,#value do if value[i]==nil then return false end end
  return true
end

local function validate(value,spec,field)
  local kind=spec.type
  if kind=='object' then
    if type(value)~='table' then return {error='invalid_batch_item',field=field} end
    for key in pairs(value) do
      if not (spec.properties or {})[key] then return {error='unsupported_batch_option',field=field..'.'..tostring(key)} end
    end
    for _,key in ipairs(spec.required or {}) do
      if value[key]==nil then return {error='required_batch_field',field=field..'.'..key} end
    end
    for key,entry in pairs(spec.properties or {}) do
      if value[key]~=nil then
        local failure=validate(value[key],entry,field..'.'..key)
        if failure then return failure end
      end
    end
  elseif kind=='array' then
    if not dense(value,spec.minItems or 0,spec.maxItems or 2000) then return {error='invalid_batch_array',field=field} end
    for i,item in ipairs(value) do
      local failure=validate(item,spec.items,field..'['..i..']')
      if failure then return failure end
    end
  elseif kind=='string' then
    if type(value)~='string' or spec.maxLength and #value>spec.maxLength then return {error='invalid_batch_string',field=field} end
  elseif kind=='boolean' then
    if type(value)~='boolean' then return {error='invalid_batch_boolean',field=field} end
  elseif kind=='integer' or kind=='number' then
    if type(value)~='number' or value~=value or value==math.huge or value==-math.huge
        or kind=='integer' and value%1~=0 or spec.minimum and value<spec.minimum or spec.maximum and value>spec.maximum then
      return {error='invalid_batch_number',field=field}
    end
  end
  if spec.enum then
    for _,choice in ipairs(spec.enum) do if value==choice then return nil end end
    return {error='invalid_batch_choice',field=field}
  end
end

function M.requests(args)
  if type(args)~='table' then return nil,{error='requests_required_1_to_8'} end
  for key in pairs(args) do if key~='requests' then return nil,{error='unsupported_batch_option',field=tostring(key)} end end
  if not dense(args.requests,1,M.MAX_ITEMS) then return nil,{error='requests_required_1_to_8'} end
  return args.requests
end

function M.item(request,spec,index)
  return validate(request,spec,'requests['..index..']')
end

function M.copy(request)
  local copy={}
  for key,value in pairs(request) do copy[key]=value end
  return copy
end

function M.read(args,spec,invoke)
  local requests,failure=M.requests(args)
  if not requests then return failure end
  local results,failed={},0
  for i,request in ipairs(requests) do
    local result=M.item(request,spec,i)
    if not result then
      local called,value=pcall(invoke,M.copy(request))
      result=called and type(value)=='table' and value or {error='batch_read_failed',detail=tostring(value)}
    end
    results[i]=result
    if type(result)~='table' or result.error or result.ok==false then failed=failed+1 end
  end
  return {ok=failed==0,results=results,failed=failed,succeeded=#requests-failed}
end

-- No effects until *all* plans and target identities are validated. Applying is
-- serial and rechecks each snapshot. A late race/write/recording failure retains
-- earlier effects; later items are explicitly not run. Never rollback or retry.
function M.mutate(args,spec,prepare,apply,identity,admit,verify)
  local requests,failure=M.requests(args)
  if not requests then return failure end
  local plans,results,keys={}, {}, {}
  local failed=0
  for i,request in ipairs(requests) do
    local plan=M.item(request,spec,i)
    if not plan then
      local called,value=pcall(prepare,M.copy(request))
      plan=called and type(value)=='table' and value or {error='batch_prepare_failed',detail=tostring(value)}
    end
    if not plan.error then
      local key=identity(plan.path)
      for j,previous in pairs(keys) do
        if key==previous or key:sub(1,#previous+1)==previous..'/' or previous:sub(1,#key+1)==key..'/' then
          plan={error='overlapping_batch_paths',path=plan.path,conflicts_with=j};break
        end
      end
      keys[i]=key
    end
    if plan.error then results[i]=plan;failed=failed+1 else plans[i]=plan end
  end
  if failed==0 and verify then
    for i,plan in ipairs(plans) do
      local refusal=verify(plan)
      if refusal then results[i]=refusal;failed=failed+1 end
    end
  end
  if failed>0 then
    for i=1,#requests do
      if not results[i] then results[i]={error='batch_preflight_aborted',executed=false,path=plans[i].path} end
    end
    return {ok=false,phase='preflight',effect='none',atomic=false,applied=0,failed=failed,
      not_run=#requests-failed,results=results}
  end
  local applied,not_run,unknown=0,0,0
  local stopped=false
  for i,plan in ipairs(plans) do
    local result
    if stopped then result={error='batch_stopped',executed=false,path=plan.path};not_run=not_run+1
    elseif admit and not admit() then
      result={error='superseded_by_steering',executed=false,effect='none',path=plan.path};failed=failed+1;stopped=true
    else
      local called,value=pcall(apply,plan)
      result=called and type(value)=='table' and value or
        {ok=false,error='batch_apply_failed',detail=tostring(value),outcome='unknown',path=plan.path}
      if result.applied then applied=applied+1 end
      if result.outcome=='unknown' then unknown=unknown+1 end
      if result.error or result.ok==false then failed=failed+1;stopped=true end
    end
    results[i]=result
  end
  local result={ok=failed==0,phase='apply',atomic=false,applied=applied,failed=failed,not_run=not_run,
    unknown=unknown,partial=applied>0 and failed>0,results=results}
  if results[1].error=='superseded_by_steering' and applied==0 and unknown==0 then
    result.error='superseded_by_steering';result.executed=false;result.effect='none'
  end
  return result
end
return M
