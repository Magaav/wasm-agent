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
  if owner then
    local json=dofile('lua/vendor/json.lua')
    local identity=json.decode(host.node_identity())
    -- Hash public node/account identity only, never an authentication token or credential.
    result.embed_scope=host.sha256('provider-embed-v1:'..tostring(identity.node_id)..':'..owner)
  end
  for _,item in ipairs(M.routes) do
    local row={id=item.id,label=item.label,source=vault.base(item.id) and 'vault' or 'native',entitlement='unknown',operator_url=operator_url(item.id)}
    if row.source=='vault' then
      local status,problem=vault.status(item.id)
      local entry=status and status.providers[item.id]
      row.vault_url=vault.url(item.id);row.vault_id=status and status.vault_id
      if row.operator_url and type(row.vault_id)=='string' and row.vault_id:match('^[%x%-]+$') and #row.vault_id==36 then
        row.operator_url=row.operator_url:gsub('/$','')..'/#vault='..row.vault_id
        if item.id=='opencode-go' then row.embed_url=row.operator_url:gsub('/#vault=.*$','')..'/embed/go' end
      else row.operator_url=nil end
      if type(entry)=='table' then row.configured=entry.configured;row.enabled=entry.enabled;row.error=entry.last_error and 'vault_provider_error' or nil;row.generation=entry.generation;row.operation=entry.operation
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
      local key=host.getenv('WASM_AGENT_LLM_API_KEY') or host.getenv('OPENCODE_GO_API_KEY') or host.getenv('OPENAI_API_KEY')
      row.configured=type(key)=='string' and key~=''
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
-- ---- /login and /provider in `wa chat` ----------------------------------------------------------
--
-- `/login` signs in, `/provider` switches. Neither accepts a credential: a ChatGPT login is a
-- device code entered in the browser, and an API key is pasted on the vault page, never into this
-- terminal (whose lines have recall history and land in the transcript).
--
-- `io`: print(text), ask(question) -> line|nil, wait(ms) -> line|nil (returns early when the reader
-- presses Enter), paint(text, role) -> text (optional).
local CHECK, CROSS = '\226\156\148', '\226\156\151'
local function trim(text) return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function yes(answer, default)
  answer = trim(answer):lower()
  if answer == '' then return default end
  return answer == 'y' or answer == 'yes' or answer == 's' or answer == 'sim'
end
local function painter(io) return io.paint or function(text) return text end end

local function describe(row)
  if row.source == 'legacy Pi (explicit rollback)' then return 'legacy Pi credentials (not managed here)', 'muted' end
  if row.configured == true then
    local text = CHECK .. ' signed in' .. (row.enabled == false and ', disabled on the vault page' or '')
    if row.error then text = text .. ' (last use failed)' end
    return text .. (row.source == 'vault' and ' \194\183 wa-vault' or ''), row.enabled == false and 'warning' or 'success'
  end
  if row.configured == false then return 'not signed in', 'muted' end
  return 'status unknown (' .. tostring(row.error or 'no answer') .. ')', 'warning'
end

local function vault_page(row)
  if row.operator_url then return row.operator_url end
  return 'the wa-vault admin page (set WASM_AGENT_VAULT_OPERATOR_URL to have it linked here)'
end

local function list(io, state, title)
  local paint = painter(io)
  io.print('' .. paint(title, 'bold'))
  io.print('')
  for n, row in ipairs(state.providers) do
    local text, role = describe(row)
    local kind = row.id == 'openai-sub' and 'ChatGPT login' or 'API key'
    io.print(string.format('%d. %-22s %-15s %s%s', n, row.label, kind, paint(text, role),
      row.id == state.selected and paint(' \194\183 in use', 'accent') or ''))
  end
  io.print('')
end

local function choose(io, state, title, question)
  list(io, state, title)
  local answer = trim(io.ask(question))
  for n, row in ipairs(state.providers) do
    if answer == tostring(n) or answer == row.id then return row end
  end
  io.print('' .. (answer == '' and 'Cancelled.' or ('No provider ' .. answer .. '. Cancelled.')))
  return nil
end

local function code_box(io, url, code)
  local paint = painter(io)
  io.print('')
  io.print('Open ' .. paint(tostring(url), 'mdLink'))
  io.print('and enter the code  ' .. paint(tostring(code), { 'bold', 'accent' }))
  io.print('')
  io.print(paint('Waiting for you to finish in the browser\226\128\166 (Enter stops waiting)', 'muted'))
end

