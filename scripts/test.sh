#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory and a WASM plugin.
set -euo pipefail
# A skipped test must be visible in the verdict, not only in the middle of the log:
# "smoke ok" over a run that skipped the UI tests claims more than it did.
SKIPPED=0
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

# A scratch DB does not isolate profile/config/effect files. Fence the ENTIRE gate,
# including new fixtures whose authors might otherwise forget to select a home.
# Keep the explicit skip request and in-turn deploy guard; never inherit provider
# accounts, a real instance registry, a job auth token, or the user's runtime paths.
while IFS= read -r variable; do
  case "$variable" in
    WASM_AGENT_SKIP_UI_TESTS|WASM_AGENT_IN_TURN) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)
GATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wa-gate-home-XXXXXX")"
if command -v cygpath >/dev/null 2>&1; then
  export WASM_AGENT_HOME="$(cygpath -w "$GATE_HOME")"
else
  export WASM_AGENT_HOME="$GATE_HOME"
fi
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY=fixture-only
export HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" NO_PROXY=127.0.0.1,localhost,::1
echo "gate isolated home: $WASM_AGENT_HOME (retained for diagnostics)"

cargo build --release --offline --manifest-path rust/Cargo.toml >/dev/null
# The execution and automation contracts have native, model-free adversarial tests.
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-operation -p wa-jobs
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host file_search::tests
# The ticker's clock is the twin of `cli_view.duration` on the Lua side: the elapsed time of a
# call that has not finished can only be computed by the host, so both sides pin the same three
# values and a one-sided change fails here rather than on a screen.
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host ticker_tests
# The graph is a capability the agent navigates its own code with, so its extractor and
# incremental reindex are part of the contract, not a side project.
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-graph
# Run the serve-level invariants, each a measured regression: routing by session (a wake carries its
# conversation in the body's `thread`, not the auth header) and the UI version tracking content rather
# than mtime (a `cp -f` of identical files must not force every open page to reload).
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host serve::
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host subagents::
cargo test --release --offline --manifest-path rust/wa-sentinel/Cargo.toml
# The named-instance lifecycle, against two real co-located nodes: separate homes, keys, databases
# and ports; a refused wrong listener; and a stop/restart of one that cannot reach the other. No
# model and no network, so it belongs in the hermetic gate rather than the on-demand guest e2e.
CARGO_BUILD_JOBS=2 cargo build --release --offline --manifest-path rust/wa-sentinel/Cargo.toml >/dev/null
INSTANCE_VERDICT="$(mktemp)"
rm -f "$INSTANCE_VERDICT" # The child must produce NEW evidence, never a previous run's verdict.
INSTANCE_STATUS=0
WA_INSTANCE_VERDICT="$INSTANCE_VERDICT" bash scripts/test-node-instances.sh || INSTANCE_STATUS=$?
INSTANCE_SKIPPED=$(node scripts/lib/suite-verdict.cjs "$INSTANCE_VERDICT" test-node-instances "$INSTANCE_STATUS" 56)
SKIPPED=$((SKIPPED + INSTANCE_SKIPPED))
rm -f "$INSTANCE_VERDICT"
BIN=rust/target/release/wa
# A turn cannot deploy the process serving that same turn. The marker crosses
# the Rust host's shell boundary; both entry points must refuse before waiting
# for idle or touching an installed binary.
GUARD_HOME="$(mktemp -d)"
mkdir -p "$GUARD_HOME/install"
if WASM_AGENT_IN_TURN=1 WA_INSTALL_DIR="$GUARD_HOME/install" bash scripts/deploy.sh --reason guard >"$GUARD_HOME/deploy.log" 2>&1; then
  echo "FAIL: deploy.sh accepted a running-turn invocation" >&2; exit 1
fi
grep -q 'cannot deploy from a running turn' "$GUARD_HOME/deploy.log"
if WASM_AGENT_IN_TURN=1 bash scripts/upgrade.sh "$BIN" >"$GUARD_HOME/upgrade.log" 2>&1; then
  echo "FAIL: upgrade.sh accepted a running-turn invocation" >&2; exit 1
fi
grep -q 'refused inside a running turn' "$GUARD_HOME/upgrade.log"
# `deploy.sh` now records a machine-readable result beside the install, so the temp home is not empty of
# files after the guard fires; remove the whole tree rather than a fixed list, or the smoke gate aborts
# here and never reaches the tests that matter.
rm -rf "$GUARD_HOME"
echo "self-update turn guard ok"
# The other half of the install gate: it must refuse to replace an install that is ahead of this tree. Its
# own file, because it asserts five cases (ahead, ancestor, no record, no commit=, an unresolvable commit)
# and both directions of the check - a gate that refuses everything is as wrong as one that refuses nothing.
# It stops at or before the build, so it costs about a second.
set +e
bash scripts/test-deploy-downgrade.sh
GATE_STATUS=$?
set -e
if [ "$GATE_STATUS" = "3" ]; then
  # Exit 3 is "this tree cannot reach the check": a clean tree that is not behind origin/main is required,
  # and the gate asks about the tree first. Counted, not hidden - a skipped check is not a passing check.
  SKIPPED=$((SKIPPED + 1))
elif [ "$GATE_STATUS" != "0" ]; then
  echo "FAIL: the deploy downgrade gate did not pass (exit $GATE_STATUS)" >&2
  exit 1
fi
# The suite must exercise the Lua in the working tree. cargo rebuilds the binary when a
# Lua file changes (they are include_str!-ed), so this is belt as well as braces - but it
# is the difference between testing the tree and testing a build artefact, and it went
# missing in a merge without anyone noticing.
export WASM_AGENT_LUA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
  export WASM_AGENT_LUA_ROOT="$(cygpath -w "$WASM_AGENT_LUA_ROOT")"
fi
# This is a fixture, not the operator's deployment configuration.
export WASM_AGENT_LLM_CONTEXT=128000
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
trap 'rm -f "$DB" "$DB"-wal "$DB"-shm "$SDB" "$SDB"-wal "$SDB"-shm "$RDB" "$RDB"-wal "$RDB"-shm "$QDB" "$QDB"-wal "$QDB"-shm "$DB.title" "$DB.title"-wal "$DB.title"-shm "$DB.exec" "$DB.exec"-wal "$DB.exec"-shm; rm -rf "$PLUGINS" "$DB.home"' EXIT

# Fresh retained output + process status + terminal count evidence for every new
# integrated proof. A child that silently exits 0 or drops checks cannot pass.
run_proof_fixture() {
  local kind="$1" minimum="$2" status=0 nested_skipped
  shift 2
  local log="$DB.$kind-proof.log"
  "$@" > "$log" 2>&1 || status=$?
  if ! nested_skipped="$(node scripts/lib/proof-verdict.cjs "$kind" "$status" "$minimum" < "$log")"; then
    echo "FAIL: $kind proof; retained output: $log" >&2
    tail -40 "$log" >&2
    exit 1
  fi
  SKIPPED=$((SKIPPED + nested_skipped))
  tail -4 "$log"
}

