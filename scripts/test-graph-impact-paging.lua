-- Actual native graph facade, oversized diagnostics, private source only.
local json=dofile('lua/vendor/json.lua')
local graph=dofile('lua/core/graph.lua')
local paths=dofile('lua/core/paths.lua')
local root=paths.data()..'/impact-paging'
local source={};local lines={}
for i=1,28 do
 source[#source+1]='local setting_'..i..' = '..i
 source[#source+1]='function changed_'..i..'() unknown_'..i..'(); return '..i..' end'
 lines[#lines+1]=i*2-1;lines[#lines+1]=i*2
end
assert(host.write_file(root..'/source.lua',table.concat(source,'\n')..'\n'))
for i=1,8 do assert(host.write_file(root..'/caller_'..i..'.lua','function caller_'..i..'() return changed_'..i..'() end\n'))end
local indexed,index_error=graph.index({root=root});assert(indexed,index_error)
local patch={root=root,changes={{path='source.lua',lines=lines}}}
local all,err=graph.impact(patch,{direction='inbound',depth=1,limit=200,max_bytes=200000})
assert(all,err);assert(not all.truncated)
local checks=0
local function ok(v,msg)assert(v,msg);checks=checks+1 end
for _,budget in ipairs({2048,12000,24000})do
 local cursor;local pages=0;local rows={{},{},{},{}}
 repeat
  local page,error=graph.impact(patch,{direction='inbound',depth=1,limit=200,max_bytes=budget,cursor=cursor})
  ok(page~=nil,error);ok(#json.encode(page)<=budget,'whole Lua JSON bound')
  pages=pages+1;ok(pages<200,'nonadvancing cursor')
  for i,stream in ipairs({page.impact.rows,page.changed_symbols.rows,page.coverage.gaps,page.coverage.unresolved_calls.rows})do
   for _,row in ipairs(stream)do rows[i][#rows[i]+1]=row end
  end
  ok(page.next_cursor==page.impact.next_cursor,'compatibility cursor')
  local next=page.next_cursor;ok(next==nil or next~=cursor,'cursor advances');cursor=next
 until not cursor
 for i,stream in ipairs({all.impact.rows,all.changed_symbols.rows,all.coverage.gaps,all.coverage.unresolved_calls.rows})do
  ok(json.encode(rows[i])==json.encode(stream),'all exact rows once, stream '..i)
 end
end
print(json.encode({ok=true,checks=checks,skipped=0,paid_calls=0,scope='native impact full-response pagination'}))
