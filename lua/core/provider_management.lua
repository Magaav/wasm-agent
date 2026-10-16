-- Deterministic operator contract shared by CLI and UI. Never accepts a credential.
local vault=dofile('lua/core/vault.lua')
local auth=dofile('lua/core/openai_sub_auth.lua')
local M={}
M.quota='OpenCode Go monthly GoUsageLimitError is account/workspace quota, not proof of an invalid key. Replacing a key from the same exhausted workspace may still fail. No automatic retry, compaction or provider switch.'
M.routes={{id='openai-sub',label='OpenAI subscription'},{id='opencode-go',label='OpenCode Go'}}
local function operator_url(id)
  local variable=id=='opencode-go' and 'WASM_AGENT_OPENCODE_GO_OPERATOR_URL' or 'WASM_AGENT_OPENAI_SUB_OPERATOR_URL'
  local url=host.getenv(variable) or host.getenv('WASM_AGENT_VAULT_OPERATOR_URL')
  if type(url)~='string' or url:find('[%s@?#]') then return nil end
  -- An operator URL is public configuration, never a token-bearing URL. HTTP is loopback only.
  if url:match('^https://[%w%.%-]+:?%d*/?$') or url:match('^http://127%.0%.0%.1:%d+/?$') or url:match('^http://localhost:%d+/?$') then return url end
  return nil
end
function M.state(owner)
  local state=dofile('lua/core/state.lua')
  local result={providers={},selected=state.read('provider') or host.getenv('WASM_AGENT_PROVIDER') or 'opencode-go',quota=M.quota,revision=state.revision()}
  for _,item in ipairs(M.routes) do
    local row={id=item.id,label=item.label,source=vault.base(item.id) and 'vault' or 'native',entitlement='unknown',operator_url=operator_url(item.id)}
    if row.source=='vault' then
      local status,problem=vault.status(item.id)
      local entry=status and status.providers[item.id]
      row.vault_url=vault.url(item.id);row.vault_id=status and status.vault_id
      if row.operator_url and type(row.vault_id)=='string' and row.vault_id:match('^[%x%-]+$') and #row.vault_id==36 then
        row.operator_url=row.operator_url:gsub('/$','')..'/#vault='..row.vault_id
      else row.operator_url=nil end
      if entry then row.configured=entry.configured;row.enabled=entry.enabled;row.error=entry.last_error and 'vault_provider_error' or nil;row.generation=entry.generation
      else row.error=problem and problem.code or 'vault_status_unknown' end
    elseif item.id=='openai-sub' then
      if dofile('lua/core/openai_sub.lua').transport()~='native' then
        row.source='legacy Pi (explicit rollback)';row.error='Explicit rollback source; management will not change or copy its credentials.'
      else
        result.native_login=owner and auth.management_state(owner) or nil
        local status=auth.status();row.configured=status.present;row.enabled=true;row.error=status.last_error and 'subscription_authentication_error' or (not status.present and status.code or nil)
      end
    else
      row.source='legacy environment'
      row.configured=host.getenv('WASM_AGENT_LLM_API_KEY')~=nil or host.getenv('OPENCODE_GO_API_KEY')~=nil or host.getenv('OPENAI_API_KEY')~=nil
      row.enabled=true
    end
    row.management=row.source=='vault' and (row.operator_url and 'operator vault page' or 'operator setup required') or item.id=='openai-sub' and 'device login' or 'operator vault setup required'
    result.providers[#result.providers+1]=row
  end
  return result
end
function M.device(action,operation,owner)
  if dofile('lua/core/openai_sub.lua').transport()~='native' then return nil,{code='explicit_legacy_source',message='Pi rollback authentication is not changed by native management.'} end
  if vault.base('openai-sub') then return nil,{code='vault_login_required',message='Use the enrolled operator vault page for this authentication source.'} end
  return auth.manage_device(action,operation,owner)
end
function M.cli(io)
  local state=M.state('local-operator')
  io.print('  /provider — explicit selection and credential management; opening changes nothing.')
  for n,row in ipairs(state.providers) do
    io.print(string.format('  %d. %s (%s): configured=%s, enabled=%s, source=%s, entitlement=unknown%s',n,row.label,row.id,tostring(row.configured==nil and 'unknown' or row.configured),tostring(row.enabled==nil and 'unknown' or row.enabled),row.source,row.error and ', error present' or ''))
  end
  io.print('  '..M.quota)
  local choice=io.ask('  Provider [1/2, Enter cancels]: ')
  local row=state.providers[tonumber(choice or '')]
  if not row then io.print('  Cancelled; no changes.');return end
  local action=io.ask('  Action [select/manage, Enter cancels]: ')
  if action=='select' then
    local ok,problem=dofile('lua/core/provider.lua').set_provider(row.id,state.revision)
    io.print(ok and ('  Selected '..row.label..' for subsequent turns.') or ('  Selection refused: '..tostring(problem)))
  elseif action=='manage' then
    if row.source=='vault' or row.id=='opencode-go' then
      io.print(row.operator_url and ('  Open '..row.operator_url..' in your operator browser. Enroll with its dedicated admin password field; replace/cancel there. Never paste credentials into this terminal or chat. This page manages only that vault, not the selected node.') or '  Operator setup required: configure a durable isolated vault and its nonsecret WASM_AGENT_VAULT_OPERATOR_URL; see docs/VAULT.md. No key prompt opened.')
      return
    end
    local operation,login,problem
    if state.native_login then
      login=state.native_login;operation=login.operation
      local pending_action=io.ask('  Existing operator login [check/cancel, Enter keeps it pending]: ')
      if pending_action=='cancel' then
        local cancelled,err=M.device('cancel',operation,'local-operator')
        io.print(cancelled and '  Pending login cancelled; previous credential retained.' or ('  Cancel held: '..tostring(err and err.code)));return
      elseif pending_action~='check' then io.print('  Pending login retained; no action sent.');return end
    else
      if io.ask('  Confirm explicit subscription re-login (old login retained until commit) [yes/Enter cancels]: ')~='yes' then io.print('  Cancelled.');return end
      operation=host.uuid()
      login,problem=M.device('begin',operation,'local-operator')
    end
    if not login then io.print('  Login refused: '..tostring(problem and problem.code));return end
    io.print('  Open '..tostring(login.verification_url)..' and enter '..tostring(login.user_code)..'. Enter cancels.')
    while login.state~='done' do
      if io.wait(math.max(1000,(login.interval or 5)*1000))~=nil then
        local cancelled,err=M.device('cancel',operation,'local-operator')
        io.print(cancelled and '  Login cancelled; previous credential retained.' or ('  Cancel outcome unknown: '..tostring(err and err.code)));return
      end
      login,problem=M.device('poll',operation,'local-operator')
      if not login then io.print('  Login failed/held: '..tostring(problem and problem.code)..'; no automatic replay.');return end
    end
    io.print('  Fresh login committed. Entitlement remains unknown; provider selection unchanged.')
  else io.print('  Cancelled; no changes.') end
end
return M
