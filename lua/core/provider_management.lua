-- Deterministic operator contract shared by CLI and UI. Never accepts a credential.
local vault=dofile('lua/core/vault.lua')
local M={}
M.quota='OpenCode Go monthly GoUsageLimitError is account/workspace quota, not proof of an invalid key. Replacing a key from the same exhausted workspace may still fail. No automatic retry, compaction or provider switch.'
M.routes={{id='opencode-go',label='OpenCode Go'},{id='anthropic',label='Anthropic (Claude subscription)',subscription=true}}
local function operator_url(id)
  local url=host.getenv('WASM_AGENT_OPENCODE_GO_OPERATOR_URL') or host.getenv('WASM_AGENT_VAULT_OPERATOR_URL')
  if type(url)~='string' or url:find('[%s@?#]') then return nil end
  -- An operator URL is public configuration, never a token-bearing URL. HTTP is loopback only.
  if url:match('^https://[%w%.%-]+:?%d*/?$') or url:match('^http://127%.0%.0%.1:%d+/?$') or url:match('^http://localhost:%d+/?$') then return url end
  return nil
end
-- THE VAULT STATUS IS THE WHOLE COST OF /login, AND IT WAS PAID ON EVERY PAINT (claude-inside-wa, slice 4).
--
-- Measured on this node (28/11, scratch home, one provider): provider_management.state() 53.0 / 52.8 / 52.7 ms,
-- of which vault.status() alone is 51.6 ms and the balloon's own pages cost 0.01 ms. So Enter->list paint is a
-- wait on a vault round trip per provider, spent before anything is drawn.
--
-- A SHORT CACHE, and why the TTL is short: /login must show what the vault says, but two paints a second apart
-- cannot disagree about a key that a human is about to paste - the next action that CHANGES a provider clears
-- this cache by bumping the generation below. WA_LOGIN_STATUS_TTL_MS=0 restores the old always-ask behaviour.
local status_cache = {at = nil, generation = nil, by_id = {}}

local function status_ttl_ms()
  local set = tonumber(host.getenv('WA_LOGIN_STATUS_TTL_MS') or '')
  if set and set >= 0 then return set end
  -- 30 s, not 2: the point of the cache is that the FIRST /login of a session is cheap, and it is cheap only if
  -- the entry written at STARTUP is still good when the reader types it (the warming call below). A provider
  -- changed by anyone else is a vault edit that the next action clears.
  return 30000
end

-- A cached status per provider, refilled when the generation moves or the TTL lapses.
local function vault_status(id)
  local ttl = status_ttl_ms()
  local now = host.monotonic_ms()
  local generation = tostring(M.quota_generation or '')
  if ttl > 0 and status_cache.at and status_cache.generation == generation and (now - status_cache.at) < ttl then
    local hit = status_cache.by_id[id]
    if hit then return hit.status, hit.problem end
  end
  if not status_cache.at or status_cache.generation ~= generation or (now - status_cache.at) >= ttl then
    status_cache.by_id = {}
    status_cache.at = now
    status_cache.generation = generation
  end
  local status, problem = vault.status(id)
  status_cache.by_id[id] = { status = status, problem = problem }
  return status, problem
end

-- Any action that changes a provider (a key pasted, a switch) must not be served from the cache.
function M.status_cache_clear()
  status_cache.at = nil
  status_cache.by_id = {}
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
    local row={id=item.id,label=item.label,subscription=item.subscription,source=vault.base(item.id) and 'vault' or 'native',entitlement='unknown',operator_url=operator_url(item.id)}
    if row.source=='vault' then
      local status,problem=vault_status(item.id)
      local entry=status and status.providers[item.id]
      row.vault_url=vault.url(item.id);row.vault_id=status and status.vault_id
      if row.operator_url and type(row.vault_id)=='string' and row.vault_id:match('^[%x%-]+$') and #row.vault_id==36 then
        row.operator_url=row.operator_url:gsub('/$','')..'/#vault='..row.vault_id
        if item.id=='opencode-go' then row.embed_url=row.operator_url:gsub('/#vault=.*$','')..'/embed/go' end
      else row.operator_url=nil end
      if type(entry)=='table' then row.configured=entry.configured;row.enabled=entry.enabled;row.error=entry.last_error and 'vault_provider_error' or nil;row.generation=entry.generation;row.operation=entry.operation
        -- A subscription's accounts, presence only: which are signed in, which is active, which was refused.
        if item.subscription then row.accounts=type(entry.accounts)=='table' and entry.accounts or {};row.active=entry.active;row.refused=entry.refused end
      else row.error=problem and problem.code or 'vault_status_unknown' end
    elseif item.subscription then
      -- The tokens live in wa-vault or nowhere: without one this node has no place to keep a sign-in.
      row.source='no vault';row.configured=false;row.enabled=false;row.accounts={}
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

local function account_label(row, name)
  for _, account in ipairs(row.accounts or {}) do
    if account.account == name then return tostring(account.label or name) end
  end
  return tostring(name)
