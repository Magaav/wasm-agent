-- Benchmark-only host adapter. Native catalogue/schema/profile/routing/code-mode
-- checks still execute unchanged; raw filesystem/shell effects occur ONLY inside
-- a fresh networkless Docker tool container. No repaired runtime enters that box.
local M={}
function M.install(url)
 assert(url:match('^http://127%.0%.0%.1:%d+/%x+$'),'private sandbox RPC required')
 local json=dofile('lua/vendor/json.lua');local active=0;local controller_depth=0;local loading=false
 local private_root=tostring(host.getenv('WASM_AGENT_HOME') or ''):gsub('\\','/'):gsub('/+$',''):lower();assert(private_root~='','private benchmark home required')
 local function controller_io(fn,...)
  local old=active;active=0;controller_depth=controller_depth+1;local values=table.pack(pcall(fn,...));controller_depth=controller_depth-1;active=old
  if not values[1]then error(values[2])end;return table.unpack(values,2,values.n)
 end
 -- The trusted static module loader reads runtime code on the controller. It is
 -- not a model-facing file API and can never load a workspace-supplied Lua file.
 local load_module=dofile;local shared={}
 dofile=function(name)
  if shared[name] then return shared[name]end
  assert(type(name)=='string' and name:match('^lua/[%w_./-]+%.lua$') and not name:find('..',1,true),'untrusted benchmark module path')
  local old=active;local was_loading=loading;active=0;loading=true;local ok,value=pcall(load_module,name);loading=was_loading;active=old
  if not ok then error(value)end
  -- These trusted functions only address generated/hash-validated private
  -- artifacts, never a model-selected filesystem path. User read/write calls
  -- remain in the container, including attempts to read an artifact's host path.
  local exports=name=='lua/core/tool_output.lua' and {'store','read'} or name=='lua/core/read_batch.lua' and {'start','resume'} or name=='lua/core/memory.lua' and {'store_image'} or nil
  if exports then for _,key in ipairs(exports)do local fn=value[key];if fn then value[key]=function(...)return controller_io(fn,...)end end end end
  if name=='lua/core/tools.lua' or name=='lua/core/memory.lua' then shared[name]=value end
  return value
 end
 local function rpc(op,args)
  local response=json.decode(host.http('POST',url,json.encode({['content-type']='application/json'}),json.encode({op=op,args=args})))
  local value=response and json.decode(response.body or '')
  assert(value and value.ok,value and value.error or 'sandbox transport outcome unknown; no replay')
  return value.value
 end
 for _,name in ipairs({'read_file','write_file','path_kind','canonical_path','list_dir','grep','exec','read_image_base64'}) do
  local original=host[name]
  host[name]=function(...)
   if active>0 then return rpc(name,{...}) end
   if controller_depth>0 and not loading and (name=='read_file' or name=='write_file')then
    local p=tostring((...)):gsub('\\','/'):gsub('^//%?/',''):lower()
    assert(p:sub(1,#private_root+1)==private_root..'/','artifact storage outside private benchmark home')
   end
   if original then return original(...) end
   return nil
  end
 end
 -- Never index the controller's own files as a side effect of a sandbox write.
 for _,name in ipairs({'graph_index','graph_enqueue'})do
  local original=host[name];if original then host[name]=function(...)if active>0 then return nil end;return original(...)end end
 end
 local info=host.platform
 host.platform=function()local value=info();value.os='linux';value.shell='/bin/bash -c';value.cwd='/tmp/work';value.pathSeparator='/';return value end
 local tools=dofile('lua/core/tools.lua')
 local allowed={read=true,read_many=true,write=true,write_many=true,edit=true,edit_many=true,bash=true,ls=true,grep=true,grep_many=true,diagnose=true,tool_search=true,tool_call=true,capabilities=true,tool_result=true,codemode=true}
 local all=tools.all
 tools.all=function(role)local result={};for _,row in ipairs(all(role))do if allowed[row['function'].name]then result[#result+1]=row end end;return result end
 local effects={read=true,read_many=true,write=true,write_many=true,edit=true,edit_many=true,bash=true,ls=true,grep=true,grep_many=true}
 local original=tools.dispatch
 tools.dispatch=function(memory,name,args,role,ctx)
  if not allowed[name]then return {error='benchmark_tool_not_permitted:'..tostring(name),effect='none'} end
  -- A tool never falls through to an ambient host filesystem. Nested native
  -- dispatch keeps the same admission checks and increases this dynamic scope.
  local scoped=effects[name] and true or false
  if scoped then active=active+1 end
  local ok,result=pcall(original,memory,name,args,role,ctx)
  if scoped then active=active-1 end
  if not ok then error(result)end;return result
 end
 if tools.start_parallel_bash then tools.start_parallel_bash=function()return {}end end
 return {tools=tools,rpc=rpc,
  begin_tool=function(name)assert(allowed[name],'benchmark tool not permitted');if effects[name]then active=active+1 end end,
  end_tool=function(name)if effects[name]then assert(active>0,'benchmark tool scope underflow');active=active-1 end end}
end
return M
