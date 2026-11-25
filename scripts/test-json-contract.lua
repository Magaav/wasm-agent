-- The tool-argument validator against the schemas real connectors send (10/11).
--
-- mail-mcp 0.6.1 is a pydantic v2 server: every `inputSchema` it publishes carries
-- `"$schema": "https://json-schema.org/draft/2020-12/schema"`. The validator refused that metadata as
-- an unknown keyword, so 34 of its 37 tools answered `schema_unsupported:arguments:$schema` and never
-- reached the MCP server at all - the call died inside this process. Measured on the `google`
-- connector: `imap_list_mailboxes` failed identically from the sandbox and from a direct call.
--
-- This pins both halves: the published shape is accepted, and the guard is still a guard (a keyword
-- that would change what is accepted is still refused), plus the checks the validator exists for.
local contract=dofile('lua/core/json_contract.lua')
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function eq(a,b,label)assert(a==b,(label or '')..': got '..tostring(a)..', want '..tostring(b));checks=checks+1 end

-- ---- the schema that broke the connector, verbatim in shape -------------------------------------
local list_mailboxes={
  ['$schema']='https://json-schema.org/draft/2020-12/schema',
  title='AccountOnlyInput',
  description='Input: account_id only',
  type='object',
  properties={account_id={type='string',default='default',description='Account identifier'}},
}
local node,err=contract.validate(list_mailboxes,'{}')
check(node~=nil,'a pydantic $schema no longer refuses the call ('..tostring(err)..')')
eq(node and node.kind,'object','the empty argument object is still a valid object')
local with_arg,e2=contract.validate(list_mailboxes,'{"account_id":"vicscar_zangao"}')
check(with_arg~=nil,'and a real argument passes ('..tostring(e2)..')')

-- ---- the rest of what such a server publishes ----------------------------------------------
local rich={
  ['$schema']='https://json-schema.org/draft/2020-12/schema',
  ['$id']='urn:mail-mcp:draft_create',
  type='object',
  properties={
    body={type='string',format='date-time'},
    attachment={['$ref']='#/$defs/AttachmentInput'},
    reply_to={type='string',nullable=true},
  },
  ['$defs']={AttachmentInput={type='object',properties={path={type='string'}}}},
}
local r,er=contract.validate(rich,'{"body":"2026-11-10T20:00:00Z","reply_to":null}')
check(r~=nil,'$id/$defs/$ref/format are metadata and nullable accepts null ('..tostring(er)..')')

-- ---- the guard is still a guard ---------------------------------------------------------------
local _,pattern=contract.validate({type='object',properties={a={type='string',patternProperties={}}}},'{"a":"x"}')
eq(pattern,'schema_unsupported:arguments.a:patternProperties','an unknown shape keyword is still refused')
local _,allof=contract.validate({type='object',allOf={}},'{}')
eq(allof,'schema_unsupported:arguments:allOf','a composition keyword this validator cannot enforce is refused')

-- ---- and what the validator exists for still holds --------------------------------------------
local req={type='object',properties={a={type='string'}},required={'a'}}
local _,missing=contract.validate(req,'{}')
eq(missing,'schema_required:arguments.a','a missing required key is refused')
local _,typed=contract.validate({type='object',properties={a={type='string'}}},'{"a":1}')
eq(typed,'schema_type:arguments.a','a wrong type is refused')
local _,enum=contract.validate({type='object',properties={a={enum={'x','y'}}}}, '{"a":"z"}')
eq(enum,'schema_enum:arguments.a','a value outside the enum is refused')
local ok_enum=contract.validate({type='object',properties={a={enum={'x','y'}}}}, '{"a":"y"}')
check(ok_enum~=nil,'a value inside the enum passes')
local _,extra=contract.validate({type='object',additionalProperties=false},'{"a":1}')
eq(extra,'unknown_argument:a','additionalProperties=false still refuses an extra key, by name (25/11: one code for the rule)')
-- An object that declares no arguments has no close name to suggest, so the refusal makes no suggestion: a
-- guess that is not close is worse than none.
check(not extra:find('did you mean',1,true),'and suggests nothing when there is nothing near: '..tostring(extra))
-- The refusal that names the wrong argument also names the right ones, through the ONE renderer
-- (lua/core/refusal.lua) that turns the code into the sentence a model reads (13/11: the model guessed
-- `query` for a tool whose parameter is `q`, then `name`, then found `q` - three calls for one question).
local guessed_schema={type='object',additionalProperties=false,properties={
  q={type='string'}, ['from']={type='string'}, limit={type='integer'}}}
local _, guessed = contract.validate(guessed_schema, '{"query":"laura"}')
eq(guessed,'unknown_argument:query','the refusal names the argument that does not exist')
local rendered=dofile('lua/core/refusal.lua').build(guessed,{},{tool='probe',parameters=guessed_schema})
check(rendered.fix:find('from',1,true) and rendered.fix:find('limit',1,true) and rendered.fix:find('q',1,true),
  'and the sentence names every argument the tool accepts: '..tostring(rendered.fix))
-- Bounded: a wide schema names the first twelve and says there are more, so the refusal stays a
-- refusal and not a schema dump.
local wide={type='object',additionalProperties=false,properties={}}
for index=1,20 do wide.properties['arg'..index]={type='string'} end
local _, many = contract.validate(wide,'{"nope":1}')
eq(many,'unknown_argument:nope','a key far from every declared name is refused without a suggestion')
local rendered_many=dofile('lua/core/refusal.lua').build(many,{},{tool='probe',parameters=wide})
check(rendered_many.fix:find('arg1',1,true) and rendered_many.fix:find('arg10',1,true)~=nil,
  'a wide schema is listed, sorted, from the start: '..tostring(rendered_many.fix))
check(rendered_many.fix:find('...',1,true)~=nil,'and says the list continues: '..tostring(rendered_many.fix))

print('test-json-contract: '..checks..' checks passed')
