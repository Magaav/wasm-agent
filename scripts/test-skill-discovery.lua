-- Metadata discovery is not execution; complete skill bodies and policy remain.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local skills=dofile('lua/core/skills.lua')
local agent=dofile('lua/core/agent.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
host.http=function()error('provider/network forbidden')end
local root=dofile('lua/core/paths.lua').config()..'/skills'
local function fixture(name,description,hidden)
 local text='---\nname: '..name..'\ndescription: '..description..'\n'..(hidden and 'disable-model-invocation: true\n' or '')..'---\nFULL BODY — keep user drafts and verify identity before sending.\n'
 assert(host.write_file(root..'/'..name..'/SKILL.md',text));return text
end
local body=fixture('discovery-whatsapp','WhatsApp account identity and draft-safe reporting.')
fixture('discovery-hidden','humanonlyfixturetoken hidden human-only procedure.',true)
for i=1,10 do fixture('discovery-example-'..i,'discoveryfixturematchtoken separate procedure.')end
local sid=memory.start_session('','discovery fixture',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local found=tools.dispatch(memory,'skill',{query='discovery-whatsapp',limit=1},'master',ctx)
check(not found.error and type(found.skills)=='table','skill metadata discovery is available')
check(found.skills[1].name=='discovery-whatsapp','ranked exact-name metadata discovery')
check(found.skills[1].content==nil and found.skills[1].description:find('identity',1,true),'discovery returns metadata, not body')
local loaded=tools.dispatch(memory,'skill',{name=found.skills[1].name},'master',ctx)
check(loaded.content==body and loaded.dir==root..'/discovery-whatsapp','full UTF-8 procedure and relative address preserved')
check(loaded.usage==nil,'shared policy not duplicated into every skill reply')
local guest=tools.dispatch(memory,'skill',{query='discovery-whatsapp',limit=1},'guest',{session_id=sid,user_id='guest'})
check(guest.skills[1].name=='discovery-whatsapp','existing guest skill knowledge remains accessible')
check(tools.dispatch(memory,'write',{path=root..'/forbidden',content='x'},'guest').error~=nil,'discovery does not grant guest writes')
local denied=tools.dispatch(memory,'skill',{query='*'},'master',{subagent={allowed={read=true}}})
check(denied.error=='capability_not_in_profile:skill','profile ceiling precedes discovery')
local query='discoveryfixturematchtoken'
local one=tools.dispatch(memory,'skill',{query=query,limit=3},'master',ctx)
check(one.matches==10 and #one.skills==3 and one.has_more and one.next_offset==3,'explicit complete match count and continuation')
local names={};for _,s in ipairs(one.skills)do names[s.name]=true end
local page=one
while page.has_more do
 page=tools.dispatch(memory,'skill',{query=query,limit=3,offset=page.next_offset,snapshot=page.snapshot},'master',ctx)
 check(not page.error,'stable metadata page')
 for _,s in ipairs(page.skills)do check(not names[s.name],'no omitted or duplicate skill');names[s.name]=true end
end
local count=0;for _ in pairs(names)do count=count+1 end;check(count==10 and page.complete,'all matches retained across pages')
for _,other in ipairs({{session_id=sid,user_id='other'},{session_id='other-session',user_id='master'},
 {session_id=sid,user_id='master',subagent={allowed={skill=true}}}})do
 check(tools.dispatch(memory,'skill',{query=query,offset=3,snapshot=one.snapshot},'master',other).error=='skill_catalogue_changed','caller/profile snapshot scope refuses drift')
end
check(tools.dispatch(memory,'skill',{query=query,offset=3,snapshot=one.snapshot},'guest',ctx).error=='skill_catalogue_changed','role snapshot drift refused')
local bound=setmetatable({session_workspace=function()return {required=true,state='allocated',worktree=root}end},{__index=memory})
check(tools.dispatch(bound,'skill',{query=query,offset=3,snapshot=one.snapshot},'master',ctx).error=='skill_catalogue_changed','workspace binding drift refused')
check(tools.dispatch(memory,'skill',{name='discovery-whatsapp',query='*'},'master',ctx).error=='skill_forms_are_exclusive','exclusive forms')
check(tools.dispatch(memory,'skill',{name='discovery-whatsapp',offset=1},'master',ctx).error=='skill_query_required','search controls require query')
for _,args in ipairs({{query=''},{query=string.rep('a',257)},{query='*',limit=0},{query='*',limit=9},
 {query='*',offset=-1},{query='*',offset=0.5},{query='*',offset=1},{query='*',snapshot='tampered'}})do
 check(tools.dispatch(memory,'skill',args,'master',ctx).error~=nil,'invalid discovery visibly refuses')
end
check(tools.dispatch(memory,'skill',{query='nevermatchfixturezzzz'},'master',ctx).matches==0,'no-match is explicit')
check(tools.dispatch(memory,'skill',{query='humanonlyfixturetoken'},'master',ctx).matches==0,'hidden metadata never discovered')
check(tools.dispatch(memory,'skill',{name='discovery-hidden'},'master',ctx).content~=nil,'explicit hidden load compatibility')
local schemas=tools.envelope('master',ctx)
local first=agent.system_prompt('master','PROJECT POLICY — WhatsApp consent stays mandatory.','fixture/AGENTS.md',schemas,'progressive')
check(not first:find('<available_skills>',1,true) and not first:find('discovery-whatsapp',1,true),'optional catalogue absent from progressive bootstrap')
check(first:find('WhatsApp consent stays mandatory',1,true)~=nil,'project policy never keyword-filtered away')
check(first:find(skills.usage(),1,true)~=nil,'complete shared skill policy retained once')
check(first:find('skill(query=',1,true) and first:find('skill(name=',1,true),'explicit discovery/load contract')
check(first:find('final answer so `rg` can be installed',1,true),'ripgrep shell fallback disclosure rule')
fixture('discovery-added','A newly installed procedure with large metadata '..string.rep('more ',300))
check(tools.dispatch(memory,'skill',{query=query,offset=3,snapshot=one.snapshot},'master',ctx).error=='skill_catalogue_changed','changed catalogue refuses stale continuation')
check(first==agent.system_prompt('master','PROJECT POLICY — WhatsApp consent stays mandatory.','fixture/AGENTS.md',schemas,'progressive'),'prefix independent of catalogue growth/discovery')
local full=agent.system_prompt('master','PROJECT','fixture/AGENTS.md',tools.all('master'),'full')
check(full:find('<available_skills>',1,true) and full:find('discovery-whatsapp',1,true),'full rollback retains metadata')
local child=agent.subagent_system_prompt({role='master',subagent={allowed={skill=true}}},tools.all_for({skill=true},'master'))
check(not child:find('<available_skills>',1,true) and #agent.subagent_tool_list({allowed={skill=true}},'master')==1,
 'child exact profile remains unchanged without inheriting parent catalogue')
for _,s in ipairs(tools.all('master'))do
 if s['function'].name=='graph' then check(s['function'].description:find('whether it helped your reasoning and why',1,true)~=nil,'graph final-answer reasoning assessment is discoverable') end
end
local all=tools.dispatch(memory,'skill',{query='*',limit=8},'master',ctx)
check(all.matches>10 and all.skills[1] and all.has_more,'complete visible catalogue remains enumerable')
print('skill discovery ok ('..checks..' checks, 0 skipped; no provider or paid calls)')