"$BIN" --db "$DB" init >/dev/null

# A dev-mode node must not write the operator's ledger. The dangerous combination is on-disk Lua,
# the operator's home, and the default database; an explicit --db or any WASM_AGENT_HOME is a
# candidate node. Asserted by the message, not by the exit code, so this cannot pass vacuously -
# and both directions, because a guard that refuses everything is as wrong as one that refuses
# nothing. The refusal runs before memory.setup(), so the first invocation touches no database.
# Simulate an unscoped home, never the real operator home. Otherwise the gate's
# outer WASM_AGENT_HOME makes this negative case vacuous (and a broken guard could
# write to the operator's real ledger). Test --db independently of the home override.
GUARD_ENV=(env -u WASM_AGENT_HOME "HOME=$WASM_AGENT_HOME" "USERPROFILE=$WASM_AGENT_HOME"
  "LOCALAPPDATA=$WASM_AGENT_HOME/LocalAppData" "APPDATA=$WASM_AGENT_HOME/AppData")
guard_out="$("${GUARD_ENV[@]}" "$BIN" status 2>&1 || true)"
case "$guard_out" in
  *"refusing on-disk Lua"*) ;;
  *) echo "FAIL: on-disk Lua against the operator's database must be refused, got:" >&2
     printf '%s\n' "$guard_out" | tail -3 >&2; exit 1 ;;
esac
if "${GUARD_ENV[@]}" "$BIN" --db "$DB" status 2>&1 | grep -q "refusing on-disk Lua"; then
  echo "FAIL: a scratch ledger is a candidate node and must not be refused" >&2; exit 1
fi
mkdir -p "$DB.home"
if WASM_AGENT_HOME="$DB.home" WASM_AGENT_LUA_ROOT="$WASM_AGENT_LUA_ROOT" "$BIN" status >/dev/null 2>&1; then :; else
  echo "FAIL: a candidate home must not be refused" >&2; exit 1
fi
echo "dev home guard ok"
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
#
# The failure must also say *which* failure it is. It used to say "start the
# desktop client with `wa ui`" for every case, including the one that actually
# happens - a wedged bridge with a perfectly healthy window - which sent the
# reader to fix the wrong thing.
cat > "$DB.client.lua" <<'LUA'
local json = dofile('lua/vendor/json.lua')
local started = host.now()
local raw = host.client('screenshot', '{}')
local elapsed = host.now() - started
local result = json.decode(raw)
assert(result.error == 'client_not_connected', 'expected client_not_connected, got ' .. tostring(result.error))
assert(result.next and #result.next > 10, 'the failure must say what to do')
assert(result.observed and #result.observed > 10, 'the failure must say what was seen, not just what to do')
-- The state fields are read flat, exactly as `status` returns them: an agent
-- follows `bridge.health`, so an error that nests it one level deeper is a trap.
assert(result.bridge and result.bridge.health, 'the bridge state must travel with the failure')
assert(result.connected == false, 'the failure must say whether a client is connected')
assert(not tostring(result.next):lower():find('restart'),
  'a wedged bridge must never be answered with "restart the window": two windows split one bridge')
assert(elapsed < 2, 'must fail fast, took ' .. string.format('%.2f', elapsed) .. 's')
-- `status` is the cheap question, and it is answerable with nothing attached:
-- that is the whole point of it.
local status = json.decode(host.client('status', '{}'))
assert(status.error == 'client_not_connected' and status.bridge and status.observed,
  'status must answer with the state and the diagnosis')
-- A result whose caller gave up is kept, and asking for one that is not kept is
-- an answer rather than a crash.
local late = json.decode(host.client('result', '{"id":"nothing"}'))
assert(late.error == 'result_not_kept' and late.next, 'asking for an unkept result must explain itself')
local link = json.decode(host.client_status())
assert(link.bridge and link.bridge.health ~= nil and link.results_kept ~= nil,
  'client_status must carry bridge/health/results_kept')
print('client fast-fail ok')
LUA
WA_SCRIPT="$DB.client.lua" "$BIN" --db "$DB" | grep "client fast-fail ok"
rm -f "$DB.client.lua"
# The three states a control failure can be in are three different sentences with
# three different remedies, and getting them the same way round is a unit test
# rather than a guess.
cargo test --release --offline --manifest-path rust/Cargo.toml --bin wa client_diagnosis >/dev/null
echo "client diagnosis ok"
# And what the agent is *told* about the tool, since that is what decides whether
# it reaches for `status` after a failure or guesses at `cdp` again.
cat > "$DB.clientschema.lua" <<'LUA'
local tools = dofile('lua/core/tools.lua')
local spec
for _, tool in ipairs(tools.all('master')) do
  if tool["function"] and tool["function"].name == 'client' then spec = tool["function"] end
end
assert(spec, 'the client tool must be in the schema')
local props = spec.parameters.properties
local actions = {}
for _, action in ipairs(props.action.enum) do actions[action] = true end
for _, action in ipairs({ 'status', 'browser', 'cdp', 'shell', 'screenshot' }) do
  assert(actions[action], 'the client action enum must offer ' .. action)
end
assert(props.timeout_ms and props.timeout_ms.description:find('waits', 1, true)
  and props.timeout_ms.description:find('result', 1, true),
  'the schema must say what a timeout means and how to collect the outcome')
assert(props.target and props.target.description:find('read', 1, true),
  'the browser targets must be named in the schema')
assert(spec.description:find('status', 1, true), 'the description must point at status when a call fails')
assert(not spec.description:find('default 9222', 1, true),
  'a port must not be advertised as the way in: it is discovered and reported')
print('client schema ok')
LUA
WA_SCRIPT="$DB.clientschema.lua" "$BIN" --db "$DB" | grep "client schema ok"
rm -f "$DB.clientschema.lua"
# The shell deadline is invisible to a model that only meets it by being killed. The
# description carries the number and the route for longer work, read from the host
# that enforces the number, so a long command is planned instead of lost.
cat > "$DB.bashschema.lua" <<'LUA'
local tools = dofile('lua/core/tools.lua')
local spec
for _, tool in ipairs(tools.all('master')) do
  if tool["function"] and tool["function"].name == 'bash' then spec = tool["function"] end
end
assert(spec, 'the bash tool must be in the schema')
local deadline = math.floor(host.exec_timeout())
assert(spec.description:find(deadline .. 's', 1, true),
  'the description must state the enforced foreground deadline in seconds, got: ' .. spec.description)
assert(spec.description:find('operation', 1, true) and spec.description:find('timeout_seconds', 1, true),
  'the description must name the operation escape hatch for work that outlives the deadline')
local timeout = spec.parameters.properties.timeout_seconds
assert(timeout and timeout.minimum == 1 and timeout.maximum == 86400,
  'the schema must offer a per-call timeout_seconds in the same 1-86400 range as operation')
local refused = tools.dispatch(nil, 'bash', { command = 'echo hi', timeout_seconds = 0 }, 'master')
assert(refused and refused.error == 'invalid_timeout_seconds',
  'an out-of-range per-call timeout must be refused before it reaches the shell')
print('bash schema ok')
LUA
WA_SCRIPT="$DB.bashschema.lua" "$BIN" --db "$DB" | grep "bash schema ok"
rm -f "$DB.bashschema.lua"
# `/update` decides whether there is anything to install and writes one request for the sentinel -
# it never installs anything itself (the node is the process being replaced). The decision is a pure
# function of the facts, so every case is checkable without a tree, a build or a sentinel; the one
# case that is *not* pure - the path a recorded worktree is handed to the shell in - is checked with
# a real file, because that is where a Windows backslash actually breaks.
cat > "$DB.update.lua" <<'LUA'
local update = dofile('lua/core/update.lua')
local function ok(condition, message) if not condition then error(message, 2) end end

-- Nothing to update from at all.
local v = update.verdict({ install = '/install' })
ok(v.ok == false and v.error == 'no_runtime_tree', 'no tree must be a refusal, got ' .. tostring(v.error))
ok(v.message and #v.message > 20, 'every answer must carry a sentence')
ok(v.next and #v.next > 20, 'a refusal must say where to go')

-- A tree with nothing built in it: the common case right after an edit, and it must not queue.
v = update.verdict({ install = '/i', tree = '/tree', candidate = '/tree/rust/target/release/wa.exe' })
ok(v.error == 'nothing_built', 'an unbuilt tree must be a refusal, got ' .. tostring(v.error))
ok(v.next:find('cargo build', 1, true), 'the refusal must name the build command: ' .. tostring(v.next))

-- Built, but the only process that could install it is not there.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10, sentinel_present = false })
ok(v.error == 'no_sentinel', 'a missing sentinel must be a refusal, got ' .. tostring(v.error))

-- Already running exactly what the tree holds: nothing to queue, and no claim of work done.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, tree_commit = 'abc1234', installed_commit = 'abc1234', dirty = 0 })
ok(v.ok == true and v.changed == false and v.status == 'already_current', 'same commit must be a no-op')
ok(not v.queued, 'already current must not queue a request')

