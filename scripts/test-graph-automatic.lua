-- Private, model-free native dispatch: no manual graph index, jobs or child runs.
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
local first=call('write_many',{requests={{path='a.lua',content='function alpha() return 1 end\n'},{path='b.lua',content='function beta() return alpha() end\n'}}})
check(first.ok and first.applied==2 and first.results[1].graph_index.ok and first.results[2].graph_index.queued,'writes queue owned-root indexing')
local wait_command=dofile('lua/core/platform.lua').os()=='windows' and 'ping -n 2 127.0.0.1 >NUL' or 'sleep 1'
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
local edited=call('edit_many',{requests={{path='a.lua',edits={{old_text='alpha() return 1',new_text='gamma() return 2'}}},{path='b.lua',edits={{old_text='alpha()',new_text='gamma()'}}}}})
check(edited.ok and edited.applied==2 and edited.results[1].graph_index.ok,'edit_many queues every successful mutation')
local after=graph({action='search_symbols',name='gamma',limit=3})
check(after.count>=1 and after.results[1].name=='gamma' and after.graph_snapshot.required_revision>required,'edit_many to graph needs no manual refresh')
local batch=call('symbol_source_many',{requests={{path='a.lua',name='gamma',line=1},{path='b.lua',name='beta',line=1},{path='absent.lua',name='absent',line=1}}})
check(batch.failed==1 and batch.succeeded==2 and batch.results[3].error=='symbol_path_not_found','per-item source failures preserve siblings')
check(batch.results[1].source=='function gamma() return 2 end' and batch.results[2].source=='function beta() return gamma() end','both exact definitions')
check(#batch.graph_snapshots==1 and batch.results[1].graph_snapshot_index==batch.results[2].graph_snapshot_index and batch.graph_snapshots[1].committed_revision>=batch.graph_snapshots[1].required_revision,'one root admission and pinned batch snapshot, without duplicated status')
local alias=graph({action='symbol_source_many',requests={{path='a.lua',name='gamma',line=1},{path='b.lua',name='beta',line=1}}})
check(alias.ok and alias.results[1].source==batch.results[1].source and alias.results[2].source_version==batch.results[2].source_version,'graph and compatibility source batches share the backend')
local stale=graph({action='symbol_source',path='a.lua',name='gamma',line=1,source_version=source.source_version})
check(stale.error=='symbol_source_changed' and stale.required_revision and stale.committed_revision and not stale.source,'stale source identity refuses with revision evidence')
check(call('symbol_source_many',{requests={{path='a.lua',name='gamma',line=1,action='index'}}}).failed==1,'source batch cannot smuggle an effect')
local refused=call('symbol_source_many',{requests={{path='a.lua',name='gamma',line=1}}},{session_id=ctx.session_id,subagent={allowed={symbol_source_many=true}},user_id='master'})
check(refused.error=='capability_not_in_profile:graph','both profile permissions remain mandatory')
-- host.write_file is an external-to-dispatch native write; capture still detects it with watchers off.
assert(host.write_file(root..'/a.lua','function gamma() return 7 end\n'))
local external=graph({action='symbol_source',path='a.lua',name='gamma',line=1})
check(external.source=='function gamma() return 7 end' and external.source_version~=batch.results[1].source_version,'content evidence, not Git diff or mtime')
local foreign=root..'-foreign';assert(host.write_file(foreign..'/a.lua','function gamma() return 99 end\n'))
local mixed=call('symbol_source_many',{requests={{path='a.lua',name='gamma',line=1},{cwd=foreign,path='a.lua',name='gamma',line=1}}})
check(mixed.ok and mixed.results[1].source~=mixed.results[2].source and #mixed.graph_snapshots==2 and mixed.graph_snapshots[1].root~=mixed.graph_snapshots[2].root and mixed.graph_snapshots[1].db~=mixed.graph_snapshots[2].db,'independent root/cache groups preserve exact sources')
host.graph_index=manual
local full=graph({action='index',force=true})
check(full.ok and full.indexed==2 and type(full.nodes)=='number' and type(full.resolved)=='number','full rebuild and legacy report fields retained')
local broken=setmetatable({session_workspace=function()return {required=true,state='failed',error='fixture binding failed'}end},{__index=memory})
local missing=tools.dispatch(broken,'graph',{action='search_symbols',name='gamma'},'master',ctx)
check(missing.error and not missing.results,'missing required binding never falls back to runtime')
print('graph automatic native ok ('..checks..' checks)')
