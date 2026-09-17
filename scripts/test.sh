#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory and a WASM plugin.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

cargo build --release --offline --manifest-path rust/Cargo.toml >/dev/null
BIN=rust/target/release/wa
DB="$(mktemp -u /tmp/wa-smoke-XXXXXX.db)"
PLUGINS="$(mktemp -d)"
trap 'rm -f "$DB" "$DB"-wal "$DB"-shm; rm -rf "$PLUGINS"' EXIT

"$BIN" --db "$DB" init >/dev/null
ID="$("$BIN" --db "$DB" remember "smoke fact about the rust lua core")"
"$BIN" --db "$DB" recall smoke | grep -q "smoke fact"
"$BIN" --db "$DB" memories | grep -q "$ID"
"$BIN" --db "$DB" forget "$ID" | grep -q '"forgotten":true'
"$BIN" --db "$DB" memories | grep -q "(empty)"
"$BIN" --db "$DB" stats | grep -q '"memories":0'

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
  "spell_save", "session_debug", "session_fixture",
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
-- Masking must stay useful: which key, not what key.
local masked = redact.text("OPENAI_API_KEY=" .. fake)
assert(masked:find("sk-%.%.%.", 1) ~= nil, "expected a sk-...xxxx mask, got " .. masked)
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
