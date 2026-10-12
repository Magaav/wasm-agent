-- Model-free real-tree retrieval workload. No edits, provider, jobs or production DB.
local json=dofile('lua/vendor/json.lua');local graph=dofile('lua/core/graph.lua')
local root=assert(host.getenv('WA_RETRIEVAL_BENCH_ROOT'));local db=assert(host.getenv('WA_RETRIEVAL_BENCH_DB'))
local mode=assert(host.getenv('WA_RETRIEVAL_BENCH_MODE'));local t=host.now()
local index,err=graph.index({root=root,db=db});assert(index,type(err)=='table' and json.encode(err) or err)
local index_ms=(host.now()-t)*1000
local selectors={}
for _,name in ipairs({'M.tool_calls','read_snapshot'})do
 local found,error=graph.search_symbols(name,{root=root,db=db,limit=8});assert(found,error)
 local selected
 for _,candidate in ipairs(found.results)do if candidate.name==name then assert(not selected,'ambiguous fixture selector');selected=candidate end end
 assert(selected,'exact fixture symbol absent');selectors[#selectors+1]=selected
end
local requests={};for i=1,8 do local s=selectors[(i-1)%2+1];requests[i]={path=s.path,name=s.name,line=s.line,kind=s.kind,max_bytes=20000} end
local times,hashes,bytes={},{},{}
for pass=1,4 do
 local results={};local reply;t=host.now()
 if mode=='batch' then reply,err=graph.symbol_sources(requests,{root=root,db=db});assert(reply,err);results=reply.results
 else for i,request in ipairs(requests)do results[i],err=graph.symbol_source(request,{root=root,db=db,max_bytes=20000});assert(results[i],err)end;reply={results=results} end
 times[pass]=(host.now()-t)*1000;bytes[pass]=#json.encode(reply)
 local contents={};for i,item in ipairs(results)do assert(not item.error and item.eof,'complete exact source required');contents[i]=item.source end
 hashes[pass]=host.sha256(json.encode(contents));assert(hashes[pass]==hashes[1],'unstable source during workload')
end
local stats=assert(graph.stats({root=root,db=db}))
print(json.encode({ok=true,mode=mode,files=stats.files,nodes=stats.nodes,index_ms=index_ms,source_ms=times,reply_bytes=bytes,source_sha256=hashes[1],index_report=index,paid_calls=0,skipped=0,scope='one real-tree two-symbol eight-selector workload; not model-quality or token billing evidence'}))
