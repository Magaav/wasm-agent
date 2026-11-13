-- Prompt/envelope bytes for one role, measured without a model call. Two runs of this probe - one
-- against the base tree, one against the change - are the before/after the retirement reports.
--
--   WASM_AGENT_LUA_ROOT=<tree> WA_SCRIPT=scripts/probe-prompt-bytes.lua wa --db /tmp/x.db
--
-- What it prints, one JSON line:
--   catalogue        declared tool count per role (the whole catalogue a role may use)
--   envelope         the tools the model is SHOWN for an empty master session, by name
--   envelope_bytes   the exact JSON bytes of that declaration array (what the request carries)
--   system_bytes     the exact system-prompt bytes for that session
--   prompt_bytes     system_bytes + the serialized declaration array (the prompt half of the request)
--   codemode_bytes   the routing block appended to the system prompt when code mode is on
--   retired          per-name bytes of each retired schema, measured from the base when present
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return 'native' end;return env(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local agent=dofile('lua/core/agent.lua')
local policy=dofile('lua/core/codemode_policy.lua')
-- The base tree predates the retirement, so the name list is spelled here when the module is absent:
-- the probe must measure BOTH sides with the same code.
local retired_ok,retired=pcall(dofile,'lua/core/retired.lua')
if not retired_ok or type(retired)~='table' then
  local names={'read_many','write_many','edit_many','grep_many','session_many','search_messages_many','symbol_source_many'}
  retired={list=function() return names end}
end

local out={}
local sid=memory.start_session('','bytes probe',{user_id='master',node_id='',title='bytes probe'})
local ctx={session_id=sid,user_id='master',role='master'}
policy.pin(memory,'master',ctx)

local counts={}
for _,role in ipairs({'master','guest'}) do counts[role]=#tools.catalog(role) end
out.catalogue=counts

local declared,mode=tools.envelope('master',ctx)
local names={}
for _,item in ipairs(declared) do names[#names+1]=(item['function'] or item).name end
table.sort(names)
out.mode=mode
out.envelope=names
out.envelope_count=#names
out.envelope_bytes=#json.encode(declared)

-- The full system prompt for an empty session, exactly as the first request builds it.
local bot=agent.new(sid,function() end,'master','master','')
local ok,messages=pcall(function() return bot:build_context() end)
if ok and type(messages)=='table' and messages[1] then
  out.system_bytes=#tostring(messages[1].content or '')
  out.prompt_bytes=out.system_bytes+out.envelope_bytes
  local block=dofile('lua/core/codemode_policy.lua').prompt(tools.all('master',ctx,memory))
  out.codemode_bytes=#tostring(block or '')
else
  out.system_error='build_context_failed'
end

-- Per-name bytes: what each retired schema cost while it was declared (0 when it is not in this tree).
local per={}
local catalog=tools.catalog('master')
local by_name={}
for _,item in ipairs(catalog) do by_name[item['function'].name]=item end
for _,name in ipairs(retired.list()) do
  if by_name[name] then per[name]=#json.encode(by_name[name]) else per[name]=0 end
end
out.retired=per
local retired_total=0
for _,bytes in pairs(per) do retired_total=retired_total+bytes end
out.retired_schema_bytes=retired_total
out.retired_names_present=0
for _,bytes in pairs(per) do if bytes>0 then out.retired_names_present=out.retired_names_present+1 end end
print(json.encode(out))