-- ChatGPT through wa-vault: the node-side door starts a first device login, or answers the one
-- already pending - which is what makes a second `/login` resume instead of failing.
local function chatgpt_vault(io, row)
  local paint = painter(io)
  if row.configured then
    io.print('' .. paint(CHECK, 'success') .. ' Already signed in to ChatGPT (held by wa-vault).')
    io.print('To sign in with another account, replace the login on ' .. vault_page(row) .. '.')
    return true
  end
  local started, problem = vault.start_subscription_login()
  if not started then io.print('' .. paint(CROSS, 'error') .. ' Could not start the ChatGPT login: ' .. tostring(problem)); return false end
  local login = started.login or {}
  if login.state ~= 'pending' or not login.user_code then
    io.print('' .. paint(CROSS, 'error') .. ' The vault did not hand out a code (state ' .. tostring(login.state) .. ').')
    return false
  end
  code_box(io, login.verification_url, login.user_code)
  while true do
    if io.wait(3000) ~= nil then
      io.print('Stopped waiting. The code stays valid ~15 min: finish in the browser, then run /login again.')
      return false
    end
    local current, poll_problem = vault.login_state()
    if not current then io.print('' .. paint(CROSS, 'error') .. ' ' .. tostring(poll_problem)); return false end
    local now = current.login or {}
    if now.operation ~= login.operation then
      io.print('' .. paint(CROSS, 'error') .. ' The login was replaced or cancelled elsewhere (vault page).'); return false
    end
    if now.state == 'done' then
      local entry = (current.providers or {})['openai-sub'] or {}
      io.print('' .. paint(CHECK, 'success') .. ' Signed in to ChatGPT'
        .. (type(entry.account) == 'string' and (' (account ' .. entry.account .. ')') or '') .. '.')
      return true
    end
    if now.state == 'error' then io.print('' .. paint(CROSS, 'error') .. ' Login failed: ' .. tostring(now.error)); return false end
    if now.state ~= 'pending' and now.state ~= 'starting' then
      io.print('' .. paint(CROSS, 'error') .. ' The login was cancelled.'); return false
    end
  end
end

-- ChatGPT without a vault: this node's own device flow (`openai_sub_auth.manage_device`).
local function chatgpt_native(io, row, state)
  local paint = painter(io)
  if row.source ~= 'native' then io.print('' .. tostring(row.error)); return false end
  local operation, login, problem
  if state.native_login and state.native_login.state == 'pending' then
    login = state.native_login; operation = login.operation
    io.print('Resuming the sign-in already in progress.')
  else
    if row.configured and not yes(io.ask('Already signed in to ChatGPT. Sign in again (the current login stays until the new one completes)? [y/N]'), false) then
      return true
    end
    operation = host.uuid()
    login, problem = M.device('begin', operation, 'local-operator')
  end
  if not login then io.print('' .. paint(CROSS, 'error') .. ' Login refused: ' .. tostring(problem and (problem.message or problem.code))); return false end
  code_box(io, login.verification_url, login.user_code)
  while login.state ~= 'done' do
    if io.wait(math.max(1000, (login.interval or 5) * 1000)) ~= nil then
      local cancelled, err = M.device('cancel', operation, 'local-operator')
      io.print(cancelled and 'Login cancelled; the previous login (if any) is kept.'
        or ('Cancel outcome unknown: ' .. tostring(err and err.code)))
      return false
    end
    login, problem = M.device('poll', operation, 'local-operator')
    if not login then
      io.print('' .. paint(CROSS, 'error') .. ' Login failed: ' .. tostring(problem and (problem.message or problem.code)) .. '; nothing replayed.')
      return false
    end
  end
  io.print('' .. paint(CHECK, 'success') .. ' Signed in to ChatGPT.')
  return true
end

local function opencode(io, row)
  local paint = painter(io)
  if row.source ~= 'vault' then
    if row.configured then io.print('' .. paint(CHECK, 'success') .. ' OpenCode Go key found in the environment.'); return true end
    io.print('Set OPENCODE_GO_API_KEY in this node\'s environment, or run it with WASM_AGENT_VAULT_URL to use wa-vault.')
    return false
  end
  if row.configured then
    io.print('' .. paint(CHECK, 'success') .. ' An OpenCode Go key is stored in wa-vault. Replace it on ' .. vault_page(row) .. '.')
    return true
  end
  io.print('Paste the key on the vault page (keys never go through this terminal):')
  io.print(painter(io)(vault_page(row), 'mdLink'))
  if trim(io.ask('Press Enter once it is saved (or type q to stop):')):lower() == 'q' then return false end
  local fresh = M.state()
  for _, item in ipairs(fresh.providers) do
    if item.id == row.id and item.configured then
      io.print('' .. paint(CHECK, 'success') .. ' wa-vault now holds an OpenCode Go key.'); return true
    end
  end
  io.print('' .. paint(CROSS, 'error') .. ' wa-vault still has no key for OpenCode Go.')
  return false
end

