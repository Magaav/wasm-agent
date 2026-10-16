-- Private deterministic Git fixtures. No model, runtime installation or production Git mutation.
local json=dofile('lua/vendor/json.lua')
local audit=dofile('lua/core/patch_audit.lua')
local graph=dofile('lua/core/graph.lua')
local checks=0
local function check(v,m) assert(v,m);checks=checks+1 end
local function q(s) return "'"..s:gsub("'","'\\''").."'" end
local root=assert(host.getenv('WA_REPAIR_ROOT'))
local function write(p,s) assert(host.write_file(p,s)) end
local function exec(cmd,cwd) local r=json.decode(host.exec(cmd,cwd,30));assert(r.code==0,json.encode(r));return r.stdout end
local function init(name,files)
 local p=root..'/'..name;for path,s in pairs(files) do write(p..'/'..path,s) end
 exec('git init -q',p);exec('git -c core.autocrlf=false add .',p)
 exec('git -c user.name=Fixture -c user.email=f@invalid -c core.hooksPath=/dev/null commit -qm fixture',p)
 return p
end
local function capture(p)
 local before=exec('git ls-files --stage -z',p);local head=exec('git rev-parse HEAD',p)
 local patch,e=audit.git_changes(p);check(patch~=nil,tostring(e))
 check(exec('git ls-files --stage -z',p)==before,'capture mutated index')
 check(exec('git rev-parse HEAD',p)==head,'capture moved HEAD')
 return patch
end
local function impact(patch,bytes)
 local r,e=graph.impact(patch,{max_bytes=bytes or 12000,limit=50});check(r~=nil,tostring(e));return r
