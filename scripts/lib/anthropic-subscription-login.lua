-- /login and /model for the Claude subscription, driven by scripted panel answers against a vault the
-- caller started (scripts/test-anthropic-subscription.py, which points that vault at a local stub).
-- Not a scripts/test-*.lua row on its own: without that vault it has nothing to sign in to.
local provider = dofile("lua/core/provider.lua")
local manager = dofile("lua/core/provider_management.lua")
local model_cli = dofile("lua/core/model_cli.lua")
local balloon = dofile("lua/core/balloon.lua")
local vault = dofile("lua/core/vault.lua")
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

ok(vault.base("anthropic") ~= nil, "the caller set WASM_AGENT_VAULT_URL to its vault")

-- The list names the route.
local listing = balloon.text(manager.login_views(manager.state("local-operator"), {}), balloon.WIDTH)
ok(listing:find("Anthropic (Claude subscription)", 1, true) ~= nil, "/login lists Anthropic (Claude subscription)")

-- Sign in: the list -> Anthropic -> Sign in -> paste code#state -> Close.
local printed, specs = {}, {}
local function scripted(answers)
  return function(spec)
    specs[#specs + 1] = spec
    local answer = table.remove(answers, 1) or { action = "cancel" }
    if type(answer) == "function" then answer = answer(spec) end
    return answer
  end
end
local anthropic_index
for index, row in ipairs(manager.state().providers) do if row.id == "anthropic" then anthropic_index = index end end
local answers = {
  { action = "select", index = anthropic_index },
  { action = "select", index = 1 },
  function()
    local url = (table.concat(printed, "\n"):match("(https://claude%.ai/oauth/authorize%?%S+)"))
    local state = url and url:match("[?&]state=([^&]+)")
    return { action = "submit", text = "code-three#" .. tostring(state) }
  end,
  { action = "cancel" },
}
local io_ = { print = function(text) printed[#printed + 1] = tostring(text) end }
io_.show = function(pages) return balloon.flow(pages, { open = scripted(answers), close = function() end }) end
manager.login_cli(io_)
local code_spec
for _, spec in ipairs(specs) do if spec.input == "secret" then code_spec = spec end end
ok(code_spec ~= nil, "the code is asked for in a secret field")
local link = table.concat(printed, "\n"):match("(https://claude%.ai/oauth/authorize%?%S+)")
-- The chat prints through the redactor: the link must come out whole, or the person cannot open it.
ok(link and dofile("lua/core/redact.lua").text(link) == link, "the sign-in link survives the transcript redactor")
local shown = json.encode(specs) .. table.concat(printed, "\n")
ok(shown:find("signed in as three@example.com", 1, true) ~= nil, "the outcome names the signed-in account")
ok(not shown:find("sk-ant-", 1, true), "no page and no printed line carries a token")
ok(provider.active().id == "anthropic", "the subscription is the provider in use")
ok(provider.active().api_key == vault.PLACEHOLDER, "the route holds only the placeholder")

local after = balloon.text(manager.login_views(manager.state("local-operator"), {}), balloon.WIDTH)
ok(after:find("signed in as three@example.com", 1, true) ~= nil, "/login shows the active account")
ok(after:find("Use one@example.com", 1, true) ~= nil, "/login offers the other signed-in accounts, no login needed")
ok(after:find("refused", 1, true) ~= nil, "/login shows the refused account as refused")

-- /model lists the subscription's ids, and picking one sets it.
local want = { "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2" }
ok(table.concat(provider.list_models(), ",") == table.concat(want, ","), "/model lists " .. table.concat(want, ", "))
local model_specs = {}
local picked = model_cli.model({ print = function() end, panel = function(spec)
  model_specs[#model_specs + 1] = spec
  for index, option in ipairs(spec.options) do
    if option.label == "claude-opus-5-5" then return { action = "select", index = index } end
  end
  return { action = "cancel" }
end })
ok(picked == true and provider.settings().model == "claude-opus-5-5", "picking claude-opus-5-5 in /model sets it")
ok(model_specs[1] and json.encode(model_specs[1]):find("Anthropic (Claude subscription)", 1, true), "/model names the provider")

print(string.format("anthropic /login and /model: %d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
