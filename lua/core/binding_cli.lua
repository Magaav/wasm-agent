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
  if r.scope then output('Scope: '..r.scope..' | consent: '..binding.lifetime_label(r)) end
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
      -- `permanent` is the operator's named no-expiry intent: `wa bind permanent`, `/bind permanent
      -- <service>`. Anything else keeps the ordinary 24-hour consent, so renew never drifts into it.
      local rest,lifetime=arg,'standard'
      if rest=='permanent' or rest:match('^permanent%s') then lifetime='permanent';rest=rest:gsub('^permanent%s*','') end
      local renew=rest=='renew';local service=rest
      if renew then local s,e=binding.saved();if not s then result={error=e or 'not_bound'} else service=s.service end end
      if not result then
        if service=='' then
          local suggested=binding.default_service()
          output(suggested~='' and ('Fabric HTTPS URL ['..suggested..']:') or 'Fabric HTTPS URL (e.g. https://fabric.example.com):')
          service=(read() or ''):gsub('^%s+',''):gsub('%s+$','');if service=='' then service=suggested end
        end
        local preview=binding.inspect(service)
        if not preview.ok then result=preview else
          output('Fabric: '..preview.service..' | binding protocol 1 | lifetimes: '..table.concat(preview.lifetimes or {'standard'},','))
          output('Existing identity: '..preview.identity.node_id..' | local conversation/model preserved')
          for _,p in ipairs(preview.operators) do output('Operator: '..p.node_id..' | key '..fingerprint(p)) end
          output('WARNING: these operators may run commands and access files with your current OS-user-account authority. This is NOT a workspace sandbox; root is not requested.')
          if lifetime=='permanent' then
            output('PERMANENT: this consent has NO EXPIRY instead of the 24-hour default. It stays bound and in sync until you revoke it.')
            output('RISK: a lost or stolen device, or a compromised relay, keeps access until you revoke it (/unbind) or an administrator revokes/demotes it.')
            output('An administrator must affirm this separately: a standard request is never upgraded, and asking alone grants nothing.')
          end
          output(lifetime=='permanent' and 'Consent: no expiry (permanent binding). Compare operator fingerprints through a trusted channel. No login service/jobs enabled.'
            or 'Consent: 24 hours. Compare operator fingerprints through a trusted channel. No login service/jobs enabled.')
          result=binding.begin(preview,confirmation(read,output,lifetime=='permanent' and 'PERMANENT' or 'BIND'),renew,lifetime)
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
      local permanent=binding.lifetime_of(preview.binding.request)=='permanent'
      if permanent then
        output('PERMANENT: this request asks for NO EXPIRY. Accepting grants a permanent binding, not a 24-hour one.')
        output('RISK: that node keeps access until you revoke or demote it, even if the device is lost or its relay is compromised.')
      end
      output('Compare pairing phrase on both devices. Accept as guest; NOT master or administrator.')
      result=binding.accept(preview,confirmation(read,output,permanent and 'ACCEPT-PERMANENT' or 'ACCEPT'))
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
  -- A submitted request ends in ONE copy-able line: paste it on any node of the same fabric and that is
  -- the whole hand-off (`wa accept <code>` is what the administrator side takes). The pairing phrase stays
  -- on that line as a shell comment, so a copy-paste into a terminal still runs exactly the command and
  -- both consoles can still compare the phrase. 31/10: the actionable line was buried under a JSON dump
  -- plus a side note, and the operator asked for one line.
  if result.ok and result.state=='pending' then
    if not repl then
      -- Naming who keeps the transport is the difference between "this consent is live" and "start a
      -- second process": beside a running node the CLI stands by and the node attaches by itself.
      if result.attachment=='standby' then
        output('The running node keeps the outbound transport: this consent is saved, nothing has to stay open.')
      else
        output('Saved consent is not a connected runtime: keep this foreground process, or run: wa bind run')
      end
    end
    output('wa accept '..result.code..'   # phrase '..(result.phrase or result.code))
  else
    output(json.encode(result))
  end
  return result
end
return M
