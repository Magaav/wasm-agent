-- tool_search by exact name (07/11): the model can ask for the tools it already knows instead of
-- guessing keywords. names=[...] loads 1-8 exact definitions in ONE loadout write (all or
-- envelope_loadout_changed with effect none), each permitted name pinned and guided exactly like a
-- keyword hit, and an unknown or not-permitted name comes back in `missing` with the nearest
-- permitted names - never a denied one. query="select:a,b,c" is the same request in one string.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local envelope=dofile('lua/core/envelope.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function session(title)return memory.start_session('',title,{user_id='master',node_id='',title=title})end
local function ctx_for(title,extra)
 local c={session_id=session(title),user_id='master',role='master'}
 for k,v in pairs(extra or {})do c[k]=v end;return c
end
-- The loadout row the facade writes: read it directly so "one write, all names" is measured on the
-- store, not inferred from the reply.
local function loadout_key(c)
 return 'envelope.v1:'..host.sha256(c.session_id..'\0'..tostring(c.user_id or '')..'\0'..tostring(c.role or 'guest'))..':loaded'
end
local function stored(c)
 local rows=json.decode(host.sql_query('SELECT value FROM meta WHERE key=?',json.encode({loadout_key(c)})))
 return rows[1] and json.decode(rows[1].value) or nil
end
local function stored_names(c)
 local map=stored(c) or {};local list={};for name in pairs(map)do list[#list+1]=name end;table.sort(list);return list
end
-- Count only the loadout row's writes (the meta key ends in :loaded), whatever form they take.
local writes=0;local real_exec=host.sql_exec
host.sql_exec=function(statement,params)
 if type(params)=='string' and params:find(':loaded"',1,true) then writes=writes+1 end
 return real_exec(statement,params)
end

-- 1. A batch of four known names: four loaded, one write, one row.
local ctx=ctx_for('batch')
writes=0
local batch=tools.dispatch(memory,'tool_search',{names={'read','grep','ls','write'}},'master',ctx)
check(batch.error==nil,'a named batch is accepted: '..json.encode(batch):sub(1,200))
check(#batch.tools==4 and batch.loaded==4 and batch.matches==4 and batch.requested==4,'four known names load in one call')
check(batch.tools[1].name=='read' and batch.tools[4].name=='write','a named batch keeps the caller order')
for _,item in ipairs(batch.tools)do check(item.loaded==true,'named definition reports loaded') end
check(writes==1,'the whole batch is ONE loadout write, not four ('..writes..')')
local row=stored(ctx)
check(row and row.read and row.grep and row.ls and row.write,'the single loadout row carries all four names: '..table.concat(stored_names(ctx),','))
check(row.read==host.sha256(json.encode(batch.tools[1].schema)),'a named load pins the exact schema hash a keyword hit pins')
check(type(batch.missing)=='table' and #batch.missing==0,'a fully known batch has nothing missing')
-- A second batch is still one compare-and-swap on the existing row.
writes=0
local again=tools.dispatch(memory,'tool_search',{names={'edit'}},'master',ctx)
check(again.loaded==1 and writes==1,'a second batch is one compare-and-swap write ('..writes..')')
check(#stored_names(ctx)==5,'the loadout accumulates names across batches')
-- Duplicates are one name, not two loads.
local dup=ctx_for('duplicate');writes=0
local dupe=tools.dispatch(memory,'tool_search',{names={'read','read','grep'}},'master',dup)
check(dupe.loaded==2 and dupe.requested==2 and writes==1,'a repeated name is loaded once ('..tostring(dupe.requested)..')')

-- 2. Mixed known and unknown: the known name loads, the unknown one is reported with suggestions.
local mixed=tools.dispatch(memory,'tool_search',{names={'read','reed'}},'master',ctx_for('mixed'))
check(mixed.error==nil and mixed.loaded==1 and mixed.tools[1].name=='read','the known half of a mixed batch loads')
check(mixed.matches==1 and mixed.requested==2,'matches counts the recognised names, requested the batch size')
check(#mixed.missing==1 and mixed.missing[1].name=='reed','the unknown name is reported in missing')
check(table.concat(mixed.missing[1].suggestions,','):find('read',1,true)~=nil,'missing carries the nearest permitted names')

-- 3. A denied name is never disclosed: suggestions come from the caller's own catalogue only.
local guest={session_id=session('guest-batch'),user_id='guest',role='guest'}
local denied=tools.dispatch(memory,'tool_search',{names={'web_search','integrate'}},'guest',guest)
check(denied.error==nil and denied.loaded==0 and #denied.missing==2,'a guest batch loads nothing it may not use')
local leaked=false
for _,entry in ipairs(denied.missing)do
 for _,name in ipairs(entry.suggestions)do if name=='web_search' or name=='integrate' then leaked=true end end
end
check(not leaked,'a denied name is never suggested back')
check(json.encode(denied):find('web_search',1,true)~=nil,'the guest does hear the name it asked for echoed in missing')
local guest_near=tools.dispatch(memory,'tool_search',{names={'recalll'}},'guest',guest)
check(#guest_near.missing==1 and table.concat(guest_near.missing[1].suggestions,','):find('recall',1,true)~=nil,'a misspelt guest name is corrected from the guest catalogue')
local child={session_id=session('child-batch'),user_id='master',role='master',subagent={allowed={tool_call=true,tool_search=true,read=true}}}
local narrowed=tools.dispatch(memory,'tool_search',{names={'write','bash','raed'}},'master',child)
check(narrowed.loaded==0 and #narrowed.missing==3,'a profile ceiling bounds a named batch')
local profile_leak=false
for _,entry in ipairs(narrowed.missing)do
 for _,name in ipairs(entry.suggestions)do if name=='write' or name=='bash' then profile_leak=true end end
end
check(not profile_leak,'a name outside the profile is never suggested')
check(table.concat(narrowed.missing[3].suggestions,','):find('read',1,true)~=nil,'the profile-visible name is still suggested for a misspelt ask')

-- 4. The one-string spelling is the same request, and a comma list sent as a string too.
local sel_ctx=ctx_for('select');writes=0
local sel=tools.dispatch(memory,'tool_search',{query='select:read, grep ,ls'},'master',sel_ctx)
check(sel.error==nil and sel.loaded==3 and #sel.tools==3,'query="select:a,b,c" loads the same batch: '..json.encode(sel):sub(1,200))
check(sel.tools[2].name=='grep' and writes==1,'select: keeps order and is one write')
local spelled=tools.dispatch(memory,'tool_search',{names='read,grep'},'master',ctx_for('names-string'))
check(spelled.error==nil and spelled.loaded==2,'names sent as one comma string has exactly one reading')
local upper=tools.dispatch(memory,'tool_search',{query='SELECT:read'},'master',ctx_for('select-case'))
check(upper.error==nil and upper.loaded==1,'the select: prefix is case-insensitive')

-- 5. Refusals: bounds, exclusivity, and an empty batch.
local nine={};for i=1,9 do nine[i]='read'..i end
local oversized=ctx_for('oversized');writes=0
check(tools.dispatch(memory,'tool_search',{names=nine},'master',oversized).error=='invalid_tool_search_names','more than 8 names is refused')
check(writes==0 and stored(oversized)==nil,'a refused batch writes nothing')
check(tools.dispatch(memory,'tool_search',{names={}},'master',ctx).error=='invalid_tool_search_names','an empty names list is refused')
check(tools.dispatch(memory,'tool_search',{names={'read'},query='read'},'master',ctx).error=='tool_search_arguments_exclusive','names and query are mutually exclusive')
check(tools.dispatch(memory,'tool_search',{query='select:'},'master',ctx).error=='invalid_tool_search_names','an empty select: list is refused')
check(tools.dispatch(memory,'tool_search',{query='read',limit=9},'master',ctx).error=='invalid_tool_search_limit','a keyword limit above 8 is still refused')
check(tools.dispatch(memory,'tool_search',{},'master',ctx).error=='tool_search_query_required','neither form is still refused')
check(tools.dispatch(memory,'tool_search',{names={1}},'master',ctx).error=='invalid_tool_search_names','a non-string name is refused')
-- An exact name is looked up whole; only the echo of a miss is bounded.
local long=string.rep('x',80)
local long_ctx=ctx_for('long-name')
local long_catalog={};for _,item in ipairs(tools.all('master',long_ctx,memory))do long_catalog[#long_catalog+1]=item end
long_catalog[#long_catalog+1]={type='function',['function']={name=long,description='long named demo',parameters={type='object',properties={}}}}
local long_load=envelope.search(long_catalog,{names={long}},long_ctx,function()return {status='not_blocked'} end)
check(long_load.loaded==1 and #long_load.tools[1].name==#long,'an exact name longer than 64 characters is loaded whole, not truncated')
local huge=envelope.search(long_catalog,{names={string.rep('y',300)}},long_ctx,function()return {status='not_blocked'} end)
check(#huge.missing[1].name==64,'the echo of an oversized missing name is bounded')

-- 6. Atomicity: a lost compare-and-swap loads nothing and reports effect none.
local atomic=ctx_for('atomic')
check(tools.dispatch(memory,'tool_search',{names={'read'}},'master',atomic).loaded==1,'the atomic case starts with one loaded name')
local before=json.encode(stored(atomic))
host.sql_exec=function(statement,params)
 if statement:find('^UPDATE meta',1) and type(params)=='string' and params:find(':loaded"',1,true) then
  return json.encode({ok=true,changes=0})
 end
 return real_exec(statement,params)
end
local stale=tools.dispatch(memory,'tool_search',{names={'grep','ls'}},'master',atomic)
host.sql_exec=real_exec
check(stale.error=='envelope_loadout_changed' and stale.effect=='none','a lost compare-and-swap is a loadout_changed refusal with effect none')
check(json.encode(stored(atomic))==before,'the refused batch left no name behind')
check(stored(atomic).grep==nil and stored(atomic).ls==nil,'no half-applied batch in the loadout row')

-- 7. The same blocked/unknown/codemode-only rules and guidance as a keyword hit.
local root=dofile('lua/core/paths.lua').data()..'/batch-envelope'
check(host.write_file(root..'/inside.txt','inside'),'scratch workspace written')
local bound={session_workspace=function()return {required=true,state='allocated',worktree=root}end}
local blocked=tools.dispatch(bound,'tool_search',{names={'client'}},'master',ctx_for('blocked'))
check(blocked.loaded==0 and blocked.tools[1].loaded==false,'a name blocked by the workspace policy is not loaded')
check(table.concat(blocked.guidance,' '):find('Do not invoke client',1,true)~=nil,'a blocked named load keeps the keyword guidance line')
local fake={{type='function',['function']={name='mcp_demo_thing',description='demo connector',parameters={type='object',properties={}}}}}
local connector_ctx=ctx_for('connector',{codemode_policy={enabled=true}})
local gated=envelope.search(fake,{names={'mcp_demo_thing'}},connector_ctx,function()return {status='not_blocked'} end)
check(gated.loaded==0 and table.concat(gated.guidance,' '):find('Code mode only: call mcp_demo_thing',1,true)~=nil,'a connector name keeps the code-mode-only rule in a batch')
check(gated.tools[1].execution.status=='not_blocked','the execution metadata is still reported for a name it refused to load')

-- 8. A named pin still fences a changed definition, exactly like a keyword pin.
local changed_ctx=ctx_for('changed')
local all=tools.all('master',changed_ctx,memory)
local pinned_load=envelope.search(all,{names={'web_read'}},changed_ctx,function()return {status='not_blocked'} end)
check(pinned_load.loaded==1,'the changed-definition case starts from a named load')
local changed={};for _,item in ipairs(all)do
 local name=item['function'].name
 if name=='web_read' then item['function'].description=item['function'].description..' changed' end
 changed[#changed+1]=item
end
local _,problem=envelope.resolve(changed,'web_read',changed_ctx)
check(problem=='tool_definition_changed: use tool_search again','a named load pins the definition like a keyword load')

print('tool_search names ok ('..checks..' checks)')
