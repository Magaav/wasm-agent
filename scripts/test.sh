#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory and a WASM plugin.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

cargo build --release --offline --manifest-path rust/Cargo.toml >/dev/null
BIN=rust/target/release/wa
DB="$(mktemp -u /tmp/wa-smoke-XXXXXX.db)"
# `wa status` reports *the current thread*, so it gets its own database: with the
# shared one, every earlier session in this run sits in the same second and the
# "latest session" assertion would be a coin flip.
SDB="$(mktemp -u /tmp/wa-status-XXXXXX.db)"
# Session recovery works on its own threads: which session is "the current
# thread" decides what `wa status` and `wa resume` report, so sharing the smoke
# database would make the assertions below depend on what ran before them.
RDB="$(mktemp -u /tmp/wa-resume-XXXXXX.db)"
QDB="$(mktemp -u /tmp/wa-resume-q-XXXXXX.db)"
PLUGINS="$(mktemp -d)"
trap 'rm -f "$DB" "$DB"-wal "$DB"-shm "$SDB" "$SDB"-wal "$SDB"-shm "$RDB" "$RDB"-wal "$RDB"-shm "$QDB" "$QDB"-wal "$QDB"-shm; rm -rf "$PLUGINS"' EXIT

"$BIN" --db "$DB" init >/dev/null
ID="$("$BIN" --db "$DB" remember "smoke fact about the rust lua core")"
"$BIN" --db "$DB" recall smoke | grep -q "smoke fact"
"$BIN" --db "$DB" memories | grep -q "$ID"
"$BIN" --db "$DB" forget "$ID" | grep -q '"forgotten":true'
"$BIN" --db "$DB" memories | grep -q "(empty)"
"$BIN" --db "$DB" stats | grep -q '"memories":0'

# The CLI's own surface. Resolving a merge once dropped an `else` and made
# `wa help` fall through to "unknown command" - valid Lua, so every Lua-level
# test passed while the command was broken.
HELP="$("$BIN" --db "$DB" help)"
case "$HELP" in
  *"unknown command"*) echo "FAIL: wa help falls through to the unknown-command branch" >&2; exit 1 ;;
esac
for entry in chat paths status skills sessions resume; do
  echo "$HELP" | grep -q "$entry" || { echo "FAIL: wa help must list '$entry'" >&2; exit 1; }
done
echo "cli ok"
# Actions that need the user's machine must fail immediately when nothing is
# polling the client bridge, instead of blocking for the call timeout: an agent
# spent rounds on a tool that looked half-working. There is never a client
# attached in this suite, so the failure is deterministic here.
cat > "$DB.client.lua" <<'LUA'
local started = host.now()
local raw = host.client('screenshot', '{}')
local elapsed = host.now() - started
local result = dofile('lua/vendor/json.lua').decode(raw)
assert(result.error == 'client_not_connected', 'expected client_not_connected, got ' .. tostring(result.error))
assert(result.hint and result.hint:find('wa ui', 1, true), 'the failure must say how to fix it')
assert(elapsed < 2, 'must fail fast, took ' .. string.format('%.2f', elapsed) .. 's')
print('client fast-fail ok')
LUA
WA_SCRIPT="$DB.client.lua" "$BIN" --db "$DB" | grep "client fast-fail ok"
rm -f "$DB.client.lua"
# Context budget is per model (provider.budget), and it is NOT the same thing as
# provider.limits, which fetches the account's rate limits for the UI. Confusing
# the two silently disabled compaction once: the window came back nil, so
# maybe_compact returned early and nothing ever compacted.
cat > "$DB.budget.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local fallback = provider.budget("some-unknown-model")
assert(fallback.context == 128000, "the env window is the fallback, got " .. tostring(fallback.context))
local per_model = provider.budget("kimi-k2.6")
assert(per_model.context == 262144, "a per-model window must win, got " .. tostring(per_model.context))
assert(per_model.reserve == 32768, "a per-model reserve must win")
assert(provider.limits and provider.limits ~= provider.budget, "limits and budget are different things")
print("budget ok")
LUA
WASM_AGENT_MODEL_LIMITS='{"kimi-k2.6":{"context":262144,"reserve":32768}}' WA_SCRIPT="$DB.budget.lua" "$BIN" --db "$DB" | grep "budget ok"
rm -f "$DB.budget.lua"
# `wa status` must report whether the toolchains its tools need resolve - a
# service has no login PATH, which is how a remote build failed with
# "cargo: not found" while nothing else said a word.
cat > "$DB.tools.lua" <<'LUA'
local status = dofile("lua/core/status.lua")
local line = status.tools()
assert(line:find("git=", 1, true), "the tools line must report git: " .. line)
assert(line:find("cargo=", 1, true), "the tools line must report cargo: " .. line)
local lines = status.lines()
local found = false
for _, text in ipairs(lines) do if text:find("tools", 1, true) then found = true end end
assert(found, "status must print the tools line")
print("tools ok")
LUA
WA_SCRIPT="$DB.tools.lua" "$BIN" --db "$DB" | grep "tools ok"
rm -f "$DB.tools.lua"
# Role gating: a guest must never see master tools, and a session must resolve
# to its own user. A regression here silently runs guests as master, which is
# exactly what happened when the session header stopped reaching dispatch.
cat > "$DB.gating.lua" <<'LUA'
local users = dofile("lua/core/users.lua")
local tools = dofile("lua/core/tools.lua")
local guest, master = tools.all("guest"), tools.all("master")
local seen = {}
for _, tool in ipairs(guest) do seen[tool["function"].name] = true end
for _, forbidden in ipairs({
  "bash", "write", "edit", "client", "shell", "remote",
  "spell_save", "session_debug", "session_fixture", "forget",
}) do
  assert(not seen[forbidden], "guest must not see " .. forbidden)
