-- Deterministic operator contract shared by CLI and UI. Never accepts a credential.
local vault=dofile('lua/core/vault.lua')
local M={}
M.quota='OpenCode Go monthly GoUsageLimitError is account/workspace quota, not proof of an invalid key. Replacing a key from the same exhausted workspace may still fail. No automatic retry, compaction or provider switch.'
M.routes={{id='opencode-go',label='OpenCode Go'}}
local function operator_url(id)
  local url=host.getenv('WASM_AGENT_OPENCODE_GO_OPERATOR_URL') or host.getenv('WASM_AGENT_VAULT_OPERATOR_URL')
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
    else
      row.source='legacy environment'
      local key=host.getenv('WASM_AGENT_LLM_API_KEY') or host.getenv('OPENCODE_GO_API_KEY') or host.getenv('OPENAI_API_KEY')
      row.configured=type(key)=='string' and key~=''
      row.enabled=true
    end
    row.management=row.source=='vault' and (row.operator_url and 'operator vault page' or 'operator setup required') or 'operator vault setup required'
    result.providers[#result.providers+1]=row
  end
  return result
end
-- ---- /login and /provider in `wa chat` ----------------------------------------------------------
--
-- `/login` signs in, `/provider` switches. Neither accepts a credential in the chat line: an API key
-- is pasted on the vault page or in a secret panel, never into this terminal's line editor (whose
-- lines have recall history and land in the transcript).
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
    io.print(string.format('%d. %-22s %-15s %s%s', n, row.label, 'API key', paint(text, role),
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
    options[#options + 1] = { label = row.label .. ' (API key)',
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

local function login_panel(io)
  local state = M.state('local-operator')
  local options, selected = provider_options(state)
  local answer = io.panel({ title = 'Sign in to a provider', lines = { 'Credentials go to wa-vault; this terminal never keeps them.' },
    options = options, selected = selected })
  if answer.action ~= 'select' then return false end
  local row = state.providers[answer.index]
  local outcome = key_panel(io, row)
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
  if not opencode(io, row) then return false end
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
