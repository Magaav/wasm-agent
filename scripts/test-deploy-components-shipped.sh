#!/usr/bin/env bash
# Proof for "ship every production component" (docs/FEATURES.md, docs/COMPONENTS.md): components.lock
# pins the whole shipped set, and the deploy's component step installs and rolls back that set - not
# `graph` alone, which is what it did until the 08/11 finding left eight production components built,
# tested and never installed.
#
# What it proves, with no network, no wasm toolchain and no node:
#   A. the real components.lock: every name it pins is well formed, `graph` is among them, the shipped
#      set is exactly the production components (no test fixture is pinned), and a name is shipped by
#      being pinned - nothing else in the tree decides it;
#   B. the real lock installed for real, when this checkout has the artifacts
#      (`build/shipcomps-components`, what `bash scripts/build-components.sh` wrote): a temp bundle ->
#      the release resolution path -> all names staged and installed, pins verified, the previous set
#      recorded as absent, and the rollback removing them again. Reported SKIPPED, never passed, when
#      the artifacts are not here;
#   C. the set's mechanics on a fixture lock that is always available: install v1, record, deploy v2,
#      roll back to v1 (and a component that was absent before is removed, not left behind), and a
#      refusal in the middle of the set stops the install instead of reporting a partial success;
#   D. the deploy itself uses that step: the block in scripts/deploy.sh reads its names from
#      components.lock, records the set, installs it, restores it and records `component_set=` in
#      installed.txt (read out of the file by its own markers, so a change that removes it fails here).
#
#   bash scripts/test-deploy-components-shipped.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. scripts/lib/deploy-components.sh

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0; skipped=0
ok() { checks=$((checks + 1)); }
skip() { skipped=$((skipped + 1)); echo "SKIP $*"; }
fail() { echo "deploy components (shipped) FAILED: $*" >&2; exit 1; }
expect_status() { [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"; ok; }
contains() { printf '%s' "$1" | grep -qF -- "$2" || fail "$3: '$2' not in: $1"; ok; }
absent() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: '$2' should not be there: $1"; fi; ok; }

# The production components this release ships. Named here as the EXPECTATION, so the lock growing a
# test fixture or losing a component is a failure of this test rather than a silent change.
SHIPPED="agent-core codemode graph hooks memory mesh model-gateway selfloop telemetry-sink wa-email"

# ---------------------------------------------------------------------------------------------------
# A. components.lock is the shipped set
# ---------------------------------------------------------------------------------------------------
names="$(wa_components_shipped "$ROOT")"
expect_status 0 "$?" "the real lock is readable"
actual="$(printf '%s\n' "$names" | sort | tr '\n' ' ' | sed 's/ *$//')"
expected="$(printf '%s\n' $SHIPPED | sort | tr '\n' ' ' | sed 's/ *$//')"
[ "$actual" = "$expected" ] || fail "components.lock pins '$actual', expected '$expected'"
ok
contains "$names" "graph" "graph (the component every host.graph_* call runs) is pinned"
awk '/^[[:space:]]*(#|$)/ {next} $1 != "" {if ($2 !~ /^[0-9a-f]{64}$/) exit 1; if ($3 !~ /^[0-9]+$/) exit 2}' "$ROOT/components.lock" \
  || fail "a components.lock line is not '<name> <64 hex sha256> <bytes>'"
ok
for fixture in svc-echo svc-echo-v1 svc-echo-wasip1 svc-queue-echo svc-drain svc-wasi-env svc-wasi-fs svc-wasi-kv svc-wasi-net svc-wasi-stdin memory-crash memory-wedge mcp-echo; do
  absent "$names" "$fixture" "a test fixture is not shipped"
done
# Every pinned name is a component this tree can build (a manifest beside it), and the components that
# are production but pinned elsewhere (wa-whatsapp, mcp-whatsapp) are not silently in the set.
for name in $names; do
  [ -f "$ROOT/rust/components/$name/manifest.json" ] || fail "pinned $name has no rust/components/$name/manifest.json"
done
ok

# ---------------------------------------------------------------------------------------------------
# B. the real lock, installed for real (when this checkout has the built artifacts)
# ---------------------------------------------------------------------------------------------------
ARTIFACTS="${SHIP_ARTIFACTS:-$ROOT/build/shipcomps-components}"
missing=""
for name in $names; do
  [ -f "$ARTIFACTS/$name.wasm" ] && [ -f "$ARTIFACTS/$name.json" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  skip "the real set (no artifacts in $ARTIFACTS for:$missing; build them with 'bash scripts/build-components.sh <name>' or set SHIP_ARTIFACTS)"
else
  bundle="$WORK/bundle"; mkdir -p "$bundle"
  cp -f "$ROOT/components.lock" "$bundle/components.lock"
  for name in $names; do cp -f "$ARTIFACTS/$name.wasm" "$ARTIFACTS/$name.json" "$bundle/"; done
  dest="$WORK/install-components"; mkdir -p "$dest"
  stage="$WORK/stage"
  # WA_COMPONENT_RELEASE_URL puts the fetch on a directory: the same code path a node uses against the
  # release, with the network removed (docs/COMPONENTS.md, "Distributing components").
  out="$(WA_COMPONENT_RELEASE_URL="$bundle" WA_COMPONENTS_DIR="$dest" WA_COMPONENTS_CACHE="$WORK/cache" \
    wa_components_prepare "$ROOT" "$stage" "$WORK/install" $names 2>&1)" || fail "prepare failed: $out"
  staged="$(printf '%s' "$out" | grep -c '^component_source:')"
  [ "$staged" = "$(printf '%s\n' $names | wc -l | tr -d '[:space:]')" ] \
    || fail "staged $staged components, expected $(printf '%s\n' $names | wc -l | tr -d '[:space:]'): $out"
  ok
  # Every staged component is the pinned one: the pin file is the sha256 of the staged bytes.
  for name in $names; do
    [ "$(wa_component_sha256 "$stage/$name.wasm")" = "$(cat "$stage/$name.wasm.sha256")" ] \
      || fail "$name staged bytes differ from its pin"
    [ "$(wa_component_pin "$ROOT" "$name" | awk '{print $1}')" = "$(cat "$stage/$name.wasm.sha256")" ] \
      || fail "$name was staged at a sha256 components.lock does not pin"
  done
  ok
  wa_components_record_set "$dest" $names || fail "record_set failed"
  grep -c ' absent$' "$dest/.prev/components.set" | grep -qx "$(printf '%s\n' $names | wc -l | tr -d '[:space:]')" \
    || fail "the previous set was not recorded as absent for every component"
  ok
  installed="$(wa_components_install_set "$stage" "$dest" $names 2>&1)" || fail "install_set failed: $installed"
  [ "$(printf '%s' "$installed" | grep -c '^component_installed:')" = "$(printf '%s\n' $names | wc -l | tr -d '[:space:]')" ] \
    || fail "installed a different number of components than the lock pins: $installed"
  ok
  for name in $names; do
    cmp -s "$dest/$name.wasm" "$stage/$name.wasm" || fail "$name was not installed from the staged bytes"
  done
  ok
  restored="$(wa_components_restore_set "$dest" $names 2>&1)" || fail "restore_set failed: $restored"
  leftover="$(ls "$dest"/*.wasm 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$leftover" = "0" ] || fail "the rollback of a first install left $leftover module(s) behind"
  ok
fi

# ---------------------------------------------------------------------------------------------------
# C. the set's mechanics, on a fixture lock
# ---------------------------------------------------------------------------------------------------
repo="$WORK/repo"; mkdir -p "$repo"
v1="$WORK/v1"; v2="$WORK/v2"; mkdir -p "$v1" "$v2"
fixture_names="graph hooks memory"
lock="$repo/components.lock"
: > "$lock"
for name in $fixture_names; do
  printf '%s bytes v1' "$name" > "$v1/$name.wasm"
  printf '{"name":"%s","kind":"test"}\n' "$name" > "$v1/$name.json"
  printf '%s bytes v2' "$name" > "$v2/$name.wasm"
  printf '{"name":"%s","kind":"test"}\n' "$name" > "$v2/$name.json"
  printf '%s %s %s\n' "$name" "$(wa_component_sha256 "$v1/$name.wasm")" "$(wc -c < "$v1/$name.wasm" | tr -d '[:space:]')" >> "$lock"
done
same="$(wa_components_shipped "$repo")"
[ "$same" = "$(printf '%s\n' $fixture_names)" ] || fail "wa_components_shipped did not read the fixture lock in order: $same"
ok

dest="$WORK/mech-components"; mkdir -p "$dest"
stage1="$WORK/stage1"; stage2="$WORK/stage2"
WA_DEPLOY_COMPONENT_SOURCE="$v1" wa_components_prepare "$repo" "$stage1" "$WORK/mech" $fixture_names >/dev/null || fail "fixture v1 prepare"
wa_components_install_set "$stage1" "$dest" $fixture_names >/dev/null || fail "fixture v1 install"
ok
# `hooks` was not installed before the v2 deploy: the record must say absent for it and its sha for the
# two the node already had, and the rollback must remove only `hooks`.
rm -f "$dest/hooks.wasm" "$dest/hooks.wasm.sha256" "$dest/hooks.json"
wa_components_record_set "$dest" $fixture_names || fail "fixture record"
contains "$(cat "$dest/.prev/components.set")" "hooks absent" "a component the node did not have is recorded absent"
# v2 pins different bytes: re-pin the lock so the staging step accepts them.
: > "$lock"
for name in $fixture_names; do
  printf '%s %s %s\n' "$name" "$(wa_component_sha256 "$v2/$name.wasm")" "$(wc -c < "$v2/$name.wasm" | tr -d '[:space:]')" >> "$lock"
done
WA_DEPLOY_COMPONENT_SOURCE="$v2" wa_components_prepare "$repo" "$stage2" "$WORK/mech2" $fixture_names >/dev/null || fail "fixture v2 prepare"
wa_components_install_set "$stage2" "$dest" $fixture_names >/dev/null || fail "fixture v2 install"
cmp -s "$dest/graph.wasm" "$v2/graph.wasm" || fail "the v2 deploy did not install v2's graph"
[ -f "$dest/hooks.wasm" ] || fail "the v2 deploy did not install the component that was absent before"
ok
wa_components_restore_set "$dest" $fixture_names >/dev/null || fail "fixture restore"
cmp -s "$dest/graph.wasm" "$v1/graph.wasm" || fail "the rollback did not restore v1's graph bytes"
[ -f "$dest/hooks.wasm" ] && fail "the rollback left a component the node did not have before this deploy"
[ -f "$dest/.prev/components.set" ] || fail "the recorded set was lost by the rollback"
ok
# A refusal in the middle of the set: the second component's staged bytes are not its pin.
badstage="$WORK/badstage"; cp -f "$stage1"/*.wasm "$stage1"/*.json "$stage1"/*.sha256 "$badstage" 2>/dev/null || { mkdir -p "$badstage"; cp -f "$stage1"/*.wasm "$stage1"/*.json "$stage1"/*.sha256 "$badstage"; }
printf 'tampered' > "$badstage/memory.wasm"
out="$(wa_components_install_set "$badstage" "$WORK/bad-dest" $fixture_names 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "install_set accepted a component whose bytes are not its pin"
contains "$out" "component_hash_mismatch" "the refusal names the mismatch"
# ...and the set stops there AND undoes what it had already installed: a refused component leaves no
# half-installed set behind (the caller rollback is then a no-op, not a second repair).
for name in $fixture_names; do
  [ -f "$WORK/bad-dest/$name.wasm" ] && fail "a refused set left $name installed in a directory it did not exist in before"
done
ok

# ---------------------------------------------------------------------------------------------------
# D. the deploy uses that step
# ---------------------------------------------------------------------------------------------------
# Read out of the file (not piped through printf: a haystack that large dies of SIGPIPE under
# `set -o pipefail`, which would report a missing string that is there).
file_has() { grep -qF -- "$2" "$1" || fail "$3: '$2' is not in $1"; ok; }
deploy="$ROOT/scripts/deploy.sh"
file_has "$deploy" 'COMPONENT_NAMES="$(wa_components_shipped "$ROOT")"' "deploy reads its set from components.lock"
file_has "$deploy" 'wa_components_prepare "$ROOT" "$COMPONENT_STAGE" "$INSTALL_DIR" $COMPONENT_NAMES' "deploy stages the whole set"
file_has "$deploy" 'wa_components_install_set' "deploy installs the set through the set function"
file_has "$deploy" 'wa_components_record_set' "deploy records the previous set before replacing it"
file_has "$deploy" 'wa_components_restore_set' "deploy rolls the set back"
file_has "$deploy" 'component_set=' "deploy records the installed set in installed.txt"
grep -qF -- 'wa_components_prepare "$ROOT" "$COMPONENT_STAGE" "$INSTALL_DIR" graph' "$deploy"   && fail "deploy still stages graph alone"
ok
# The proof the deploy runs is still about the graph component: it is the one every host.graph_* call
# needs, and it must stay in the set (checked in A) and in that proof.
file_has "$deploy" 'graph component ok' "the deploy still proves a graph call through the staged component"

# The publisher builds exactly the lock's names, offline (`--check` reads, it never builds).
publish_out="$(bash "$ROOT/scripts/publish-components.sh" --check 2>&1)"
case "$?" in 0|2) ;; *) fail "publish-components.sh --check did not answer: $publish_out" ;; esac
for name in $names; do
  contains "$publish_out" "$name" "publish-components plans $name"
done

# ---------------------------------------------------------------------------------------------------
# E. installing is not enabling: the feature table a node answers after that install
# ---------------------------------------------------------------------------------------------------
# `wa features` is the same resolver the Lua gates ask (`docs/FEATURES.md`). This is the end-to-end half
# of "installed is not enabled": the components are in the directory the node reads, the policy file
# turns one on, the environment overrides it, and a component that is named but not installed is
# reported by name. SKIPPED (never passed) when there is no `wa` binary here, or when the one found does
# not know the verb (an older installed node).
BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  for candidate in "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" "$(command -v wa 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { BIN="$candidate"; break; }
  done
fi
# One JSON object per `{`, so a field can be asserted inside ITS feature's object and not anywhere in
# the document (serde prints the keys alphabetically: active, component, enabled, env, feature, …).
feature_object() { # <json> <id>
  printf '%s' "$1" | tr '{' '
' | grep -F '"feature":"'"$2"'"' | head -1
}
if [ -z "$BIN" ]; then
  skip "the feature table (no wa binary: set WA_BIN, or build rust/wa-host)"
  BIN=""
elif "$BIN" features --json >/dev/null 2>&1; then
  :
elif "$BIN" features --json 2>&1 | grep -q 'unknown command: features'; then
  skip "the feature table ($BIN does not know 'wa features': an older node)"
  BIN=""
else
  skip "the feature table ($BIN could not answer 'wa features --json')"
  BIN=""
fi
if [ -n "$BIN" ]; then
  home="$WORK/feature-home"; mkdir -p "$home/.wasm-agent"
  comps="$WORK/feature-components"; mkdir -p "$comps"
  # `memory` is shipped and copied in; `hooks` is enabled by the same policy file and is NOT installed.
  printf '{"version":1,"sensitive_capabilities":[],"features":{"memory":true,"hooks":true},"components":{}}
' > "$home/.wasm-agent/policy.json"
  if [ -z "$missing" ]; then
    cp -f "$ARTIFACTS/memory.wasm" "$ARTIFACTS/memory.wasm.sha256" "$ARTIFACTS/memory.json" "$comps/"
  fi
  win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
  run_features() { # [env assignment...] -> the JSON answer; prints nothing when the verb is unknown
    env WASM_AGENT_HOME="$(win "$home")" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0       WA_COMPONENTS_DIR="$(win "$comps")" WA_FEATURES_WATCH_MS=0 "$@" "$BIN" features --json 2>/dev/null
  }
  if [ -n "$missing" ]; then
    skip "the feature table's installed/active assertions (no artifacts to install)"
  fi
  out="$(run_features)"; status=$?
  # exit 3 is an answer, not a failure: "a feature I was asked for is running natively".
  [ "$status" = 0 ] || [ "$status" = 3 ] || fail "wa features --json did not answer (exit $status)"
  memory_obj="$(feature_object "$out" memory)"
  [ -n "$memory_obj" ] || fail "memory is not in the table: $out"
  contains "$memory_obj" '"enabled":true' "the policy switch turns memory on"
  contains "$memory_obj" '"source":"policy"' "the switch is attributed to the policy file"
  contains "$memory_obj" '"active":"component"' "an enabled feature with its component installed is the active path"
  contains "$memory_obj" '"reason":"active_component"' "the reason is the active component"
  hooks_obj="$(feature_object "$out" hooks)"
  [ -n "$hooks_obj" ] || fail "hooks is not in the table: $out"
  contains "$hooks_obj" '"enabled":true' "the policy turned hooks on too"
  contains "$hooks_obj" '"active":"native"' "an enabled feature with no component runs native"
  contains "$hooks_obj" '"reason":"component_missing"' "and says component_missing"
  contains "$hooks_obj" '"installed":null' "an absent component has no installed sha"
  # env beats policy, in both directions.
  env_out="$(run_features WA_MEMORY_COMPONENT=0)"; status=$?
  [ "$status" = 0 ] || [ "$status" = 3 ] || fail "wa features with an env override did not answer (exit $status)"
  memory_obj="$(feature_object "$env_out" memory)"
  contains "$memory_obj" '"enabled":false' "WA_MEMORY_COMPONENT=0 overrides a policy that says on"
  contains "$memory_obj" '"source":"env"' "and the source says env"
  env_out="$(run_features WA_CODEMODE_COMPONENT=1)"; status=$?
  [ "$status" = 0 ] || [ "$status" = 3 ] || fail "wa features with WA_CODEMODE_COMPONENT=1 did not answer (exit $status)"
  contains "$(feature_object "$env_out" codemode)" '"enabled":true' "WA_CODEMODE_COMPONENT=1 turns codemode on"
  # The exit status says "a feature I was asked for is running natively", so a script can check it.
  run_features >/dev/null; status=$?
  [ "$status" = 3 ] || fail "wa features exited $status, expected 3 (hooks is enabled and native)"
  ok
fi

if [ "$skipped" -gt 0 ]; then
  echo "deploy components (shipped): $checks checks, 0 failed, $skipped SKIPPED (see the SKIP lines)"
else
  echo "deploy components (shipped): $checks checks, 0 failed"
fi
