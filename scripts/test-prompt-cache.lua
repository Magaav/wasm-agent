-- The prompt prefix never changes inside a session (docs/PROMPT-CACHE.md).
--
-- A provider cache matches from the first byte of the request: the declared tool list and the system
-- prompt. Any mid-session edit to either re-reads the whole conversation at full price. This drives the
-- real agent loop through a mock provider that captures the raw request bodies, and asserts what a
-- provider cache sees:
--   * every request in a session carries exactly the bytes of the session's first request;
--   * the message list only ever grows (an append-only prefix chain), so a cache hit is possible;
--   * a change that would have edited the prefix (tool_search load, orchestration on/off/on, a skill
--     installed, a memory write, an instruction edit, a policy reload, a platform/time-zone change) is
--     delivered as one appended `[session update]` note, durably, and never as new prefix bytes;
--   * a fresh session picks up the new state from the start.
--
-- Hermetic: no network, no paid inference, no node. Run:
--   WASM_AGENT_LUA_ROOT=<checkout> WA_SCRIPT=scripts/test-prompt-cache.lua wa --db /tmp/x.db
local json=dofile('lua/vendor/json.lua')

local native_getenv=host.getenv
local env={
  WASM_AGENT_LLM_API_KEY='fixture-prompt-cache', WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE='missing-fixture-store',
  WASM_AGENT_CONTEXT_BUDGET='0', WASM_AGENT_MAX_TOOL_ROUNDS='8',
  WASM_AGENT_PROVIDER_TRANSIENT_RETRIES='0', WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0',
  WASM_AGENT_CODEMODE='off',
}
host.getenv=function(key) if env[key]~=nil then return env[key] end return native_getenv(key) end
host.http=function() error('prompt-cache fixture: unexpected non-streaming network request') end

local paths=dofile('lua/core/paths.lua')
local root=paths.temp()..'/wa-prompt-cache-'..tostring(host.uuid()):gsub('%-','')
local agents_md=root..'/AGENTS.md'
env.WASM_AGENT_AGENTS_MD=agents_md
env.WASM_AGENT_SKILLS=root..'/skills'
assert(host.write_file(agents_md,'Project rule: this is the prompt-cache fixture.\n'),
  'the scratch instruction file can be written')

local memory=dofile('lua/core/memory.lua');memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local agent=dofile('lua/core/agent.lua')
local mode=dofile('lua/core/orchestration_mode.lua')
local tools=dofile('lua/core/tools.lua')
local envelope=dofile('lua/core/envelope.lua')
local prompt_cache=dofile('lua/core/prompt_cache.lua')

local checks=0
local function ok(value,label)
  checks=checks+1
  if not value then error(label,0) end
end

-- ---- the mock provider: it records what was sent and answers from a per-turn script -----------------
local requests, queue = {}, {}
local function usage() return {prompt_tokens=1200,completion_tokens=20,total_tokens=1220,
  prompt_tokens_details={cached_tokens=1000}} end
local function answer(step)
  if step.tool then
    return json.encode({status=200,content='',stream_complete=true,finish_reason='tool_calls',
      tool_calls={{id=(step.id or 'call')..'-1',type='function',
        ['function']={name=step.tool,arguments=json.encode(step.arguments or {})}}},usage=usage()})
  end
  return json.encode({status=200,content=step.content or 'answered',stream_complete=true,
    finish_reason='stop',tool_calls={},usage=usage()})
