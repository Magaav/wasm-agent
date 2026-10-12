-- Private native dispatch: skill instructions are exact, not a 12,000-byte prefix.
local json=dofile('lua/vendor/json.lua')
local skills=dofile('lua/core/skills.lua')
local tools=dofile('lua/core/tools.lua')
local output=dofile('lua/core/tool_output.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local root=dofile('lua/core/paths.lua').config()..'/skills'
local checks=0
local function check(value,label)checks=checks+1;assert(value,label)end
local fixtures={}
local function fixture(name,text)
  local path=root..'/'..name..'/SKILL.md'
  assert(host.write_file(path,text))
  fixtures[name]={path=path,text=text}
end
local function body(name,size)
  local first='---\nname: '..name..'\ndescription: Full-content private fixture.\n---\n'
  local last='\nFINAL SAFETY RULE: never replay an unknown effect.\n'
  return first..string.rep('x',size-#first-#last)..last
end
for _,size in ipairs({11999,12000,12001,28457})do
  local name='skill-content-'..size;fixture(name,body(name,size))
end
local unicode_name='skill-content-unicode'
local prefix='---\nname: '..unicode_name..'\ndescription: Unicode exactness.\n---\n'
fixture(unicode_name,prefix..string.rep('u',11999-#prefix)..'🧭ação漢字\nFINAL UNICODE SAFETY RULE\n')
fixture('skill-content-hidden','---\nname: skill-content-hidden\ndescription: Hidden instructions.\ndisable-model-invocation: true\n---\nHIDDEN BODY MUST NOT BE IN THE PROMPT\n')
fixture('skill-content-oversized',body('skill-content-oversized',output.MAX_BYTES*2))
local repo=host.getenv('SKILL_TEST_REPO') or dofile('lua/core/platform.lua').cwd()
local real=host.read_file(repo..'/skills/git-orchestrator/SKILL.md')
assert(real and #real>12000,'real git-orchestrator regression must exceed the old cap')
fixture('git-orchestrator',real)
skills.list(true)
for _,name in ipairs({'skill-content-11999','skill-content-12000','skill-content-12001','skill-content-28457',unicode_name,'git-orchestrator'})do
  local found=skills.find(name);check(found~=nil,'discover '..name)
  check(skills.content(found)==fixtures[name].text,'exact module content '..name)
  for _,role in ipairs({'master','guest'})do
    local loaded=tools.dispatch(memory,'skill',{name=name},role)
    check(loaded.content==fixtures[name].text,'exact tool content '..name..' '..role)
    check(loaded.path==fixtures[name].path and loaded.dir==root..'/'..name,'preserved skill address '..name..' '..role)
    local projected=json.decode(output.project('skill',loaded))
    check(projected.content==fixtures[name].text and not projected.omitted,'one-call model view '..name..' '..role)
  end
end
local report=skills.report('master')
local counts={};for _,entry in ipairs(report.skills)do counts[entry.name]=entry.body_chars end
check(counts['skill-content-28457']==28457,'inventory reports the complete body length')
local block=skills.prompt_block()
check(block:find('skill-content-28457',1,true)~=nil,'metadata stays discoverable')
check(not block:find('FINAL SAFETY RULE',1,true),'full procedures stay on demand')
check(not block:find('HIDDEN BODY MUST',1,true) and not block:find('<name>skill-content-hidden</name>',1,true),'hidden skills stay out of prompt')
check(tools.dispatch(memory,'skill',{name='skill-content-hidden'},'master').content==fixtures['skill-content-hidden'].text,'explicit hidden load remains available')
check(tools.dispatch(memory,'skill',{name='not-a-real-skill'},'master').error=='unknown_skill','unknown skill refuses')
check(tools.dispatch(memory,'skill',{},'master').error=='name_required','missing name refuses')
check(skills.content({path=root..'/not-a-real-file/SKILL.md'})==nil,'unreadable content stays missing')
local big=tools.dispatch(memory,'skill',{name='skill-content-oversized'},'master')
check(big.content==fixtures['skill-content-oversized'].text,'oversized body is never destructively clipped')
local projected=json.decode(output.project('skill',big))
check(projected.omitted==true and projected.full_result and projected.full_result.sha256,'shared budget retains full-original evidence')
local parts,offset={},1
while true do
  local page=tools.dispatch(memory,'tool_result',{sha256=projected.full_result.sha256,offset=offset,limit=8192},'master')
  assert(not page.error and page.next_offset>offset,'exact shared result paging')
  parts[#parts+1]=page.content
  if page.eof then break end
  offset=page.next_offset
end
local original=json.decode(table.concat(parts))
check(original.content==big.content and original.path==big.path,'shared full-result pages preserve every instruction byte')
print('skill content ok ('..checks..' checks; skipped0)')
