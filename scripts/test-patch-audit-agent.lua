-- The real run loop must pause a final answer for one graph lead, let the agent
-- inspect the caller, and then finish without a second graph prompt.
local json=dofile("lua/vendor/json.lua")
local paths=dofile("lua/core/paths.lua")
local root=paths.temp().."/wa-patch-loop-"..tostring(host.now())
local source=root.."/source.lua"
local caller=root.."/caller.lua"
assert(host.write_file(source,"function M.changed() return 1 end\n"))
assert(host.write_file(caller,"function caller() return M.changed() end\n"))
local real_getenv,real_stream,real_audit=host.getenv,host.http_stream,host.graph_patch_audit
host.getenv=function(key)
  if key=="WA_GRAPH_PATCH_AUDIT" then return "1" end
  if key=="WASM_AGENT_LLM_API_KEY" then return "fixture-only" end
  return real_getenv(key)
end
local round,audits=0,0
host.http_stream=function()
  round=round+1
  if round==1 then
    return json.encode({status=200,content="",finish_reason="tool_calls",tool_calls={{
      id="patch-write",type="function",["function"]={name="write",
        arguments=json.encode({path=source,content="function M.changed() return 2 end\n"})}}}})
  elseif round==2 then
    return json.encode({status=200,content="done",finish_reason="stop",tool_calls={}})
  elseif round==3 then
    return json.encode({status=200,content="",finish_reason="tool_calls",tool_calls={{
      id="caller-read",type="function",["function"]={name="read",
        arguments=json.encode({path=caller})}}}})
  elseif round==4 then
    return json.encode({status=200,content="",finish_reason="tool_calls",tool_calls={{
      id="audit-assess",type="function",["function"]={name="graph",
        arguments=json.encode({action="audit_assess",grade=2,
          reason="The caller read confirmed the changed function is still used",
          critique="The graph did not show whether the caller has test coverage",
          evidence="caller.lua:1"})}}}})
  end
  return json.encode({status=200,content="audited",finish_reason="stop",tool_calls={}})
end
host.graph_patch_audit=function(raw)
  audits=audits+1
  local request=json.decode(raw)
  assert(request.changes[1].lines[1]==1)
  local seen=false
  for _, path in ipairs(request.reviewed or {}) do if path==caller then seen=true end end
  return json.encode({root=root,verdict=seen and "no_leads" or "leads",
    lead_count=seen and 0 or 1,mapped_lines=1,changed_lines=1,gaps={},
    leads=seen and {} or {{path="caller.lua",line=1,symbol="M.changed"}}})
end
local memory=dofile("lua/core/memory.lua")
memory.setup()
local session=memory.ensure_session("patch-audit-test","local","audit loop")
local agent=dofile("lua/core/agent.lua").new(session,function() end,"master","patch-audit-test","local")
agent.stream=true
local ok, reply=pcall(agent.run,agent,"change the function")
host.getenv,host.http_stream,host.graph_patch_audit=real_getenv,real_stream,real_audit
assert(ok,tostring(reply))
assert(reply=="audited",tostring(reply))
assert(round==5 and audits==2,string.format("rounds=%d audits=%d",round,audits))
local assessment=dofile("lua/core/patch_audit.lua").report(48).self_assessment
assert(assessment.steps==1 and assessment.recorded==1 and assessment.missing==0)
assert(assessment.grades["2"]==1)

-- An agent that omits the assessment gets one bounded reminder, then finishes
-- with an explicit missing verdict instead of spinning or fabricating a grade.
round,audits=0,0
host.getenv=function(key)
  if key=="WA_GRAPH_PATCH_AUDIT" then return "1" end
  if key=="WASM_AGENT_LLM_API_KEY" then return "fixture-only" end
  return real_getenv(key)
end
host.http_stream=function()
  round=round+1
  if round==1 then
    return json.encode({status=200,content="",finish_reason="tool_calls",tool_calls={{
      id="second-write",type="function",["function"]={name="write",
        arguments=json.encode({path=source,content="function M.changed() return 3 end\n"})}}}})
  end
  return json.encode({status=200,content="done without assessment",finish_reason="stop",tool_calls={}})
end
host.graph_patch_audit=function()
  audits=audits+1
  return json.encode({root=root,verdict="leads",lead_count=1,mapped_lines=1,changed_lines=1,
    gaps={},leads={{path="caller.lua",line=1,symbol="M.changed"}}})
end
local second=dofile("lua/core/agent.lua").new(session,function() end,"master","patch-audit-test","local")
second.stream=true
local second_ok,second_reply=pcall(second.run,second,"change it again")
host.getenv,host.http_stream,host.graph_patch_audit=real_getenv,real_stream,real_audit
assert(second_ok,tostring(second_reply))
assert(round==4 and audits==3,string.format("rounds=%d audits=%d",round,audits))
assert(second_reply:find("self-assessment missing",1,true),tostring(second_reply))
assert(dofile("lua/core/patch_audit.lua").report(48).self_assessment.missing==1)
print("patch audit agent ok")
