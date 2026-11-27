#!/bin/bash
# ONE TEST FOR lib/main-binary.sh, and it can fail.
#
# The rule is "main is graded by main's own binary, never the laptop's install". The FIRST version of that rule
# refused too eagerly and the loop printed "NOT GRADED: no binary of main's own" for every tip - a watchdog that
# never barks. This test therefore pins the ORDER and the three outcomes:
#   1. the deploy's own resolver finds a release (the tip, or one covering its compiled inputs) -> use it, do not
#      build, do not touch ~/.local/bin;
#   2. no release -> build in its own target dir, NICED, holding a lock, and use that;
#   3. neither -> a named refusal that says what was tried, and STILL not the installed binary;
#   plus: a loop that cannot grade two tips in a row raises the alarm, and one graded tip clears it.
#
# WHAT IT CAN CATCH: a resolver step that is ordered after the build, a build that runs unniced or unbounded, a
# fall back to ~/.local/bin, a silent refusal, and a loop that stays quiet while never grading anything.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-mainbin.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-main-binary: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }
. "$HERE/lib/main-binary.sh"

B="$WORK/bin"; ROOT="$WORK/root"; STAGE="$WORK/releases"; TARGET="$WORK/target"
mkdir -p "$B" "$ROOT/scripts/lib" "$ROOT/rust" "$STAGE" "$TARGET"
SHA=0123456789abcdef0123456789abcdef01234567; SHORT=${SHA:0:12}

# --- 1. THE RELEASE PATH: the deploy's resolver answers, so no build and no install.
mkdir -p "$WORK/rel-$SHORT"; printf '#!/bin/bash\necho wa\n' > "$WORK/rel-$SHORT/wa"; chmod +x "$WORK/rel-$SHORT/wa"
cat > "$ROOT/scripts/lib/node-binaries.sh" <<EOS
wa_node_target_triple() { echo x86_64-unknown-linux-gnu; }
wa_node_binary_source_resolve() { echo "$WORK/rel-$SHORT"; }
EOS
# cargo: if it is EVER called here, the ordering is wrong. It records the fact.
printf '#!/bin/bash\necho cargo-called >> %s/cargo.called\nexit 0\n' "$WORK" > "$B/cargo"; chmod +x "$B/cargo"

OUT=$(PATH="$B:/usr/bin:/bin" bash -c '. "$1"; wa_main_binary "$2" "$3" "$4" "$5"' _ "$HERE/lib/main-binary.sh" "$SHA" "$STAGE" "$TARGET" "$ROOT" 2>&1); rc=$?
ok "$rc" "0" "a published release for the tip is used"
like "$OUT" "$WORK/rel-$SHORT/wa" "and it is the release's binary"
checks=$((checks + 1)); [ ! -f "$WORK/cargo.called" ] || fail "the release path must not build"

# --- 2. THE BUILD PATH: the resolver finds nothing, so it builds HERE, niced, under a lock.
cat > "$ROOT/scripts/lib/node-binaries.sh" <<EOS
wa_node_target_triple() { echo x86_64-unknown-linux-gnu; }
wa_node_binary_source_resolve() { echo "wa_main_binary: the resolver named no release" >&2; return 1; }
EOS
cat > "$B/cargo" <<'EOS'
#!/bin/bash
# Record the niceness the build was given (field 19 of /proc/self/stat) and whether the lock was held.
ni=$(awk '{print $19}' /proc/self/stat)
printf '%s\n' "$ni" > "$CARGO_TARGET_DIR.nice"
[ -f "$CARGO_TARGET_DIR/.build.lock" ] && echo held > "$CARGO_TARGET_DIR.locked"
mkdir -p "$CARGO_TARGET_DIR/release"; printf '#!/bin/bash\necho built\n' > "$CARGO_TARGET_DIR/release/wa"; chmod +x "$CARGO_TARGET_DIR/release/wa"
exit 0
EOS
chmod +x "$B/cargo"
rm -f "$WORK/cargo.called"
OUT=$(PATH="$B:$PATH" bash -c '. "$1"; wa_main_binary "$2" "$3" "$4" "$5"' _ "$HERE/lib/main-binary.sh" "$SHA" "$STAGE" "$TARGET" "$ROOT" 2>&1); rc=$?
ok "$rc" "0" "with no release it builds one instead of refusing"
like "$OUT" "$TARGET/release/wa" "and hands back the build in its OWN target dir"
checks=$((checks + 1)); [ -s "$TARGET.nice" ] || fail "the build recorded no niceness"
checks=$((checks + 1)); { [ "$(cat "$TARGET.nice" 2>/dev/null || echo 0)" -gt 0 ]; } || fail "the build must be niced (niceness $(cat "$TARGET.nice" 2>/dev/null))"
checks=$((checks + 1)); [ -f "$TARGET.locked" ] || fail "the build must hold a lock, so two runs cannot build into one dir"

# --- 3. THE REFUSAL: no resolver, no cargo -> a named refusal, and never the install.
rm -f "$ROOT/scripts/lib/node-binaries.sh" "$TARGET/release/wa"
mkdir -p "$WORK/nocargo"
OUT=$(PATH="$WORK/nocargo:/usr/bin:/bin" WA_NODE_BINARIES_LIB="$WORK/none.sh" bash -c '. "$1"; wa_main_binary "$2" "$3" "$4" "$5"' _ "$HERE/lib/main-binary.sh" "$SHA" "$STAGE" "$TARGET" "$ROOT" 2>&1); rc=$?
ok "$rc" "1" "nothing to grade with is a refusal, not a verdict"
like "$OUT" "NO BINARY OF $SHORT" "and the refusal names the tip"
like "$OUT" "is NOT used" "and says the installed binary is not the answer"
checks=$((checks + 1)); case "$OUT" in *"/.local/bin/wa"*) case "$OUT" in *"NOT used"*) ;; *) fail "the refusal must not offer the installed binary as an answer";; esac;; esac

# --- 4. THE ALARM: two tips in a row that could not be graded.
STATE="$WORK/state"; mkdir -p "$STATE"
wa_note_ungraded aaaa1111 "$STATE"; rc1=$?
ok "$rc1" "0" "one ungraded tip is not the alarm"
wa_note_ungraded bbbb2222 "$STATE" >/dev/null; rc2=$?
ok "$rc2" "1" "two tips in a row that could not be graded raise the alarm"
ok "$(cat "$STATE/health-ungraded" | grep -c .)" "2" "both tips are recorded, so the message can name them"
wa_note_graded "$STATE"
checks=$((checks + 1)); [ ! -f "$STATE/health-ungraded" ] || fail "a graded tip must clear the counter"
wa_note_ungraded aaaa1111 "$STATE"; rc3=$?
ok "$rc3" "0" "after a graded tip, one ungraded tip starts the count again"

if [ "$failed" -gt 0 ]; then echo "test-main-binary: $failed failed of $checks checks"; exit 1; fi
echo "test-main-binary ok ($checks checks)"
