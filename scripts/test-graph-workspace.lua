-- Real native graph + Git, with canonical/workspace intentionally different.
local json=dofile('lua/vendor/json.lua')
local tools=dofile('lua/core/tools.lua')
local audit=dofile('lua/core/patch_audit.lua')
local paths=dofile('lua/core/paths.lua')
local checks=0
local function check(value,why) assert(value,why);checks=checks+1 end
local function decode(raw) local value=json.decode(raw);assert(not value.error,tostring(value.error));return value end
local root=paths.data()..'/graph-workspace-fixture'
local canonical=root..'/canonical'
local owned=root..'/owned'
local sibling=root..'/sibling'
local function write(path,text) assert(host.write_file(path,text)) end
local function exec(command,cwd) local r=decode(host.exec(command,cwd,30));assert(r.code==0,r.stderr);return r.stdout end
write(canonical..'/src/existing.lua','function canonical_only() return 1 end\n')
write(owned..'/src/existing.lua','function before_shift() return 1 end\n')
write(sibling..'/src/other.lua','function sibling_only() return 1 end\n')
exec('git init --quiet',owned)
exec('git config core.longpaths true',owned)
exec('git -c core.autocrlf=false add .',owned)
exec('git -c user.name=Fixture -c user.email=fixture@invalid -c core.hooksPath=/dev/null commit --quiet -m fixture',owned)
write(owned..'/src/existing.lua','-- shifted workspace\n\nfunction owned_shifted() return 2 end\n')
write(owned..'/src/new.lua','function owned_new() return 3 end\n')
write(owned..'/src/extra.lua','function workspace_extra() return 5 end\n')
write(owned..'/src/callers.lua','function first() owned_new() end\nfunction second() owned_new() end\n')
local memory={session_workspace=function() return {required=true,state='allocated',worktree=owned} end}
local ctx={session_id='graph-fixture',run_id='graph-fixture',changes={files={}}}
local durable=dofile('lua/core/memory.lua');durable.setup()
durable.start_session('local','chat',{id=ctx.session_id,user_id='fixture',node_id='fixture'})
durable.set_session_worktree(ctx.session_id,owned)
local real=assert(host.canonical_path(owned))
local function same(value) return type(value)=='string' and value:gsub('\\','/')==real end
local function dispatch(args,mem) return tools.dispatch(mem or memory,'graph',args,'master',ctx) end
check(not dispatch({action='index',cwd=owned}).error,'explicit workspace index')
local impact=dispatch({action='impact',source='git',cwd=owned,direction='inbound',depth=1,limit=50})
check(not impact.error,'impact failed: '..json.encode(impact))
check(impact.coverage.gap_count==0,'false missing-file/line gaps: '..json.encode(impact.coverage))
check(same(impact.root),'explicit cwd must select actual indexed root')
local found={};for _,symbol in ipairs(impact.changed_symbols.rows) do found[symbol.name]=symbol end
check(found.owned_new~=nil,'new workspace-only symbol must not be missing')
check(found.owned_shifted and found.owned_shifted.line==3,'changed lines must map to workspace definition')
check(not found.canonical_only,'canonical symbol leaked into workspace impact')
local implicit=dispatch({action='impact',source='git',direction='inbound',depth=1,limit=50})
check(not implicit.error and same(implicit.root) and implicit.patch_fingerprint==impact.patch_fingerprint,'default session binding differs from explicit cwd')
local nested=dispatch({action='impact',source='git',cwd='src',direction='inbound',depth=1,limit=50})
check(not nested.error and same(nested.root) and nested.patch_fingerprint==impact.patch_fingerprint,'Git subdirectory did not normalize to top-level')
local native=dispatch({action='impact',source='native',direction='inbound'}, {
  session_workspace=memory.session_workspace})