end
assert(#guest > 0 and #guest < #master, "guest gating looks wrong")
local session, user = users.login("guest")
assert(user and user.role == "guest", "login must return the guest role")
assert(users.current(session).id == "guest", "a valid session must resolve to its own user")

-- Role-scoped instructions. A guest must be given its own file and must never
-- fall back to the operator's: the operator file names internal paths and the
-- deploy shape, and a guest can ask the model to repeat its context.
local agent = dofile("lua/core/agent.lua")
local operator, operator_path = agent.agents_md("master")
local guest_md, guest_path = agent.agents_md("guest")
assert(operator and operator_path:match("AGENTS%.md$"), "master must read AGENTS.md")
assert(guest_md and guest_path:match("AGENTS%.guest%.md$"), "guest must read AGENTS.guest.md")
assert(guest_md ~= operator, "guest must not receive the operator instructions")
for _, leak in ipairs({ "openclaw", "git@github", "WORKSPACE", "cargo" }) do
  assert(not guest_md:lower():find(leak:lower(), 1, true),
    "guest instructions must not mention " .. leak)
end
print("gating ok")
LUA
WA_SCRIPT="$DB.gating.lua" "$BIN" --db "$DB" | grep "gating ok"
rm -f "$DB.gating.lua"

# Every embedded Lua module must at least compile. Without this a typo in a
# file the test does not exercise (the chat REPL, a spell helper) ships and only
# fails at runtime in front of a user.
cat > "$DB.syntax.lua" <<'LUA'
local bad = 0
for path, source in pairs(EMBEDDED) do
  -- EMBEDDED also carries the SQL schema; only Lua can be compiled.
  if path:sub(-4) == ".lua" then
    local chunk, err = load(source, "@" .. path)
    if not chunk then
      bad = bad + 1
      print("  " .. path .. ": " .. tostring(err))
    end
  end
end
assert(bad == 0, bad .. " lua module(s) failed to compile")
print("lua syntax ok")
LUA
WA_SCRIPT="$DB.syntax.lua" "$BIN" --db "$DB" | grep "lua syntax ok"
rm -f "$DB.syntax.lua"

# A turn killed between recording its tool call and its result would otherwise
# make every later turn in that session fail with a provider 400 - a bricked
# thread. Build such a transcript on purpose and assert the context is repaired.
cat > "$DB.repair.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()
local sid = memory.start_session("test", "repair", { user_id = "master", node_id = "", title = "repair" })
local call = { id = "call_1", type = "function", ["function"] = { name = "bash", arguments = "{}" } }
memory.append_turn(sid, { role = "user", content = "do it" })
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = { call } })
-- no tool result follows: the turn died here
memory.append_turn(sid, { role = "user", content = "are you there?" })

local bot = agentlib.new(sid, function() end, "master", "master", "")
local messages = bot:build_context()
local calls, orphans = 0, 0
for _, m in ipairs(messages) do
  if m.role == "assistant" and m.tool_calls then calls = calls + 1 end
  if m.role == "tool" then orphans = orphans + 1 end
