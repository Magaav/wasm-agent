-- Human-only command front door shared by native CLI and slash REPL; never model inference.
local json=dofile('lua/vendor/json.lua')
local binding=dofile('lua/core/binding.lua')
local M={}
local function confirmation(read,output,word)
  output('Type '..word..' to confirm, or cancel:')
  local line=read();return line and line:gsub('^%s+',''):gsub('%s+$','') or ''
end
local function fingerprint(pin) return pin.public_key end
local function describe(output,r)
  output('Node: '..tostring(r.name)..' | ID: '..r.node_id)
  output('Key: '..r.public_key)
  if r.code then output('Pairing phrase: '..r.code:sub(1,4)..'-'..r.code:sub(5,8)..'-'..r.code:sub(9,12)) end
  if r.scope then output('Scope: '..r.scope..' | consent expires: '..r.expires_at) end
end
function M.run(command,arg,read,output)
  local repl=read~=nil
  read=read or function()return io.read('*l')end;output=output or print;arg=arg or ''
  local result
  if command=='bind' then
    if arg=='status' then result=binding.status()
    elseif arg=='run' then
      if repl then local refused={ok=false,error='binding_run_native_cli_only; this conversation already owns its transport'};output(json.encode(refused));return refused end
      result=host.binding_transport and json.decode(host.binding_transport('start')) or {error='binding_host_upgrade_required'}
      output(json.encode(result));if not result.ok then return result end
      output('Outbound capability runtime active; Ctrl+C exits. No model or inbound listener.')
      while true do host.sleep(2) end
    else
      local renew=arg=='renew';local service=arg
      if renew then local s,e=binding.saved();if not s then result={error=e or 'not_bound'} else service=s.service end end
      if not result then
        if service=='' then output('Fabric HTTPS URL ['..binding.DEFAULT_SERVICE..']:');service=read() or '';if service=='' then service=binding.DEFAULT_SERVICE end end
        local preview=binding.inspect(service)
        if not preview.ok then result=preview else
          output('Fabric: '..preview.service..' | binding protocol 1')
          output('Existing identity: '..preview.identity.node_id..' | local conversation/model preserved')
          for _,p in ipairs(preview.operators) do output('Operator: '..p.node_id..' | key '..fingerprint(p)) end
          output('WARNING: these operators may run commands and access files with your current OS-user-account authority. This is NOT a workspace sandbox; root is not requested.')
          output('Consent: 24 hours. Compare operator fingerprints through a trusted channel. No login service/jobs enabled.')
          result=binding.begin(preview,confirmation(read,output,'BIND'),renew)
        end
      end
    end
  elseif command=='unbind' then result=binding.unbind()
  elseif command=='nodes' then
    if arg=='pending' then result=binding.pending() else result={nodes=dofile('lua/core/nodes.lua').list()} end
  elseif command=='accept' then
    local preview=binding.accept_preview(arg)
    if not preview.ok then result=preview else
      describe(output,preview.binding.request);output('Request digest: '..preview.binding.digest)
      output('Compare pairing phrase on both devices. Accept as guest; NOT master or administrator.')
      result=binding.accept(preview,confirmation(read,output,'ACCEPT'))
    end
  elseif command=='promote' or command=='demote' or command=='revoke' then
    local preview=binding.target(arg)
    if not preview.ok then result=preview else
      describe(output,preview.binding.request)
      if command=='revoke' then
        output('Revoke this exact network binding; future remote calls stop, in-flight effects may finish.')
        result=binding.revoke(preview,confirmation(read,output,'REVOKE'))
      else
        local word=command=='promote' and 'PROMOTE' or 'DEMOTE'
        output(command=='promote' and 'Grant network master: peer discovery/requests, NOT administrator and NOT access to every device.' or 'Grant network guest: preserve local CLI/model authority.')
        result=binding.role(preview,command=='promote' and 'master' or 'guest',confirmation(read,output,word))
      end
    end
  else result={error='binding_command_invalid'} end
  output(json.encode(result))
  if result.ok and result.state=='pending' then output('Compare pairing phrase on the administrator. This CLI must stay open; after a one-shot wa bind, use wa bind run to attach. Saved consent is not a connected runtime.') end
  return result
end
return M
