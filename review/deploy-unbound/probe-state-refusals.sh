#!/usr/bin/env bash
# Attack 5: do the state refusals still fire? A scratch repository with its own bare
# `origin`, the real deploy.sh from the reviewed tree, WA_DEPLOY_ROOT pointed at the
# scratch tree, a private WA_INSTALL_DIR. Nothing is built and nothing is installed.
# Run from the repository root:  bash review/deploy-unbound/probe-state-refusals.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
git init -q --bare "$SB/origin.git"
git init -q --initial-branch=main "$SB/work"; cd "$SB/work" || exit 1
git config user.name f; git config user.email f@x.invalid
printf 'one\n' > f.txt; git add -A; git commit -qm one
git remote add origin "$SB/origin.git"; git push -q origin main; git branch --set-upstream-to=origin/main main >/dev/null
mkdir -p "$SB/inst"; printf 'nothing\n' > "$SB/inst/serve.pid"
run() { # extra args...
  local out st
  out="$( cd "$SB/work" && env -u WASM_AGENT_IN_TURN WA_DEPLOY_ROOT="$SB/work" WA_INSTALL_DIR="$SB/inst" \
      WASM_AGENT_HOME="$SB/home" WA_PORT=18996 WA_CLIENT_PORT=18997 bash "$ROOT/scripts/deploy.sh" "$@" 2>&1 )"; st=$?
  printf '%s\n' "$out" | tail -2 | sed 's/^/    /'; echo "    exit=$st"
}
echo "== (a) dirty tree =="; printf 'edit\n' >> "$SB/work/f.txt"; run --reason probe; git -C "$SB/work" checkout -q -- .
echo "== (b) HEAD not on origin/main, WITHOUT --require-main (the WA_INSTALL_DIR exemption) =="
git -C "$SB/work" checkout -q -b feature; printf 'x\n' > "$SB/work/g.txt"
git -C "$SB/work" add -A; git -C "$SB/work" commit -qm feature; run --reason probe
echo "== (b') HEAD not on origin/main, WITH --require-main =="; run --require-main --reason probe
echo "== (c) HEAD behind origin/main =="
git -C "$SB/work" checkout -q main
git clone -q -b main "$SB/origin.git" "$SB/other"
( cd "$SB/other" && git config user.name f && git config user.email f@x.invalid \
  && printf 'two\n' > h.txt && git add -A && git commit -qm two && git push -q origin main )
run --reason probe
echo "== (d) a deploy from inside a run =="
( cd "$ROOT" && WASM_AGENT_IN_TURN=1 WA_INSTALL_DIR="$SB/inst" bash scripts/deploy.sh --reason guard ) 2>&1 | head -1
( cd "$ROOT" && WASM_AGENT_IN_TURN=1 bash scripts/upgrade.sh "$ROOT/scripts/deploy.sh" ) 2>&1 | head -1
echo "== (e) the knob is truthy on any non-empty value (the proof block, read out of deploy.sh) =="
mkdir -p "$SB/proofroot/scripts/lib" "$SB/proofroot/rust"
printf '[workspace]\n' > "$SB/proofroot/rust/Cargo.toml"
cat > "$SB/proofroot/scripts/lib/full-gate-proof.mjs" <<'P'
import fs from 'node:fs'; if (process.env.M) fs.writeFileSync(process.env.M, 'invoked\n');
console.log(JSON.stringify({ verified: false, reason: 'no receipt' }));
P
git -C "$SB/proofroot" init -q --initial-branch=main; git -C "$SB/proofroot" add -A >/dev/null 2>&1
git -C "$SB/proofroot" -c user.name=f -c user.email=f@x.invalid commit -qm fixture
BLOCK="$(awk '/^# 4\. Build\.$/{on=1} on{print} on && /^fi$/ {exit}' "$ROOT/scripts/deploy.sh")"
{ echo 'set -uo pipefail'; echo "ROOT=\"$SB/proofroot\""; echo "cd \"$SB/proofroot\""
  echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'; echo 'note() { echo "NOTE: $*"; }'
  printf '%s\n' "$BLOCK"; echo 'echo CONTINUED'; } > "$SB/run-block.sh"
for v in "" 1 0 false no; do
  if [ -z "$v" ]; then out="$(bash "$SB/run-block.sh" 2>&1)"; label=unset
  else out="$(WA_DEPLOY_REQUIRE_RELEASE_PROOF="$v" bash "$SB/run-block.sh" 2>&1)"; label="$v"; fi
  printf '    WA_DEPLOY_REQUIRE_RELEASE_PROOF=%-6s -> %s\n' "$label" \
    "$(printf '%s\n' "$out" | grep -m1 -E 'REFUSED|CONTINUED' | cut -c1-84)"
done
