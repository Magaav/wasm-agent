-- The provider prefix is frozen for the life of a session (docs/PROMPT-CACHE.md).
--
-- A provider matches its prompt cache from the first byte of the request: the declared tool list and
-- the system prompt. Editing either one mid-session makes the provider re-read the whole conversation
-- at full price, so this module makes the prefix append-only by construction: the first turn of a
-- session records the exact bytes (system prompt and tool list) keyed by the session, and every later
-- request in that session sends those bytes.
--
-- A change that *would* have edited the prefix - an orchestration toggle, a skill installed, a policy
-- reload, an instruction edit, a new platform/time-zone line, a node update - is delivered instead as
-- one appended user-role note (`[session update] ...`) at the end of the conversation. The transcript
-- stays the source of truth: the note is a durable row, so it survives a restart and is not repeated.
--
-- The record lives in `meta`, not in module state, because the provider cache is keyed on bytes and
-- not on which process or interpreter sent them: a restart, a new pooled worker or a node update must
-- keep sending the same prefix.
--
-- Nothing here decides authority. Permission, grants and effects are rechecked at every call; the
-- frozen tool list is what was declared to the model, never a capability it grants.
local json=dofile('lua/vendor/json.lua')
local M={}
M.VERSION=1
-- A note is node state, not the reader speaking, and it says so in its first sentence.
M.NOTE_PREFIX='[session update]'
-- Bounded: a note is re-sent in every later request of the session, so it buys its bytes.
M.NOTE_LIMIT=16000
M.KEY_PREFIX='prompt-cache.v1:'

local function sha(text) return host.sha256(text) end

local function store_key(ctx)
 if type(ctx.session_id)~='string' or ctx.session_id=='' then return nil end
 return M.KEY_PREFIX..sha(ctx.session_id..'\0'..tostring(ctx.user_id or '')..'\0'..tostring(ctx.role or ''))
end
M.key=store_key

-- The record, or nil and why. Never raises: a request must not fail because a cache record could not
-- be read, and an unreadable record is reported (the caller refreezes and says so).
local function read_row(k)
 local ok,raw=pcall(host.sql_query,'SELECT value FROM meta WHERE key=?',json.encode({k}))
 if not ok or type(raw)~='string' then return nil,nil,'prompt_cache_store' end
 local decoded
 ok,decoded=pcall(json.decode,raw)
 if not ok or type(decoded)~='table' or decoded.error then return nil,nil,'prompt_cache_store' end
 local row=decoded[1]
 if not row then return nil,nil,'missing' end
 local value
 ok,value=pcall(json.decode,row.value)
 if not ok or type(value)~='table' or value.v~=M.VERSION or type(value.system)~='string'
   or type(value.tools)~='string' or type(value.state)~='string' then
  return nil,row.value,'prompt_cache_corrupt'
 end
 value.raw_value=row.value
 return value,row.value,nil
end

local function write_row(k,value)
 local ok,raw=pcall(host.sql_exec,'INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
   json.encode({k,json.encode(value)}))
 if not ok or type(raw)~='string' then return false,'prompt_cache_store' end
 local decoded
 ok,decoded=pcall(json.decode,raw)
 if not ok or type(decoded)~='table' or decoded.error or decoded.ok~=true then
  return false,'prompt_cache_store'
 end
 value.raw_value=json.encode(value)
 return true
end

-- Compare-and-set: only the writer that still sees `expected` stores the new value, so two
-- processes cannot both deliver the same note for one change.
local function cas_row(k,expected,value)
 if type(expected)~='string' then return false,'no_record' end
 local ok,raw=pcall(host.sql_exec,'UPDATE meta SET value=? WHERE key=? AND value=?',
   json.encode({json.encode(value),k,expected}))
 if not ok or type(raw)~='string' then return false,'prompt_cache_store' end
 local decoded
 ok,decoded=pcall(json.decode,raw)
 if not ok or type(decoded)~='table' or decoded.error or decoded.ok~=true then
  return false,'prompt_cache_store'
 end
 return decoded.changes==1,'changed_elsewhere'
end

local function state_hash(system_sha256,tools_sha256)
 return sha(system_sha256..'\0'..tools_sha256)
end
M.state_hash=state_hash

local function decode(record)
 local tools=json.decode(record.tools)
 return {system=record.system, system_sha256=sha(record.system),
   tools=tools, tools_sha256=sha(json.encode(tools)),
   orchestration=record.orchestration==true, parts=record.parts or {},
   record=record, raw_value=record.raw_value, at=record.at}
end
M.decode=decode

