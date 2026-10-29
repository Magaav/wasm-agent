-- Pure metadata/typed invocation contracts; private files/DB, no providers/apps.
local json=dofile('lua/vendor/json.lua')
local contract=dofile('lua/core/json_contract.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local envelope=dofile('lua/core/envelope.lua')
local output=dofile('lua/core/tool_output.lua')
local agent=dofile('lua/core/agent.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local data=dofile('lua/core/paths.lua').data()
if host.getenv('WA_ITERATION_PHASE')=='restart' then
 local saved=json.decode(assert(host.read_file(data..'/group-restart.json')))
 local r=tools.dispatch(memory,'tool_call',{cursor=saved.cursor},'master',saved.ctx)
 check(r.complete and #r.results==1,'native group cursor reconstruction')
 check(json.encode(r.results[1].value)==saved.exact,'reconstruction preserves nested null/object/array types')
 check(#json.encode(r)<=output.MAX_BYTES,'reconstruction unchanged budget')
 print('envelope iteration restart ok ('..checks..' checks, 0 skipped)');return
end
local sid=memory.start_session('','typed capture fixture',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local root=dofile('lua/core/paths.lua').data()..'/iteration'
local function call(name,args,raw,c) c=c or ctx;c.tool_arguments_json=raw;local r=tools.dispatch(memory,name,args,'master',c);c.tool_arguments_json=nil;return r end
local schemas=tools.envelope('master',ctx)
check(#schemas==14,'lean thirteen declarations plus codemode; read_many and web are immediate')
local all=tools.all('master');local names={};for _,s in ipairs(schemas)do names[s['function'].name]=true end
check(names.recall and names.remember and names.session_worktree and names.read_many and not names.capabilities and not names.tool_result,'measured optional helpers deferred; memory and workspace remain immediate')
local env=host.getenv;host.getenv=function(k)if k=='WASM_AGENT_BOOTSTRAP_MODE' then return 'classic' end;return env(k)end
check(#envelope.bootstrap(all)==16,'classic bootstrap rollback')
host.getenv=function(k)if k=='WASM_AGENT_BOOTSTRAP_MODE' then return 'invalid' end;return env(k)end
check(not pcall(envelope.bootstrap,all),'invalid bootstrap visible');host.getenv=env
local system=agent.system_prompt('master','PRESERVE PROJECT POLICY','fixture/AGENTS.md',schemas,'progressive')
check(not system:find('Available tools:',1,true) and not system:find('Be concise in your responses',1,true),'no duplicated progressive tool index/style')
check(system:find('PRESERVE PROJECT POLICY',1,true) and system:find('ripgrep',1,true),'mandatory project/search policy retained')
check(not system:find('Never overwrite the installed UI',1,true),'UI procedure deferred rather than global')
local discovered=call('tool_search',{query='client',limit=1})
check(#discovered.guidance>0 and discovered.guidance[1]:find('installed UI',1,true),'local UI guidance comes with discovery')
local raw='{ "null": null, "object": {}, "array": [], "nested": [null,{},[]] }'
local ast=assert(contract.parse(raw));check(contract.compact(ast)=='{"null":null,"object":{},"array":[],"nested":[null,{},[]]}','exact JSON type distinctions')
check(contract.raw(raw,contract.at(ast,{'nested',2}))=='{}','exact raw fragment')
for _,bad in ipairs({'{"x":1,"x":2}','[1,]','{} trailing','{"x":}'})do check(not contract.parse(bad),'malformed/ambiguous JSON refuses')end
local schema={type='object',properties={n={type='integer',minimum=1,maximum=8},s={type='string',maxLength=3},a={type='array',minItems=1,items={type='boolean'}}},required={'n'},additionalProperties=false}
check(contract.validate(schema,'{"n":2,"s":"éé","a":[true]}')~=nil,'schema values/UTF-8 validate')
for _,bad in ipairs({'{}','{"n":1.5}','{"n":9}','{"n":2,"s":"long"}','{"n":2,"a":[]}','{"n":2,"a":[null]}','{"n":2,"extra":true}','{"n":1e999}'})do check(not contract.validate(schema,bad),'typed refusal before dispatch')end
check(not contract.validate({type='string',pattern='x'},'"x"'),'unsupported constraints refuse, not ignored')
check(not contract.validate({anyOf={{type='string'},{type='string',pattern='x'}}},'"x"'),'unsupported alternate cannot hide behind accepted branch')
check(not contract.validate({type='object',properties={optional={pattern='x'}}},'{}'),'unused unsupported property still refuses')
check(not contract.validate({enum={{}}},'{}'),'composite enum explicitly outside subset')
for _,bad in ipairs({'01','1.','1e','+1','0x1','-.1','1e999','"'..string.char(255)..'"','"\\uD800"','{\\11"x":1}'})do check(not contract.parse(bad),'strict numbers/UTF-8/JSON whitespace')end
check(contract.parse(' \t\r\n{"x":-0.2e+3}')~=nil,'valid JSON whitespace/exponent')
check(not contract.parse('{'..string.char(11)..'"x":1}'),'non-JSON whitespace refused')
check(contract.validate({anyOf={{type='string'},{type='null'}}},'null')~=nil,'supported explicit nullable alternative')
assert(host.write_file(root..'/a.txt','alpha'));assert(host.write_file(root..'/b.txt','beta'))
for _,name in ipairs({'read','grep','ls','capture_inspect','skill','write'})do check(call('tool_search',{query=name,limit=1}).loaded==1,'definition discovered '..name)end
local r=call('tool_call',{name='read',arguments={path=root..'/a.txt'},checked=true})
check(r.content=='alpha','typed single parity')
local realread=host.read_file;local reads=0;host.read_file=function(p)if p==root..'/a.txt' or p==root..'/b.txt' then reads=reads+1 end;return realread(p)end
r=call('tool_call',{calls={{name='read',arguments={path=root..'/a.txt'}},{name='read',arguments={path=77}}}})
check(r.error and r.index==2 and reads==0,'all types preflight before any read')
r=call('tool_call',{calls={{name='read',arguments={path=root..'/a.txt'}},{name='write',arguments={path=root..'/forbidden',content='x'}}}})
check(r.error=='batch_target_not_pure_read' and reads==0 and not realread(root..'/forbidden'),'no effectful batch')
r=call('tool_call',{calls={{name='read',arguments={path=root..'/a.txt'}},{name='read',arguments={path=root..'/b.txt'}}}})
check(r.typed and r.serial and r.executed==2 and r.results[1].content=='alpha' and r.results[2].content=='beta' and reads==2,'native serial read group parity')
local badraw='{"calls":[{"name":"read","arguments":{"path":'..json.encode(root..'/a.txt')..'}},null]}'
r=call('tool_call',json.decode(badraw),badraw)
check(r.error and reads==2,'null call slots cannot disappear or execute prefix')
host.read_file=realread
local routed=dofile('lua/core/routed_calls.lua');local catalog=json.decode(json.encode(tools.all('master')));local pure={calls={{name='read',arguments={path=root..'/a.txt'}},{name='read',arguments={path=root..'/b.txt'}}}}
local cancel=host.run_cancelled;host.run_cancelled=function()return '{"cancelled":true}'end
local issued=0;local stopped=routed.invoke(catalog,pure,ctx,'fixture',function()issued=issued+1;return {}end)
check(stopped.executed==0 and issued==0 and stopped.results[1].executed==false and stopped.results[2].executed==false,'cancellation leaves explicit unexecuted suffix');host.run_cancelled=cancel
stopped=routed.invoke(catalog,pure,ctx,'fixture',function()issued=issued+1;for _,s in ipairs(catalog)do if s['function'].name=='read' then s['function'].description=s['function'].description..' drift' end end;return {ok=true}end)
check(stopped.executed==1 and issued==1 and stopped.results[2].executed==false and stopped.results[2].error:find('definition_changed',1,true),'authority drift stops before second dispatch')
local duplicate='{"cursor":"a","cursor":"b"}'
check(call('tool_call',json.decode(duplicate),duplicate).error:find('json_duplicate_member',1,true),'cursor cannot bypass raw duplicate-member check')
check(call('tool_call',{name='read',arguments={path=root..'/a.txt'},checked='true'}).error=='checked_boolean_required','typed flag shape visible')
check(call('tool_call',{name='read',arguments={},calls={}}).error=='tool_call_forms_are_exclusive','exclusive route forms')
check(call('tool_call',{name='read',arguments={path=2},checked=true}).error:find('schema_type',1,true),'typed scalar refusal')
local denied={session_id=sid,user_id='master',subagent={allowed={tool_call=true,tool_search=true}}}
check(call('tool_call',{calls={{name='read',arguments={path=root..'/a.txt'}}}},nil,denied).error~=nil,'profile ceiling on target')
check(tools.dispatch(memory,'capture_inspect',{path=root..'/a.txt'},'guest').error~=nil,'operator capture permission retained')
local request={messages={{role='system',content=string.rep('instruction ',5000)}},tools={{name='read',parameters={type='object'}}}}
assert(host.write_file(root..'/capture.json',json.encode({requests={request,request},extra='ORIGINAL MUST REMAIN'})))
r=call('capture_inspect',{path=root..'/capture.json'})
check(r.ok and r.total==2 and r.has_more and #json.encode(r)<8192,'large raw capture becomes bounded metadata')
check(realread(r.full_result.path)==realread(root..'/capture.json'),'full capture byte identity retained')
local nextpage=call('capture_inspect',{path=root..'/capture.json',offset=r.next_offset,snapshot=r.snapshot})
check(nextpage.complete and nextpage.results[1].index==2,'snapshot metadata continuation')
check(call('capture_inspect',{path=root..'/capture.json',offset=1}).error=='capture_snapshot_required','no unbound continuation')
assert(host.write_file(root..'/capture.json','{"requests":[]}'))
check(call('capture_inspect',{path=root..'/capture.json',snapshot=r.snapshot}).error=='capture_snapshot_changed','changed capture refusal')
local shape='{"requests":[{"messages":[{"role":"system","content":"literal"}],"tools":[{"name":"shape","parameters":{"x":null,"o":{},"a":[]}}]}]}'
assert(host.write_file(root..'/shapes.json',shape))
local exact=call('capture_inspect',{path=root..'/shapes.json',view='tool'})
check(json.encode(exact.value)=='{"name":"shape","parameters":{"x":null,"o":{},"a":[]}}','selected exact JSON null/empty shapes')
check(call('capture_inspect',{path=root..'/shapes.json',view='message'}).value~=nil,'exact message view')
assert(host.write_file(root..'/duplicate.json','{"requests":[],"requests":[]}'))
check(call('capture_inspect',{path=root..'/duplicate.json'}).error~=nil,'ambiguous capture refused with original')
local exactcapture=host.getenv('WA_EXACT_CAPTURE')
if exactcapture then
 local expected=assert(realread(exactcapture));assert(host.write_file(root..'/historical.json',expected))
 local viewed=call('capture_inspect',{path=root..'/historical.json'})
 check(viewed.ok and viewed.total==6 and viewed.has_more and #json.encode(viewed)<8192,'exact historical first-envelope metadata has no oversized reply')
 local stages=call('capture_inspect',{path=root..'/historical.json',limit=8})
 check(stages.complete and #json.encode(stages)<=output.MAX_BYTES,'all historical stage metadata fits the unchanged total budget')
 check(realread(viewed.full_result.path)==expected,'exact historical capture preserved')
else error('exact_capture_fixture_required')end
-- Cached oversized groups do not refetch source or cross tool/account scopes.
assert(host.write_file(root..'/large-a.txt',string.rep('A',30000)));assert(host.write_file(root..'/large-b.txt',string.rep('B',30000)))
r=call('tool_call',{calls={{name='read',arguments={path=root..'/large-a.txt'}},{name='read',arguments={path=root..'/large-b.txt'}}}})
check(r.next_cursor and #json.encode(r)<=output.MAX_BYTES,'whole grouped results page inside unchanged budget')
assert(host.write_file(root..'/large-b.txt','changed'))
local resumed=call('tool_call',{cursor=r.next_cursor})
check(resumed.results[1].content==string.rep('B',30000) and resumed.complete,'group cursor is captured retrieval, not reread')
check(call('read_many',{cursor=r.next_cursor}).error=='batch_cursor_tool_changed','cursor cannot cross tool owner')
check(call('tool_call',{cursor=r.next_cursor},nil,{session_id=sid,user_id='other'}).error~=nil,'cursor account fence')
local large_shape='{"name":"large","parameters":{"x":null,"o":{},"a":[],"padding":'..json.encode(string.rep('x',26000))..'}}'
assert(host.write_file(root..'/large-shapes.json','{"requests":[{"tools":['..large_shape..']}]}'))
local grouped=call('tool_call',{calls={{name='read',arguments={path=root..'/large-a.txt'}},{name='capture_inspect',arguments={path=root..'/large-shapes.json',view='tool'}}}})
check(grouped.next_cursor~=nil,'exact shaped view enters cached group suffix')
assert(host.write_file(root..'/large-shapes.json','changed after capture'))
local shaped=call('tool_call',{cursor=grouped.next_cursor})
check(shaped.complete and json.encode(shaped.results[1].value)==large_shape,'cached group preserves null/object/array types without reread')
assert(host.write_file(data..'/group-restart.json',json.encode({cursor=grouped.next_cursor,ctx=ctx,exact=large_shape})))
print('envelope iteration ok ('..checks..' checks, 0 skipped; private native data, no provider/app calls)')