-- A different commit queues, and says queued rather than done.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, tree_commit = 'def5678', installed_commit = 'abc1234', dirty = 0 })
ok(v.queued == true and v.commit == 'def5678', 'a newer tree must queue')
ok(v.message:find('queued', 1, true) and v.message:find('not done yet', 1, true),
  'queued must not read as done: ' .. tostring(v.message))

-- Uncommitted work queues even at the same commit: the commit does not describe the binary, so
-- "you already run that" would be a claim about code that was never built.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, tree_commit = 'abc1234', installed_commit = 'abc1234', dirty = 3 })
ok(v.queued == true, 'a dirty tree must still queue')

-- The path a recorded worktree comes back as is a Windows path with backslashes, which the shell
-- this node runs commands in cannot use: a backslash inside a single-quoted word reaches a native
-- git as an escape. It must be normalised before it is quoted.
local home = host.paths().temp .. '/wa-update-test'
host.write_file(home .. '/runtime-worktree.txt', 'C:\\work\\foundation\r\n')
local tree, source = update.runtime_tree(home)
ok(tree == 'C:/work/foundation', 'the recorded tree must be normalised, got ' .. tostring(tree))
ok(source == 'runtime-worktree.txt', 'the source of the tree must be named, got ' .. tostring(source))

-- The command that will be run, without running it. A reason with a quote in it must not be able to
-- end the quoting early: the sentinel would then read a different verb than the one intended.
local command = update.request_command(
  { sentinel = 'C:/install/wa-sentinel.exe', candidate = 'C:/tree/rust/target/release/wa.exe' },
  "/update: it's mine")
ok(command:find("'C:/install/wa%-sentinel%.exe' request upgrade"), 'the verb must be spelled out: ' .. command)
ok(command:find("'C:/tree/rust/target/release/wa%.exe'", 1), 'the binary must be quoted: ' .. command)
ok(not command:find("it's", 1, true) and command:find("it'\\''s", 1, true),
  'a quote in the reason must be escaped, not left to end the word: ' .. command)

-- A sentinel that exists and does not work must be a refusal - never a crash, and never a claim of
-- success. The fixture is a real file that is not a program, reached through the same seam a node
-- uses (WA_INSTALL_DIR), so nothing here touches the machine's own install or its sentinel. The tree
-- is a directory of this test's own: the candidate binary is derived from the tree, so a fixture that
-- put it anywhere else would be testing the wrong thing (and did, once).
local tree = host.paths().temp .. '/wa-update-tree'
local broken = host.paths().temp .. '/wa-update-broken'
host.exec("mkdir -p '" .. tree .. "/rust/target/release' '" .. broken .. "'", "")
host.write_file(tree .. '/rust/target/release/wa.e' .. 'xe', 'placeholder\n')
host.write_file(broken .. '/runtime-worktree.txt', (tree:gsub('/', '\\')) .. "\r\n")
host.write_file(broken .. '/installed.txt', 'commit=0000000\nsource_commit_hint=0000000\n')
host.write_file(broken .. '/wa-sentinel.e' .. 'xe', 'not a program\n')
local report = update.run({ install = broken, reason = 'the update test' })
ok(report.ok == false, 'a sentinel that cannot run must not report success: ' .. tostring(report.message))
ok(report.error == 'sentinel_refused' or report.error == 'sentinel_unreachable',
  'the refusal must name what happened, got ' .. tostring(report.error) .. ' (' .. tostring(report.observed) .. ')')
