#!/usr/bin/env bash
# THE WHOLE SEQUENCE AGAINST THE REAL upgrade.sh, signed part and all (Fable's gate before WA_VERSION_FOLDERS).
#
# WHAT IS REAL: scripts/versions-adopt.sh, the lua part signing (a scratch wa-vault, as the publisher signs), the part's
# verification by the node's own `release verify`, scripts/version-install.sh's seal and point, and the REAL
# scripts/upgrade.sh at every step including the restart.
#
# WHAT THIS NODE CANNOT DO, said instead of faked: there is no live node here to restart, so step 4 ends in the sequence's
# own refusal - `version_folders_restart_failed: no previous version to move back to (first install)`. The row asserts THAT
# sentence, so it proves the sequence reached the restart through the pointer and reported honestly. The switch-back case
# needs a SECOND version (so there is a previous one to return to) and is the next case to add, not a claim of this one.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh
. scripts/lib/lua-part.sh
. scripts/lib/sentinel-move.sh

n=0
ok()  { n=$((n+1)); printf '  ok   %s\n' "$*"; }
fail(){ echo "FAIL test-version-folders-real-restart: $*" >&2; exit 1; }

# THE ROW RUNNER HANDS EVERY ROW WA_BIN (ROW-CONTRACT row-runner8): the program IT built for this commit. A row that looks
# only in $HOME/.local/bin SKIPs inside the runner while passing on a workstation - measured: rc=0-SKIP.
WA_BIN="${WA_TEST_BINARY:-${WA_BIN:-${HOME}/.local/bin/wa}}"
# THE SENTINEL AND THE SUPERVISOR ARE LOOKED FOR BESIDE WA_BIN FIRST: a build tree keeps the three together, and the
# runner's target directory is the only place they can be for a commit that is not installed.
SENTINEL="${WA_SENTINEL_BINARY:-$(dirname "$WA_BIN")/wa-sentinel}"
# THE ROW BUILDS WHAT IT NEEDS FROM ITS OWN COMMIT. The runner builds `wa` for the requested commit and nothing else, so
# asking it for wa-sentinel and wa-operations-supervisor can only SKIP (measured twice). Both live in this repository, and
# CARGO_TARGET_DIR is already pointed at the mission target, so the three end up beside each other exactly as a release
# install lays them out.
build_companion() { # <bin name> <target dir>
  local bin="$1" dir="$2" root
  [ -x "$dir/$bin" ] && return 0
  root="$(cd "$(dirname "$0")/.." && pwd)"
  [ -f "$root/rust/Cargo.toml" ] || return 1
  command -v cargo >/dev/null 2>&1 || return 1
  # A VIRTUAL WORKSPACE NEEDS THE PACKAGE NAMED: `cargo build --bin X` from rust/ refuses, so the crate is named
  # explicitly. Measured: without -p the build failed and the row SKIPped a third time.
  ( cd "$root/rust" && timeout 900 cargo build --release -p "$bin" --bin "$bin" > "${TMPDIR:-/tmp}/build-$bin.log" 2>&1 ) || return 1
  [ -x "$dir/$bin" ]
}
WA_DIR="$(dirname "$WA_BIN")"
build_companion wa-sentinel "$WA_DIR" || true
build_companion wa-operations-supervisor "$WA_DIR" || true
[ -x "$SENTINEL" ] || SENTINEL="${HOME}/.local/bin/wa-sentinel"
SUPERVISOR="${WA_SUPERVISOR_BINARY:-}"
if [ ! -x "$SUPERVISOR" ]; then
  for candidate_sup in "$(dirname "$0")/../rust/target/release/wa-operations-supervisor" \
                       $(ls -t "$(dirname "$0")"/../rust/target/*/release/wa-operations-supervisor 2>/dev/null | head -1); do
    [ -x "$candidate_sup" ] && SUPERVISOR="$candidate_sup" && break
  done
fi
[ -x "$WA_BIN" ] && [ -x "$SENTINEL" ] && [ -x "$SUPERVISOR" ] \
  || { echo 'SKIP version-folders-real-restart: needs wa, wa-sentinel and wa-operations-supervisor (WA_TEST_BINARY / WA_SENTINEL_BINARY / WA_SUPERVISOR_BINARY)'; exit 0; }

# DISK-BACKED, NOT tmpfs: with the scratch under /tmp the real sentinel never came up (status stayed down), while the same
# start on a disk-backed directory reaches `sentinel: up` at once.
BASE="${WA_ROW_SCRATCH_ROOT:-${HOME}/.cache/wa-row}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
S=$(mktemp -d "$BASE/wa-vfrestart-XXXXXX") || { echo 'FAIL: no scratch' >&2; exit 2; }
cleanup() {
  # THE WATCHER IS KILLED BY PID: `stop` asks, and a watcher that is already confused does not answer - which is exactly
  # how one run's watcher survived into the next run and made its `status` hang (measured: 2 green runs, then hangs).
  timeout 5 "$S/install/wa-sentinel" stop >/dev/null 2>&1
  for pid_file in "$S"/home/.wasm-agent/sentinel/sentinel.pid "$HOME"/.wasm-agent/sentinel/sentinel.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill "$pid" 2>/dev/null; sleep 0.2; kill -9 "$pid" 2>/dev/null
  done
  test_release_vault_stop >/dev/null 2>&1
  # THE SENTINEL WRITES AS IT EXITS, so one rm can leave a directory behind and print an error after a green run.
  chmod -R u+w "$S" 2>/dev/null
  for _ in 1 2 3; do rm -rf "$S" 2>/dev/null; [ -e "$S" ] || break; sleep 0.2; done
  [ -e "$S" ] && echo "  note: scratch left at $S" || true
}
trap cleanup EXIT
wa_scratch_env_apply "$S" >/dev/null
wa_scratch_env_check "$S" >/dev/null || fail 'the row environment is NOT isolated'
ok 'scratch node isolated'

INSTALL="$S/install"; mkdir -p "$INSTALL" "$S/cand"
# hard links: the same bytes, none of the disk (ten copies of an 80 MB binary fill /tmp and look like a staging bug)
# A COPY, NOT A LINK: /tmp and /var/tmp are separate filesystems here, so `ln` fails with EXDEV and the row then reported
# "the host declares no lua interface" because the binary was never there - a row defect dressed as a product one.
cp -f "$WA_BIN" "$INSTALL/wa"; cp -f "$SENTINEL" "$INSTALL/wa-sentinel"
cp -f "$WA_BIN" "$S/cand/wa"; cp -f "$WA_BIN" "$S/cand/wa-term"; cp -f "$SUPERVISOR" "$S/cand/wa-operations-supervisor"
printf 'commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbranch=main\nvia=linux-bootstrap\n' > "$INSTALL/installed.txt"
HOST_INT="$(wa_lua_part_host_interface "$INSTALL/wa" 2>/dev/null)"
[ -n "$HOST_INT" ] || fail 'the host declares no lua interface'
ok "the host declares its interface ($HOST_INT)"

# A SIGNED part, signed the way the publisher signs it
. scripts/lib/test-release-vault.sh
. scripts/lib/release-signing.sh
test_release_vault_start || { echo 'SKIP version-folders-real-restart: no scratch vault to sign the part'; exit 0; }
export WA_RELEASE_KEYS="$TEST_RELEASE_VAULT_KEYS"
mkdir -p "$S/part/lua/core"; printf 'init from the part\n' > "$S/part/lua/core/init.lua"
{ printf 'capabilities %s\n' "$HOST_INT"; printf 'commit deadbeefcafe\n'
  printf '%s  lua/core/init.lua\n' "$(sha256sum < "$S/part/lua/core/init.lua" | awk '{print $1}')"; } > "$S/part/manifest.txt"
( cd "$S/part" && tar czf "$S/lua-core.tar.gz" manifest.txt lua )
( cd "$S" && sha256sum lua-core.tar.gz > SHA256SUMS )
wa_release_sign_sums "$S/SHA256SUMS" "$S/SHA256SUMS.sig" >/dev/null 2>&1 || fail 'the part could not be signed'
ok 'the part is signed (scratch vault)'
{ printf 'compat 1\n'; printf 'lua-core %s %s interface=%s\n' "$(sha256sum < "$S/lua-core.tar.gz" | awk '{print $1}')" \
    "$(wc -c < "$S/lua-core.tar.gz" | tr -d ' ')" "$HOST_INT"; } > "$S/lua.lock"

export WA_SHARE_ROOT="$S/share" WA_SENTINEL_SUPERVISOR=none WA_PORT="${WA_PORT:-8919}"
timeout 30 "$INSTALL/wa-sentinel" start >"$S/sentinel.log" 2>&1 || true
echo "  diag: sentinel start exit=$? log=[$(head -2 "$S/sentinel.log" | tr "\n" " ")]" || fail "the sentinel did not start: $(tail -2 "$S/sentinel.log")"
# READINESS IS THE PRODUCT'S OWN WAIT, NOT MY LOOP (law 17). scripts/lib/sentinel-move.sh already knows how to wait for a
# sentinel to be ready - bounded, 0.1 s ticks, 15 s by default - and version-install.sh uses that same function. The row
# uses it too, with the unit layer stubbed, so the readiness rule has ONE implementation and a start's exit code proves
# nothing.
cat > "$S/systemctl-stub" <<'STUB'
#!/bin/sh
# answers only the question the product's wait asks, from the sentinel's own status answer
check() {
  for a in "$@"; do
    case "$a" in
      is-active)
        if "$ROW_SENTINEL" status 2>/dev/null | grep -qE '^ *sentinel: *up'; then echo active; else echo inactive; fi
        exit 0 ;;
    esac
  done
  echo inactive
  exit 0
}
check "$@"
STUB
chmod +x "$S/systemctl-stub"
export WA_SENTINEL_UNIT_SYSTEMCTL="$S/systemctl-stub" WA_SENTINEL_UNIT_DIR="$S/units"
ROW_SENTINEL="$INSTALL/wa-sentinel"; export ROW_SENTINEL
if wa_sentinel_move_active 15; then
  ok "the product's own readiness wait (wa_sentinel_move_active) sees the sentinel up"
else
  SENT_STATE="$(timeout 10 "$INSTALL/wa-sentinel" status 2>&1)"
  printf '  sentinel status: %s\n' "$(printf '%s' "$SENT_STATE" | tr '\n' ' ' | cut -c1-170)"
  fail 'the product readiness wait never saw the sentinel up within 15s'
fi
ok 'the real sentinel supervises the scratch node'

OUT="$S/seq.log"
timeout 250 bash scripts/version-sequence.sh --install "$INSTALL" --candidate "$S/cand/wa" \
  --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --root "$(pwd)" --upgrade "$(pwd)/scripts/upgrade.sh" \
  --lua-part "$S/lua-core.tar.gz" --lua-lock "$S/lua.lock" --sentinel-fail-expected > "$OUT" 2>&1
rc=$?
grep -q 'SEQSTEP 1 convert' "$OUT" && ok 'step 1 convert (the real versions-adopt)' || fail 'step 1 never ran'
grep -q 'SEQSTEP 2 stage' "$OUT" && ok 'step 2 stage (the real upgrade.sh)' || fail 'step 2 never ran'
grep -q 'lua_part_signed_ok' "$OUT" && ok 'the node verified the part signature (release verify)' \
  || fail "the part was not accepted: $(grep -m1 lua_part "$OUT")"
grep -q 'lua_part_filled' "$OUT" && ok 'and the part filled the lua-core member' || fail 'the part did not fill the member'
grep -q 'SEQSTEP 3 seal and point' "$OUT" && ok 'step 3 seal and point (the real version-install.sh)' || fail 'step 3 never ran'
grep -q 'SEQSTEP 4 restart through the pointer' "$OUT" && ok 'step 4 restart through the pointer (the real upgrade.sh)' || fail 'step 4 never ran'
# NO LIVE NODE HERE: the sequence must SAY that, and not pretend it restarted
[ "$rc" = 3 ] && ok 'the sequence exits 3 on a restart it could not make' || fail "the sequence exited $rc, not 3: $(tail -2 "$OUT" | tr '\n' ' ')"
grep -q 'version_folders_restart_failed' "$OUT" && ok 'and it reports the failed restart by name' \
  || fail 'the failed restart was not named'
KEPT=$(ls "$S/share/versions" 2>/dev/null | tr '\n' ' ')
case "$KEPT" in *aaaaaaaaaaaa*) ok 'the previous version is still on disk' ;; *) fail "the previous version is gone: $KEPT" ;; esac
case "$KEPT" in *bbbbbbbbbbbb*) ok 'and the new version is sealed and kept' ;; *) fail "the new version is gone: $KEPT" ;; esac

printf 'version folders, real restart: %d checks\n' "$n"
echo 'version folders, real restart ok'