end
local p=init('staged',{['src/code.lua']='function before() return 1 end\n'})
write(p..'/src/code.lua','function staged() return 2 end\n');exec('git add .',p)
local patch=capture(p..'/src');check(#patch.changes==1 and patch.changes[1].stage=='index','staged-only fact missing')
local r=impact(patch);check(r.coverage.changed_lines>0 and r.changed_symbols.total==1,'staged symbol not mapped')
check(r.root:gsub('\\','/')==host.canonical_path(p),'nested root wrong')
check(r.patch_facts.rows[1].index_source_version==host.sha256(host.read_file(p..'/src/code.lua')),'index exact source hash wrong')
write(p..'/src/code.lua','-- shift\n\nfunction mixed() return 3 end\n')
patch=capture(p);check(#patch.changes==2,'mixed stages collapsed')
local seen={};for _,c in ipairs(patch.changes) do seen[c.stage]=c end
check(seen.index.gap=='index_source_differs_from_worktree','index bytes silently treated as shifted worktree')
check(seen.worktree.source_version==host.sha256(host.read_file(p..'/src/code.lua')),'worktree hash wrong')
r=impact(patch);check(r.coverage.gap_count>0 and r.coverage.changed_lines>0,'mixed gap hidden')
write(p..'/src/code.lua','function before() return 1 end\n')
check(exec('git diff HEAD --stat',p)=='','cancellation fixture is not net-clean')
patch=capture(p);check(#patch.changes==2 and patch.changes[1].changed_line_count>0,'cancelled index facts lost')
r=impact(patch);check(r.coverage.changed_lines>0 and r.coverage.gap_count>0,'cancelled patch reported clean')
local w=init('unstaged',{['src/a.lua']='function first() return 1 end\n'})
write(w..'/src/a.lua','function second() return 2 end\n');patch=capture(w);check(#patch.changes==1 and patch.changes[1].stage=='worktree','unstaged-only missing')
check(impact(patch).changed_symbols.total==1,'unstaged mapping failed')
local linked=root..'/linked';exec('git worktree add --quiet --detach '..q(linked)..' HEAD',w)
write(linked..'/src/a.lua','function linked_only() return 4 end\n');exec('git add .',linked)
local linked_patch=capture(linked..'/src');local linked_result=impact(linked_patch)
check(linked_result.changed_symbols.rows[1].name=='linked_only','linked worktree root leaked')
check(impact(capture(w)).changed_symbols.rows[1].name=='second','sibling graph mutated')
local d=init('distinctions',{['old.lua']='function moved() end\n',['gone.lua']='function gone() end\n',['binary.dat']='a\0b',['meta.txt']='old\n'})
exec('git mv old.lua "new é.lua"; git rm -q gone.lua',d);write(d..'/binary.dat','c\0d');write(d..'/meta.txt','new\n');exec('git add .',d)
write(d..'/untracked.json','{"unsupported":true}\n');write(d..'/fresh.go','package demo\nfunc Fresh() {}\n')
patch=capture(d);local kinds={};for _,c in ipairs(patch.changes) do kinds[c.path]=c end
check(kinds['new é.lua'].old_path=='old.lua','rename identity lost')
check(kinds['gone.lua'].gap=='deleted_file','deletion not explicit')
check(kinds['binary.dat'].gap=='binary_file','binary not explicit')
check(kinds['untracked.json'].stage=='untracked','unsupported untracked hidden')
check(kinds['fresh.go'].stage=='untracked','untracked Go hidden')
r=impact(patch);check(r.coverage.changed_lines>0 and r.coverage.gap_count>=4,'distinction gaps not exposed')
local removal=init('removed-hunk',{['code.lua']='function safe() end\nfunction removed() end\n'})
write(removal..'/code.lua','function safe() end\n');exec('git add .',removal)
local removed_patch=capture(removal);check(removed_patch.changes[1].gap=='deleted_lines_without_current_source','deleted hunk invented a current-line anchor')
local removed_result=impact(removed_patch);check(removed_result.coverage.changed_lines==1 and removed_result.changed_symbols.total==0,'deleted hunk mapped unrelated remaining function')
local g=init('go',{['go.mod']='module example.test/demo\n',['main.go']='package demo\nfunc Old() {}\n'})
write(g..'/main.go','package demo\nfunc 新() string { return "é🙂" }\n');exec('git add .',g)
patch=capture(g);r=impact(patch);check(r.changed_symbols.rows[1].name=='新','Go staged symbol missing')
local rows,e=graph.search_symbols('新',{root=g});check(rows~=nil,tostring(e));local h=rows.results[1]
local exact=assert(graph.symbol_source(h,{root=g,source_version=h.source_version}));check(exact.source=='func 新() string { return "é🙂" }','Go exact Unicode source wrong')
write(g..'/main.go','package demo\nfunc 新() string { return "changed" }\n')
local stale,se=graph.symbol_source(h,{root=g,source_version=h.source_version});check(stale==nil and se=='symbol_source_changed','Go freshness fence missing: '..tostring(se))
local domains=init('domains',{['src/live.lua']='function resolve_route() return 1 end\n',
 ['reviews/evidence/src/live.lua']='function resolve_route() return 2 end\nfunction historic_only() end\n',
 ['tests/current.lua']='function active_test() resolve_route() end\n',
 ['src/import.lua']="local old = dofile('reviews/evidence/src/live.lua')\nfunction historical_import() old.resolve_route() end\n"})
local domain_hits=assert(graph.search_symbols('resolve_route',{root=domains,limit=10}))
check(domain_hits.results[1].path=='src/live.lua' and domain_hits.results[1].source_domain=='active','active discovery not favored/labeled')
local historic;for _,hit in ipairs(domain_hits.results) do if hit.source_domain=='evidence' then historic=hit end end
check(historic~=nil,'historical duplicate hidden');check(assert(graph.symbol_source(historic,{root=domains})).source:find('return 2',1,true),'explicit historical selector broken')
check(assert(graph.query('historic_only',{root=domains})).results[1].source_domain=='evidence','query discarded provenance')
local test_hits=assert(graph.search_symbols('active_test',{root=domains}));check(test_hits.results[1].source_domain=='active' and test_hits.results[1].source_role=='test','active test misclassified')
local history_edge=assert(graph.explain('historical_import',{root=domains})).definitions[1]
check(history_edge.source_domain=='active' and history_edge.use_evidence[1].dst_source_domain=='evidence','explicit historical dependency provenance lost')
-- The original 104-file delivery is staged in a separate private repository by the runner.
local real=host.getenv('WA_REPAIR_REAL104')
if real and real~='' then
 local real_patch=capture(real);check(#real_patch.changes==104,'real delivery manifest changed: '..#real_patch.changes)
 local first=impact(real_patch,6000);check(first.coverage.changed_lines>0 and first.coverage.gap_count>0,'real staged delivery returned zero/clean')
 local facts={};local page=first;local pages=0
 while true do
  for _,fact in ipairs(page.patch_facts.rows) do facts[#facts+1]=fact end
  pages=pages+1;check(pages<1000,'nonadvancing patch cursor')
  if not page.next_cursor then break end
  page=assert(graph.impact(real_patch,{max_bytes=6000,limit=50,cursor=page.next_cursor}))
 end
 check(#facts==104,'staged manifest not losslessly paged')
 print('REAL104 '..json.encode({changed_lines=first.coverage.changed_lines,gaps=first.coverage.gap_count,facts=#facts,pages=pages,root=first.root}))
end
print('graph repair ok ('..checks..' checks, 0 skips)')