end

local function describe(row)
  if row.subscription then
    if row.source == 'no vault' then return 'needs wa-vault (set WASM_AGENT_VAULT_URL)' end
    if row.refused then return CROSS .. ' sign-in refused (' .. tostring(row.refused) .. ') - sign in again' end
    if row.configured == true then
      local more = #(row.accounts or {}) > 1 and (' \194\183 ' .. #row.accounts .. ' accounts') or ''
      return CHECK .. ' signed in as ' .. account_label(row, row.active) .. more .. ' \194\183 wa-vault'
    end
  end
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
      -- The key just changed, so the cached status is stale by definition: the next paint must ask.
      M.status_cache_clear()
      key = nil
      if not stored then
        return key_page(row, io, { CROSS .. ' Not saved: ' .. tostring(problem), 'Paste the key again, or Esc to go back.' })
      end
      return use(row, io, CHECK .. ' ' .. row.label .. ' key saved in wa-vault')
    end,
  })
end

-- THE CLAUDE SUBSCRIPTION SIGN-IN: the vault makes the link (OAuth with PKCE, the flow pi uses), the
-- person opens it in any browser and signs in, Anthropic shows a code, and the code is pasted into a
-- secret field here. It goes to wa-vault, which trades it for the account's tokens and keeps them;
-- nothing in this process ever holds a token.
local function code_page(row, io, lines)
  return balloon.page({
    title = row.label .. ' - paste the code',
    lines = lines,
    input = 'secret',
    placeholder = 'code#state',
    act = function(text)
      local code = trim(text)
      if code == '' then return code_page(row, io, { CROSS .. ' Nothing pasted. Paste the code Anthropic shows, or Esc.' }) end
      local done, problem = vault.anthropic_login_finish(code)
      code = nil
      M.status_cache_clear()
      if not done then
        return code_page(row, io, { CROSS .. ' Not signed in: ' .. tostring(problem),
          'Paste the code again, or Esc and start the sign-in again from /login.' })
      end
      local entry = type(done.providers) == 'table' and done.providers.anthropic or {}
      row.accounts, row.active, row.configured, row.refused = entry.accounts or {}, entry.active, true, nil
      return use(row, io, CHECK .. ' signed in as ' .. account_label(row, entry.active))
    end,
  })
end

local function sign_in(row, io)
  local started, problem = vault.anthropic_login_start()
  if not started or type(started.url) ~= 'string' then
    return outcome(CROSS .. ' Could not start the sign-in: ' .. tostring(problem))
  end
  -- The link is too long for a box line, so it is printed whole, where it can be copied.
  if io.print then io.print('Open this link in a browser and sign in to Claude:\n' .. started.url) end
  return code_page(row, io, {
    '1. Open the sign-in link printed above this box, in any browser.',
    '2. Sign in with your Claude Pro/Max account and approve.',
    '3. Anthropic shows a code: copy it and paste it here.',
  })
end

local function switch_account(row, account)
  local done, problem = vault.anthropic_use(account)
  M.status_cache_clear()
  if not done then return outcome(CROSS .. ' Could not switch: ' .. tostring(problem)) end
  return outcome(CHECK .. ' ' .. row.label .. ' now uses ' .. account_label(row, account))
end

local function subscription_page(row, io)
  local options = {}
  if row.source == 'vault' then
    options[#options + 1] = { label = row.refused and 'Sign in again' or (row.configured and 'Sign in to another account' or 'Sign in'),
      hint = 'opens a sign-in link; the tokens stay in wa-vault', act = function() return sign_in(row, io) end }
    for _, account in ipairs(row.accounts or {}) do
      if account.account ~= row.active and account.signed_in ~= false then
        options[#options + 1] = { label = 'Use ' .. tostring(account.label or account.account),
          hint = account.refused and ('refused: ' .. tostring(account.refused)) or 'signed in, no new login',
          act = function() return switch_account(row, account.account) end }
      end
    end
  end
  options[#options + 1] = { label = 'Use for this chat', hint = 'the next turns use it',
    act = function() return use(row, io, '') end }
  options[#options + 1] = { label = 'Back', hint = 'the provider list', back = true }
  local lines = { describe(row) }
  for _, account in ipairs(row.accounts or {}) do
    lines[#lines + 1] = (account.account == row.active and '\226\150\184 ' or '  ') .. tostring(account.label or account.account)
      .. (account.refused and (' - refused: ' .. tostring(account.refused)) or '')
  end
  if row.source ~= 'vault' then
    lines[#lines + 1] = 'The sign-in tokens are kept only in wa-vault, and this node has none.'
  end
  return balloon.page({ title = row.label, lines = lines, options = options, selected = 1 })
end

-- One provider, as a page: how it stands, where the vault is, and what can be done from here.
local function provider_page(row, io)
  if row.subscription then return subscription_page(row, io) end
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
