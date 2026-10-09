-- Use the production host.exec (no user state/provider) to assert real MSYS selection and output.
local json=dofile('lua/vendor/json.lua')
local result=json.decode(host.exec("printf 'quiet-host-ok'",'',10))
assert(result.ok and result.stdout=='quiet-host-ok','selected shell must preserve command/output')
-- Put the PowerShell diagnostic in a generated private script, not shell quoting.
local script=assert(host.getenv('WA_QUIET_PROBE'))
local probe=json.decode(host.exec('powershell.exe -NoProfile -NonInteractive -File "'..script..'"','',10))
assert(probe.ok and probe.stdout:find('quiet',1,true),'ordinary descendant must not allocate a console')
print(json.encode({ok=true,skipped=0,checks=2,scope='real quiet host command and descendant console proof'}))