local function switch(io, row, state)
  local paint = painter(io)
  local ok, problem = dofile('lua/core/provider.lua').set_provider(row.id, state.revision)
  io.print(ok and (paint(CHECK, 'success') .. ' Now using ' .. row.label .. ' for the next turns.')
    or (paint(CROSS, 'error') .. ' Could not switch: ' .. tostring(problem)))
  return ok
end

-- ---- the same flows as panels (Claude Code style; Esc closes, back to the chat) -------------------

local function provider_options(state)
  local options, selected = {}, 1
  for n, row in ipairs(state.providers) do
    local text = describe(row)
    options[#options + 1] = { label = row.label .. (row.id == 'openai-sub' and ' (ChatGPT login)' or ' (API key)'),
      hint = text .. (row.id == state.selected and ' \194\183 in use' or '') }
    if row.id == state.selected then selected = n end
  end
  return options, selected
end

local function done_line(io, ok, text)
  local paint = painter(io)
  io.print(paint('\226\143\186', ok and 'success' or 'error') .. ' ' .. text)
end

-- After a credential is in place: use it now? Returns the line for the transcript.
local function offer_switch(io, row, saved)
  local state = M.state()
  if state.selected == row.id then return saved .. ' \194\183 ' .. row.label .. ' is in use' end
  local current = 'the current provider'
  for _, item in ipairs(state.providers) do if item.id == state.selected then current = item.label end end
  local answer = io.panel({ title = row.label, lines = { CHECK .. ' ' .. saved .. '.' },
    options = { { label = 'Use ' .. row.label .. ' for this chat' }, { label = 'Keep ' .. current } } })
  if answer.action == 'select' and answer.index == 1 then
    local ok, problem = dofile('lua/core/provider.lua').set_provider(row.id, state.revision)
    return ok and (saved .. ' \194\183 now using ' .. row.label) or (saved .. ' \194\183 could not switch: ' .. tostring(problem))
  end
  return saved
end

local function key_panel(io, row)
  if row.source ~= 'vault' then
    io.panel({ title = row.label, lines = { 'This node has no wa-vault (WASM_AGENT_VAULT_URL is unset).',
      'Set OPENCODE_GO_API_KEY in its environment instead.' }, options = { { label = 'Back' } } })
    return nil
  end
  if row.configured then
    local answer = io.panel({ title = row.label, lines = { CHECK .. ' A key is stored in wa-vault (keys/opencode-go.key).' },
      options = { { label = 'Replace the key' }, { label = 'Keep it' } } })
    if answer.action ~= 'select' then return nil end
    if answer.index == 2 then return offer_switch(io, row, 'OpenCode Go key kept') end
  end
  local lines = { 'Paste your OpenCode Go key. wa hands it straight to wa-vault, which keeps',
    'it in keys/opencode-go.key - the agent can use it, never read it.' }
  while true do
    local answer = io.panel({ title = 'OpenCode Go API key', lines = lines, input = 'secret', placeholder = 'sk-...' })
    if answer.action ~= 'submit' then return nil end
    local key = trim(answer.text)
    answer = nil
    if key ~= '' then
      local stored, problem = vault.set_key('opencode-go', key)
      key = nil
      if stored then return offer_switch(io, row, 'OpenCode Go key saved in wa-vault') end
      lines = { CROSS .. ' Not saved: ' .. tostring(problem), 'Paste the key again, or Esc to go back.' }
    end
  end
end

