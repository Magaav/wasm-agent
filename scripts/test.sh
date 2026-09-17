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
WA_SCRIPT="$DB.gating.lua" "$BIN" --db "$DB" | grep -q "gating ok"
rm -f "$DB.gating.lua"

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
WASM_AGENT_PLUGINS="$PLUGINS" WA_SCRIPT="$DB.plugin.lua" "$BIN" --db "$DB" | grep -q "plugin ok"
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
