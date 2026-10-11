-- Pure contract proof: optional properties are not rewritten into mandatory placeholders.
local json=dofile('lua/vendor/json.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local params={type='object',properties={path={type='string'},edits={type='array'},range_edits={type='array'}},required={'path'}}
local before=json.encode(params)
local body=adapter.wire().body('gpt-6.1-sol',{{role='user',content='fixture'}},{{['function']={name='edit',parameters=params}}},{},'low',adapter.catalogue().get('gpt-6.1-sol'))
assert(body.tools[1].strict==false,'native tools must explicitly disable forced strict-schema normalization')
assert(json.encode(params)==before and #body.tools[1].parameters.required==1,'declared schema and required fields unchanged')
local tools=dofile('lua/core/tools.lua');local optional=false
for _,tool in ipairs(tools.catalog('master'))do if tool['function'].name=='edit'then
 local required=tool['function'].parameters.required;assert(#required==1 and required[1]=='path','edit forms must remain optional and host-exclusive');optional=true
end end
assert(optional,'edit schema found')
print('optional native tools ok (3 checks, no inference)')