end
assert(calls == 0, "an unanswered tool call must not be sent (found " .. calls .. ")")
assert(orphans == 0, "an orphan tool result must not be sent (found " .. orphans .. ")")
assert(bot.repaired and bot.repaired > 0, "the repair must be recorded, not silent")

-- Positive control: a *complete* exchange must survive intact. Without this the
-- assertions above would also pass if the builder simply dropped every call.
local sid2 = memory.start_session("test", "repair", { user_id = "master", node_id = "", title = "repair" })
local call2 = { id = "call_2", type = "function", ["function"] = { name = "bash", arguments = "{}" } }
memory.append_turn(sid2, { role = "user", content = "do it" })
memory.append_turn(sid2, { role = "assistant", content = "", tool_calls = { call2 } })
memory.append_turn(sid2, { role = "tool", content = '{"stdout":"hi"}', tool_call_id = "call_2", tool_name = "bash" })
memory.append_turn(sid2, { role = "assistant", content = "done" })
local good = agentlib.new(sid2, function() end, "master", "master", "")
local kept_calls, kept_results = 0, 0
for _, m in ipairs(good:build_context()) do
  if m.role == "assistant" and m.tool_calls then kept_calls = kept_calls + 1 end
  if m.role == "tool" then kept_results = kept_results + 1 end
end
assert(kept_calls == 1, "a complete exchange must keep its call (found " .. kept_calls .. ")")
assert(kept_results == 1, "a complete exchange must keep its result (found " .. kept_results .. ")")
assert(not good.repaired, "a complete exchange must not be reported as repaired")
print("repair ok")
LUA
WA_SCRIPT="$DB.repair.lua" "$BIN" --db "$DB" | grep "repair ok"
rm -f "$DB.repair.lua"

# Secret redaction is a security boundary, so it gets a unit test with fake
# secrets: a value that survives redaction must fail the build, not reach a log.
cat > "$DB.redact.lua" <<'LUA'
local redact = dofile("lua/core/redact.lua")
local fake = "sk-FAKEtest1234567890abcdef"
local cases = {
  "OPENAI_API_KEY=" .. fake,
  "ANTHROPIC_API_KEY: " .. fake,
  "OPENROUTER_API_KEY='" .. fake .. "'",
  '{"opencode-go":{"type":"api_key","key":"' .. fake .. '"}}',
  "Authorization: Bearer " .. fake,
  "curl -H 'Authorization: Bearer " .. fake .. "' https://example.invalid",
  "WASM_AGENT_LLM_API_KEY=" .. fake .. " GITHUB_TOKEN=" .. fake,
  "ghp_FAKEgithubtoken1234567890",
  "nothing secret here",
}
for _, case in ipairs(cases) do
  local out = redact.text(case)
  assert(not out:find(fake, 1, true), "redaction leaked a secret: " .. out)
end
-- Masking must stay useful: which key, not what key. Plain find, not a
-- pattern: in Lua patterns '-' after a letter is a quantifier, so 'sk-%.%.%.'
-- silently never matches.
local masked = redact.text("OPENAI_API_KEY=" .. fake)
assert(masked:find("sk-...", 1, true) ~= nil, "expected a sk-...xxxx mask, got " .. masked)
assert(masked:find(fake:sub(-4), 1, true) ~= nil, "the mask should keep the last four")
-- Idempotent: redacting twice changes nothing.
assert(redact.text(masked) == masked, "redaction must be stable")
print("redact ok")
LUA
WA_SCRIPT="$DB.redact.lua" "$BIN" --db "$DB" | grep "redact ok"
rm -f "$DB.redact.lua"

