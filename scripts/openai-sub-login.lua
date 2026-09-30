-- Log in to the ChatGPT subscription, from a shell or from a chat that can run a script.
--
--   WA_SCRIPT=scripts/openai-sub-login.lua wa                 # device code: the one that works headless
--   WA_SCRIPT=scripts/openai-sub-login.lua wa --browser       # prints an authorize URL to open
--   WA_SCRIPT=scripts/openai-sub-login.lua wa --code <paste>  # completes the --browser flow
--   WA_SCRIPT=scripts/openai-sub-login.lua wa --status        # what the store holds, without a credential
--   WA_SCRIPT=scripts/openai-sub-login.lua wa --import        # the one-time move out of Pi's store
--
-- The default path is the useful one: if wasm-agent already holds a credential it says so and stops;
-- if it does not and Pi still has one, it moves that credential across once (the import refuses to
-- run twice); otherwise it starts the device-code login and prints the URL and the code for a human.
-- It exits non-zero on failure and prints the taxonomy code, so a caller can branch on it.
local json = dofile("lua/vendor/json.lua")
local auth = dofile("lua/core/openai_sub_auth.lua")

local argv = args or {}
local options = {}
for index, value in ipairs(argv) do
  if value == "--browser" then options.mode = "browser"
  elseif value == "--device" then options.mode = "device"
  elseif value == "--status" then options.status = true
  elseif value == "--import" then options.import = true
  elseif value == "--code" then options.code = argv[index + 1]
  end
end

local function report(failure)
  print("openai-sub login failed: " .. tostring(failure and failure.code))
  print("  " .. tostring(failure and failure.message))
  os.exit(1)
end

if options.status then
  print(json.encode(auth.status()))
  print(auth.describe())
  os.exit(0)
end

if options.import then
  local imported, failure = auth.import_from_pi()
  if not imported then report(failure) end
  print("openai-sub imported from " .. auth.pi_auth_path() .. " for account " ..
    tostring(imported.account_id) .. " (fingerprint " .. tostring(imported.fingerprint) .. ")")
  os.exit(0)
end

-- Already logged in? Say so rather than starting a flow nobody needs.
local existing = auth.status()
if existing.present and not options.mode then
  print(auth.describe())
  print("(logging in again replaces this credential: run with --device or --browser)")
  os.exit(0)
end

if not existing.present and not options.code then
  -- The one-time door out of Pi: only reached when this store is empty, and it refuses to run twice.
  local imported = auth.import_from_pi()
  if imported then
    print("openai-sub: imported Pi's credential for account " .. tostring(imported.account_id) ..
      " into " .. auth.store_path() .. " (Pi is not read again after this)")
    print(auth.describe())
    os.exit(0)
  end
end

local result, failure = auth.login(options.mode or "device", { code = options.code })
if not result then report(failure) end
if result.pending then
  -- A browser login needs the human to come back with the callback URL; that is not a failure.
  print("openai-sub: waiting for the browser step - re-run with --code <the address you landed on>")
  os.exit(0)
end
print("openai-sub: logged in - account " .. tostring(result.account_id) .. ", store " ..
  tostring(result.store))
os.exit(0)
