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
-- is pasted in the balloon's secret field or on the vault page, never into this terminal's line editor
-- (whose lines have recall history and land in the transcript).
--
-- Both are the same balloon every other command uses (`lua/core/balloon.lua`): the provider list is a
-- page, a provider is a page, the key is a page with `input = "secret"`, and the outcome is a page that
-- says what happened. There is no second, numbered rendering - a pipe gets the same pages as text from
-- the same renderer - and no `io.panel` of this file's own.
--
-- `io`: show(pages) -> {action, index|line}, print(text). Both come from `balloon.for_view`.
local CHECK, CROSS = '\226\156\148', '\226\156\151'
local balloon = dofile('lua/core/balloon.lua')

local function trim(text) return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function describe(row)
  if row.configured == true then
    local text = CHECK .. ' signed in' .. (row.enabled == false and ', disabled on the vault page' or '')
    if row.error then text = text .. ' (last use failed)' end
    return text .. (row.source == 'vault' and ' \194\183 wa-vault' or '')
  end
  if row.configured == false then return 'not signed in' end
  return 'status unknown (' .. tostring(row.error or 'no answer') .. ')'
end

local function vault_page(row)
  if row.operator_url then return row.operator_url end
  return 'the wa-vault admin page (set WASM_AGENT_VAULT_OPERATOR_URL to have it linked here)'
end

-- A page that says what just happened, and closes.
local function outcome(text)
  return balloon.page({
    title = 'Done',
    lines = balloon.wrap(text, balloon.WIDTH, ''),
    options = { { label = 'Close', hint = 'Esc closes too', back = true } },
  })
end

-- Use this provider from the next turn, as a page that says whether it worked.
local function use(row, io, saved)
  local state = M.state()
  if state.selected == row.id then return outcome(saved .. ' \194\183 ' .. row.label .. ' is in use') end
  if row.configured == false then return outcome(CROSS .. ' ' .. row.label .. ' has no credential yet - sign in first') end
  local ok, problem = dofile('lua/core/provider.lua').set_provider(row.id, state.revision)
  return outcome(ok and (CHECK .. ' ' .. saved .. ' \194\183 now using ' .. row.label)
    or (CROSS .. ' ' .. saved .. ' \194\183 could not switch: ' .. tostring(problem)))
end

-- The secret field for one provider's key: one page, bullets in the renderer, and the text never leaves
-- this function - it goes to wa-vault and is dropped.
local function key_page(row, io, lines, placeholder)
  return balloon.page({
    title = row.label .. ' API key',
    lines = lines,
    input = 'secret',
    placeholder = placeholder or 'sk-...',
    act = function(text)
      local key = trim(text)
      if key == '' then return key_page(row, io, { CROSS .. ' Nothing typed. Paste the key, or Esc to go back.' }) end
      local stored, problem = vault.set_key(row.id, key)
      key = nil
      if not stored then
        return key_page(row, io, { CROSS .. ' Not saved: ' .. tostring(problem), 'Paste the key again, or Esc to go back.' })
      end
      return use(row, io, CHECK .. ' ' .. row.label .. ' key saved in wa-vault')
    end,
  })
end

-- One provider, as a page: how it stands, where the vault is, and what can be done from here.
local function provider_page(row, io)
  local options = {}
  if row.configured == true then
    options[#options + 1] = { label = 'Replace the key', hint = 'wa-vault keys/' .. row.id .. '.key',
      act = function() return key_page(row, io, {
        'Paste your ' .. row.label .. ' key. wa hands it straight to wa-vault, which keeps',
        'it in keys/' .. row.id .. '.key - the agent can use it, never read it.',
      }) end }
  elseif row.source == 'vault' then
    options[#options + 1] = { label = 'Paste the key', hint = 'straight to wa-vault, never kept here',
      act = function() return key_page(row, io, {
        'Paste your ' .. row.label .. ' key. wa hands it straight to wa-vault, which keeps',
        'it in keys/' .. row.id .. '.key - the agent can use it, never read it.',
      }) end }
  end
  options[#options + 1] = { label = 'Use for this chat', hint = 'the next turns use it',
    act = function() return use(row, io, '') end }
  options[#options + 1] = { label = 'Back', hint = 'the provider list', back = true }
  local lines = {
    describe(row),
    'source: ' .. tostring(row.source) .. ' \194\183 keys: ' .. (row.source == 'vault' and ('keys/' .. row.id .. '.key') or 'environment'),
    'vault: ' .. tostring(vault_page(row)),
  }
  if row.source ~= 'vault' then
    lines[#lines + 1] = 'This node has no wa-vault for it: set the key in its environment instead '
      .. '(the vault setup is on the vault page above).'
  end
  return balloon.page({ title = row.label, lines = lines, options = options, selected = 1 })
end

-- The list, as pages: one page for the reader, a provider page behind each option. This is what `/login`
-- opens, what `/provider` opens (with the switch hint first), and what a pipe gets as text.
function M.login_views(state, io)
  state = state or M.state('local-operator')
  local pages = { balloon.page({
    title = 'Sign in to a provider',
    lines = {
      'Credentials go to wa-vault; this terminal never keeps them.',
      'Enter opens a provider \194\183 Esc or \226\134\144 closes',
    },
    options = {},
    selected = 1,
  }) }
  for index, row in ipairs(state.providers) do
    -- "· in use" is the one thing the old printed list said that the balloon must not lose: which provider
    -- the next turn will actually use.
    pages[1].options[#pages[1].options + 1] = { label = row.label,
      hint = describe(row) .. (row.id == state.selected and ' \194\183 in use' or ''), page = index + 1 }
    pages[index + 1] = provider_page(row, io)
  end
  return pages
end

function M.provider_views(state, io)
  state = state or M.state('local-operator')
  local pages = M.login_views(state, io)
  pages[1].title = 'Switch provider'
  pages[1].lines = { 'The next turns use the provider you pick.' }
  return pages
end

function M.login_cli(io)
  io = io or {}
  local pages = M.login_views(M.state('local-operator'), io)
  if io.show then
    local answer = io.show(pages)
    -- An option that queued a line (`/login` has none) is the caller's to run; nothing here changes
    -- state after the balloon closes, so the reader's choice is the whole result.
    return type(answer) == 'table' and answer.action ~= 'cancel'
  end
  -- A pipe gets every page: the list and each provider's own page (its vault link included), which is
  -- what the printed fallback showed before there was a balloon.
  if io.print then io.print(balloon.text(pages, balloon.WIDTH)) end
  return false
end

function M.provider_cli(io)
  io = io or {}
  local pages = M.provider_views(M.state('local-operator'), io)
  if io.show then
    local answer = io.show(pages)
    return type(answer) == 'table' and answer.action ~= 'cancel'
  end
  if io.print then io.print(balloon.text(pages, balloon.WIDTH)) end
  return false
end

-- The earlier name: `/login`.
M.cli = M.login_cli
return M