-- The frozen prefix for this session, or nil when it has none.
function M.read(ctx)
 local k=store_key(ctx or {})
 if not k then return nil,'session_required' end
 local record,_,reason=read_row(k)
 if not record then return nil,reason end
 return decode(record)
end

-- Which parts of the built prefix changed, in the words the guard logs. Pure: no store, no side
-- effects, so the classification can be tested on its own.
local PART_REASON={workflow='orchestration',skills='skills',project='instructions',
 environment='platform',workdir='platform',keys='keys',tools='policy',guidelines='policy',
 safety='policy',codemode='policy',generic='prompt',role='prompt'}

local REASON_ORDER={'orchestration','skills','tools','policy','instructions','platform','keys','prompt'}
local function ordered(reasons)
 local seen={}
 for _,reason in ipairs(reasons or {}) do seen[reason]=true end
 local out={}
 for _,reason in ipairs(REASON_ORDER) do if seen[reason] then out[#out+1]=reason end end
 return out
end
M.reasons_ordered=ordered

local function index(list)
 local out={}
 for _,item in ipairs(list or {}) do
  local name=(type(item)=='table' and item['function'] or {}).name
  if type(name)=='string' then out[name]=sha(json.encode(item)) end
 end
 return out
end

function M.classify(frozen,current)
 local reasons,seen,detail={},{},{}
 local function add(reason)
  if reason and not seen[reason] then seen[reason]=true;reasons[#reasons+1]=reason end
 end
 local orchestration={}
 for _,name in ipairs(dofile('lua/core/envelope.lua').orchestration_names()) do orchestration[name]=true end
 local before,after=index(json.decode(frozen.tools)),index(current.tools or {})
 local added,removed,redefined={},{},{}
 for name in pairs(after) do
  if not before[name] then added[#added+1]=name
  elseif before[name]~=after[name] then redefined[#redefined+1]=name end
 end
 for name in pairs(before) do if not after[name] then removed[#removed+1]=name end end
 table.sort(added);table.sort(removed);table.sort(redefined)
 if #added+#removed+#redefined>0 then
  detail.tools_added,detail.tools_removed,detail.tools_redefined=added,removed,redefined
  local only_orchestration=true
  for _,name in ipairs(added) do if not orchestration[name] then only_orchestration=false end end
  for _,name in ipairs(removed) do if not orchestration[name] then only_orchestration=false end end
  for _,name in ipairs(redefined) do if not orchestration[name] then only_orchestration=false end end
  add(only_orchestration and 'orchestration' or 'tools')
 end
 local before_parts=frozen.parts or {}
 local after_parts=current.parts or {}
 detail.parts={}
 for name,value in pairs(after_parts) do
  if name~='facts' and before_parts[name]~=value then
   detail.parts[#detail.parts+1]=name
   add(PART_REASON[name] or 'prompt')
  end
 end
 for name in pairs(before_parts) do
  if name~='facts' and after_parts[name]==nil then
   detail.parts[#detail.parts+1]=name
   add(PART_REASON[name] or 'prompt')
  end
 end
 table.sort(detail.parts)
 if (frozen.orchestration==true)~=(current.orchestration==true) then add('orchestration') end
 return ordered(reasons),detail
end

local function current_state(current)
 local system=tostring(current.system or '')
 local tools_json=json.encode(current.tools or {})
 return {system=system,tools_json=tools_json,system_sha256=sha(system),tools_sha256=sha(tools_json),
   parts=current.parts or {},orchestration=current.orchestration==true,
   facts=current.facts or (current.parts or {}).facts or {}}
end

-- Freeze the prefix on this session's first turn, or return the frozen one. `current` is what this
-- process would send now: {system=, tools=, parts=, orchestration=, facts=}. The frozen bytes win;
-- the report says what changed and whether a note is still owed for it.
function M.enforce(ctx,current)
 ctx=ctx or {}
 local k=store_key(ctx)
 if not k then return nil,{skipped='session_required'} end
 local now=current_state(current or {})
 local record,_,reason=read_row(k)
 if record then
  local ok=pcall(decode,record)
  if not ok then record,reason=nil,'prompt_cache_corrupt' end
 end
 if not record then
  local value={v=M.VERSION,at=host.now(),system=now.system,system_sha256=now.system_sha256,
    tools=now.tools_json,tools_sha256=now.tools_sha256,parts=now.parts,
    orchestration=now.orchestration and true or false,
    orchestration_noted=now.orchestration and true or false,
    state=state_hash(now.system_sha256,now.tools_sha256)}
  value.noted=value.state
  local written,why=write_row(k,value)
  return decode(value),{created=true,changed=false,stored=written==true,state=value.state,
    store_error=not written and why or nil,corrupt=reason=='prompt_cache_corrupt'}
 end
 local frozen=decode(record)
 local state=state_hash(now.system_sha256,now.tools_sha256)
 -- Two different questions, and they must not be conflated: `changed` means these bytes differ from
 -- the frozen prefix (the request is served from the record), `note_required` means the model has not
 -- yet been told about this state. Returning to a state the session was frozen in is not `changed`
 -- but it can still owe a note - a mode that went on and then off again is back to the original bytes
 -- while the last note in the transcript says it is on.
 local told=record.orchestration_noted
 if told==nil then told=record.orchestration==true end
 local report={created=false,state=state,frozen_state=record.state,changed=state~=record.state,
   note_required=state~=record.noted,orchestration=now.orchestration,
   orchestration_frozen=record.orchestration==true,orchestration_noted=told==true,
   facts=now.facts}
 if report.changed or report.note_required then
  local reasons,detail=M.classify(record,now)
  report.detail=detail
  if told~=(now.orchestration==true) then
   local merged={}
   for _,reason in ipairs(reasons) do merged[#merged+1]=reason end
   merged[#merged+1]='orchestration'
   reasons=ordered(merged)
  end
  report.reasons=reasons
 else
  report.reasons={}
 end
 return frozen,report
end

-- Verify the request about to be sent still carries the frozen prefix. `nil` means it does. Anything
-- else is a bug in this process, not a policy change: the caller sends the frozen bytes, reports the
-- mismatch and counts it.
function M.guard(frozen,messages,tools)
 if not frozen or type(messages)~='table' then return nil,'no_prefix' end
 local first=messages[1]
 local system=type(first)=='table' and tostring(first.content or '') or nil
 local system_ok=system~=nil and sha(system)==frozen.system_sha256
 local tools_ok=sha(json.encode(tools or {}))==frozen.tools_sha256
 if system_ok and tools_ok then return nil end
 local reason=system_ok and 'tools' or (tools_ok and 'system' or 'system,tools')
 return {reason=reason,system=frozen.system,tools=frozen.tools,messages=messages},reason
end

local function list_text(names,limit)
 if #names==0 then return nil end
 local kept={}
 for i=1,math.min(#names,limit or 12) do kept[#kept+1]=names[i] end
 return table.concat(kept,', ')..(#names>#kept and (', +'..(#names-#kept)..' more') or '')
end

-- The orchestration definitions, pinned into this session's loadout the way a tool_search hit is,
-- and rendered as the exact schemas the model may now call through tool_call.
local function pin_orchestration(ctx,catalog)
 if not ctx then return {} end
 local names={}
 for _,name in ipairs(dofile('lua/core/envelope.lua').orchestration_names()) do names[name]=true end
 local items={}
 for _,item in ipairs(catalog or {}) do
  local name=(type(item)=='table' and item['function'] or {}).name
  if names[name] then items[#items+1]=item end
 end
 if #items==0 then return {} end
 pcall(function() dofile('lua/core/envelope.lua').pin(ctx,items) end)
 local out={}
 for _,item in ipairs(items) do
  local name=item['function'].name
  out[#out+1]=name..':\n'..json.encode(item)
 end
 return out
end

local function compose(report,frozen,opts)
 local set={}
 for _,reason in ipairs(report.reasons or {}) do set[reason]=true end
 local facts=report.facts or {}
 local sentences={}
 local function add(sentence) if sentence and sentence~='' then sentences[#sentences+1]=sentence end end
 if set.orchestration then
  if report.orchestration then
   add('Orchestration mode is now ON for this conversation. '
    ..(report.orchestration_frozen
      and 'The execution instructions above already describe the mode as on.'
      or ('The execution instructions above still describe the mode as off, because they are frozen '
        ..'for this session; the mode is on.'))
    ..' Before any effectful call (write, edit, bash, operation, session_worktree) record your '
    ..'decision with route_task route="direct" for a quick answer or a short read-only inspection you '
    ..'will do here, or route_task route="delegate" for a concrete implementation, followed by the '
    ..'child (subagent action="start", profile="orchestration-worker", title, prompt, context). Both '
    ..'tools are callable through tool_call now and their definitions are pinned below.')
  else
   add('Orchestration mode is now OFF for this conversation. '
    ..(report.orchestration_frozen
      and 'The execution instructions above still describe the mode as on; they no longer apply.'
      or 'The execution instructions above already describe the mode as off; any earlier note saying '
        ..'it was on no longer applies.')
    ..' Effectful calls run directly, with no route_task and no new child. A child that is already '
    ..'running keeps running: collect it with subagent action="status" or "await".')
  end
 end
 if set.skills then
  add('The skills on this node changed since this session started, so the skill list in your '
   ..'instructions is stale. List the current set with skill(query="*") and load one by exact name '
   ..'before specialized work.')
 end
 if set.tools then
  local added=list_text((report.detail or {}).tools_added or {})
  local removed=list_text((report.detail or {}).tools_removed or {})
  local redefined=list_text((report.detail or {}).tools_redefined or {})
  add('The node\'s tool catalogue changed since this session started'
   ..(added and ('; added: '..added) or '')..(removed and ('; removed: '..removed) or '')
   ..(redefined and ('; redefined: '..redefined) or '')
   ..'. The declared list above is frozen, and it grants nothing: permission and executability are '
   ..'rechecked at every call, so find a current definition with tool_search.')
 end
 if set.policy then
  add('The node\'s tool policy or guidelines changed since this session started; the copy in your '
   ..'instructions is the old one. Use capabilities or tool_search for what is permitted and '
   ..'executable now, and treat a refusal as the current rule.')
 end
 if set.instructions then
  local where=facts.instructions
  add('The project instruction files changed on disk'
   ..(where and (' ('..where..')') or '')..'. The copy above is the one this session started with; '
   ..'read the file again before following a rule that may have moved.')
 end
 if set.platform then
  add('The platform line changed: '..tostring(facts.environment or 'see host.platform')
   ..'. Use it for shell syntax and for the local clock.')
 end
 if set.keys then
  add('The vault key names changed: '..tostring(facts.keys or 'ask the operator')..'.')
 end
 if set.prompt then
  add('The agent instructions themselves changed on disk; the copy above is frozen for this session.')
 end
 if #sentences==0 then
  add('Something this request would have put in your prefix changed since the session started; the '
   ..'copy above is kept and this note is the current state.')
 end
 local definitions={}
 if set.orchestration and report.orchestration then
  definitions=pin_orchestration(opts and opts.ctx,opts and opts.catalog)
 end
 local head=M.NOTE_PREFIX..' Automated node state, not a message from the reader and not a new task. '
  ..'Your instructions and tool definitions are frozen for this session so the provider cache stays '
  ..'warm; what changed is delivered here instead of editing them.'
 local body={head}
 for _,sentence in ipairs(sentences) do body[#body+1]='- '..sentence end
 local text=table.concat(body,'\n')
 for _,definition in ipairs(definitions) do
  local candidate=text..'\n\nCallable now through tool_call (pinned):\n'..definition
  if #candidate<=M.NOTE_LIMIT then text=candidate
  else
   text=text..'\n\nOne or more new definitions were left out for size; tool_search finds them by name.'
   break end
 end
 if #text>M.NOTE_LIMIT then
  local cut=text:sub(1,M.NOTE_LIMIT)
  local boundary=cut:match('^.*()\n')
  text=(boundary and cut:sub(1,boundary-1) or cut)..'\n(truncated)'
 end
 return text
end

-- Deliver the note the report owes, once. Returns the texts appended (empty when nothing was owed or
-- another process already delivered it). The row is durable: the note is part of the transcript from
-- now on, so a later request carries it in its natural position and nothing is repeated.
function M.notes(ctx,frozen,report,opts)
 opts=opts or {}
 if not report or not report.note_required then return {} end
 if not frozen or not frozen.record then return {} end
 local k=store_key(ctx or {})
 if not k then return {} end
 local text=compose(report,frozen,{ctx=ctx,catalog=opts.catalog})
 local memory=dofile('lua/core/memory.lua')
 if not memory.session(ctx.session_id) then return {} end
 local ok=pcall(memory.append_turn,ctx.session_id,{id=host.uuid(),role='user',content=text,
   debug=false,phase='session_update'})
 if not ok then return {} end
 local record=frozen.record
 local updated={v=record.v,at=record.at,system=record.system,system_sha256=record.system_sha256,
   tools=record.tools,tools_sha256=record.tools_sha256,parts=record.parts,
   orchestration=record.orchestration,state=record.state,noted=report.state,
   orchestration_noted=report.orchestration and true or false}
 -- The prefix is unchanged: only the "already delivered" marker moves.
 cas_row(k,record.raw_value,updated)
 pcall(function()
  dofile('lua/core/telemetry.lua').event(ctx.session_id,'','','session_update',
    table.concat(report.reasons or {},','),{bytes=#text,reasons=report.reasons,
      orchestration=report.orchestration and true or false})
 end)
 if opts.emit then
  local reasons=table.concat(report.reasons or {},',')
  pcall(opts.emit,'session update appended ('..reasons..', '..#text
    ..' bytes): the prompt prefix is unchanged')
 end
 return {text}
end

return M
