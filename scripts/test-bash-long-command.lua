-- Derived from preserved child9306399f long-command regression: sentinel,
-- exact script bytes, short-command compatibility, durable stderr metadata.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function ok(v,label) checks=checks+1;assert(v,label) end
local long='#'..string.rep('x',9999)..'\necho REACHED\n'
local result=json.decode(host.exec(long))
if dofile('lua/core/platform.lua').os()=='windows' then
 ok(tostring(result.error or result.stderr):find('shell_command_too_long',1,true),'named preflight refusal: '..json.encode(result))
 ok(tostring(result.error or result.stderr):find(tostring(#long),1,true),'refusal names exact bytes')
else
 ok(result.stdout:find('REACHED',1,true),'non-Windows direct launch')
end
local root=tostring(host.paths().temp):gsub('\\','/')
local target=root..'/wa-long-'..host.uuid()..'.sh'
ok(host.write_file(target,long)~=false,'stage script')
ok(host.read_file(target)==long,'script preserves exact requested bytes')
local staged=json.decode(host.exec("bash '"..target.."'"))
ok(staged.code==0 and staged.stdout:find('REACHED',1,true),'script-backed exact command executes sentinel')
local short=json.decode(host.exec('echo SHORT-OK'))
ok(short.stdout:find('SHORT-OK',1,true),'short command unchanged')
local background=json.decode(host.exec("printf '%09000d' 0 >&2; sleep 60 &"))
ok(background.promoted==true,'adopted receipt')
ok(background.stderr_bytes==9000 and background.stderr_truncated==true,'output bound is explicit')
ok(#host.read_file(background.stderr_path)==9000,'full stderr durable')
local cancelled=json.decode(host.operation('cancel',json.encode({id=background.operation_id})))
local settled=json.decode(host.operation('await',json.encode({id=background.operation_id,wait_for='settled'})))
ok(settled.settled==true,'owned descendants settled')
host.exec("rm -f '"..target.."'")
print('bash long command ok ('..checks..' checks)')
