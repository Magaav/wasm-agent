#!/usr/bin/env bash
# THE CANARY VERB MUST WORK FROM THE INSTALLED BUILD (Fable 24/11, G).
#
# MEASURED on this laptop's installed build (53bb69b1): `wa features canary self-wake` printed only the
# feature table - no canary verdict - and `wa features canary json` printed the table too. The release
# step's per-node question IS that command (`lua/core/land.lua`, `ask_node` -> "wa features canary json",
# parsed by `canary_answer`), so on an installed node the canary collect could never answer, and the
# self-wake canary landed on main ("a wake due now is dispatched by the node's own tick") protected
# nothing in the fleet.
#
# This row requires all of the following, from a directory that is NOT a checkout and with NO lua root
# set - an installed node's own shape, embedded modules:
#   1. the CLI routes `features <verb>` to the Lua core instead of answering the table in Rust
#      (rust/wa-host/src/main.rs: the `features` fast path used to swallow every verb);
#   2. the registry is where an install puts it (`<home>/.wasm-agent/features.json`, scripts/deploy.sh
#      step 6b) - this row installs it exactly the way the deploy does, never from the tree's own path;
#   3. a loopback canary's CHILD can read its task file, which lives in the Lua tree the binary carries
#      (`WA_SCRIPT` used to be a plain filesystem read, so an installed node panicked on
#      "read lua/core/canaries/tasks/self-wake.lua: No such file or directory").
#
# NO `--db` IS PASSED, on purpose: a `--db` argument made the OLD binary work by accident (the Rust
# intercept only fires when `features` is the first argument), so passing one would prove nothing. The
# verb itself has to be routed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "canary-verb: no wa binary (set WA_BIN)" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "canary-verb: node is not on PATH, so the JSON shape cannot be judged" >&2; exit 2; }

S=$(mktemp -d "${TMPDIR:-/tmp}/canary-verb-XXXXXX") || exit 2
cleanup() { rm -rf "$S"; }
trap cleanup EXIT INT TERM
mkdir -p "$S/home/.wasm-agent" "$S/run" || exit 2
# 2. The registry, installed the way scripts/deploy.sh step 6b installs it. A node that does not have it
# answers "the feature registry is not readable" - which is a named refusal, not a canary verdict.
install -m 0644 "$ROOT/config/features/features.json" "$S/home/.wasm-agent/features.json" || {
  echo "canary-verb: the registry could not be installed into the scratch node" >&2; exit 2; }

# The installed node's own environment: embedded modules (no lua root), its own home and ledger, and no
# provider or vault in reach - a canary touches nothing of the operator's and spends no tokens.
node_run() {
  ( cd "$S/run" && env -u WASM_AGENT_LUA_ROOT -u WA_FEATURES_FILE -u WASM_AGENT_VAULT_URL \
      -u WASM_AGENT_OPENCODE_GO_VAULT_URL -u OPENAI_API_KEY -u OPENCODE_API_KEY \
      -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE \
      HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_DB="$S/home/.wasm-agent/memory.db" \
      WASM_AGENT_MANAGED=0 WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WA_BIN="$BIN" \
      "$BIN" "$@" )
}

# ---- 1. the verdict line, for one named canary ---------------------------------------------------
OUT="$(node_run features canary self-wake 2>&1)"; CODE=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
if [ "$CODE" != 0 ]; then
  echo "FAIL canary-verb: 'wa features canary self-wake' answered exit $CODE on an installed-style build"
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -Eq '^ *self-wake +PASS'; then
  echo "FAIL canary-verb: no 'self-wake PASS' verdict line - the verb did not run (the table is not a verdict)"
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -Eq '^canaries: [0-9]+ passed'; then
  echo "FAIL canary-verb: the run printed no 'canaries: N passed' summary line"
  exit 1
fi

# ---- 2. the JSON shape the release step parses ----------------------------------------------------
# The exit code of THIS run is NOT required to be zero: `canary json` runs EVERY feature, and on a bare
# scratch node some of them are honestly not proven (run-blocks needs an effect file, release-update needs
# an install record, the WhatsApp rows need a component). What the release step needs is the DOCUMENT: the
# one `canary_answer` parses and the self-wake row inside it. A failed row elsewhere is that node's
# verdict, not this row's business - and the named run above already proved exit 0 for a passing canary.
JSON="$(node_run features canary json 2>&1)"
VERDICT="$(printf '%s' "$JSON" | node -e '
  let text = "";
  process.stdin.on("data", (chunk) => { text += chunk; });
  process.stdin.on("end", () => {
    let document;
    try { document = JSON.parse(text.trim().split("\n").pop()); } catch (error) {
      console.log("unparseable: " + error.message); process.exit(0);
    }
    if (!document || !Array.isArray(document.features)) { console.log("no features array"); process.exit(0); }
    const row = document.features.find((entry) => entry && entry.feature === "self-wake");
    if (!row) { console.log("self-wake is not in the document"); process.exit(0); }
    console.log((row.ok ? "ok" : "not-ok") + " stage=" + row.stage);
  });')"
if [ "${VERDICT%% *}" != "ok" ]; then
  echo "FAIL canary-verb: the JSON the release step parses carries no passing self-wake row (${VERDICT:-empty})"
  printf '%s\n' "$JSON" | head -2 | cut -c1-300 | sed 's/^/  /'
  exit 1
fi

echo "canary-verb ok (installed build: 'self-wake PASS', json ${VERDICT})"
