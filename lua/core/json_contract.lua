-- Structural JSON evidence and opt-in schema validation; no evaluator or effects.
local json=dofile('lua/vendor/json.lua')
local M={}
function M.parse(text)
 if type(text)~='string' then return nil,'json_text_required' end
 local p=1
 local function ws()while text:sub(p,p):match('[ \t\r\n]')do p=p+1 end end
 local function str()
  local start=p;p=p+1
  while p<=#text do local c=text:sub(p,p)
   if c=='\\' then p=p+2 elseif c=='"' then p=p+1;local decoded=json.decode(text:sub(start,p-1));if not utf8.len(decoded) then error('json_utf8_invalid') end;return decoded else p=p+1 end
  end
  error('json_string_unterminated')
 end
 local value
 value=function(depth)
  if depth>64 then error('json_depth_exceeded') end
  ws();local start=p;local c=text:sub(p,p);local n={first=start}
  if c=='{' then
   n.kind='object';n.children={};n.keys={};p=p+1;ws()
   if text:sub(p,p)~='}' then while true do
    if text:sub(p,p)~='"' then error('json_member_required') end
    local key=str();if n.children[key] then error('json_duplicate_member') end
    ws();if text:sub(p,p)~=':' then error('json_colon_required') end;p=p+1
    n.children[key]=value(depth+1);n.keys[#n.keys+1]=key;ws()
    local nextc=text:sub(p,p);if nextc=='}' then break end;if nextc~=',' then error('json_separator_required') end;p=p+1;ws()
   end end
   if text:sub(p,p)~='}' then error('json_object_unterminated') end;p=p+1
  elseif c=='[' then
   n.kind='array';n.children={};p=p+1;ws()
   if text:sub(p,p)~=']' then while true do
    n.children[#n.children+1]=value(depth+1);ws();local nextc=text:sub(p,p)
    if nextc==']' then break end;if nextc~=',' then error('json_separator_required') end;p=p+1
   end end
   if text:sub(p,p)~=']' then error('json_array_unterminated') end;p=p+1
  elseif c=='"' then n.kind='string';n.value=str()
  else
   local starttoken=p;while p<=#text and not text:sub(p,p):match('[,%]%}%s]')do p=p+1 end
   local token=text:sub(starttoken,p-1)
   if token=='null' then n.kind='null'
   elseif token=='true' or token=='false' then n.kind='boolean';n.value=token=='true'
   else
    local sign,integer,rest=token:match('^(%-?)(%d+)(.*)$')
    if not integer or #integer>1 and integer:sub(1,1)=='0' then error('json_number_invalid') end
    if rest:sub(1,1)=='.' then local fraction,tail=rest:match('^%.(%d+)(.*)$');if not fraction then error('json_number_invalid') end;rest=tail end
    if rest~='' and not rest:match('^[eE][%+%-]?%d+$') then error('json_number_invalid') end
    local decoded=json.decode(token);if type(decoded)~='number' or decoded~=decoded or math.abs(decoded)==math.huge then error('json_value_invalid') end;n.kind='number';n.value=decoded
   end
  end
  n.last=p-1;return n
 end
 local ok,root=pcall(function()local r=value(0);ws();if p<=#text then error('json_trailing_data') end;return r end)
 if not ok then return nil,'json_contract_invalid:'..tostring(root) end
 return root
end
function M.at(root,path)
 for _,key in ipairs(path or {})do if not root or not root.children then return nil end;root=root.children[key] end
 return root
end
function M.raw(text,node)return node and text:sub(node.first,node.last) or nil end
function M.compact(node)
 if node.kind=='object' then local parts={};for _,key in ipairs(node.keys)do parts[#parts+1]=json.encode(key)..':'..M.compact(node.children[key])end;return '{'..table.concat(parts,',')..'}' end
 if node.kind=='array' then local parts={};for _,item in ipairs(node.children)do parts[#parts+1]=M.compact(item)end;return '['..table.concat(parts,',')..']' end
 if node.kind=='null' then return 'null' end
 return json.encode(node.value)
end
local annotations={description=true,title=true,default=true,examples=true}
local supported={type=true,properties=true,required=true,enum=true,minimum=true,maximum=true,minLength=true,maxLength=true,minItems=true,maxItems=true,additionalProperties=true,items=true,anyOf=true}
local function supported_schema(schema,path)
 if type(schema)~='table' then return 'schema_unsupported:'..path end
 for key in pairs(schema)do if not supported[key] and not annotations[key] then return 'schema_unsupported:'..path..':'..key end end
 for key,sub in pairs(schema.properties or {})do local e=supported_schema(sub,path..'.'..key);if e then return e end end
 for _,sub in ipairs(schema.anyOf or {})do local e=supported_schema(sub,path..'.anyOf');if e then return e end end
 for _,key in ipairs({'items','additionalProperties'})do if type(schema[key])=='table' then local e=supported_schema(schema[key],path..'.'..key);if e then return e end end end
 for _,v in ipairs(schema.enum or {})do if type(v)=='table' then return 'schema_unsupported:'..path..':composite_enum' end end
end
local function validate(schema,node,path)
 if schema.anyOf then
  local accepted=false;for _,branch in ipairs(schema.anyOf)do if not validate(branch,node,path) then accepted=true;break end end
  if not accepted then return 'schema_anyof:'..path end
 end
 if schema.type then
  local types=type(schema.type)=='table' and schema.type or {schema.type};local accepted=false
  for _,kind in ipairs(types)do
   if kind==node.kind or kind=='integer' and node.kind=='number' and node.value%1==0 then accepted=true end
  end
  if not accepted then return 'schema_type:'..path end
 end
 if schema.enum then local found=false;local encoded=M.compact(node)
  for _,allowed in ipairs(schema.enum)do if json.encode(allowed)==encoded then found=true end end
  if not found then return 'schema_enum:'..path end
 end
 if node.kind=='number' then
  if node.value~=node.value or math.abs(node.value)==math.huge then return 'schema_number:'..path end
  if schema.minimum and node.value<schema.minimum or schema.maximum and node.value>schema.maximum then return 'schema_range:'..path end
 elseif node.kind=='string' then
  local length=utf8 and utf8.len(node.value) or #node.value
  if schema.minLength and length<schema.minLength or schema.maxLength and length>schema.maxLength then return 'schema_length:'..path end
 elseif node.kind=='array' then
  if schema.minItems and #node.children<schema.minItems or schema.maxItems and #node.children>schema.maxItems then return 'schema_items:'..path end
  if schema.items then for i,item in ipairs(node.children)do local e=validate(schema.items,item,path..'['..i..']');if e then return e end end end
 elseif node.kind=='object' then
  for _,key in ipairs(schema.required or {})do if not node.children[key] then return 'schema_required:'..path..'.'..key end end
  for _,key in ipairs(node.keys)do local sub=(schema.properties or {})[key]
   if sub then local e=validate(sub,node.children[key],path..'.'..key);if e then return e end
   elseif schema.additionalProperties==false then return 'schema_extra:'..path..'.'..key
   elseif type(schema.additionalProperties)=='table' then local e=validate(schema.additionalProperties,node.children[key],path..'.'..key);if e then return e end end
  end
 end
end
function M.validate(schema,text)
 local node,err=M.parse(text);if not node then return nil,err end
 local ok,failure=pcall(function()return supported_schema(schema,'arguments') or validate(schema,node,'arguments')end)
 if not ok then return nil,'schema_unsupported:malformed' end
 if failure then return nil,failure end
 return node
end
return M
