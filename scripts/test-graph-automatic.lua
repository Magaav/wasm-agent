-- Private, model-free native dispatch: no manual graph index, jobs or child runs.
-- The graph is a WASI component (docs/KERNEL.md, stream C): these checks are about its answers, so the
-- row installs the pinned component built from this tree into this test's own home first, and a machine
-- that could not build one gets a named SKIP rather than `component_not_installed` dressed as a failure.
local components = dofile('scripts/lib/test-components.lua')
local seeded, why = components.require('graph')
if not seeded then components.skip('graph-automatic', why); return end
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local changes=dofile('lua/core/changeset.lua')
local root=dofile('lua/core/paths.lua').data()..'/graph-fixture'
assert(host.write_file(root..'/marker.txt','private fixture'))
assert(type(host.graph_sources)=='function' and type(host.graph_notify)=='function','fresh graph capabilities required')
local owned=setmetatable({session_worktree=function()return root end,session_workspace=function()return {required=true,state='allocated',worktree=root}end},{__index=memory})
local ctx={session_id='graph-owned-fixture',user_id='master',changes=changes.new()}
local checks=0
local function check(value,label)checks=checks+1;assert(value,label)end
local function call(name,args,context)return tools.dispatch(owned,name,args,'master',context or ctx)end
local function graph(args)return call('graph',args)end
local irrelevant=json.decode(host.graph_notify(json.encode({root=root,path=root..'/marker.txt'})))
assert(irrelevant.ok and irrelevant.queued==false and irrelevant.reason=='not_indexable_source','ordinary scratch files must not index unrelated runtime source')
assert(host.write_file(root..'-outside.lua','function irrelevant() end\n'))
local outside=json.decode(host.graph_notify(json.encode({root=root,path=root..'-outside.lua'})))
assert(outside.ok and outside.queued==false and outside.reason=='outside_indexed_root','only the selected root owns its mutation hints')
local first=call('write',{path='a.lua',content='function alpha() return 1 end\n'})
local second=call('write',{path='b.lua',content='function beta() return alpha() end\n'})
check(first.ok and first.graph_index.ok and second.ok and second.graph_index.queued,'every native write queues its owned-root indexing')
local wait_command=dofile('lua/core/platform.lua').os()=='windows' and 'ping -n 2 127.0.0.1' or 'sleep 1'
local waited=json.decode(host.exec(wait_command,nil,5));assert(waited.code==0,'bounded fixture wait')
local background=json.decode(host.graph_status(json.encode({root=root})))
assert(background.ready and background.committed_revision>0,'successful native writes must really commit before any query admission')
local manual=host.graph_index;host.graph_index=function()error('navigation must not call manual indexing')end
local hit=graph({action='search_symbols',name='alpha',limit=3})
check(hit.count>=1 and hit.results[1].name=='alpha' and #hit.results[1].source_version==64,'automatic cold discovery and exact file selector version')
local required=hit.graph_snapshot.required_revision
check(required>0 and hit.graph_snapshot.committed_revision>=required,'required revision covered by atomic commit')
local source=graph({action='symbol_source',path='a.lua',name='alpha',line=1,source_version=hit.results[1].source_version})
check(source.source=='function alpha() return 1 end' and source.eof and #source.source_version==64,'exact committed source without reparse')
local path=graph({action='path',from='beta',to='alpha'})
check(path.found and #path.steps==2,'fresh resolved relationship')
local edited=call('edit',{path='a.lua',edits={{old_text='alpha() return 1',new_text='gamma() return 2'}}})
local edited_two=call('edit',{path='b.lua',edits={{old_text='alpha()',new_text='gamma()'}}})
check(edited.applied and edited.graph_index.ok and edited_two.applied,'every native edit queues its own mutation hint')
local after=graph({action='search_symbols',name='gamma',limit=3})
check(after.count>=1 and after.results[1].name=='gamma' and after.graph_snapshot.required_revision>required,'a native edit to graph needs no manual refresh')
-- The `symbol_source_many` action is retired: one call answers one definition, each with its own
-- pinned snapshot, and a selector that is not there is that call's own refusal. The guarantees the
-- batch test asserted one at a time are all still here; the batch's shared snapshot is gone with it.
local one=graph({action='symbol_source',path='a.lua',name='gamma',line=1})
local two=graph({action='symbol_source',path='b.lua',name='beta',line=1})
local absent=graph({action='symbol_source',path='absent.lua',name='absent',line=1})
check(one.source=='function gamma() return 2 end' and two.source=='function beta() return gamma() end','both exact definitions')
check(absent.error=='symbol_path_not_found','a selector that is not there is its own refusal, not a failed batch')
check(one.graph_snapshot and one.graph_snapshot.committed_revision>=one.graph_snapshot.required_revision and two.graph_snapshot,'every call admits its own pinned snapshot')
check(graph({action='symbol_source_many',requests={{path='a.lua',name='gamma',line=1}}}).error=='unknown_graph_action:symbol_source_many','the retired batch action is not an action')
check(call('symbol_source_many',{requests={{path='a.lua',name='gamma',line=1}}}).error==
  'retired: batch in code mode - Promise.all(items.map(x => tools.graph(x)))','the retired batch name answers the one sentence')
local stale=graph({action='symbol_source',path='a.lua',name='gamma',line=1,source_version=source.source_version})
check(stale.error=='symbol_source_changed' and stale.required_revision and stale.committed_revision and not stale.source,'stale source identity refuses with revision evidence')
local refused=call('graph',{action='symbol_source',path='a.lua',name='gamma',line=1},{session_id=ctx.session_id,subagent={allowed={symbol_source_many=true}},user_id='master'})
check(refused.error=='capability_not_in_profile:graph','a profile that names only the retired batch does not grant graph')
-- host.write_file is an external-to-dispatch native write; capture still detects it with watchers off.
assert(host.write_file(root..'/a.lua','function gamma() return 7 end\n'))
local external=graph({action='symbol_source',path='a.lua',name='gamma',line=1})
check(external.source=='function gamma() return 7 end' and external.source_version~=one.source_version,'content evidence, not Git diff or mtime')
local foreign=root..'-foreign';assert(host.write_file(foreign..'/a.lua','function gamma() return 99 end\n'))
check(type(two.source_version)=='string' and two.source_version~=external.source_version,'each call carries the identity of the bytes it answered')
host.graph_index=manual
local full=graph({action='index',force=true})
check(full.ok and full.indexed==2 and type(full.nodes)=='number' and type(full.resolved)=='number','full rebuild and legacy report fields retained')
local broken=setmetatable({session_workspace=function()return {required=true,state='failed',error='fixture binding failed'}end},{__index=memory})
local missing=tools.dispatch(broken,'graph',{action='search_symbols',name='gamma'},'master',ctx)
check(missing.error and not missing.results,'missing required binding never falls back to runtime')
print('graph automatic native ok ('..checks..' checks)')