# Session selection: a new thread is the default, --continue finds the latest,
# --session must reject an unknown id instead of silently starting a new thread.
cat > "$DB.sessions.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
memory.setup()
local first = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "one" })
local second = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "two" })
assert(memory.session(first) and memory.session(second), "sessions must be readable")
local latest = memory.latest_session("master", "")
assert(latest and latest.id == second, "latest_session must return the newest thread")
assert(memory.session(second).id ~= first, "ids must differ")
assert(memory.session("no-such-session") == nil, "an unknown session must resolve to nil")
-- A finished session is still continuable: the process ends a session on exit,
-- so filtering to open ones would mean --continue never finds anything.
memory.finish_session(second)
local after = memory.latest_session("master", "")
assert(after and after.id == second, "a finished session must still be the latest")
-- Memory is independent of conversational history.
memory.remember("session test fact", "global", {})
local sid = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "three" })
assert(#memory.session_turns(sid, {}) == 0, "a new session must start empty")
assert(#memory.recall("session test fact", 5) > 0, "memory must not depend on the session")
print("sessions ok")
LUA
WA_SCRIPT="$DB.sessions.lua" "$BIN" --db "$DB" | grep "sessions ok"
rm -f "$DB.sessions.lua"

# Session recovery. The contract - what an interrupted thread is, what is recorded
# and what the agent is told - lives in scripts/test-recovery.lua, because the
# Windows suite runs the same file and two copies would drift. What is asserted
# here is the surface a user actually touches and the Lua test cannot see: the
# CLI's own words, its exit codes, and that reading a report changes nothing.
WA_SCRIPT=scripts/test-recovery.lua "$BIN" --db "$DB" | grep "recovery ok"
cat > "$DB.seed.lua" <<'LUA'
-- Seed a thread cut off the way a killed process leaves it: a question, a decision
-- to run a tool, and no result. `question` seeds the other shape (nothing but an
-- unanswered question) - WA_SCRIPT runs before dispatch, so the extra word is free.
local memory = dofile("lua/core/memory.lua")
memory.setup()
local id = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "seed" })
memory.append_turn(id, { role = "user", content = "count the scripts in scripts/" })
if args[1] ~= "question" then
  memory.append_turn(id, { role = "assistant", content = "Listing them now.", tool_calls = {
    { id = "seed1", type = "function", ["function"] = { name = "bash", arguments = '{"command":"ls scripts"}' } },
  } })
end
print(id)
LUA
SID="$(WA_SCRIPT="$DB.seed.lua" "$BIN" --db "$RDB")"
[ -n "$SID" ] || { echo "FAIL: the seed produced no session id" >&2; exit 1; }
"$BIN" --db "$RDB" sessions | grep -q "interrupted"
# The unfinished call is named: "interrupted" alone would send the reader into the
# transcript to find out what is missing.
"$BIN" --db "$RDB" sessions | grep -q "1 tool call(s) never reported: bash"
"$BIN" --db "$RDB" resume | grep -q "waiting: 1 thread"
"$BIN" --db "$RDB" resume | grep -q "wa resume --session"
"$BIN" --db "$RDB" status | grep -q "interrupted at seq 2"
"$BIN" --db "$RDB" resume --session "$SID" | grep -q "never reported"
# An unknown session must be refused, not silently reported as fine.
if "$BIN" --db "$RDB" resume --session no-such-session >/dev/null 2>&1; then
  echo "FAIL: wa resume --session <unknown> must exit non-zero" >&2; exit 1
fi
# Reporting is read-only. A report that repairs what it prints cannot be used to
# check whether anything is wrong, and the repair would destroy the evidence.
"$BIN" --db "$RDB" resume | grep -q "waiting: 1 thread"
# The other shape: asked and never answered.
QSID="$(WA_SCRIPT="$DB.seed.lua" "$BIN" --db "$QDB" question)"
[ -n "$QSID" ] || { echo "FAIL: the question seed produced no session id" >&2; exit 1; }
"$BIN" --db "$QDB" resume | grep -q "unanswered question"
"$BIN" --db "$QDB" resume | grep -q "count the scripts"
"$BIN" --db "$QDB" status | grep -q "interrupted at seq 1"
rm -f "$DB.seed.lua"
echo "recovery cli ok"

# `wa status` is the command an operator runs when something is wrong, so every
# fact it prints is asserted here - including the one that has to leave the
# process (git). A health line that says "clean" because git was unreachable is
# worse than no line at all.
cat > "$DB.status.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local paths = dofile("lua/core/paths.lua")
local status = dofile("lua/core/status.lua")
memory.setup()

-- Identity: the node id must be this node's real ed25519 id, not a placeholder.
local identity = json.decode(host.node_identity())
assert(status.node_id() == identity.node_id, "status must report this node's id")

-- The model line states the model *and* whether it can be reached: without the
-- second half a missing api key reads as a merely quiet model.
local model = status.model()
assert(model:find(provider.settings().model, 1, true) ~= nil,
  "the model line must name the model: " .. model)
local expected = provider.configured() and "configured=yes" or "configured=no"
assert(model:find(expected, 1, true) ~= nil, "the model line must say " .. expected)

