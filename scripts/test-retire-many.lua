-- The `*_many` tools are retired (operator's decision, 12/11: "yes many can be retired as naturally code
-- mode can queue many"). Code mode IS the batch. This row is both halves of that decision:
--
-- 1. PARITY, name by name, on the form that replaced it:
--      read_many            -> Promise.all(items.map(x => tools.read(x)))
--      grep_many            -> Promise.all(items.map(x => tools.grep(x)))
--      session_many         -> Promise.all(items.map(x => tools.session(x)))
--      search_messages_many -> Promise.all(items.map(x => tools.search_messages(x)))
--      symbol_source_many   -> Promise.all(items.map(x => tools.graph(x)))
--      write_many/edit_many -> serial `for`/Promise.all of tools.write / tools.edit
--    The assertions are on DATA (values, request order, per-item errors), on the GUARDS (a guest and a
--    bound workspace get the same refusal the primitive gives) and on the LIMITS that matter: reads run
--    in parallel, effects are admitted one at a time and are visible to the next call in the same script,
--    and the 1-8 ceiling is gone because a script's loop is bounded by its own clock, not by a request
--    array. Measured at 6149b31f before the removal: for these fixtures the batch and the script answered
--    identical per-item data, 1 native call vs N (see the commit message); nothing here was cheaper
--    server-side, so nothing was kept.
-- 2. REFUSAL: every retired name answers exactly one sentence, from every route that can name a tool -
--    the dispatcher (which an ordinary call, a `tool_call`, a peer capability and a script's
--    `tools.<name>` all reach), and `describeTool` inside a script. There is no working alias: a retired
--    name reads, writes and edits nothing.
-- 3. GATE: no `*_many` name is in a catalogue a role or a profile can see, in the prompt envelope, or
--    offered by a live doc or skill. A `*_many` that comes back fails here.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return 'native' end;return env(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local policy=dofile('lua/core/codemode_policy.lua')
local paths=dofile('lua/core/paths.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end

local NONCE=host.uuid()
local root=paths.data()..'/retire-many-'..NONCE
assert(host.write_file(root..'/a.txt','alpha\n'))
assert(host.write_file(root..'/b.txt','beta\n'))
assert(host.write_file(root..'/c.txt','gamma\n'))

local sid=memory.start_session('','retire-many',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
policy.pin(memory,'master',ctx)
check(policy.enforced(ctx),'code mode is the batch this run measures: it is admitted here')
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local dispatched={}
local function dispatch(name,params,raw)
  dispatched[#dispatched+1]={name=name,params=params}
  return tools.dispatch(memory,name,params or {},'master',ctx)
end
local function code(source)
  return tools.dispatch(memory,'codemode',{code=source},'master',ctx)
end
-- The guest's own bytes: `text()` is the output channel, so the value is exactly what the script encoded.
local function ask(body,label)
  local result=code('text(JSON.stringify(await (async()=>{'..body..'})())); return 1;')
  if not result.ok then
    error((label or 'script')..' failed: '..tostring(result.error or result.reason or 'no reason')..
      ' ('..(#(result.attempts or {})..' calls: '..tostring(json.encode(result.attempts or {})):sub(1,220))..')')
  end
  local item=result.items and result.items[1]
  if not item or type(item.text)~='string' then
    error((label or 'script')..' printed no text: '..tostring(result.error or json.encode(result.items or {})):sub(1,300))
  end
  return json.decode(item.text)
end
local function array(value) return type(value)=='table' and value or {} end
local function q(value) return json.encode(value) end

-- ---------------------------------------------------------------------------------------------
-- 0. The inventory is exactly the seven names, and every one of them has a single tool behind it.
local RETIRED={
  read_many='read', grep_many='grep', session_many='session',
  search_messages_many='search_messages', symbol_source_many='graph',
  write_many='write', edit_many='edit',
}
local names={}
for name in pairs(RETIRED) do names[#names+1]=name end
table.sort(names)
check(#names==7,'the retired set is the seven batches that were in the catalogue: '..table.concat(names,','))

-- ---------------------------------------------------------------------------------------------
-- 1a. read_many -> Promise.all(read): same values, same request order, same per-item error.
local read_body=[[
  const items = ]]..q({{path=root..'/a.txt'},{path=root..'/b.txt'},{path=root..'/missing.txt'},{path=root..'/c.txt'}})..[[;
  const one = (p) => p.then(r => r, e => { try { const v = JSON.parse(String((e && e.message) || e)); return (v && typeof v === 'object') ? v : {error: String((e && e.message) || e)}; } catch (_) { return {error: String((e && e.message) || e)}; } });
  const out = await Promise.all(items.map(x => one(tools.read(x))));
  return out.map(r => ({content: r.content, version: typeof r.version === 'string', error: r.error || null,
                        eof: r.eof === true, path: typeof r.path === 'string'}));
]]
local reads=array(ask(read_body,'read parity'))
check(#reads==4,'one read per request, in request order: '..#reads)
check(reads[1].content=='alpha\n' and reads[2].content=='beta\n' and reads[4].content=='gamma\n','read contents are the files')
check(reads[1].version and reads[2].version,'every read keeps its version (the edit receipt input)')
check(reads[3].error~=nil and reads[3].content==nil,'a missing path is a per-item error, not a failed batch')
check(reads[3].error~='old_text_not_found','the per-item error is the primitive\'s own: '..tostring(reads[3].error))
-- The limit the batch had (1-8) does not exist in a script: a loop is bounded by the script's clock.
local many=array(ask('const items=[]; for(let i=0;i<12;i++) items.push('..q(root..'/a.txt')..');'
  ..' const out = await Promise.all(items.map(p => tools.read({path:p}))); return {n: out.length, all: out.every(r=>r.content==="alpha\\n")};','read 12'))
check(many.n==12 and many.all==true,'a script reads past the old eight-item ceiling: '..tostring(many.n)..' reads, all exact')
-- Reads run in parallel: three reads whose answers arrive in any order keep request order.
local parallel=array(ask('const out = await Promise.all(['..q(root..'/c.txt')..','..q(root..'/a.txt')..','..q(root..'/b.txt')..']'
  ..'.map(p => tools.read({path:p}).then(r => ({p: r.path, c: r.content})))); return out;','read parallel'))
check(parallel[1].c=='gamma\n' and parallel[2].c=='alpha\n' and parallel[3].c=='beta\n','parallel reads keep the request order in the answer')

-- 1b. grep_many -> Promise.all(grep): separately scoped searches answer separately.
local greps=array(ask('const items = '..q({{pattern='alpha',path=root},{pattern='beta',path=root}})..';'
  ..' const out = await Promise.all(items.map(x => tools.grep(x)));'
  ..' return out.map(r => ({count: r.count, files: (r.matches||[]).length, error: r.error||null}));','grep parity'))
check(#greps==2 and greps[1].count>=1 and greps[2].count>=1,'each scoped search answers its own count: '..q(greps))
check(greps[1].error==nil and greps[2].error==nil,'neither search is a failed batch')

-- 1c. session_many -> Promise.all(session): bounded ranges of several sessions.
local other=memory.start_session('','retire-many other',{user_id='master'})
memory.append_turn(other,{role='user',content='second session marker'})
local sessions=array(ask('const items = '..q({{session_id=sid,limit=5},{session_id=other,limit=5}})..';'
  ..' const out = await Promise.all(items.map(x => tools.session(x)));'
  ..' return out.map(r => ({messages: (r.messages||[]).length, error: r.error||null}));','session parity'))
check(#sessions==2,'one answer per session: '..#sessions)
check(sessions[2].messages>=1 and sessions[2].error==nil,'the second session answers its own messages')

-- 1d. search_messages_many -> Promise.all(search_messages): independent filters, independent answers.
memory.append_turn(sid,{role='user',content='retire-many alpha-note'})
memory.append_turn(sid,{role='user',content='retire-many beta-note'})
local searched=array(ask('const items = '..q({{query='alpha-note'},{query='beta-note'}})..';'
  ..' const out = await Promise.all(items.map(x => tools.search_messages(x)));'
  ..' return out.map(r => ({count: (r.matches||[]).length, error: r.error||null}));','search parity'))
check(#searched==2 and searched[1].count>=1 and searched[2].count>=1,'each history filter answers its own rows: '..q(searched))

-- 1e. symbol_source_many -> Promise.all(graph{symbol_source}): the same selector semantics, the same
-- delivered refusal when this node has no graph host (both forms answer it, so the parity still holds).
local symbol_source=ask('const one = (p) => p.then(r => r, e => ({error: String((e && e.message) || e)})); const items = '..q({{path='lua/core/json.lua',name='encode',line=1}})..';'
  ..' const out = await Promise.all(items.map(x => one(tools.graph({action:"symbol_source",path:x.path,name:x.name,line:x.line}))));'
  ..' return out.map(r => ({source: typeof r.source === "string", error: r.error||null}));','graph parity')
check(type(symbol_source)=='table' and #symbol_source==1,'one graph answer per selector')
check(symbol_source[1] and (symbol_source[1].source==true or type(symbol_source[1].error)=='string'),
  'a symbol source answers source text or the host\'s own refusal: '..q(symbol_source))
-- The graph action list the model reads no longer offers the batch action, and the tool refuses it.
local graph_schema
for _,item in ipairs(catalog) do if item['function'].name=='graph' then graph_schema=item['function'] end end
local offered=false
for _,action in ipairs((graph_schema.parameters.properties.action.enum or {})) do if action=='symbol_source_many' then offered=true end end
check(offered==false,'graph no longer offers the symbol_source_many action')

-- 1f. write_many/edit_many -> serial writes and edits. Effects are admitted one at a time: the second
-- call in the same script sees the first one's bytes, and a Promise.all of writes lands each exactly once.
local wrote=ask('await tools.write({path:'..q(root..'/w1.txt')..',content:"one\\n"});'
  ..' const seen = await tools.read({path:'..q(root..'/w1.txt')..'});'
  ..' await tools.write({path:'..q(root..'/w2.txt')..',content:"two\\n"});'
  ..' return {seen: seen.content};','serial write')
check(wrote.seen=='one\n','an effect completes before the next call in the same script starts')
check(host.read_file(root..'/w1.txt')=='one\n' and host.read_file(root..'/w2.txt')=='two\n','both writes are on disk')
local fanout=ask('const items = '..q({{path=root..'/f1.txt',content='1'},{path=root..'/f2.txt',content='2'},{path=root..'/f3.txt',content='3'}})..';'
  ..' const one = (p) => p.then(r => r, e => ({error: String((e && e.message) || e)})); const out = await Promise.all(items.map(x => one(tools.write(x)))); return {applied: out.filter(r=>r.ok).length};','write fanout')
check(fanout.applied==3 and host.read_file(root..'/f3.txt')=='3','every write in a Promise.all is applied once')
local edited=ask('const one = (p) => p.then(r => r, e => ({error: String((e && e.message) || e)})); const out = await Promise.all('..q({{path=root..'/a.txt',edits={{old_text='alpha',new_text='ALPHA'}}},{path=root..'/b.txt',edits={{old_text='beta',new_text='BETA'}}}})
  ..'.map(x => one(tools.edit(x)))); return out.map(r => ({applied: r.applied===true, echo: (r.replaced||[]).length, error: r.error||null}));','edit fanout')
check(edited[1] and edited[1].applied==true and edited[2].applied==true,'both edits applied with their own echo')
check(host.read_file(root..'/a.txt')=='ALPHA\n' and host.read_file(root..'/b.txt')=='BETA\n','the edited bytes are on disk')
local refused_edit=array(ask('const out = await Promise.all('..q({{path=root..'/c.txt',edits={{old_text='no-such-text',new_text='x'}}}})
  ..'.map(x => tools.edit(x).catch(e => ({threw: String(e && e.message || e)}))));'
  ..' return out.map(r => ({error: r.error || (r.threw ? "threw" : null)}));','edit guard'))
check(refused_edit[1] and refused_edit[1].error~=nil,'an anchor that is not there is refused, not silently applied')
check(host.read_file(root..'/c.txt')=='gamma\n','a refused edit changes nothing')

-- ---------------------------------------------------------------------------------------------
-- 2. The guards are the primitive's own, on both views.
-- A guest has no code mode at all, so the loop is not a way around the role ceiling.
local guest_code=tools.dispatch(memory,'codemode',{code='return 1;'},'guest',{session_id=sid,user_id='guest',role='guest'})
check(type(guest_code)=='table' and guest_code.error~=nil,'a guest is refused the loop itself: '..q(guest_code):sub(1,160))
-- The workspace binding is the primitive's own, inside the loop exactly as outside it: one dispatcher,
-- one refusal. (`workspace_path_outside_binding`, with the allowed roots named.)
local bound={session_id=sid,user_id='master',role='master'}
local bound_memory=setmetatable({session_workspace=function() return {required=true,state='allocated',worktree=root} end},
  {__index=function(_,key) return memory[key] end})
local outside='/etc/retire-many-outside.txt'
local direct_outside=tools.dispatch(bound_memory,'write',{path=outside,content='x'},'master',bound)
check(type(direct_outside)=='table' and direct_outside.error=='workspace_path_outside_binding',
  'the ordinary write refuses outside the binding: '..q(direct_outside):sub(1,160))
policy.pin(bound_memory,'master',bound)
local scripted_outside=tools.dispatch(bound_memory,'codemode',
  {code='try { const r = await tools.write({path:'..q(outside)..',content:"x"}); return {error: r.error || null}; }'
    ..' catch (e) { return {threw: String((e && e.message) || e)}; }'},'master',bound)
local scripted_text=json.encode(scripted_outside)
check(scripted_text:find('workspace_path_outside_binding',1,true)~=nil,
  'the same binding refuses the same call inside a script: '..scripted_text:sub(1,220))
check(host.read_file(outside)==nil,'the refused write created nothing')
-- The envelope a guest is shown, and every role/profile catalogue, has no batch left in it.
for _,role in ipairs({'master','guest'}) do
  for _,item in ipairs(tools.catalog(role)) do
    local name=item['function'].name
    check(not name:match('_many$'),'no batch name in the '..role..' catalogue: '..name)
    check(not tools.retired(name),'no retired name is also a catalogue name: '..name)
  end
end
local sub=dofile('lua/core/subagents.lua')
for _,listed in ipairs(sub.profiles()) do
  for _,name in ipairs(listed.allowed_tools or {}) do
    check(not name:match('_many$'),'no batch name in profile '..tostring(listed.id)..': '..name)
  end
end
-- The prompt envelope: the declared tools and the guidance, both model-visible.
local declared,mode=tools.envelope('master',ctx)
for _,item in ipairs(declared) do
  local name=(item['function'] or item).name or ''
  check(not name:match('_many$'),'no batch name in the declared envelope: '..name)
end
local prompt_text=json.encode({tools=declared,envelope=tools.envelope('guest',{session_id=sid,user_id='guest',role='guest'})})
check(prompt_text:find('read_many',1,true)==nil,'the envelope text names no retired batch')
check(prompt_text:find('symbol_source_many',1,true)==nil,'the envelope text names no retired symbol batch')

-- ---------------------------------------------------------------------------------------------
-- 3. One refusal, every route, and no working alias behind it.
local function exact(name)
  return 'retired: batch in code mode - Promise.all(items.map(x => tools.'..RETIRED[name]..'(x)))'
end
for _,name in ipairs(names) do
  local expected=exact(name)
  local direct=tools.dispatch(memory,name,{requests={{path=root..'/a.txt'}}},'master',ctx)
  check(type(direct)=='table' and direct.error==expected,'the dispatcher answers the one sentence for '..name..': '..q(direct))
  check(direct.effect=='none','a retired name has no effect: '..name)
  check(direct.results==nil and direct.applied==nil,'a retired name returns no batch result: '..name)
  local routed=tools.dispatch(memory,'tool_call',{name=name,arguments={requests={{path=root..'/a.txt'}}}}, 'master',ctx)
  check(type(routed)=='table' and (routed.error==expected or tostring(routed.error):find(expected,1,true)),
    'a tool_call to '..name..' answers the one sentence: '..q(routed))
  -- Inside a script the name is not a member of the sandbox's tool table at all, so the call is refused
  -- at the boundary (`not a function`) instead of running anything, and it never reaches a handler. The
  -- one sentence is what the script is told when it ASKS - `describeTool(name)` - which is the route a
  -- script has for a name it remembers and the catalogue no longer offers.
  local in_script=ask('try { const r = await tools.'..name..'({requests:[{path:'..q(root..'/a.txt')..'}]});'
    ..' return {error: (r && r.error) || null, ran: true}; } catch (e) { return {threw: String((e && e.message) || e)}; }',name)
  local text=tostring(in_script.error or in_script.threw or '')
  check(in_script.ran~=true and text~='','a script naming '..name..' runs nothing: '..text:sub(1,200))
  local described=ask('return await describeTool('..q(name)..');','describe '..name)
  check(type(described)=='table' and described.retired==expected,'describeTool('..name..') carries the sentence: '..q(described))
  check(described.error=='unknown_tool' and described.found==false and described.missing==true,
    'a retired name is never offered as callable: '..q(described))
  local found=ask('return await searchTools('..q(name)..');','search '..name)
  check(#array(found)==0,'searchTools finds no tool for a retired name: '..q(found))
end
-- No alias: the retired read did not read anything, and the retired write did not write.
check(host.read_file(root..'/never.txt')==nil,'a retired write created nothing')
local never=tools.dispatch(memory,'write_many',{requests={{path=root..'/never.txt',content='x'}}},'master',ctx)
check(never.error and host.read_file(root..'/never.txt')==nil,'the retired write still created nothing')

-- ---------------------------------------------------------------------------------------------
-- 4. GATE: the names are gone from the live prose too - docs and skills a model or an operator reads.
-- Two exceptions, each named: the dated records below (history, not offers - listed so the gate cannot
-- be satisfied by deleting evidence), and docs/BATCH-TOOLS.md, which is the mapping table that a reader
-- who still remembers an old name is sent to; the check below requires it to carry the one sentence.
local HISTORICAL={'docs/measurements/','docs/CODEMODE-PRESENTATION-JOURNAL.md','docs/CODEMODE-MODEL-BOUNDARY-JOURNAL.md',
  'docs/GRAPH-REPAIR-JOURNAL.md','docs/release/','reviews/','fixtures/','benchmarks/','docs/WHATSAPP-REVIEW.md',
  'docs/SUBSCRIPTION-BUFFER-RECOVERY.md','docs/BATCH-TOOLS.md'}
local function historical(path)
  for _,prefix in ipairs(HISTORICAL) do if path:sub(1,#prefix)==prefix then return true end end
  return false
end
local scanned,offered=0,{}
local repo_root=host.getenv('WASM_AGENT_LUA_ROOT')
local function scan(dir)
  local listed=json.decode(host.list_dir(dir) or '{}')
  for _,entry in ipairs(listed.entries or {}) do
    local path=dir..'/'..entry.name
    local rel=path:sub(#repo_root+2)
    if entry.kind=='dir' then
      if entry.name~='.git' and entry.name~='target' and entry.name~='node_modules' then scan(path) end
    elseif (entry.name:match('%.md$') or entry.name:match('%.json$')) and not historical(rel) then
      scanned=scanned+1
      local text=host.read_file(path) or ''
      for name in pairs(RETIRED) do
        if text:find(name,1,true) then offered[#offered+1]=path..' offers '..name end
      end
    end
  end
end
check(type(repo_root)=='string' and repo_root~='','a Lua root is where the docs live (WASM_AGENT_LUA_ROOT)')
scan(repo_root..'/docs'); scan(repo_root..'/skills')
check(#offered==0,'no live doc or skill offers a retired batch: '..table.concat(offered,', '))
-- The mapping doc is allowed to name them, and must teach the form rather than the name.
local mapping=host.read_file(repo_root..'/docs/BATCH-TOOLS.md') or ''
for _,name in ipairs(names) do
  for line in mapping:gmatch('[^\n]+') do
    if line:find(name,1,true) then
      check(line:find(RETIRED[name],1,true)~=nil,
        'the mapping doc names the single tool beside '..name..': '..line:sub(1,120))
    end
  end
end
check(mapping:find('retired: batch in code mode',1,true)~=nil,'the mapping doc quotes the one refusal')
check(scanned>20,'the prose scan actually read the docs and skills: '..scanned..' files')

print(('retire-many: %d checks, %d retired names, %d prose files scanned, refusal is one sentence'):format(checks,#names,scanned))
