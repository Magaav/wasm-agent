-- The verbs lua/core/cli_help.lua says ACT, with the lines that answer for each of them, printed for
-- scripts/test-cli-help.sh: the row drives `wa <verb> --help` for the local ones and holds each answer to the
-- text this tree declares, so the guard and its list cannot drift apart or quietly shrink.
--
-- It also checks the module's own properties in-process, which is how the verbs whose ACTING form would reach a
-- fleet are covered without asking a live rendezvous anything (rule 13): `wa network --help` and family are
-- guarded by the same `asked`, and that is what is proved here.
--
--   WA_SCRIPT=scripts/lib/cli-help-verbs.lua wa --db <scratch db>
-- prints, per verb, a "### verb <name>" line, its usage lines, and "### end"; then the verdict line.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("cli-help-verbs.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local help = dofile("lua/core/cli_help.lua")
local checks = 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then error("check failed: " .. message, 0) end
end

local verbs = help.verbs()
ok(#verbs >= 15, "the list of acting verbs is not a token gesture (" .. #verbs .. " verbs)")

for _, verb in ipairs(verbs) do
  -- A verb whose BARE form another layer answers (the binary's release CLI) is guarded in its ACTING form - the
  -- subcommand that would act - and that is the shape probed here.
  local probe = { verb }
  if help.OWNS_HELP[verb] then probe[#probe + 1] = "cut" end
  local said = table.concat(probe, " ")
  local function with_flag(flag)
    local args = { table.unpack(probe) }
    args[#args + 1] = flag
    return args
  end
  ok(help.asked(with_flag("--help")) == true, "--help is a question for wa " .. said)
  ok(help.asked(with_flag("-h")) == true, "-h is the same question for wa " .. said)
  ok(help.asked(probe) == false, "without the flag wa " .. said .. " is a command, not a question")
  ok(type(help.text({ verb })) == "string" and help.text({ verb }):find("^usage: wa " .. verb) == 1,
    "wa " .. verb .. " answers with a usage line")
  if help.OWNS_HELP[verb] then print("### delegate " .. verb) end
  print("### verb " .. verb)
  print(help.text({ verb }))
  print("### end")
end

-- A READ-ONLY verb is not listed, and the guard leaves it alone: asking it for help already runs nothing, so a
-- second place to keep in step is a place to fall out of step.
for _, verb in ipairs({ "status", "nodes", "capabilities", "sessions", "paths", "watch" }) do
  ok(help.asked({ verb, "--help" }) == false, "wa " .. verb .. " is read-only and keeps its own help")
end
-- THE MEASURED CASE (23/11 09:30Z): `wa update --help` reached the LOCAL updater, because remote_update.lua
-- treats a second word starting with -- as "no node named" and falls through. The guarded form is that one; the
-- form that HAS its own detailed help keeps it.
ok(help.asked({ "update", "--help" }) == true, "wa update --help is caught above the dispatch")
ok(help.asked({ "update", "work", "--help" }) == false,
  "wa update <node> --help keeps remote_update.lua's own help, which runs nothing either")
print(string.format("cli-help-verbs ok (%d checks)", checks))