end
host.http_stream=function(method,url,headers,body)
  requests[#requests+1]={raw=body,body=json.decode(body)}
  return answer(table.remove(queue,1) or {content='answered'})
end
local function turn(bot,steps,text)
  for i,step in ipairs(steps) do queue[i]=step end
  local reply=bot:run(text)
  queue={}
  return reply
end

local function notes_in_transcript(sid)
  local out={}
  for _,row in ipairs(memory.session_messages(sid,{all=true})) do
    if row.phase=='session_update' then out[#out+1]=row.content end
  end
  return out
end
local function last_message(index)
  local messages=requests[index].body.messages
  return messages[#messages]
end
local function request_count() return #requests end

-- ---- session A: progressive envelope, the default -----------------------------------------------------
local sid=memory.start_session('','prompt cache fixture',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
local events={}
local bot=agent.new(sid,function(event) events[#events+1]=event end,'master','master','')

turn(bot,{{content='first answer'}},'first turn')
local freeze_requests=request_count()
ok(freeze_requests==1,'one request for the first turn')
ok(prompt_cache.read(ctx)~=nil,'the first turn records the frozen prefix')
local frozen=prompt_cache.read(ctx)
ok(prompt_cache.key(ctx)~=nil,'the record is keyed by the session')

-- 1. tool_search: discovery pins a definition, the declared envelope does not move.
turn(bot,{{tool='tool_search',id='search',arguments={query='web search',limit=2}},{content='search done'}},
  'find a web search tool')
ok(request_count()==3,'two requests: the search call and the answer')
ok(json.encode(tools.envelope('master',ctx))~=nil,'the envelope still answers')

-- 2. orchestration on: the mode changes, the declared prefix does not.
ok(mode.control({mode_action='toggle',revision=0},ctx).ok,'orchestration toggled on')
turn(bot,{{content='routed'}},'now orchestrate')
local on_request=request_count()
local on_note=last_message(on_request)
ok(type(on_note)=='table' and on_note.role=='user','the change is an appended user-role note')
ok(tostring(on_note.content):find(prompt_cache.NOTE_PREFIX,1,true)==1,'the note is labelled as node state')
ok(tostring(on_note.content):find('route_task',1,true)~=nil,'the note names route_task')
ok(tostring(on_note.content):find('"subagent"',1,true)~=nil,'the note carries the subagent definition')
ok(requests[on_request].body.tools~=nil,'the request still carries a tool list')
local declared={}
for _,item in ipairs(requests[on_request].body.tools) do declared[(item['function'] or {}).name or '']=true end
ok(not declared.route_task and not declared.subagent,
  'the frozen prefix does not grow the mode tools mid-session')
-- Pinned in the loadout, the way a tool_search hit is, and callable through tool_call without one.
local catalog=tools.all('master',ctx,memory)
ok(envelope.resolve(catalog,'route_task',ctx)~=nil,'route_task resolves for this session')
ok(envelope.resolve(catalog,'subagent',ctx)~=nil,'subagent resolves for this session')
local routed=tools.dispatch(memory,'tool_call',{name='route_task',
  arguments={route='direct',task='answer the question asked',reason='a short read-only answer'}},'master',ctx)
ok(type(routed)=='table' and routed.error==nil and routed.route=='direct','route_task is callable through tool_call')
-- The facade, not a child: `profiles` starts nothing, and this asserts the tool_call path reaches it.
local reachable=tools.dispatch(memory,'tool_call',{name='subagent',arguments={action='profiles'}},'master',ctx)
ok(type(reachable)=='table' and not tostring(reachable.error or ''):find('tool_not_available',1,true),
  'subagent is reachable through tool_call without a search')
ok(not mode.is_task(prompt_cache.NOTE_PREFIX..' Automated node state'),
  'a session update is node state, not a task to route')
ok(#notes_in_transcript(sid)==1,'exactly one session update row in the transcript')

-- 3. orchestration off, then on again: no prefix change either way, one note each time.
ok(mode.control({mode_action='toggle',revision=1},ctx).ok,'orchestration toggled off')
turn(bot,{{content='direct'}},'back to direct work')
ok(tostring(last_message(request_count()).content):find('now OFF',1,true)~=nil,'the off note is delivered')
ok(#notes_in_transcript(sid)==2,'two session update rows')
ok(mode.control({mode_action='toggle',revision=2},ctx).ok,'orchestration toggled on again')
turn(bot,{{content='routed again'}},'orchestrate again')
ok(#notes_in_transcript(sid)==3,'three session update rows')
-- Toggling off then on again must not re-deliver a note the session already has: the last one was for
-- the same state as the first "on", and only a *new* state owes a note.
local sees_off=false
for _,row in ipairs(memory.session_messages(sid,{all=true})) do
  if row.phase=='session_update' and row.content:find('now OFF',1,true) then sees_off=true end
end
ok(sees_off,'the off state is still in the transcript')
ok(requests[request_count()].body.tools and #requests[request_count()].body.tools
  ==#requests[1].body.tools,'the declared list never changed size')

-- 4. a memory write: it reaches the transcript, not the prefix, so it owes no note.
local remembered=tools.dispatch(memory,'remember',{content='fixture memory note',tags={'fixture'}},'master',ctx)
ok(type(remembered)=='table' and remembered.error==nil,'the memory write succeeds')
local before=#requests
turn(bot,{{content='memory noted'}},'remember that')
ok(#requests==before+1,'one request for the memory turn')
ok(#notes_in_transcript(sid)==3,'a memory write changes no prefix state, so no note')
ok(prompt_cache.read(ctx).system==frozen.system and prompt_cache.read(ctx).tools_sha256==frozen.tools_sha256,
  'the frozen record is untouched by a memory write')

-- 5. the instruction file (the operator's memory/profile) changes on disk.
assert(host.write_file(agents_md,'Project rule: this is the prompt-cache fixture, revised.\n'),
  'the instruction file can be rewritten')
turn(bot,{{content='instructions noted'}},'follow the new rule')
ok(#notes_in_transcript(sid)==4,'the instruction edit is delivered as one note')
ok(tostring(last_message(request_count()).content):find('instruction files changed',1,true)~=nil,
  'the note names the instruction change')

-- 6. a policy reload: operator guidelines are part of the prefix.
env.WASM_AGENT_GUIDELINES='Fixture policy: prefer rg over grep.'
turn(bot,{{content='policy noted'}},'apply the policy')
ok(#notes_in_transcript(sid)==5,'the policy reload is delivered as one note')
ok(tostring(last_message(request_count()).content):find('policy or guidelines changed',1,true)~=nil,
  'the note names the policy change')

-- 7. a platform (time-zone) line change, as a node update or travel would produce.
local native_platform=host.platform
host.platform=function()
  local real=native_platform()
  return {os='fixture-os',arch=real.arch,shell=real.shell,pathSeparator=real.pathSeparator,cwd=real.cwd}
end
turn(bot,{{content='platform noted'}},'what platform is this')
host.platform=native_platform
ok(#notes_in_transcript(sid)==6,'the platform change is delivered as one note')
ok(tostring(last_message(request_count()).content):find('platform line changed',1,true)~=nil,
  'the note names the platform change')
ok(tostring(last_message(request_count()).content):find('fixture-os',1,true)~=nil,
  'the note carries the new platform line, so the model can act on it')

-- ---- the cache property, over every request of session A ---------------------------------------------
local system_bytes,tools_bytes=requests[1].body.messages[1].content,json.encode(requests[1].body.tools or {})
for index,request in ipairs(requests) do
  ok(request.body.messages[1].content==system_bytes,'request '..index..' sends the session\'s first system prompt bytes')
  ok(json.encode(request.body.tools or {})==tools_bytes,'request '..index..' sends the session\'s first tool list bytes')
end
for index=2,#requests do
  local previous,current=requests[index-1].body.messages,requests[index].body.messages
  ok(#current>=#previous,'request '..index..' does not shorten the conversation')
  for message=1,#previous do
    ok(json.encode(previous[message])==json.encode(current[message]),
      'request '..index..' rewrites message '..message..': the prefix must stay append-only')
  end
end
local spurious=0
for _,event in ipairs(telemetry.events(sid,0,1000).events or {}) do
  if event.kind=='prefix_changed' then spurious=spurious+1 end
end
ok(spurious==0,'an ordinary session logs no prefix_changed: the guard is not part of normal weather')

-- ---- a fresh session starts in the new state ---------------------------------------------------------
ok(mode.read(sid).enabled,'session A ends in orchestration mode')
local fresh_sid=memory.start_session('','prompt cache fresh',{user_id='master'})
local fresh_ctx={session_id=fresh_sid,user_id='master',role='master'}
ok(mode.control({mode_action='set',revision=0,enabled=true},fresh_ctx).ok,'the fresh session starts in orchestration mode')
local fresh=agent.new(fresh_sid,function()end,'master','master','')
turn(fresh,{{content='fresh answer'}},'first turn of a new session')
ok(#notes_in_transcript(fresh_sid)==0,'a session that starts in the new state owes no note')
local fresh_declared={}
for _,item in ipairs(requests[request_count()].body.tools or {}) do
  fresh_declared[(item['function'] or {}).name or '']=true
end
ok(fresh_declared.route_task and fresh_declared.subagent,
  'a session that starts in orchestration mode declares the mode tools from the start')
ok(requests[request_count()].body.messages[1].content:find('orchestration="on"',1,true)~=nil,
  'and its system prompt carries the mode-on instructions')

-- ---- session B: the full envelope, where the skill list lives in the prefix ---------------------------
env.WASM_AGENT_ENVELOPE_MODE='full'
local skill_path=env.WASM_AGENT_SKILLS..'/fixture-skill/SKILL.md'
local b_sid=memory.start_session('','prompt cache skills',{user_id='master'})
local b_ctx={session_id=b_sid,user_id='master',role='master'}
local b_bot=agent.new(b_sid,function()end,'master','master','')
turn(b_bot,{{content='before the skill'}},'first turn')
local b_first=request_count()
ok(requests[b_first].body.messages[1].content:find('fixture-skill',1,true)==nil,
  'no fixture skill in the full-envelope prompt yet')
assert(host.write_file(skill_path,'---\nname: fixture-skill\ndescription: A prompt-cache fixture skill.\n---\nBody.\n'),
  'the fixture skill can be installed')
dofile('lua/core/skills.lua').list(true) -- what an installer does when it refreshes the catalogue
turn(b_bot,{{content='after the skill'}},'second turn')
ok(#notes_in_transcript(b_sid)==1,'the installed skill is delivered as one note')
ok(tostring(last_message(request_count()).content):find('skills on this node changed',1,true)~=nil,
  'the note names the skills change')
ok(requests[request_count()].body.messages[1].content==requests[b_first].body.messages[1].content,
  'and the skill list in the prefix did not move')
for index=b_first+1,request_count() do
  ok(json.encode(requests[index].body.messages[1])==json.encode(requests[b_first].body.messages[1]),
    'full-envelope request '..index..' sends the first system prompt')
end

-- ---- the guard: a drifted prefix is repaired and reported, never sent ---------------------------------
local record=prompt_cache.read(b_ctx)
local drifted={{role='system',content=record.system..'\nDRIFT'}}
local repaired,reason=prompt_cache.guard(record,drifted,record.tools)
ok(repaired~=nil and reason=='system','a drifted system prompt is a mismatch')
ok(repaired.system==record.system,'the frozen bytes are the repair')
local repaired_tools,reason_tools=prompt_cache.guard(record,{{role='system',content=record.system}},{})
ok(repaired_tools~=nil and reason_tools=='tools','a changed tool list is a mismatch')
ok(prompt_cache.guard(record,{{role='system',content=record.system}},record.tools)==nil,
  'the frozen prefix passes the guard')
local classified=prompt_cache.classify({tools=json.encode(record.tools),parts=record.record.parts or {},
  orchestration=false},
  {tools=record.tools,parts=record.record.parts or {},orchestration=true})
ok(#classified==1 and classified[1]=='orchestration','a mode flip classifies as orchestration')

-- ---- the guard, end to end: a drifted prefix is repaired, reported and counted -------------------------
local guard_seen,guard_events=false,0
local g_sid=memory.start_session('','prompt cache guard',{user_id='master'})
local g_ctx={session_id=g_sid,user_id='master',role='master'}
local g_bot=agent.new(g_sid,function(event)
  if event.type=='status' and tostring(event.text):find('prefix mismatch',1,true) then guard_seen=true end
end,'master','master','')
turn(g_bot,{{content='guard baseline'}},'first turn')
local g_frozen=prompt_cache.read(g_ctx)
ok(g_frozen~=nil,'the guard session has a frozen prefix')
-- Simulate the bug the guard exists for: a builder that hands the provider a different system prompt.
local real_build=g_bot.build_context
g_bot.build_context=function(self)
  local messages=real_build(self)
  if messages[1] then messages[1].content=messages[1].content..'\nDRIFTED PREFIX' end
  return messages
end
turn(g_bot,{{content='drifted turn'}},'a turn whose builder is wrong')
g_bot.build_context=real_build
ok(guard_seen,'the mismatch is shown to the reader, not silently sent')
ok(requests[request_count()].body.messages[1].content==g_frozen.system,
  'the frozen bytes were sent instead of the drifted ones')
local counted=0
for _,row in ipairs(memory.session_messages(g_sid,{all=true})) do
  for _,span in ipairs(row.trace or {}) do
    if span.kind=='run_counts' then counted=span.prefix_changes or 0 end
  end
end
ok(counted==1,'the repair is counted in the run stats')
for _,event in ipairs(telemetry.events(g_sid,0,100).events or {}) do
  if event.kind=='prefix_changed' then
    guard_events=guard_events+1
    ok(event.phase=='system','the reason names the part that drifted')
  end
end
ok(guard_events==1,'the mismatch is logged once as prefix_changed reason=system')

print(string.format('prompt cache ok (%d checks, 0 skipped, %d captured requests)',checks,#requests))
