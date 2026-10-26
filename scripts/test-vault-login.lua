-- `/login` as panels (lua/core/provider_management.lua `login_cli`), driven by scripted panel answers
-- against a live wa-vault.
--
--   WASM_AGENT_VAULT_URL=http://<vault>:8810 WA_SCRIPT=scripts/test-vault-login.lua wa --db <db>
--
-- The vault is real (vault/wa_vault.py); the reader is not. What this pins: the key pasted in the
-- secret panel reaches the vault's key file, is never printed or put in another panel, and the
-- provider becomes the active one; Esc at the list stores nothing. Point it at a throwaway vault.
local vault = dofile("lua/core/vault.lua")
local provider = dofile("lua/core/provider.lua")
local manager = dofile("lua/core/provider_management.lua")
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end

local KEY = "sk-login-test-SECRET-4242"

local function panels(answers)
  local specs, printed, queue = {}, {}, { (table.unpack or unpack)(answers) }
  return {
    print = function(text) printed[#printed + 1] = tostring(text) end,
    ask = function() return nil end,
    panel = function(spec) specs[#specs + 1] = spec; return table.remove(queue, 1) or { action = "cancel" } end,
  }, specs, printed
end

ok(vault.url() ~= nil, "WASM_AGENT_VAULT_URL is set for this test")

-- Esc at the list: nothing stored, nothing selected.
local before = vault.login_state()
local io_cancel = panels({ { action = "cancel" } })
ok(manager.login_cli(io_cancel) == false, "Esc at the list goes back to the chat")
local after_cancel = vault.login_state()
ok(before and after_cancel and before.providers["opencode-go"].configured == after_cancel.providers["opencode-go"].configured,
   "a cancelled /login changes nothing in the vault")

-- OpenCode Go: pick 2, (replace if one is stored), paste the key, use it now.
local answers = { { action = "select", index = 2 } }
if before.providers["opencode-go"].configured then answers[#answers + 1] = { action = "select", index = 1 } end
answers[#answers + 1] = { action = "submit", text = "  " .. KEY .. "  " }
answers[#answers + 1] = { action = "select", index = 1 }
local io_go, specs, printed = panels(answers)
ok(manager.login_cli(io_go) == true, "/login stores the opencode-go key")
local secret
for _, spec in ipairs(specs) do if spec.input == "secret" then secret = spec end end
ok(secret ~= nil, "the key is asked for in a secret panel")
ok(not json.encode(specs):find(KEY, 1, true), "no panel ever shows the key")
local transcript = table.concat(printed, "\n")
ok(not transcript:find(KEY, 1, true), "the key is never printed")
ok(transcript:find("OpenCode Go key saved in wa-vault", 1, true), "the store is confirmed")
ok(transcript:find("now using OpenCode Go", 1, true) or transcript:find("OpenCode Go is in use", 1, true),
   "the provider is selected (or already was)")
local state = vault.login_state()
ok(state and state.providers["opencode-go"].configured == true and state.providers["opencode-go"].enabled ~= false,
   "the vault reports the key as set and enabled")
ok(not json.encode(state):find(KEY, 1, true), "the vault's /login answer does not carry the key")
ok(provider.active().id == "opencode-go", "opencode-go is the active provider")
ok(provider.active().api_key == vault.PLACEHOLDER, "the active provider still holds only the placeholder")

-- An empty paste asks again; Esc then leaves without storing.
local io_empty, empty_specs = panels({ { action = "select", index = 2 }, { action = "select", index = 1 },
  { action = "submit", text = "   " }, { action = "cancel" } })
ok(manager.login_cli(io_empty) == false, "an empty key, then Esc, stores nothing")
local asked = 0
for _, spec in ipairs(empty_specs) do if spec.input == "secret" then asked = asked + 1 end end
ok(asked == 2, "an empty paste asks again rather than storing it")

print(string.format("vault /login: %d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