check(native.error=='no_recorded_patch','empty native patch still refuses')
local changes=dofile('lua/core/changeset.lua').new()
dofile('lua/core/changeset.lua').record(changes,owned..'/src/new.lua',nil,host.read_file(owned..'/src/new.lua'))
ctx.changes=changes
native=dispatch({action='impact',source='native',direction='inbound',limit=50})
check(not native.error and same(native.root) and native.changed_symbols.total>=1,'native changeset indexed outside binding')
local git_audit=dispatch({action='audit',source='git'})
check(not git_audit.error and same(git_audit.root),'Git audit ignored workspace: '..json.encode(git_audit))
local native_audit=dispatch({action='audit',source='native'})
check(not native_audit.error and same(native_audit.root),'native audit ignored workspace')
local automatic=audit.git_audit(nil,{},ctx)
check(not automatic.error and same(automatic.root),'automatic audit did not resolve persisted session')
local selected=dispatch({action='search_symbols',name='owned_new'})
check(not selected.error and selected.results[1].name=='owned_new' and selected.results[1].path=='src/new.lua','symbol search ignored binding: '..json.encode(selected))
local selector=selected.results[1]
local source=dispatch({action='symbol_source',path=selector.path,name=selector.name,line=selector.line,kind=selector.kind})
check(not source.error and source.source:find('return 3',1,true),'selected source crossed trees')
local queried=dispatch({action='query',name='owned_shifted'})
check(not queried.error and queried.results[1].line==3,'query ignored binding')
local explained=dispatch({action='explain',name='owned_new'})
check(not explained.error and #explained.definitions[1].callers==2,'explain ignored binding')
local route=dispatch({action='path',from='first',to='owned_new'})
check(not route.error and route.found,'path ignored binding')
check(not dispatch({action='overview',aspects={'languages'}}).error,'overview binding')
check(not dispatch({action='caps'}).error,'capability binding')
check(not dispatch({action='stats'}).error,'stats binding')
local indexed=dispatch({action='index'})
check(not indexed.error and same(indexed.root),'index ignored binding')
local status=decode(host.graph_status(json.encode({root=owned})))
check(same(status.root) and status.ready,'root cache status not ready')
local canonical_status=decode(host.graph_status(json.encode({root=canonical})))
local sibling_status=decode(host.graph_status(json.encode({root=sibling})))
check(status.db~=canonical_status.db and status.db~=sibling_status.db,'distinct roots share mutable cache')
decode(host.graph_index(json.encode({root=canonical})))
check(decode(host.graph_query('canonical_only',json.encode({root=canonical})))[1].name=='canonical_only','canonical control query')
check(decode(host.graph_status(json.encode({root=owned}))).ready,'querying canonical invalidated owned cache')
write(owned..'/src/new.lua','function owned_new() return 4 end\n')
check(not decode(host.graph_status(json.encode({root=owned}))).ready,'workspace edit reported fresh')
check(decode(host.graph_status(json.encode({root=canonical}))).ready,'workspace edit invalidated canonical cache')
source=dispatch({action='symbol_source',path=selector.path,name=selector.name,line=selector.line,kind=selector.kind})
check(source.error=='graph_refresh_required' and source.refresh_required,'stale workspace read did not refuse')
check(not dispatch({action='index'}).error,'explicit incremental workspace refresh')
source=dispatch({action='symbol_source',path=selector.path,name=selector.name,line=selector.line,kind=selector.kind})
check(not source.error and source.source:find('return 4',1,true),'workspace refresh not observed')
local failed={session_workspace=function() return {required=true,state='failed',worktree=''} end}
check(dispatch({action='impact'},failed).error=='session_workspace_unavailable','failed binding fell back to runtime')
local missing={session_workspace=function() return {required=true,state='allocated',worktree=root..'/missing'} end}
check(dispatch({action='query',name='canonical_only'},missing).error:find('graph_root_unavailable',1,true),'missing binding fell back')
local throwing={session_workspace=function() error('lookup failed') end}
check(dispatch({action='stats'},throwing).error=='graph_workspace_lookup_failed','failed lookup fell back')
-- Cursor identity includes root even when source bytes/generation match exactly.
write(sibling..'/src/existing.lua',host.read_file(owned..'/src/existing.lua'))
write(sibling..'/src/new.lua',host.read_file(owned..'/src/new.lua'))
write(sibling..'/src/callers.lua',host.read_file(owned..'/src/callers.lua'))
-- Use an identical fresh pair, without sibling-only extra source.
local mirror=root..'/mirror'
for _,file in ipairs({'existing.lua','new.lua','extra.lua','callers.lua'}) do write(mirror..'/src/'..file,host.read_file(owned..'/src/'..file)) end
local request={root=owned,changes={{path='src/new.lua',lines={1}}},direction='inbound',depth=1,limit=1,max_bytes=24000}
local first=decode(host.graph_impact(json.encode(request)))
check(first.impact.next_cursor~=nil,'fixture has no cursor')
decode(host.graph_index(json.encode({root=mirror})))
request.root=mirror;request.cursor=first.impact.next_cursor
local crossed=json.decode(host.graph_impact(json.encode(request)))
check(crossed.error=='stale_or_mismatched_impact_cursor','cursor crossed identical-source roots')
print('graph workspace ok ('..checks..' checks)')
