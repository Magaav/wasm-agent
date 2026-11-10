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
eq(extra,'schema_extra:arguments.a','additionalProperties=false still refuses an extra key')

print('test-json-contract: '..checks..' checks passed')