local function chatgpt_panel(io, row, state)
  if row.source == 'vault' and row.configured then
    local answer = io.panel({ title = 'ChatGPT', lines = { CHECK .. ' Signed in (the login is held by wa-vault).',
      'To use another account, replace it on the vault page:', vault_page(row) },
      options = { { label = 'Use ChatGPT for this chat' }, { label = 'Back' } } })
    if answer.action ~= 'select' or answer.index ~= 1 then return nil end
    local ok, problem = dofile('lua/core/provider.lua').set_provider(row.id, M.state().revision)
    return ok and 'Now using OpenAI subscription' or ('Could not switch: ' .. tostring(problem))
  end
  local login, problem, operation, native = nil, nil, nil, row.source ~= 'vault'
  if native then
    if row.source ~= 'native' then
      io.panel({ title = 'ChatGPT', lines = { tostring(row.error) }, options = { { label = 'Back' } } }); return nil
    end
    if state.native_login and state.native_login.state == 'pending' then
      login = state.native_login
    else
      if row.configured then
        local answer = io.panel({ title = 'ChatGPT', lines = { CHECK .. ' Already signed in on this node.' },
          options = { { label = 'Sign in again (the current login stays until the new one completes)' }, { label = 'Back' } } })
        if answer.action ~= 'select' or answer.index ~= 1 then return nil end
      end
      login, problem = M.device('begin', host.uuid(), 'local-operator')
    end
    operation = login and login.operation
  else
    local started
    started, problem = vault.start_subscription_login()
    login = started and started.login
    if login and (login.state ~= 'pending' or not login.user_code) then problem = 'the vault handed out no code'; login = nil end
  end
  if not login then
    io.panel({ title = 'ChatGPT', lines = { CROSS .. ' Could not start the sign-in: ' .. tostring(problem and (problem.message or problem.code) or problem) },
      options = { { label = 'Back' } } })
    return nil
  end
  local lines = { '1. Open  ' .. tostring(login.verification_url), '2. Enter the code  ' .. tostring(login.user_code), '',
    'Waiting for you to finish in the browser\226\128\166' }
  while true do
    local answer = io.panel({ title = 'Sign in to ChatGPT', lines = lines, timeout_ms = native and math.max(1000, (login.interval or 5) * 1000) or 3000,
      hint = 'Esc to stop waiting (the code stays valid ~15 min)' })
    if answer.action ~= 'timeout' then
      if native then M.device('cancel', operation, 'local-operator') end
      return nil
    end
    if native then
      local now, poll_problem = M.device('poll', operation, 'local-operator')
      if not now then lines = { CROSS .. ' Login failed: ' .. tostring(poll_problem and (poll_problem.message or poll_problem.code)) }
        io.panel({ title = 'ChatGPT', lines = lines, options = { { label = 'Back' } } }); return nil end
      if now.state == 'done' then return offer_switch(io, row, 'Signed in to ChatGPT') end
    else
      local current, poll_problem = vault.login_state()
      local now = current and current.login or {}
      if not current or now.operation ~= login.operation or now.state == 'error'
          or (now.state ~= 'pending' and now.state ~= 'starting' and now.state ~= 'done') then
        io.panel({ title = 'ChatGPT', lines = { CROSS .. ' ' .. tostring(poll_problem or now.error or 'the sign-in was cancelled') },
          options = { { label = 'Back' } } })
        return nil
      end
      if now.state == 'done' then return offer_switch(io, row, 'Signed in to ChatGPT') end
    end
  end
end

local function login_panel(io)
  local state = M.state('local-operator')
  local options, selected = provider_options(state)
  local answer = io.panel({ title = 'Sign in to a provider', lines = { 'Credentials go to wa-vault; this terminal never keeps them.' },
    options = options, selected = selected })
  if answer.action ~= 'select' then return false end
  local row = state.providers[answer.index]
  local outcome = row.id == 'openai-sub' and chatgpt_panel(io, row, state) or key_panel(io, row)
  if outcome then done_line(io, true, outcome) end
  return outcome ~= nil
end

local function provider_panel(io)
  local state = M.state('local-operator')
  local options, selected = provider_options(state)
  local answer = io.panel({ title = 'Switch provider', lines = { 'The next turns use the provider you pick.' },
    options = options, selected = selected })
  if answer.action ~= 'select' then return false end
  local row = state.providers[answer.index]
  if row.id == state.selected then return true end
  if row.configured == false then done_line(io, false, row.label .. ' has no credential yet - /login signs in first'); return false end
  local ok, problem = dofile('lua/core/provider.lua').set_provider(row.id, state.revision)
  done_line(io, ok, ok and ('Now using ' .. row.label) or ('Could not switch: ' .. tostring(problem)))
  return ok
end

function M.login_cli(io)
  if io.panel then return login_panel(io) end
  local state = M.state('local-operator')
  local row = choose(io, state, 'Sign in to a provider', 'Choose 1-' .. #state.providers .. ' (Enter to cancel):')
  if not row then return false end
  local signed
  if row.id == 'openai-sub' then
    if row.source == 'vault' then signed = chatgpt_vault(io, row) else signed = chatgpt_native(io, row, state) end
  else
    signed = opencode(io, row)
  end
  if not signed then return false end
  if state.selected == row.id then
    io.print('' .. row.label .. ' is already the provider in use.')
  elseif yes(io.ask('Use ' .. row.label .. ' for this chat? [Y/n]'), true) then
    switch(io, row, M.state())
  end
  return true
end

function M.provider_cli(io)
  if io.panel then return provider_panel(io) end
  local state = M.state('local-operator')
  local row = choose(io, state, 'Switch provider', 'Switch to 1-' .. #state.providers .. ' (Enter to cancel):')
  if not row then return false end
  if row.id == state.selected then io.print('Already using ' .. row.label .. '.'); return true end
  if row.configured == false then
    io.print('' .. row.label .. ' has no credential yet - /login signs in first.')
    return false
  end
  return switch(io, row, state)
end

-- The earlier name: `/login`.
M.cli = M.login_cli
return M