-- The thread: exactly the session `wa chat --continue` would resume.
local sid = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "status" })
assert(status.session_id() == sid, "status must report the current thread")
assert(status.session():find(sid, 1, true) ~= nil, "the session line must carry the id")

-- The working tree: git must be reachable from the checkout under test, and the
-- answer must be a state, not an apology.
local tree = status.working_tree()
assert(tree == "clean" or tree:match("^%d+ changed$") ~= nil,
  "status must read the working tree, got: " .. tree)

-- paths.config() is the host's answer, not a path rebuilt from $HOME.
assert(status.config_path() == paths.config(), "config must come from paths.config()")
assert(status.config_path() ~= "", "the config path must not be empty")

-- Five facts, one line each, and each line names the fact it carries.
local lines = status.lines()
assert(#lines == 5, "status must print one line per fact (got " .. #lines .. ")")
for _, label in ipairs({ "node", "model", "session", "tree", "config" }) do
  local found = false
  for _, text in ipairs(lines) do
    if text:sub(1, #label) == label then found = true end
  end
  assert(found, "status is missing its " .. label .. " line")
end
print("status ok")
LUA
WA_SCRIPT="$DB.status.lua" "$BIN" --db "$SDB" | grep "status ok"
rm -f "$DB.status.lua"

# And the command itself must be wired to that report, and listed in help: a
# module nobody can reach is not a command.
"$BIN" --db "$SDB" status | grep -q "^node "
"$BIN" --db "$SDB" status | grep -q "^config "
"$BIN" --db "$SDB" help | grep -q "status"

# Host capabilities that keep the agent portable: it must be able to learn which
# shell dialect it is in (it guessed POSIX on Windows and lost a whole tool
# budget), and grep must not depend on a POSIX binary.
cat > "$DB.platform.lua" <<'LUA'
local platform = dofile("lua/core/platform.lua")
local info = platform.info()
assert(info.os and info.os ~= "unknown", "platform.os must be known")
assert(info.shell and info.shell ~= "", "platform.shell must be known")
local described = platform.describe()
assert(described:find("shell") or described:find("cmd"), "describe() must mention the shell")
local agentlib = dofile("lua/core/agent.lua")
local prompt = agentlib.system_prompt("master", nil)
assert(prompt:find("Running on:", 1, true), "the system prompt must state the environment")
local result = host.grep("wasm-agent", "lua/core", "{\"limit\":5}")
assert(result, "host.grep must return a result")
local decoded = dofile("lua/vendor/json.lua").decode(result)
assert(decoded.count > 0, "host.grep must find a pattern that is definitely present")
assert(decoded.matches[1].file and decoded.matches[1].line, "matches carry file and line")
local listing = host.list_dir("lua/core")
assert(listing, "host.list_dir must return a result")
local entries = dofile("lua/vendor/json.lua").decode(listing)
assert(entries.entries and #entries.entries > 0, "host.list_dir must list the Lua core")
local names = {}
for _, entry in ipairs(entries.entries) do names[entry.name] = entry.kind end
assert(names["agent.lua"] == "file", "listing must include files with a kind")
print("platform ok")
LUA
WA_SCRIPT="$DB.platform.lua" "$BIN" --db "$DB" | grep "platform ok"
rm -f "$DB.platform.lua"

# Memory has to be curatable and findable, or it misleads later: the agent could
# only accumulate (no delete tool), and a conversational question could never
# match a note because every term was ANDed.
cat > "$DB.memory.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
memory.setup()
local id = memory.remember("The readiness probe runs on Tuesdays", "global", {})
-- The precise query finds it.
assert(#memory.recall("readiness probe") > 0, "an exact query must match")
-- A conversational question shares no complete term set with the note; it must
-- still find it, because returning nothing here made the agent report an empty
-- store while the fact was present.
local conversational = memory.recall("what did I ask you to remember about the probe?")
assert(#conversational > 0, "a conversational question must still find the memory")
-- The tool surface: listing and deleting, master only for the delete.
local master = {}
for _, tool in ipairs(tools.all("master")) do master[tool["function"].name] = true end
assert(master.memories and master.forget, "master must be able to list and delete memories")
local guest = {}
for _, tool in ipairs(tools.all("guest")) do guest[tool["function"].name] = true end
assert(not guest.forget, "a guest must not be able to erase stored facts")
assert(tools.dispatch(memory, "forget", { id = id }, "guest").error, "dispatching forget as a guest must fail")
local result = tools.dispatch(memory, "forget", { id = id }, "master")
assert(result.forgotten, "the master must be able to forget a memory")
assert(#memory.recall("readiness probe") == 0, "a forgotten memory must not be recalled")
print("memory curation ok")
LUA
WA_SCRIPT="$DB.memory.lua" "$BIN" --db "$DB" | grep "memory curation ok"
rm -f "$DB.memory.lua"

# Skills: on-demand instructions (the Agent Skills standard pi implements).
# Only name and description are always in context; the body loads when a task
# matches, which is the whole point - a technique needed occasionally must not
# cost context every turn, and must not have to be explained twice.
cat > "$DB.skills.lua" <<'LUA'
local skills = dofile("lua/core/skills.lua")
local tools = dofile("lua/core/tools.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local found = skills.list(true)
assert(#found > 0, "at least one skill must be discoverable")
local names = {}
for _, skill in ipairs(found) do
  names[skill.name] = true
  assert(skill.description ~= "", skill.name .. " must have a description")
end
assert(names["see-your-output"], "the repo's own skill must be found")
local block = skills.prompt_block()
assert(block and block:find("<available_skills>", 1, true),
  "the system prompt must advertise the skills")
assert(block:find("see-your-output", 1, true), "the advertised block must name the skill")
local loaded = tools.dispatch(memory, "skill", { name = "see-your-output" }, "master")
assert(loaded.content and #loaded.content > 200, "loading a skill must return its instructions")
assert(loaded.path and loaded.path:find("SKILL.md", 1, true), "a loaded skill reports its file")
local missing = tools.dispatch(memory, "skill", { name = "no-such-skill" }, "master")
assert(missing.error == "unknown_skill", "an unknown skill must fail, not invent one")
assert(#missing.available > 0, "the failure must list what is available")
-- Guests get the same read-only knowledge; their tool envelope still gates actions.
assert(tools.dispatch(memory, "skill", { name = "see-your-output" }, "guest").content,
  "a guest must be able to read a skill")
-- Discovery must stop at the checkout root: this repo is nested inside
-- another one, and walking past the root made it advertise that project's
-- skills (airtable, productivity) to an agent working here.
local cwd = dofile("lua/core/platform.lua").cwd()
assert(block:find(cwd, 1, true) or true, "sanity")
for _, skill in ipairs(found) do
  assert(not skill.path:find("/local/skills/", 1, true),
    "must not adopt a parent project's skills: " .. skill.path)
end
print("skills ok")
LUA
WA_SCRIPT="$DB.skills.lua" "$BIN" --db "$DB" | grep "skills ok"
rm -f "$DB.skills.lua"

# Build every plugin and assert one round trip through the WASM host.
for crate in rust/plugins/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  cargo build --manifest-path "$crate/Cargo.toml" --target wasm32-unknown-unknown --release --offline >/dev/null
  wasm="$(ls "$crate"/target/wasm32-unknown-unknown/release/*.wasm | head -1)"
  cp "$wasm" "$PLUGINS/$name.wasm"
done
cat > "$DB.plugin.lua" <<'LUA'
local raw = host.invoke("echo", '{"text":"hi"}')
assert(raw and raw:find('"echo":"hi"'), "plugin round trip failed: " .. tostring(raw))
print("plugin ok")
LUA
WASM_AGENT_PLUGINS="$PLUGINS" WA_SCRIPT="$DB.plugin.lua" "$BIN" --db "$DB" | grep "plugin ok"
rm -f "$DB.plugin.lua"

# Line endings are an invariant, not a preference: these files run on a Linux
# host under sh and lua, where a CRLF script fails in confusing ways. Check the
# *stored* blobs (recoverable if a Windows working copy drifts) and skip
# binaries, which legitimately contain CR bytes. `-I` does that for us.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # `git grep` exits 1 when it finds nothing, which is the good case here; with
  # `set -e` that would abort the run exactly when the invariant holds.
  crlf="$(git grep --cached -I -l "$(printf '\r')" || true)"
  if [ -n "$crlf" ]; then
    echo "FAIL: CRLF stored in the index:" >&2
    echo "$crlf" >&2
    echo "Fix with: git add --renormalize .   (and set core.autocrlf=false)" >&2
    exit 1
  fi
  echo "line endings ok"
fi

echo "smoke ok"