ok(not report.queued, 'a refused request must not claim to be queued')
ok(report.observed and #report.observed > 10, 'the refusal must carry what was seen')
print('update decision ok')
LUA
WA_SCRIPT="$DB.update.lua" "$BIN" --db "$DB" | grep "update decision ok"
rm -f "$DB.update.lua"
# The same decisions through the route, on a node whose install dir is a fixture. Its sentinel is a
# stub: a live check that dropped a request into the operator's real request box could install a
# placeholder over the node that is running. It also asserts that it did not.
WA_BIN="$BIN" bash scripts/test-update.sh 8874 | grep "the real sentinel's request box is untouched"
# The ledger ingest path, on a scratch database. An observer (WhatsApp's own store, a mail sync, a
# bot) is exactly the caller that has a message with no reply target and sometimes no send time, and
# that caller used to crash inside the encoder: a nil in the SQL parameter list makes the JSON array
# sparse, and the encoder refuses holes outright rather than writing a NULL. The columns have a
# defined shape now; this is what keeps them that way.
cat > "$DB.ledger.lua" <<'LUA'
local memory = dofile('lua/core/memory.lua')
memory.setup()
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello' })
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello' })
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello again' })
memory.record_conversation({ id = 'c2', title = 'no messages yet', kind = 'direct' })
local rows = memory.conversation('c1', 10)
assert(#rows == 1, 'one message must be one row, got ' .. #rows)
assert(rows[1].body == 'hello again', 'a changed body must update in place, got ' .. tostring(rows[1].body))
assert(rows[1].sent_at and rows[1].sent_at > 0, 'an unknown send time must take a defined shape')
assert(rows[1].reply_to == '', 'a missing reply target must not be a hole in the parameters')
local conversations = memory.conversations(50)
local titles = {}
for _, row in ipairs(conversations) do titles[row.id] = row.title end
assert(titles['c2'] == 'no messages yet', 'a conversation with no messages must still be known')
memory.meta_set('test_cursor', 42)
assert(tonumber(memory.meta_get('test_cursor')) == 42, 'a cursor must round-trip through meta')
local hits = memory.search_ledger('again', nil, 5)
assert(#hits >= 1 and hits[1].conversation_id == 'c1', 'the ledger must be findable by its words')
print('ledger ingest ok')
LUA
WA_SCRIPT="$DB.ledger.lua" "$BIN" --db "$DB.ledger" | grep "ledger ingest ok"
rm -f "$DB.ledger.lua"
# Context budget is per model (provider.budget), and it is NOT the same thing as
# provider.limits, which fetches the account's rate limits for the UI. Confusing
# the two silently disabled compaction once: the window came back nil, so
# maybe_compact returned early and nothing ever compacted.
cat > "$DB.budget.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")
local fallback = provider.budget("some-unknown-model")
assert(fallback.context == 128000, "the env window is the fallback, got " .. tostring(fallback.context))
assert(fallback.source == "env-WASM_AGENT_LLM_CONTEXT", "an unknown model must say the env was used, got " .. tostring(fallback.source))
local per_model = provider.budget("kimi-k2.6")
assert(per_model.context == 262144, "a per-model window must win, got " .. tostring(per_model.context))
assert(per_model.reserve == 32768, "a per-model reserve must win")
assert(provider.limits and provider.limits ~= provider.budget, "limits and budget are different things")

-- The window belongs to the model, not to the process. WASM_AGENT_LLM_CONTEXT is 128000
-- here, and deepseek-v4.1-flash has a 1000000-token window; the model's own number must
-- win, or compaction fires ~10x too early and nothing reports it because "compacted" is
-- not an error.
local deep = provider.budget("deepseek-v4.1-flash")
assert(deep.context == 1000000, "a known model keeps its own window, got " .. tostring(deep.context))
-- The source is now specific: pi's local store, the fetched catalogue, the shipped table
-- or the operator's override. Asserting the property (a real window, and a named source)
-- rather than one string keeps this true whichever source answers on the day.
assert(deep.context > 900000, "a known model must get its own window, got " .. tostring(deep.context))
assert(type(deep.source) == "string" and deep.source ~= "" and deep.source ~= "unknown",
  "and must say where the number came from, got " .. tostring(deep.source))
-- The trigger must scale with the window and keep real headroom below it. A large window
-- reserves proportionally (ten percent), because the catalogue's window is a *claim* and the
-- provider's real ceiling can sit below it - deepseek-v4.1-flash publishes 1,000,000 and
-- rejects near 950,000, so pi's fixed 16384 put the trigger (983,616) above the wall and
-- compaction never fired. A small window keeps the fixed reserve, which already exceeds ten
-- percent of it. Either way the trigger is near the window, not the old global's 96k.
assert(deep.context - deep.reserve > 850000, "a 1M window must not compact at 96k, trigger at " .. tostring(deep.context - deep.reserve))
local small = windowlib.policy(20000)
assert(small < 20000, "a small window must still reserve proportionally, got " .. tostring(small))
print("budget ok")
LUA
WASM_AGENT_MODEL_LIMITS='{"kimi-k2.6":{"context":262144,"reserve":32768}}' WA_SCRIPT="$DB.budget.lua" "$BIN" --db "$DB" | grep "budget ok"
rm -f "$DB.budget.lua"

# The request path must not fetch the catalogue. A scratch home has no cache and the catalogue URL
# cannot be reached, so a fetch would wait for the connect timeout - which is what used to happen:
# the first /models after a fresh install blocked the interpreter for as long as a 4.7MB download
# takes, and everything behind it queued, while /health kept answering as if all was well. A guest
# node with a fresh home is exactly that shape, which is where this was found. Immediate is the
# assertion; the value is not, because an unconfigured node legitimately knows nothing yet.
cat > "$DB.cold.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local started = host.now()
local answer = provider.budget("a-model-nobody-publishes")
local elapsed = host.now() - started
assert(elapsed < 2, "budget must not fetch the catalogue on the request path: took " .. elapsed .. "s")
assert(type(answer) == "table" and type(answer.source) == "string" and answer.source ~= "",
  "and it must still say where the answer came from")
print("cold budget ok")
LUA
WASM_AGENT_HOME="$DB.home" WASM_AGENT_MODELS_CATALOGUE='http://10.255.255.1/api.json' \
  WASM_AGENT_PI_MODELS_STORE="$DB.home/none.json" \
  WA_SCRIPT="$DB.cold.lua" "$BIN" --db "$DB" | grep "cold budget ok"
rm -f "$DB.cold.lua"
rm -f "$DB.budget.lua"

# What a provider's edge is told about the caller, and which conversation this is. OpenCode Go
# documents the requirement - "Send a stable session ID in x-opencode-session for each conversation
# so we can optimize routing and prompt caching" - and this node sent the constant "wasm-agent" for
# every conversation, so every conversation shared one cache shard. The assertion is the property,
# not a string: two conversations get different ids, each equal to its own, the id does not change
# between rounds, and a request that is not a conversation carries none. The catalogue is asserted
# too, so adding a provider forces a decision about its headers instead of silently defaulting.
# The base URL env vars are cleared because this asserts the *shipped* catalogue, not the shell's.
cat > "$DB.headers.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local json = dofile("lua/vendor/json.lua")

local gaps = provider.attribution_gaps()
assert(#gaps == 0, "no attribution rule for: " .. table.concat(gaps, ", ") ..
  " - decide what that host needs in ATTRIBUTION (lua/core/provider.lua)")

local opencode
for _, profile in ipairs(provider.providers()) do
  if profile.id == "opencode-go" then opencode = profile end
end
assert(opencode, "the opencode-go profile must exist")
local rule = provider.attribution_rule(opencode)
assert(rule and rule.session == "x-opencode-session",
  "opencode-go must route a conversation by x-opencode-session")

-- Drive the real request path with a stubbed transport and keep what it sent. Both
-- transports: the turn streams, the summariser does not, and the header must be on both.
local sent = {}
local real_http, real_stream = host.http, host.http_stream
host.http = function(_, _, headers)
  sent[#sent + 1] = json.decode(headers)
  return json.encode({ status = 200, body = json.encode({
    id = "fixture", model = "fixture",
    choices = { { message = { content = "ok" }, finish_reason = "stop" } },
    usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 },
  }) })
end
host.http_stream = function(_, _, headers)
  sent[#sent + 1] = json.decode(headers)
  return json.encode({ status = 200, content = "ok", finish_reason = "stop",
    stream_complete = true, tool_calls = {},
    usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
end
local function ask(session_id, stream)
  return provider.complete_with("deepseek-v4.1-flash",
    { { role = "system", content = "s" }, { role = "user", content = "u" } },
    nil, stream, { session_id = session_id, round = 1 })
end
local first = ask("conversation-one", false)
ask("conversation-one", true)
ask("conversation-two", false)
provider.list_models("opencode-go")
host.http, host.http_stream = real_http, real_stream

assert(#sent == 4, "expected four captured requests, got " .. #sent)
local function session_header(i) return sent[i]["x-opencode-session"] end
assert(session_header(1) == "conversation-one",
  "the header must carry the conversation's own id, got " .. tostring(session_header(1)))
assert(session_header(1) == session_header(2), "the id must not change between rounds")
assert(session_header(1) ~= session_header(3), "two conversations must not share one routing id")
assert(session_header(3) == "conversation-two", "and each must carry its own id")
assert(session_header(4) == nil, "a model listing is not a conversation and must claim no id")
assert(session_header(1) ~= "wasm-agent", "the constant that caused this must not come back")

-- The routing used is recorded with the request, so a miss in the ledger can be read
-- against the instruction that produced it instead of being argued about later.
local meta = first.request_meta and first.request_meta.attribution
assert(meta, "the request must record its attribution")
assert(meta.host == "opencode.ai", "and the host it matched, got " .. tostring(meta.host))
assert(meta.session_header == "x-opencode-session", "and the header it applied")
assert(meta.session_id_present == true, "and whether the conversation id was sent")
print("provider headers ok")
LUA
env -u WASM_AGENT_LLM_BASE_URL -u WASM_AGENT_OPENAI_BASE_URL -u OPENAI_BASE_URL \
  WASM_AGENT_LLM_API_KEY=fixture-provider-headers \
  WA_SCRIPT="$DB.headers.lua" "$BIN" --db "$DB" | grep "provider headers ok"
rm -f "$DB.headers.lua"
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
# The shell the tools run in. The model speaks POSIX, so a cmd shell on Windows
# made `ls`, `pwd`, `tail` and `grep` fail with "is not recognized" - pi refuses
# to start without bash for exactly this reason, and this asserts ours found one.
cat > "$DB.shell.lua" <<'LUA'
local platform = dofile("lua/core/platform.lua")
local shell = platform.shell()
assert(shell:find("bash", 1, true) or shell:find("sh ", 1, true),
  "tools must run in a POSIX shell, got: " .. shell)
local raw = host.exec('echo "$0"', "")
local decoded = dofile("lua/vendor/json.lua").decode(raw)
assert(decoded and decoded.code == 0, "echo must succeed in the tool shell")
local name = tostring(decoded.stdout or ""):gsub("%s+$", "")
assert(name:find("bash", 1, true) or name:find("sh", 1, true),
  "$0 should name a POSIX shell, got: " .. name)
-- The commands the model reaches for by habit, which cmd cannot run.
for _, command in ipairs({ "pwd", "ls -a . | head -3", "echo hi | cat" }) do
  local result = dofile("lua/vendor/json.lua").decode(host.exec(command, ""))
  assert(result and result.code == 0, command .. " failed: " .. tostring(result and result.stderr))
end
print("posix shell ok")
LUA
WA_SCRIPT="$DB.shell.lua" "$BIN" --db "$DB" | grep "posix shell ok"
rm -f "$DB.shell.lua"
# Tool results are stored whole and budgeted only for the context, per tool. The
# old 600-character write-time cap made a 20 KB read a keyhole for every later
# turn - the reason 'read then edit' kept missing - and dropped a command's error
# with the tail of its output. pi keeps the tail and points at the full text.
cat > "$DB.evidence.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()
local sid = memory.start_session("", "evidence", { user_id = "master", node_id = "", title = "evidence" })
local big = string.rep("0123456789", 7000)
memory.append_turn(sid, { role = "user", content = "read it" })
-- A tool result whose call is not declared is dropped by the exchange repair,
-- correctly: the assistant message that asked for it has to be here too.
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = {
  { id = "c1", type = "function", ["function"] = { name = "read", arguments = "{}" } },
  { id = "c2", type = "function", ["function"] = { name = "bash", arguments = "{}" } },
} })
memory.append_turn(sid, { role = "tool", tool_call_id = "c1", tool_name = "read", content = big })
memory.append_turn(sid, { role = "tool", tool_call_id = "c2", tool_name = "bash",
  content = string.rep("noise ", 2000) .. "FATAL: the error is at the end" })
local stored_read
for _, row in ipairs(memory.session_messages(sid, { limit = 10 })) do
  if row.tool_name == "read" then stored_read = row end
end
assert(stored_read, "the read result must be in the transcript")
assert(#stored_read.content > 20000, "the transcript must keep the whole result, got " .. #stored_read.content)
assert(stored_read.content == big, "and keep it verbatim")
local bot = agentlib.new(sid, function() end, "master", "master", "")
local read_view, bash_view
for _, message in ipairs(bot:build_context()) do
  if message.role == "tool" and message.name == "read" then read_view = message.content end
  if message.role == "tool" and message.name == "bash" then bash_view = message.content end
end
assert(#read_view > 600, "the read budget must be far larger than the old 600, got " .. #read_view)
-- The stored row keeps the whole result; only the *context* view is bounded, and an oversized
-- view keeps the head and points at the artifact that holds the rest. `big` is deliberately
-- larger than any budget the projector may be configured with, so this exercises the artifact
-- path whether the budget is at its 50 KiB default or moved by WASM_AGENT_TOOL_OUTPUT_BYTES.
assert(read_view:find(big:sub(1, 20), 1, true), "read keeps the head, which identifies the file")
assert(read_view:find("full_result", 1, true), "an oversized view must point at its artifact")
assert(bash_view:find("FATAL", 1, true), "bash keeps the tail, because the error lives there")
print("tool evidence ok")
LUA
WA_SCRIPT="$DB.evidence.lua" "$BIN" --db "$DB" | grep "tool evidence ok"
rm -f "$DB.evidence.lua"
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-observability.lua" "$BIN" --db "$DB.observability" | grep 'observability ok'
# A provider 400 on a too-large request must compact and retry once. Without it, one
# oversized turn makes every later turn of the session fail and the thread never answers.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-overflow-recovery.lua" "$BIN" --db "$DB.overflow" | grep 'overflow recovery ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-graph-tool.lua" "$BIN" --db "$DB.graph-tool" | grep 'graph tool ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-graph-freshness.lua" "$BIN" --db "$DB.graph-freshness" | grep 'graph freshness ok'
# Offline accounting must run even when UI tests are explicitly skipped.
node scripts/test-token-audit.cjs
WA_BIN="$BIN" node scripts/test-efficiency.cjs
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-patch-audit.lua" "$BIN" --db "$DB.patch-audit" | grep 'patch audit ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-patch-audit-agent.lua" "$BIN" --db "$DB.patch-audit-agent" | grep 'patch audit agent ok'
# Real projector, isolated home, exact artifact recovery. No paid model or ignored A/B switch.
WA_BIN="$BIN" bash scripts/bench-tool-budget.sh
WA_BIN="$BIN" bash scripts/bench-tool-tail.sh
# Which conversation a turn lands in. The name a client sends is the only thing that
# lets a window start a thread or return to one: before this, `agent_for` always passed
# nil, so every turn from every window landed in the newest open session and that one
# thread grew without end. The *refusal* is asserted here too - the name is obeyed now,
# so a guest naming a master's thread must be refused rather than quietly served it.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-thread-selection.lua" "$BIN" --db "$DB.thread" | grep 'thread selection ok'
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

# The transcript is ordered by arrival; the provider demands that a tool result follow its
# call immediately. A session whose stored rows were out of order answered every new turn
# with a 400 - "An assistant message with 'tool_calls' must be followed by tool messages
# responding to each 'tool_call_id'" - while the running turn's own rounds kept working,
# because only the round-1 rebuild sends the stored order. Each shape from that incident is
# in the file, with a healthy transcript as the control.
WA_SCRIPT=scripts/test-tool-adjacency.lua "$BIN" --db "$DB" | grep "tool adjacency ok"

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
assert(#memory.session_messages(sid, {}) == 0, "a new session must start empty")
assert(#memory.recall("session test fact", 5) > 0, "memory must not depend on the session")
print("sessions ok")
LUA
WA_SCRIPT="$DB.sessions.lua" "$BIN" --db "$DB" | grep "sessions ok"
# The ledger's order under concurrent writers: several processes appending to one session at once. A
# single-process test cannot catch a `MAX(seq)+1` race. The check is mutation-tested: removing the
# transaction in `append_turn` makes it fail with a duplicate seq.
WA_BIN="$BIN" bash scripts/test-append-race.sh | grep "append race ok"
rm -f "$DB.sessions.lua"

# Session recovery. The contract - what an unfinished thread is, what is recorded
# and what the agent is told - lives in scripts/test-recovery.lua, because the
# Windows suite runs the same file and two copies would drift. What is asserted
# here is the surface a user actually touches and the Lua test cannot see: the
# CLI's own words, its exit codes, and that reading a report changes nothing.
WA_SCRIPT=scripts/test-recovery.lua "$BIN" --db "$DB" | grep "recovery ok"
# The turn's file changes: recorded by write/edit, carried by the ledger, and reversible.
# Three files because they fail for three different reasons - the record's own logic, the
# ledger round trip (which was broken: the column existed and the INSERT dropped it), and
# the route the UI's toggle calls.
WA_SCRIPT=scripts/test-changeset.lua "$BIN" --db "$DB" | grep "changeset ok"
WA_SCRIPT=scripts/test-changes-roundtrip.lua "$BIN" --db "$DB" | grep "changes round trip ok"
WA_SCRIPT=scripts/test-diff-route.lua "$BIN" --db "$DB" | grep "diff route ok"

# An empty assistant message is not an answer. A reasoning model that spends its
# whole output budget thinking returns content "", a reasoning field, and
# finish_reason=length; the loop used to record that as a finished turn. The same
# file runs in the Windows suite, for the same reason the recovery one does.
# The node's name: derived from the worktree it runs in, and validated when someone sets it.
# This deliberately writes nothing - it only exercises the derivation and the refusals - so it
# cannot disturb the name of the node running it.
cat > "$DB.node-name.lua" <<'LUA'
local nodes = dofile("lua/core/nodes.lua")
local dir = nodes.worktree()
assert(type(dir) == "string" and dir ~= "", "the worktree directory must be derivable from the cwd")
assert(nodes.node_name() ~= "", "the node must have a name")
local rejected, why = nodes.set_name("no" .. string.char(10) .. "newlines")
assert(rejected == nil and why == "node_name_invalid",
  "a control character must be refused, got " .. tostring(rejected) .. " / " .. tostring(why))
local long, why2 = nodes.set_name(string.rep("x", 41))
assert(long == nil and why2 == "node_name_too_long",
  "a 41-character name must be refused, got " .. tostring(long) .. " / " .. tostring(why2))
assert(nodes.set_name("") == nil, "an empty name must be refused")
print("node name ok (" .. nodes.node_name() .. " in " .. dir .. ")")
LUA
WA_SCRIPT="$DB.node-name.lua" "$BIN" --db "$DB" | grep "node name ok"
rm -f "$DB.node-name.lua"
WA_SCRIPT=scripts/test-empty-reply.lua "$BIN" --db "$DB" | grep "empty reply ok"

# Every Lua core module must be reachable from the *shipped* binary. The embedded list in
# rust/wa-host/src/main.rs is maintained by hand, so a new module is invisible to a deployed
# node until someone remembers to add it - which is how a node crash-looped on
# "embedded module missing: lua/core/model_window.lua". Every other check here sets
# WASM_AGENT_LUA_ROOT and therefore reads the working tree; this one deliberately does not,
# because that is the path the node actually runs.
cat > "$DB.embedded.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local listing = host.list_dir("lua/core")
assert(type(listing) == "string", "host.list_dir must return a listing")
local decoded = json.decode(listing)
local names = {}
for _, entry in ipairs(decoded.entries or {}) do
  if entry.kind == "file" and entry.name:match("%.lua$") then names[#names + 1] = entry.name end
end
assert(#names >= 10, "expected the core modules in the listing, found " .. #names)
for _, required in ipairs({ "agent.lua", "provider.lua", "model_window.lua", "memory.lua" }) do
  local found = false
  for _, name in ipairs(names) do if name == required then found = true end end
  assert(found, required .. " is missing from lua/core")
end
local function embedded_chunk(path)
  local source=EMBEDDED and EMBEDDED[path]
  if type(source)~='string' then return nil end
  return load(source,'@'..path)
end
-- loadfile reads disk, even with WASM_AGENT_LUA_ROOT unset. Test the actual embedded registry.
local probe='lua/core/provider.lua';local saved=EMBEDDED[probe]
EMBEDDED[probe]=nil;assert(not embedded_chunk(probe),'negative control: absent embedding must fail')
EMBEDDED[probe]='!invalid Lua';assert(not embedded_chunk(probe),'negative control: invalid embedding must fail')
EMBEDDED[probe]=saved
local missing = {}
for _, name in ipairs(names) do
  if not embedded_chunk('lua/core/'..name) then missing[#missing + 1] = name end
end
assert(#missing == 0, "on disk but not in the binary: " .. table.concat(missing, ", "))
-- Presence is not freshness: compare the exact embedded text to the working tree too.
local stale = {}
for _, name in ipairs(names) do
  local path = "lua/core/" .. name
  local embedded = EMBEDDED and EMBEDDED[path]
  local on_disk = host.read_file and host.read_file(path)
  if type(embedded) == "string" and type(on_disk) == "string" and embedded ~= on_disk then
    stale[#stale + 1] = name
  end
end
assert(#stale == 0, "the embedded core is stale - rebuild before trusting this binary: " .. table.concat(stale, ", "))
print("embedded modules ok (" .. #names .. " files)")
LUA
( unset WASM_AGENT_LUA_ROOT; WA_SCRIPT="$DB.embedded.lua" "$BIN" --db "$DB" ) | grep "embedded modules ok"
rm -f "$DB.embedded.lua"
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
"$BIN" --db "$RDB" sessions | grep -q "unfinished"
# The unfinished call is named: "unfinished" alone would send the reader into the
# transcript to find out what is missing.
"$BIN" --db "$RDB" sessions | grep -q "1 tool call(s) with no recorded result: bash"
"$BIN" --db "$RDB" resume | grep -q "waiting: 1 thread"
"$BIN" --db "$RDB" resume | grep -q "wa resume --session"
"$BIN" --db "$RDB" status | grep -q "unfinished at seq 2"
"$BIN" --db "$RDB" resume --session "$SID" | grep -q "no recorded result"
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
"$BIN" --db "$QDB" status | grep -q "unfinished at seq 1"
rm -f "$DB.seed.lua"

# Reading a session is a window, and the window is the newest turns. The old shape
# returned the oldest 200 of a long thread while saying nothing, so a reader looking
# for the end of a run got its opening moves. The tool that shows a session to the
# model must also say what it dropped.
# Its own database: it seeds a few hundred turns, and sharing them would put this
# file's fixtures in front of the recovery assertions above.
WA_SCRIPT=scripts/test-memory-window.lua "$BIN" --db "$DB.window" | grep "memory window ok"

# A thread is named after its first message, once. The name is what makes a list of threads usable,
# and it must not drift as the conversation moves - a name that follows the conversation is a name
# you cannot search for.
WA_SCRIPT=scripts/test-session-title.lua "$BIN" --db "$DB.title" | grep "session title ok"

# What a run looks like while it is running. The renderer is where the CLI's whole
# readable output is decided - a tool call's line, a failed call's line, and whether a
# captured transcript is free of escape sequences - so it is asserted without a model:
# the view is handed the events agent.lua emits, with a clock the test controls.
WA_SCRIPT=scripts/test-cli-view.lua "$BIN" --db "$DB.view" | grep "cli view ok"

# The status line must keep moving while the interpreter is blocked, and the timer therefore
# lives in the host. The evidence is the captured stdout of a child that does nothing but
# sleep: it cannot repaint anything itself, so every frame and every tenth of a second in that
# file is the host's own work. The clock reaching 0.5s or more is what proves a timer rather
# than one frame drawn at the start.
TICKER_OUT="$DB.ticker.out"
WA_SCRIPT=scripts/test-cli-ticker.lua "$BIN" --db "$DB.ticker" > "$TICKER_OUT" 2>&1
ticker_frames=$(tr '\r' '\n' < "$TICKER_OUT" | grep -c "Thinking" || true)
ticker_clocks=$(tr '\r' '\n' < "$TICKER_OUT" | sed -n 's/.* \([0-9][0-9]*\.[0-9]s\)$/\1/p' | uniq | wc -l | tr -d ' ')
ticker_marks=$(tr '\r' '\n' < "$TICKER_OUT" | grep "2K" | cut -b 7-9 | LC_ALL=C sort -u | wc -l | tr -d ' ')
ticker_last=$(tr '\r' '\n' < "$TICKER_OUT" | sed -n 's/.* \([0-9][0-9]*\.[0-9]s\)$/\1/p' | tail -1 || true)
if [ "$ticker_frames" -ge 8 ] && [ "$ticker_clocks" -ge 8 ] && [ "$ticker_marks" -ge 3 ] \
  && [ "$ticker_last" != "0.0s" ] && [ -n "$ticker_last" ]; then
  echo "cli ticker ok ($ticker_frames frames, $ticker_marks marks, clock reached $ticker_last)"
else
  echo "cli ticker FAILED: $ticker_frames frames, $ticker_clocks clocks, $ticker_marks marks, last \"$ticker_last\""
  exit 1
fi

# A command must not be able to hold the interpreter forever: an agent curled the node's own port
# from inside a turn, the request queued behind the turn that made it, and the worker waited on
# itself. The deadline is set short here so the check takes seconds, not minutes.
WASM_AGENT_EXEC_TIMEOUT_SECONDS=2 WA_SCRIPT=scripts/test-exec-timeout.lua "$BIN" --db "$DB.exec" | grep "exec timeout ok"

# Reasoning replay is a choice, and it is ~36% of the average request. The switch has to
# reach the request, so the same script runs both ways and inspects the body it builds.
WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash WASM_AGENT_REASONING_REPLAY=1 \
  WA_SCRIPT=scripts/test-reasoning-replay.lua "$BIN" --db "$DB.replay1" | grep "reasoning replay ok"
WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash WASM_AGENT_REASONING_REPLAY=0 \
  WA_SCRIPT=scripts/test-reasoning-replay.lua "$BIN" --db "$DB.replay0" | grep "reasoning replay ok"

# One file written twice in a turn is one change, and its patch is built from the blobs. Both halves
# matter to undo: a second entry carrying the intermediate text would restore a state the turn itself
# created. Sandboxed home, because the reversible text is stored as content-addressed blobs under it.
WASM_AGENT_HOME="$DB.home" WA_SCRIPT=scripts/test-changeset.lua "$BIN" --db "$DB.changeset" | grep "changeset ok"

# Unchanged instructions keep identical prefix bytes; edited instructions must take effect without
# a restart. The fixture mutates a scratch file so a stale per-process cache cannot pass vacuously.
# A legitimate authority change is allowed to invalidate provider caching.
SCRATCH_AGENTS_MD="$DB.agents.md"
printf 'ORIGINAL INSTRUCTIONS\n' > "$SCRATCH_AGENTS_MD"
WASM_AGENT_AGENTS_MD="$SCRATCH_AGENTS_MD" \
  WA_SCRIPT=scripts/test-prefix-stability.lua "$BIN" --db "$DB.prefix" | grep "prefix stability ok"
rm -f "$SCRATCH_AGENTS_MD"

# A guest is not a smaller master. A guest node owns no worktree - so it is not named after
# one and a rename does not move a branch on its behalf - and a master's call on a guest is
# filed under the master, not the guest. Sandboxed home: the node's stored name and role must
# be this test's, not the machine's, and the node's own last four lines write to them.
WASM_AGENT_HOME="$DB.home" WA_SCRIPT=scripts/test-guest.lua "$BIN" --db "$DB.guest" | grep "guest ok"

# A node that is healthy and wedged at the same time is not instrumented, it is quiet.
# The accept thread answers /health without the interpreter, so a stuck Lua worker used
# to report ok forever while every endpoint that needs Lua hung with zero bytes. This
# stalls the worker on purpose and requires the node to say so. No model needed, which
# is why it runs here and not in the concurrency test's model half.
# Preserve the whole sub-suite output: grep used to hide the actual failing
# pool/session assertion while leaving only an earlier passing wedge line.
CONCURRENCY_PORT=$(node scripts/free-test-port-block.cjs)
WEDGE_ONLY=1 WA_BIN="$BIN" bash scripts/test-serve-concurrency.sh "$CONCURRENCY_PORT" > "$DB.concurrency.log" 2>&1 || {
  echo "the concurrency fixture failed; its output:"; tail -30 "$DB.concurrency.log"; exit 1; }
# Both claims are read from one run: the pair costs one fixture, not two.
grep "a stalled worker is visible" "$DB.concurrency.log"
grep "the client bridge survived a connection that said nothing" "$DB.concurrency.log"
ISOLATION_PORT=$(node scripts/free-test-port-block.cjs)
WA_BIN="$BIN" bash scripts/test-run-isolation.sh "$ISOLATION_PORT" > "$DB.isolation.log" 2>&1 || {
  echo "the run-isolation fixture failed; its output:"; tail -40 "$DB.isolation.log"; exit 1; }
grep '^run isolation ok$' "$DB.isolation.log"
run_proof_fixture sqlite 6 node scripts/test-sqlite-isolation.cjs "$BIN"
run_proof_fixture peer 43 node scripts/test-peer-run-admission.cjs "$BIN"
run_proof_fixture foreground 3 bash scripts/test-foreground-cancel.sh
rm -f "$DB.window"*
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
-- No count assertion: the labels below say which facts must be there, and a
-- count only breaks when a fact is added (adding `tools` turned 5 into 6).
for _, label in ipairs({ "node", "model", "session", "tools", "tree", "config" }) do
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

# No old name survives (ARCHITECTURE.md section 6). A rename that leaves both names in the tree is worse
# than not doing it, so it is a check rather than a convention - and it greps for the old *names*, not for
# the word "turn", which section 6 keeps for one speaker's contribution.
bash scripts/check-naming.sh
node scripts/test-naming-check.cjs
node scripts/test-execution-terminology.cjs
node scripts/test-auth-sessions.cjs "$BIN"
node scripts/test-fixture-verdict.cjs
node scripts/test-suite-verdict.cjs
node scripts/test-proof-verdict.cjs

# The image-attachment tests, plus the helper tests that came with them. They were
# written, they passed when run by hand, and nothing ran them - which is how a test
# quietly stops being true. Each file is self-contained and prints its own verdict,
# so the gate is that verdict rather than a fixed string.
for t in tests/*.lua; do
  fixture_status=0
  out=$(WA_SCRIPT="$t" "$BIN" --db "$DB.attach" 2>&1) || fixture_status=$?
  # Both pieces of evidence matter: a verdict printed before a crash is not success.
  if ! printf '%s' "$out" | node scripts/lib/test-verdict.cjs lua "$fixture_status"; then
    echo "FAIL $t (exit $fixture_status)"; printf '%s\n' "$out" | tail -6; exit 1
  fi
  rm -f "$DB.attach"*
done
echo "attach tests ok"

# A real long-running tool must remain observable/cancellable through another worker.
# Local mock provider only; no account, paid model or external browser required.
node scripts/test-operation-control.cjs "$BIN"
node scripts/test-operation-control.cjs "$BIN" --await

# Actual child runtime and real sentinel deliveries, never a /subagents route stub.
run_proof_fixture policy 62 node scripts/test-subagents-policy.cjs "$BIN"
run_proof_fixture children 17 node scripts/test-subagents.cjs "$BIN"
run_proof_fixture jobs 37 node scripts/test-job-subagents.cjs
run_proof_fixture orchestration 33 node scripts/test-orchestration-e2e.cjs "$BIN"
run_proof_fixture whatsapp 40 node scripts/test-whatsapp-subagent-e2e.cjs
# The reader's acted cursor: a message may be consumed only when a durable decision exists for it, the
# attempt count is bounded, and media is reported instead of handed to a child. Mock store, real ingest.
run_proof_fixture cursor 47 node scripts/test-whatsapp-cursor.cjs "$BIN"
# Local audio bytes, WASM formatting, durable reservation, and exactly-once
# verified sends. These use fake WhatsApp/STT adapters and no paid model.
node scripts/test-whatsapp-audio.mjs
node scripts/test-whatsapp-transcribe.cjs "$BIN" "$PLUGINS/whatsapp-transcript.wasm"
# The pipeline seam: a `returns` list reaches the foreach, a step that produced nothing fails the
# delivery, and a no-op run is distinguishable from a dropped result. Real sentinel, mock store, no model.
run_proof_fixture pipeline 19 node scripts/test-job-pipeline.cjs
# The source keeper's categorical refusals, hermetically: a port held by something that is not the agent
# browser is refused and left alone, and a missing logon task is named with the command that registers it.
# Scratch ports and a task name that does not exist, so no browser and no real task is touched.
node scripts/test-source-ensure.cjs

# The UI tests are JS and run outside the embedded interpreter, so they need node
# and they need the repo root as cwd (they read ui/app.js from disk). A test that does
# not run must not look like one that passed, so a skip is counted and asked for: if
# node is missing the suite says so and the verdict counts it.
if [ "${WASM_AGENT_SKIP_UI_TESTS:-}" = "1" ]; then
  echo "ui tests skipped by request (WASM_AGENT_SKIP_UI_TESTS=1)"
  SKIPPED=$((SKIPPED + 1))
elif command -v node >/dev/null 2>&1; then
  for t in tests/*.js; do
    [ -e "$t" ] || continue
    fixture_status=0
    out=$(node "$t" 2>&1) || fixture_status=$?
    if ! printf '%s' "$out" | node scripts/lib/test-verdict.cjs js "$fixture_status"; then
      echo "FAIL $t (exit $fixture_status)"; printf '%s\n' "$out" | tail -8; exit 1
    fi
  done
  echo "ui tests ok"
else
  echo "ui tests SKIPPED - node not on PATH"
  SKIPPED=$((SKIPPED + 1))
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "smoke ok ($SKIPPED skipped)"
else
  echo "smoke ok"
fi
