-- The login CLI as a *module*, so an installed node can run it.
--
--   wa subscription login            device code: prints the verification URL and the user code,
--                                    then waits for a human inside its own budget
--   wa subscription login --browser  prints an authorize URL to open, and comes back with --code
--   wa subscription login --code <the address you landed on>
--   wa subscription status           what the store holds, without spending anything
--   wa subscription login --import   the one-time move out of Pi's store
--
-- This lived in `scripts/openai-sub-login.lua`, which cannot work in the shape it exists for: the
-- binary's `EMBEDDED` registry carries 57 entries under `lua/` and none under `scripts/`, so
-- `lua/core/init.lua`'s `dofile("scripts/openai-sub-login.lua")` resolved in a checkout and died in
-- an installed node with `embedded module missing: scripts/openai-sub-login.lua`. The policy is here
-- now, where the registry can carry it; `scripts/openai-sub-login.lua` remains as a wrapper for the
-- `WA_SCRIPT=` spelling that the credential module's own `LOGIN_COMMAND` (and its tests) name, and
-- that spelling keeps working in both shapes because this module is embedded.
--
-- `run(argv)` returns an exit code instead of exiting, so `wa subscription login` and the wrapper
-- share one policy rather than two; a caller that needs the process to end does it itself.
local json = dofile("lua/vendor/json.lua")
local auth = dofile("lua/core/openai_sub_auth.lua")

local M = {}

function M.options(argv)
  local options = {}
  for index, value in ipairs(argv or {}) do
    if value == "--browser" then options.mode = "browser"
    elseif value == "--device" then options.mode = "device"
    elseif value == "--status" then options.status = true
    elseif value == "--import" then options.import = true
    elseif value == "--code" then options.code = argv[index + 1] end
  end
  return options
end

-- One exit code per answer, and the taxonomy code printed so a caller can branch on it: this never
-- reports success for a credential it did not store.
function M.run(argv)
  local options = M.options(argv)
  local function report(failure)
    print("openai-sub login failed: " .. tostring(failure and failure.code))
    print("  " .. tostring(failure and failure.message))
    return 1
  end

  if options.status then
    print(json.encode(auth.status()))
    print(auth.describe())
    return 0
  end

  if options.import then
    local imported, failure = auth.import_from_pi()
    if not imported then return report(failure) end
    print("openai-sub imported from " .. auth.pi_auth_path() .. " for account " ..
      tostring(imported.account_id) .. " (fingerprint " .. tostring(imported.fingerprint) .. ")")
    return 0
  end

  -- Already logged in? Say so rather than starting a flow nobody needs.
  local existing = auth.status()
  if existing.present and not options.mode then
    print(auth.describe())
    print("(logging in again replaces this credential: run with --device or --browser)")
    return 0
  end

  if not existing.present and not options.code then
    -- The one-time door out of Pi: only reached when this store is empty, and it refuses to run twice.
    local imported = auth.import_from_pi()
    if imported then
      print("openai-sub: imported Pi's credential for account " .. tostring(imported.account_id) ..
        " into " .. auth.store_path() .. " (Pi is not read again after this)")
      print(auth.describe())
      return 0
    end
  end

  local result, failure = auth.login(options.mode or "device", { code = options.code })
  if not result then return report(failure) end
  if result.pending then
    -- A browser login needs the human to come back with the callback URL; that is not a failure.
    print("openai-sub: waiting for the browser step - re-run with --code <the address you landed on>")
    return 0
  end
  print("openai-sub: logged in - account " .. tostring(result.account_id) .. ", store " ..
    tostring(result.store))
  return 0
end

-- The `WA_SCRIPT=` entry point's half: run, then end the process with that code.
function M.main(argv)
  os.exit(M.run(argv))
end

return M
