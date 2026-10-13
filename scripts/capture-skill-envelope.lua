-- Exact bootstrap system/schema capture; no provider request or tool execution.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local agent=dofile('lua/core/agent.lua')
local tools=dofile('lua/core/tools.lua')
local sid=memory.start_session('','bootstrap capture',{user_id='master'})
local bot=agent.new(sid,function()end,'master','master','')
local context=bot:build_context()
local schemas=tools.envelope('master',{session_id=sid,user_id='master',role='master'})
local request={messages=context,tools=schemas}
local system=context[1].content
local catalogue={}
for _,skill in ipairs(dofile('lua/core/skills.lua').list(true))do
 if not skill.hidden then catalogue[#catalogue+1]={name=skill.name,description=skill.description,path=skill.path,dir=skill.dir} end
end
local capture={catalogue_sha256=host.sha256(json.encode(catalogue)),catalogue_count=#catalogue,
 request=request,system_bytes=#system,schema_bytes=#json.encode(schemas),envelope_bytes=#json.encode(request),
 metadata_present=system:find('<available_skills>',1,true)~=nil,whatsapp_present=system:lower():find('whatsapp',1,true)~=nil,
 policy_retained=system:find(dofile('lua/core/skills.lua').usage and dofile('lua/core/skills.lua').usage() or 'Never weaken checks',1,true)~=nil,
 tool_count=#schemas,provider_calls=0}
assert(host.write_file(assert(host.getenv('WA_CAPTURE_OUTPUT')),json.encode(capture)))
print('bootstrap capture ok')
