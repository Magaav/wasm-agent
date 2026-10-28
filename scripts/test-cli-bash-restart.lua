-- `!command` (bash mode) and the CLI restarting itself into its session.
--
-- Bash mode: the command is run, the result is redacted, and the session gets one user message in
-- Claude Code's shape that the model reads next turn - and that the session state does not mistake
-- for a question nobody answered. Restart: the loop guard, which is what stops a restart that keeps
-- being asked for from exec'ing the CLI forever.
--
-- Run from the repo root:
--   WASM_AGENT_KEYS_DIR=/tmp/k WA_SCRIPT=scripts/test-cli-bash-restart.lua wa --db /tmp/x.db
local memory = dofile("lua/core/memory.lua")
memory.setup()
local bash_mode = dofile("lua/core/bash_mode.lua")
local cli_restart = dofile("lua/core/cli_restart.lua")
local commands = dofile("lua/core/commands.lua")
local keys = dofile("lua/core/keys.lua")
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

-- 1. What counts as a bash line.
ok(bash_mode.command("!git status") == "git status", "! then the command")
ok(bash_mode.command("!   ls -la  ") == "ls -la", "spaces around it are not the command")
ok(bash_mode.command("!") == nil and bash_mode.command("hello !x") == nil, "no command, or not at the start: not bash mode")

-- 2. A real run, recorded in the session, in Claude Code's shape.
local session = memory.start_session("", "chat", { user_id = "bash-test", node_id = "", title = "chat" })
local result, content = bash_mode.run("printf 'one\\ntwo'; printf 'oops' >&2", { session_id = session, cwd = "" })
ok(tostring(result.stdout):find("one\ntwo", 1, true), "it ran here", json.encode(result))
ok(content == "<bash-input>printf 'one\\ntwo'; printf 'oops' >&2</bash-input>\n<bash-stdout>one\ntwo</bash-stdout><bash-stderr>oops</bash-stderr>",
  "recorded as <bash-input> then <bash-stdout><bash-stderr>", content)
local rows = memory.session_messages(session, { all = true })
ok(#rows == 1 and rows[1].role == "user" and rows[1].phase == "bash" and rows[1].content == content,
  "one user message, phase bash", json.encode(rows))
local state = memory.session_state(session)
ok(state.state == "answered", "a bash line is context, not a question waiting for a turn", state.state)
local command, stdout, stderr = bash_mode.parse(content)
ok(command and stdout == "one\ntwo" and stderr == "oops", "and it reads back for the replay")

-- 3. A failure with nothing on stderr still says so; output is redacted before it is kept.
local failed = select(2, bash_mode.run("exit 3", { cwd = "", record = function() end }))
ok(failed:find("<bash-stderr>exit code 3</bash-stderr>", 1, true), "a silent failure records its exit code", failed)
local secret = "bash-mode-secret-value-4f9e"
ok(keys.set("bash_test_key", secret).ok, "a /vault key to leak")
local leaked = select(2, bash_mode.run("cat '" .. keys.path("bash_test_key") .. "'", { cwd = "", record = function() end }))
ok(not leaked:find(secret, 1, true), "a key printed by a ! command never reaches the context", leaked)
host.exec("rm -f '" .. keys.path("bash_test_key") .. "'", "")

-- 4. The restart loop guard.
local now = 1000000
local allowed, carried = cli_restart.budget(nil, now)
ok(allowed and carried == "1:1000000", "a first restart is allowed and counted", carried)
allowed, carried = cli_restart.budget("2:" .. (now - 10), now)
ok(allowed and carried == "3:" .. (now - 10), "a third inside the window still is")
local refused, _, why = cli_restart.budget("3:" .. (now - 10), now)
ok(not refused and why:find("restarts in the last", 1, true), "a fourth inside the window is refused, and says why")
allowed, carried = cli_restart.budget("3:" .. (now - cli_restart.WINDOW - 1), now)
ok(allowed and carried == "1:" .. now, "after the window the count starts again", carried)

-- 5. The help says what `!` does, and offers /restart.
local help = commands.help()
ok(help:find("!<command>", 1, true) and help:find("/restart", 1, true), "the help lists bash mode and /restart")

print("cli bash restart ok (" .. checks .. " checks)")
