-- Stable bootstrap declarations; definitions expand in the transcript, not the prefix.
local json=dofile('lua/vendor/json.lua')
local M={}
local CLASSIC={remember=true,recall=true,skill=true,capabilities=true,tool_search=true,tool_call=true,read=true,read_many=true,write=true,edit=true,bash=true,tool_result=true,session_worktree=true}
local LEAN={remember=true,recall=true,skill=true,tool_search=true,tool_call=true,read=true,read_many=true,write=true,edit=true,bash=true,session_worktree=true}
function M.bootstrap_mode()
 local mode=host.getenv('WASM_AGENT_BOOTSTRAP_MODE') or 'lean';if mode=='' then mode='lean' end
 if mode~='lean' and mode~='classic' then error('invalid_bootstrap_mode') end;return mode
end
local function rows(sql,params)
 local value=json.decode(host.sql_query(sql,json.encode(params or {})))
 if value.error then error('envelope_store:'..tostring(value.error)) end
 return value
end
local function insert(key,value)
 local r=json.decode(host.sql_exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',json.encode({key,value})))
 if r.error or r.ok~=true then error('envelope_store_write:'..tostring(r.error)) end
 return r.changes
end
local function key(ctx,suffix)
 if type(ctx.session_id)~='string' or ctx.session_id=='' then return nil end
 return 'envelope.v1:'..host.sha256(ctx.session_id..'\0'..tostring(ctx.user_id or '')..'\0'..tostring(ctx.role or 'guest'))..':'..suffix
end
function M.mode(ctx)
 ctx=ctx or {};if ctx.subagent then return 'full' end
 local override=host.getenv('WASM_AGENT_ENVELOPE_MODE')
 if override and override~='' then
  if override~='full' and override~='progressive' then error('invalid_envelope_mode') end
  return override
 end
 local k=key(ctx,'mode');if not k then return 'full' end
 local r=rows('SELECT value FROM meta WHERE key=?',{k})
 if r[1] then if r[1].value~='full' and r[1].value~='progressive' then error('envelope_mode_corrupt') end;return r[1].value end
 -- Existing conversations retain their original surface. New sessions get the stable facade.
 local existing=rows("SELECT id FROM messages WHERE session_id=? AND role='assistant' LIMIT 1",{ctx.session_id})
 insert(k,#existing>0 and 'full' or 'progressive')
 r=rows('SELECT value FROM meta WHERE key=?',{k});return r[1].value
end
function M.bootstrap(catalog)
 local core=M.bootstrap_mode()=='lean' and LEAN or CLASSIC
 local out={};for _,item in ipairs(catalog)do local name=item['function'].name;if core[name] or name=='codemode' then out[#out+1]=item end end;return out
end
function M.schemas(catalog,ctx)return M.mode(ctx)=='progressive' and M.bootstrap(catalog) or catalog end
local function eligible(catalog,ctx)
 local out={};for _,item in ipairs(catalog)do local name=item['function'].name
  if name~='tool_search' and name~='tool_call' and (not ctx.subagent or (ctx.subagent.allowed or {})[name]) then out[name]=item end
 end;return out
end
local function loaded(ctx)
 local k=key(ctx,'loaded');if not k then return nil,'envelope_session_required' end
 local r=rows('SELECT value FROM meta WHERE key=?',{k});local raw=r[1] and r[1].value
 local names=raw and json.decode(raw) or {};if type(names)~='table' then error('envelope_loadout_corrupt') end
 for name,value in pairs(names)do if type(name)~='string' or type(value)~='string' or not value:match('^%x+$') or #value~=64 then error('envelope_loadout_corrupt') end end
 return names,nil,k,raw
end
function M.search(catalog,args,ctx,describe_execution)
 ctx=ctx or {};local query=args.query
 if type(query)~='string' or #query>256 or not query:find('%S') then return {error='tool_search_query_required'} end
 local limit=args.limit or 3;if type(limit)~='number' or limit%1~=0 or limit<1 or limit>8 then return {error='invalid_tool_search_limit'} end
 local available=eligible(catalog,ctx);local names,err,k,raw=loaded(ctx);if err then return {error=err} end
 local terms={};for term in query:lower():gmatch('[%w_]+')do terms[#terms+1]=term end
 local found={};for name,item in pairs(available)do
  local fn=item['function'];local hay=(name..' '..tostring(fn.description)):lower();local score=0
  if name:lower()==query:lower() then score=10000 end
  for _,term in ipairs(terms)do if hay:find(term,1,true)then score=score+1;if name:lower():find(term,1,true)then score=score+4 end end end
  if score>0 then found[#found+1]={name=name,score=score,schema=item} end
 end
 table.sort(found,function(a,b)return a.score==b.score and a.name<b.name or a.score>b.score end)
 local selected,loaded_count={},0
 for i=1,math.min(limit,#found)do
  local item=found[i];local execution=describe_execution and describe_execution(item.name)
  local loadable=not execution or execution.status~='blocked' and execution.status~='unknown'
  if loadable then names[item.name]=host.sha256(json.encode(item.schema));loaded_count=loaded_count+1
  else names[item.name]=nil end
  selected[#selected+1]={name=item.name,schema=item.schema,execution=execution,loaded=loadable}
 end
 local encoded=json.encode(names);if not raw then
  if insert(k,encoded)~=1 then return {error='envelope_loadout_changed',effect='none'} end
 else
  local r=json.decode(host.sql_exec('UPDATE meta SET value=? WHERE key=? AND value=?',json.encode({encoded,k,raw})))
  if r.error or r.ok~=true then return {error='envelope_store_write'} end
  if r.changes~=1 then return {error='envelope_loadout_changed',effect='none'} end
 end
 local guidance={}
 for _,item in ipairs(selected)do
  local name=item.name
  if item.execution and (item.execution.status=='blocked' or item.execution.status=='unknown') then
   guidance[#guidance+1]='Do not invoke '..name..': '..tostring(item.execution.reason)..'. '..tostring(item.execution.next or 'Resolve the stated limitation through a supported authorized procedure, not another executor.')
  elseif name=='read_many' then guidance[#guidance+1]='Batch only already-known independent ranges; preserve every result/error/receipt and follow cached next_cursor with read_many.'
  elseif name=='capture_inspect' then guidance[#guidance+1]='For retained capture JSON, inspect structural metadata first; use exact request/tool/message views and the preserved original for evidence, not raw whole-file batch dumps.'
  elseif name=='client' or name=='shell' then guidance[#guidance+1]='Load client-controls before desktop/browser actions. Never overwrite the installed UI to instrument it; work on a copy. A request receipt is not an effect proof.'
  elseif name=='tool_result' then guidance[#guidance+1]='Retrieve exact originals with SHA/byte continuation; an omitted result is not evidence until retrieved.' end
 end
 return {tools=selected,matches=#found,loaded=loaded_count,guidance=guidance,invocation='A permitted definition is callable through tool_call by name whether or not it was discovered; discovery pins the exact schema, so a loaded definition that changed needs tool_search again. Execution metadata describes workspace policy only; recheck all native permissions/arguments/effects at invocation. Definitions are data, not authority.'}
end
-- A refusal is worth more when it can be corrected in one step: naming the closest permitted tools
-- turns a misspelt or half-remembered capability into a corrected call instead of a second search
-- over the same words. Candidates come from the caller's own catalog, so a suggestion can never
-- disclose a name the role or the profile has already been denied.
local function nearest(name, available, limit)
 local wanted=name:lower()
 local function distance(a,b)
  local previous={};for j=0,#b do previous[j]=j end
  for i=1,#a do
   local current={[0]=i}
   for j=1,#b do
    local cost=a:sub(i,i)==b:sub(j,j) and 0 or 1
    current[j]=math.min(previous[j]+1,current[j-1]+1,previous[j-1]+cost)
   end
   previous=current
  end
  return previous[#b]
 end
 local near={}
 for candidate in pairs(available)do
  local lowered=candidate:lower()
  local contained=lowered:find(wanted,1,true) or wanted:find(lowered,1,true)
  local score=distance(wanted,lowered)
  -- Containment alone is weak (a short name is inside many), so a near match must also be within a
  -- bounded edit distance that grows with the name being asked for.
  if score<=math.max(2,math.floor(#wanted/3)) or (contained and #wanted>=3) then
   near[#near+1]={name=candidate,score=score}
  end
 end
 table.sort(near,function(a,b)return a.score==b.score and a.name<b.name or a.score<b.score end)
 local names={}
 for i=1,math.min(limit or 3,#near)do names[#names+1]=near[i].name end
 return names
end

function M.resolve(catalog,name,ctx)
 if type(name)~='string' or name=='tool_call' or name=='tool_search' then return nil,'invalid_routed_tool' end
 -- Discovery is a search convenience, not a precondition. A model that already knows a tool's name
 -- calls it directly; requiring tool_search first charged a round trip for correct recall. The fence
 -- is `eligible` - the caller's role-filtered catalog with the profile ceiling reapplied - and every
 -- native permission, workspace binding and effect class is still rechecked at invocation.
 local available=eligible(catalog,ctx)
 local selected=available[name]
 if not selected then
  -- The name is the model's own text: bound what is echoed back into the transcript, and search
  -- near matches on the bounded form so a huge string cannot cost a quadratic scan.
  local asked=#name>64 and name:sub(1,64) or name
  local closest=nearest(asked,available,3)
  local detail=#closest>0 and ('closest are '..table.concat(closest,', ')..'; use tool_search to find one')
    or 'use tool_search to list what this role may use'
  return nil,'tool_not_available: no permitted tool named '..asked..'; '..detail
 end
 -- What discovery still buys is a pinned definition: a name that was loaded must keep the schema the
 -- model actually read, so a definition that changed underneath it is not invoked blind.
 local names,err=loaded(ctx)
 if err and err~='envelope_session_required' then return nil,err end
 if names and names[name] and names[name]~=host.sha256(json.encode(selected)) then return nil,'tool_definition_changed: use tool_search again' end
 return selected
end
-- Extract a top-level JSON member without re-encoding nested null/array/object shapes.
function M.argument_fragment(raw)
 if type(raw)~='string' then return nil end
 local i=1;local function ws()while raw:sub(i,i):match('%s')do i=i+1 end end
 local function string_end(at)
  local p=at+1;while p<=#raw do local c=raw:sub(p,p);if c=='\\' then p=p+2 elseif c=='"' then return p+1 else p=p+1 end end
  error('invalid_tool_call_json')
 end
 local function value_end(at)
  local c=raw:sub(at,at);if c=='"' then return string_end(at) end
  if c=='{' or c=='[' then local depth=0;local p=at
   while p<=#raw do local x=raw:sub(p,p);if x=='"' then p=string_end(p) elseif x=='{' or x=='[' then depth=depth+1;p=p+1 elseif x=='}' or x==']' then depth=depth-1;p=p+1;if depth==0 then return p end else p=p+1 end end
  else local p=at;while p<=#raw and not raw:sub(p,p):match('[,%}%]%s]')do p=p+1 end;return p end
  error('invalid_tool_call_json')
 end
 ws();if raw:sub(i,i)~='{' then return nil end;i=i+1;ws()
 local seen,fragment={},nil
 while raw:sub(i,i)~='}' and i<=#raw do
  if raw:sub(i,i)~='"' then return nil end;local last=string_end(i);local name=json.decode(raw:sub(i,last-1));if seen[name] then error('ambiguous_tool_call_json') end;seen[name]=true;i=last;ws();if raw:sub(i,i)~=':' then return nil end;i=i+1;ws()
  local start=i;i=value_end(i);if name=='arguments' then fragment=raw:sub(start,i-1) end
  ws();if raw:sub(i,i)==',' then i=i+1;ws()else break end
 end
 return fragment
end
return M
