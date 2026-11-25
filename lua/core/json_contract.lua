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
-- Strict balanced-closer completion for a tool-argument text that stopped early: the ONLY repair
-- is appending the `}`/`]` still open, in nesting order. Refused (nil, reason) when the text ends
-- inside a string, after `,`, `:` or an opener (a value is missing, not a closer), when a closer
-- does not match its opener, when nothing is open, or when the completed text is not a JSON
-- object. The caller must still validate the result against the tool's schema before using it.
function M.close_truncated(text)
 if type(text)~='string' or text=='' then return nil,'empty' end
 local stack,in_string,escaped,last={},false,false,nil
 for i=1,#text do local c=text:sub(i,i)
  if in_string then
   if escaped then escaped=false elseif c=='\\' then escaped=true elseif c=='"' then in_string=false end
  elseif c=='"' then in_string=true
  elseif c=='{' or c=='[' then stack[#stack+1]=c
  elseif c=='}' or c==']' then
   local open=stack[#stack];if not open or (open=='{')~=(c=='}') then return nil,'closer_mismatch' end
   stack[#stack]=nil
  end
  if not c:match('%s') then last=c end
 end
 if in_string then return nil,'ends_inside_string' end
 if #stack==0 then return nil,'nothing_open' end
 if last==',' or last==':' or last=='{' or last=='[' then return nil,'value_missing' end
 local closers={};for i=#stack,1,-1 do closers[#closers+1]=stack[i]=='{' and '}' or ']' end
 local completed=text..table.concat(closers)
 local node,problem=M.parse(completed);if not node then return nil,problem end
 if node.kind~='object' then return nil,'not_an_object' end
 return completed,table.concat(closers)
end
function M.compact(node)
 if node.kind=='object' then local parts={};for _,key in ipairs(node.keys)do parts[#parts+1]=json.encode(key)..':'..M.compact(node.children[key])end;return '{'..table.concat(parts,',')..'}' end
 if node.kind=='array' then local parts={};for _,item in ipairs(node.children)do parts[#parts+1]=M.compact(item)end;return '['..table.concat(parts,',')..']' end
 if node.kind=='null' then return 'null' end
 return json.encode(node.value)
end
-- Materialize a validated AST as traversable data, never opaque raw JSON.
-- Nulls and empty objects need payload-free tags because ordinary Lua tables
-- otherwise erase their distinction from empty arrays during recursive copies.
function M.materialize(node,keymap)
 if node.kind=='null' then return setmetatable({}, {__json_empty='null'}) end
 if node.kind=='object' then
  local value={};for _,key in ipairs(node.keys)do
   local mapped=keymap and keymap(key) or key
   if value[mapped]~=nil then error('json_materialize_key_collision') end
   value[mapped]=M.materialize(node.children[key],keymap)
  end
  if next(value)==nil then setmetatable(value,{__json_empty='object'}) end
  return value
 end
 if node.kind=='array' then
  local value={};for i,child in ipairs(node.children)do value[i]=M.materialize(child,keymap) end
  return value
 end
 return node.value
end
local annotations={description=true,title=true,default=true,examples=true,
 ['$schema']=true,['$id']=true,['$comment']=true,['$defs']=true,['$ref']=true,format=true}
-- WHY THESE ARE ANNOTATIONS AND NOT REFUSALS. `$schema` is metadata naming the dialect, and refusing
-- it refused the TOOL: mail-mcp 0.6.1 (pydantic v2) stamps `"$schema": "https://json-schema.org/
-- draft/2020-12/schema"` inside every `inputSchema`, so 34 of the connector's 37 tools answered
-- `schema_unsupported:arguments:$schema` before the MCP server was contacted at all - the call never
-- left this process. `$defs`/`$ref` name subschemas, `format` is a presentation hint, and the
-- constraints a `$ref` stands for are validated by the server's own pydantic model, which still runs
-- and still answers. A keyword that changes the SHAPE of an accepted value (patternProperties,
-- allOf, propertyNames, ...) is still refused: the guard is a guard, not a rubber stamp.
-- `nullable` is NOT an annotation: it is handled in validate(), because it changes what is accepted.
local supported={type=true,properties=true,required=true,enum=true,minimum=true,maximum=true,minLength=true,maxLength=true,minItems=true,maxItems=true,additionalProperties=true,items=true,anyOf=true,
 nullable=true}
local function supported_schema(schema,path)
 if type(schema)~='table' then return 'schema_unsupported:'..path end
 for key in pairs(schema)do if not supported[key] and not annotations[key] then return 'schema_unsupported:'..path..':'..key end end
 for key,sub in pairs(schema.properties or {})do local e=supported_schema(sub,path..'.'..key);if e then return e end end
 for _,sub in ipairs(schema.anyOf or {})do local e=supported_schema(sub,path..'.anyOf');if e then return e end end
 for _,key in ipairs({'items','additionalProperties'})do if type(schema[key])=='table' then local e=supported_schema(schema[key],path..'.'..key);if e then return e end end end
 for _,v in ipairs(schema.enum or {})do if type(v)=='table' then return 'schema_unsupported:'..path..':composite_enum' end end
end
-- The argument names an object schema accepts, for the refusal that just named one it does not.
--
-- `schema_extra:arguments.query` says what was wrong and never what would have been right, so a model
-- that guessed `query` for a tool whose parameter is `q` had to guess again - measured on 13/11, three
-- calls and three refusals before the accepted name was found by luck (the connector tools were offered
-- with empty `properties`, so there was nothing to read). The refusal now carries the names, sorted and
-- bounded: the point is one retry, not a schema dump.
local ACCEPTED_SHOWN = 12
-- HOW FAR two names are apart, for the one suggestion a refusal makes. Plain Levenshtein, bounded: the
-- strings here are argument names, so this is a handful of cells and never a cost worth optimising.
local function edit_cost(a, b)
 local la, lb = #a, #b
 if la == 0 then return lb end
 if lb == 0 then return la end
 local row = {}
 for j = 0, lb do row[j] = j end
 for i = 1, la do
  local previous = row[0]
  row[0] = i
  for j = 1, lb do
   local current = row[j]
   row[j] = math.min(row[j] + 1, row[j - 1] + 1, previous + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
   previous = current
  end
 end
 return row[lb]
end
-- THE NAME THE CALLER PROBABLY MEANT, from the schema's own declared names, or nil when none is close.
-- A suggestion that is not near the word sent sends the model to a second wrong call, which is worse
-- than saying only what the tool takes - so the budget is half the length of the word, at least 2.
-- Measured 14/11: a refusal that said only "does not take q" cost three calls and three refusals before
-- the accepted name was found by luck.
local function nearest(name, declared)
 local best, best_cost
 for candidate in pairs(declared or {}) do
  local word = tostring(candidate)
  local cost = edit_cost(tostring(name), word)
  if best_cost == nil or cost < best_cost or (cost == best_cost and word < best) then
   best, best_cost = word, cost
  end
 end
 if not best or best_cost > math.max(2, math.floor(#tostring(name) / 2)) then return nil end
 return best
end
local function accepted_note(schema)
 local names = {}
 for name in pairs(schema.properties or {}) do names[#names + 1] = tostring(name) end
 if #names == 0 then return ' (this object takes no arguments)' end
 table.sort(names)
 local shown = {}
 for index = 1, math.min(#names, ACCEPTED_SHOWN) do shown[#shown + 1] = names[index] end
 local text = table.concat(shown, ', ')
 if #names > ACCEPTED_SHOWN then text = text .. ', ...' end
 return ' (accepted: ' .. text .. ')'
end
local function validate(schema,node,path,extra)
 -- OpenAPI/pydantic `nullable: true`: a null is accepted where the schema says it may be, otherwise
 -- the `type` check below would refuse an argument the connector's own contract allows.
 if schema.nullable==true and node.kind=='null' then return nil end
 if schema.anyOf then
  local accepted=false;for _,branch in ipairs(schema.anyOf)do if not validate(branch,node,path,extra) then accepted=true;break end end
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
  if schema.items then for i,item in ipairs(node.children)do local e=validate(schema.items,item,path..'['..i..']',extra);if e then return e end end end
 elseif node.kind=='object' then
  for _,key in ipairs(schema.required or {})do if not node.children[key] then return 'schema_required:'..path..'.'..key end end
  -- AN OBJECT SCHEMA THAT DECLARES ARGUMENTS IS CLOSED (25/11, one rule, here and nowhere else).
  --
  -- MEASURED on this node before the rule: 52 of the 57 host tools declared arguments and still accepted
  -- a name they never declared, and the 4 that take no arguments at all accepted anything; one schema in
  -- a hundred refused. The handler dropped the value, so the call RAN AS A DIFFERENT CALL and answered as
  -- if it had not - the class this mission exists for. `additionalProperties` was the only door that
  -- refused, and it is the schema's own way of saying "closed", so it is what decides:
  --   * `true` (or a schema) = open by declaration: a tool that forwards its arguments to something with
  --     a schema of its own (`remote`, a connector, a peer). Its keys are judged by THAT schema, never
  --     refused here for a name this host does not know;
  --   * anything else - absent, or false - = closed, and a name outside `properties` is refused by name
  --     with the nearest name it does declare, because "unknown argument: q" without "did you mean
  --     query?" is a refusal a model has to guess its way out of.
  for _,key in ipairs(node.keys)do local sub=(schema.properties or {})[key]
   if sub then local e=validate(sub,node.children[key],path..'.'..key,extra);if e then return e end
   elseif type(schema.additionalProperties)=='table' then local e=validate(schema.additionalProperties,node.children[key],path..'.'..key,extra);if e then return e end
   elseif schema.additionalProperties==true then
    -- open by declaration: the tool takes the arguments of something else, exactly as it says.
   elseif type(extra)=='table' and extra[key] then
    -- the caller's own module says this tool takes the name (a synonym its handler maps, a field the
    -- runtime stamps); it is not a name the schema never declares by accident.
   elseif path~='arguments' and next(schema.properties or {})==nil and not schema.required then
    -- NOT THE TOOL'S OWN ARGUMENTS, AND NOTHING DECLARED: `arguments={type="object"}` is how a schema says
    -- "an object of anything" (the target's own arguments, a free-form bag). Closing that would refuse every
    -- key of a bag the schema deliberately did not enumerate - measured on `tool_call`, whose `arguments`
    -- subschema is exactly this shape.
   else
    local did=nearest(key,schema.properties)
    return 'unknown_argument:'..tostring(key)..(did and (' - did you mean '..did..'?') or '')
   end
  end
 end
end
-- The names models reach for that a schema spells differently (14/11: contacts({query}) against `q`).
-- A key is renamed only when the schema lacks it, takes the synonym, and the call did not pass the
-- synonym too - so nothing a schema declares is ever reinterpreted. Returns the text and the renames.
local SYNONYMS={query={'q'},search={'q'},term={'q'},keyword={'q'},q={'query'},
 chat_id={'chat'},jid={'chat'},message={'text'},msg={'text'},body={'text'},content={'text'},
 max={'limit'},n={'limit'},file={'path'},filepath={'path'},file_path={'path'},cmd={'command'}}
function M.normalize_names(schema,text)
 if type(schema)~='table' or type(schema.properties)~='table' or type(text)~='string' or text=='' then return text,nil end
 local codec=dofile('lua/vendor/json.lua')
 local ok,args=pcall(codec.decode,text)
 if not ok or type(args)~='table' or args[1]~=nil then return text,nil end
 local renamed={}
 for key,value in pairs(args) do
  if schema.properties[key]==nil and SYNONYMS[key] then
   for _,target in ipairs(SYNONYMS[key]) do
    if schema.properties[target]~=nil and args[target]==nil then args[target]=value;args[key]=nil;renamed[#renamed+1]=key..'->'..target;break end
   end
  end
 end
 if #renamed==0 then return text,nil end
 table.sort(renamed)
 return codec.encode(args),renamed
end

-- `extra` is a SET of names the caller knows the tool accepts without the schema declaring them - the
-- runtime's own fields and the synonyms its handlers map (lua/core/tool_arguments.lua INTERNAL, one list,
-- one place). The rule stays the schema's: a name is accepted because the schema declares it, or because
-- the caller's own module says this tool takes it; nothing else is let through.
function M.validate(schema,text,extra)
 local node,err=M.parse(text);if not node then return nil,err end
 local ok,failure=pcall(function()return supported_schema(schema,'arguments') or validate(schema,node,'arguments',extra)end)
 if not ok then return nil,'schema_unsupported:malformed' end
 if failure then return nil,failure end
 return node
end
return M
