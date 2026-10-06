-- `/login` (lua/core/vault.lua `M.login`), driven by a scripted reader against a live wa-vault.
--
--   WASM_AGENT_VAULT_URL=http://<vault>:8810 WA_SCRIPT=scripts/test-vault-login.lua wa --db <db>
--
-- The vault is real (vault/wa_vault.py); the reader is not. What this pins: the key typed at the
-- private prompt reaches the vault, is never printed, and the provider becomes the active one; a
-- cancelled choice stores nothing.
local vault = dofile("lua/core/vault.lua")
local provider = dofile("lua/core/provider.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end

local KEY = "sk-login-test-SECRET-4242"

local function reader(answers)
  local printed, asked, private = {}, {}, {}
  local queue = { (table.unpack or unpack)(answers) }
  return {
    print = function(text) printed[#printed + 1] = tostring(text) end,
    ask = function(text) asked[#asked + 1] = text; return table.remove(queue, 1) end,
    ask_private = function(text) private[#private + 1] = text; return table.remove(queue, 1) end,
    wait = function() return nil end,
    select = function(id) return provider.set_provider(id) end,
  }, printed, asked, private
end

ok(vault.url() ~= nil, "WASM_AGENT_VAULT_URL is set for this test")

-- Cancelled at the choice: nothing stored, nothing selected.
local before = vault.login_state()
local io_cancel, printed_cancel = reader({ "" })
ok(vault.login(io_cancel) == false, "Enter at the choice cancels")
ok(table.concat(printed_cancel, "\n"):find("cancelled", 1, true), "the cancel is said")
local after_cancel = vault.login_state()
ok(before and after_cancel and before.providers["opencode-go"].configured == after_cancel.providers["opencode-go"].configured,
   "a cancelled /login changes nothing in the vault")

-- OpenCode Go: choose 2, paste the key at the private prompt.
local io_go, printed, asked, private = reader({ "2", "  " .. KEY .. "  " })
ok(vault.login(io_go) == true, "/login stores the opencode-go key")
ok(#asked == 1 and #private == 1, "the choice is asked in the open and the key at the private prompt")
local transcript = table.concat(printed, "\n")
ok(not transcript:find(KEY, 1, true), "the key is never printed")
ok(transcript:find("opencode-go key stored", 1, true), "the store is confirmed")
ok(transcript:find("provider is now opencode-go", 1, true), "the provider is selected")
local state = vault.login_state()
ok(state and state.providers["opencode-go"].configured == true, "the vault reports the key as set")
ok(not dofile("lua/vendor/json.lua").encode(state):find(KEY, 1, true), "the vault's /login answer does not carry the key")
ok(provider.active().id == "opencode-go", "opencode-go is the active provider")
ok(provider.active().api_key == vault.PLACEHOLDER, "the active provider still holds only the placeholder")

-- An empty paste cancels and stores nothing new.
local io_empty, printed_empty = reader({ "opencode-go", "" })
ok(vault.login(io_empty) == false and table.concat(printed_empty, "\n"):find("cancelled", 1, true),
   "an empty key cancels")

print(string.format("vault /login: %d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
