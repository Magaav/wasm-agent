-- Derived from preserved child9306399f long-command regression: sentinel,
-- exact script bytes, short-command compatibility, durable stderr metadata.
-- 2026-10-28: Git-Bash cuts a `-c` string at 8192 bytes (measured: a 9000-byte
-- command ran, did nothing, exited 0), so a long command is staged to a private
-- file and run as `bash <file>` instead of being refused.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function ok(v,label) checks=checks+1;assert(v,label) end
local long='#'..string.rep('x',29999)..'\necho REACHED\n'
local result=json.decode(host.exec(long))
if dofile('lua/core/platform.lua').os()=='windows' then
 ok(result.code==0,'long command exit: '..json.encode(result.code))
 ok(tostring(result.stdout):find('REACHED',1,true),'long command ran from a staged file: '..json.encode(result))
 ok(type(result.staged_script)=='string','result names the staged script: '..json.encode(result))
else
 ok(result.stdout:find('REACHED',1,true),'non-Windows direct launch')
end
-- Still bounded: an absurd script is refused by name rather than written to disk.
local absurd=json.decode(host.exec('#'..string.rep('x',1100000)..'\necho NOPE\n'))
ok(tostring(absurd.error or absurd.stderr):find('shell_command_too_long',1,true),'absurd script refused: '..json.encode(absurd))
local root=tostring(host.paths().temp):gsub('\\','/')
local target=root..'/wa-long-'..host.uuid()..'.sh'
local staged='#'..string.rep('x',9999)..'\necho REACHED\n'
ok(host.write_file(target,staged)~=false,'stage script')
ok(host.read_file(target)==staged,'script preserves exact requested bytes')
local manual=json.decode(host.exec("bash '"..target.."'"))
ok(manual.code==0 and manual.stdout:find('REACHED',1,true),'script-backed exact command executes sentinel')
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
