-- The speech seam's answers, one canonical line per request: the JSON the five host.stt_* capabilities
-- answer, which is what lua/core/stt.lua and server.lua read. The expected lines are
-- fixtures/stt-seam-answers.txt, RECORDED ON the pre-move build: a change to a refusal's sentence, to the
-- status view or to the pump's shapes fails here.
--
-- STT_SEAM_RECORD=1 rewrites the fixture and nothing else does. Every case is chosen to be deterministic
-- on a fresh home: no key material, no clock, no queue rows.
local json=dofile('lua/vendor/json.lua')
local function ask(name, fn, ...)
  local ok, answer = pcall(fn, ...)
  local text = tostring(answer)
  if type(answer)=='table' then text=json.encode(answer) end
  text=text:gsub('"ms":%d+','"ms":<n>'):gsub('"now":%d+','"now":<n>'):gsub('"age_s":%d+','"age_s":<n>')
  return name..' '..text
end
local cases={}
local function case(name, fn, ...) cases[#cases+1]={name=name, fn=fn, args={...}} end
case('pending', function() return host.stt_pending() end)
case('deliver_none', function() return host.stt_deliver(0, '{}') end)
case('call_empty', function() return host.stt_call('{}', 'node-a') end)
case('call_notjson', function() return host.stt_call('not an envelope', 'node-a') end)
case('submit_missing', function() return host.stt_submit('{}') end)
case('submit_notjson', function() return host.stt_submit('nope') end)
case('admin_status', function() return host.stt_admin(json.encode({action='status'})) end)
case('admin_off', function() return host.stt_admin(json.encode({action='configure', role='off'})) end)
case('admin_bad_role', function() return host.stt_admin(json.encode({action='configure', role='nonesuch'})) end)
case('admin_job', function() return host.stt_admin(json.encode({action='job', job=1})) end)
case('admin_sweep', function() return host.stt_admin(json.encode({action='sweep'})) end)
case('admin_notjson', function() return host.stt_admin('nope') end)
local produced={}
for _,c in ipairs(cases) do produced[#produced+1]=ask(c.name, c.fn, table.unpack(c.args)) end
local path='fixtures/stt-seam-answers.txt'
if host.getenv and host.getenv('STT_SEAM_RECORD')=='1' then
  local f=assert(io.open(path,'w'))
  for _,line in ipairs(produced) do f:write(line..'\n') end
  f:close()
  print(('stt seam answers recorded (%d cases)'):format(#produced))
  return
end
local expected={}
local f=assert(io.open(path,'r'),'missing fixture '..path)
for line in f:lines() do if line~='' then expected[#expected+1]=line end end
f:close()
if #expected~=#produced then print(('stt seam FAILED: %d recorded, %d produced'):format(#expected,#produced)); os.exit(1) end
local bad=0
for i,line in ipairs(produced) do
  if line~=expected[i] then
    bad=bad+1
    if bad<=3 then print(('stt seam FAILED on line %d:'):format(i)); print('  recorded: '..expected[i]:sub(1,300)); print('  produced: '..line:sub(1,300)) end
  end
end
if bad>0 then print(('stt seam FAILED (%d of %d differ)'):format(bad,#expected)); os.exit(1) end
print(('stt seam answers ok (%d cases, %d lines identical)'):format(#produced,#produced))
