#!/usr/bin/env bash
# The install record after a deploy: whose is it, and what does it say?
#
# The failure this exists for (2026-10-02 19:30). A deploy installed the node at 2f02b4c through
# upgrade.sh and then died before its own record step - the installed copy of `deploy.sh` had just been
# `cp`ed over itself while it was running (the sentinel's capture of that run ends on
# `line 534: syntax error near unexpected token '('`; the measured cause and fix are at deploy.sh's
# `ship_file' rule). What was left in the install was upgrade.sh's record - `commit=unknown`,
# `source_provenance=unverified-binary`, `via=upgrade.sh`, `reason=upgrade requested` - while the node
# served a build of 2f02b4c, and `verify-install.sh --json` could only report
# `installed unknown is not an ancestor of tree 2f02b4c` plus a stale `sentinel_sha256`.
#
# This file asserts the result of that repair, each claim by RUNNING the real code out of
# `scripts/deploy.sh` / `scripts/upgrade.sh` in a PRIVATE install directory (WA_INSTALL_DIR is always the
# fixture; the live install is never read or written, nothing is built, nothing is restarted):
#
#   1. the deploy's record step names the EXACT commit with `source_provenance=clean-built-by-deploy` and
#      `record_role=final`, over an interim record upgrade.sh had already written (the observed ordering);
#   2. the `sentinel_sha256` it records is the hash of the sentinel the install carries;
#   3. running the record step twice is idempotent, and the record exists BEFORE the steps that can die
#      after the install (the early call) - so a deploy that dies there still leaves the deploy's record;
#   4. upgrade.sh's record says `record_role=interim` when a deploy called it and `final` when it did not;
#   5. the deploy hands upgrade.sh its caller identity (WA_UPGRADE_VIA / WA_UPGRADE_REASON / WA_INSTALL_DIR
#      / WA_PORT), and the old shape - a comment inside the command's continuation - is measured to lose it;
#   6. nothing is left half-written: no `.installed.txt.deploy.*` staging file survives.
#
# The other two claims in the delivery's brief - a plain deploy with the knob unset does NOT consult a
# release proof, and `WA_DEPLOY_REQUIRE_RELEASE_PROOF=1` refuses when no proof exists - are pinned by
# `scripts/test-deploy-gate-policy.sh`, which reads the same block out of deploy.sh and measures the
# absence of the proof lookup with a poisoned proof script.
#
# Hermetic: a temp directory per run, no cargo, no network, no sentinel, no model.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
UPGRADE="$ROOT_DIR/scripts/upgrade.sh"

checks=0
fail() { echo "test-deploy-record: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
check() { # condition label [detail]
  if [ "$1" = "1" ]; then ok "$2" "${3:-}"; else fail "$2${3:+ - $3}"; fi
}
sha() { [ -f "$1" ] && sha256sum < "$1" | awk '{print $1}'; }
field() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
[ -f "$UPGRADE" ] || fail "no $UPGRADE to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-record-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# --- the real code, read out of the files that ship it -------------------------------------------
awk '/^record_installed\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$DEPLOY" > "$WORK/record.sh"
grep -q 'record_role=final' "$WORK/record.sh" \
  || fail "could not read the record step out of deploy.sh (the marker moved?), or it no longer writes record_role=final"
grep -q 'source_provenance=clean-built-by-deploy' "$WORK/record.sh" \
  || fail "the extracted record step does not write source_provenance=clean-built-by-deploy"
awk '/^record_install\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$UPGRADE" > "$WORK/upgrade-record.sh"
grep -q 'record_role=' "$WORK/upgrade-record.sh" \
  || fail "could not read upgrade.sh's record_install out of it, or it no longer writes a record_role"
awk '/^# wa-deploy-upgrade-invocation: begin$/{on=1} on{print} on && /^# wa-deploy-upgrade-invocation: end$/{exit}' \
  "$DEPLOY" > "$WORK/invocation.sh"
grep -q 'WA_UPGRADE_VIA=deploy.sh' "$WORK/invocation.sh" \
  || fail "could not read the deploy -> upgrade invocation out of deploy.sh (the markers moved?)"

# --- the fixture: a private install directory and a tree that names a real commit -----------------
TREE="$WORK/tree"; INSTALL="$WORK/install"
mkdir -p "$TREE/scripts" "$INSTALL/scripts" "$TREE/rust/target/release" || fail "cannot stage the fixture"
git -C "$TREE" init -q --initial-branch=main || fail "cannot init the fixture repository"
git -C "$TREE" config user.name "record fixture"
git -C "$TREE" config user.email "record@example.invalid"
printf '#!/usr/bin/env bash\necho "fixture node"\n' > "$TREE/rust/target/release/wa"
git -C "$TREE" add -A >/dev/null 2>&1
git -C "$TREE" commit -qm "fixture: the tree a deploy builds from" || fail "cannot commit the fixture"
COMMIT="$(git -C "$TREE" rev-parse --short HEAD)"
BRANCH="$(git -C "$TREE" rev-parse --abbrev-ref HEAD)"

cp -f "$TREE/rust/target/release/wa" "$INSTALL/wa"
printf '#!/usr/bin/env bash\necho "the installed sentinel"\n' > "$INSTALL/wa-sentinel"
NODE_HASH="$(sha "$INSTALL/wa")"
SENTINEL_HASH="$(sha "$INSTALL/wa-sentinel")"
UPGRADE_HASH="$(sha "$UPGRADE")"
[ -n "$NODE_HASH" ] && [ -n "$SENTINEL_HASH" ] || fail "cannot hash the fixture artifacts"

# The state a deploy leaves behind if it stops after upgrade.sh installed the node - reproduced from the
# live install's own installed.txt of 2026-10-02 19:30 (commit=unknown, via=upgrade.sh).
interim_record() { # destination
  printf 'commit=unknown\nbranch=unknown\ndirty=unknown\nsha256=old-node\nsentinel_sha256=old-sentinel\nupgrade_sha256=%s\nsource_commit_hint=%s\nsource_provenance=unverified-binary\nrecord_role=interim\nvia=upgrade.sh\nat=2026-10-02T19:30:02Z\nreason=upgrade requested\n' \
    "$UPGRADE_HASH" "$(git -C "$TREE" rev-parse HEAD)" > "$1"
}

# The deploy's own environment, as deploy.sh has it when step 8 runs. The wrapper calls the extracted
# record step `calls` times, which is how "written early" and "written again last" are both exercised.
run_record() { # calls [path-prefix] -> the record step's output; the prefix shadows a command for that run
  local calls="$1" prefix="${2:-}"
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$INSTALL\""
    echo "COMMIT=\"$COMMIT\""
    echo "BRANCH=\"$BRANCH\""
    echo 'DIRTY=0'
    echo "HASH=\"$NODE_HASH\""
    echo "SENTINEL_HASH=\"$SENTINEL_HASH\""
    echo "UPGRADE_HASH=\"$UPGRADE_HASH\""
    echo 'REASON="land the three reviewed deliveries"'
    echo "WA_SERVICE_DIR=\"$INSTALL\""
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    cat "$WORK/record.sh"
    local i
    for i in $(seq 1 "$calls"); do echo 'record_installed'; done
  } > "$WORK/run-record.sh"
  if [ -n "$prefix" ]; then PATH="$prefix:$PATH" bash "$WORK/run-record.sh" 2>&1; else bash "$WORK/run-record.sh" 2>&1; fi
}

# 1. Whatever upgrade.sh recorded first, the deploy's record is the one that stands, and it names the
#    exact commit the deploy built - not "unknown", and not a provenance that only certifies bytes.
interim_record "$INSTALL/installed.txt"
OUT="$(run_record 1)"; STATUS=$?
[ "$STATUS" = "0" ] || fail "the record step refused: status $STATUS - $OUT"
check "$([ "$(field commit "$INSTALL/installed.txt")" = "$COMMIT" ] && echo 1)" \
  "the final record names the exact deployed commit" "commit=$(field commit "$INSTALL/installed.txt") of $COMMIT"
check "$([ "$(field source_provenance "$INSTALL/installed.txt")" = "clean-built-by-deploy" ] && echo 1)" \
  "the final record says clean-built-by-deploy" "source_provenance=$(field source_provenance "$INSTALL/installed.txt")"
check "$([ "$(field record_role "$INSTALL/installed.txt")" = "final" ] && echo 1)" \
  "the final record is the owner's final one" "record_role=$(field record_role "$INSTALL/installed.txt")"
check "$([ "$(field via "$INSTALL/installed.txt")" = "deploy.sh" ] && echo 1)" \
  "the final record names the deploy that wrote it" "via=$(field via "$INSTALL/installed.txt")"
check "$([ "$(field reason "$INSTALL/installed.txt")" = "land the three reviewed deliveries" ] && echo 1)" \
  "the final record carries the deploy's reason, not upgrade.sh's default" "reason=$(field reason "$INSTALL/installed.txt")"
check "$([ "$(field install_dir "$INSTALL/installed.txt")" = "$INSTALL" ] && echo 1)" \
  "the record states the install directory it was written for" "install_dir=$(field install_dir "$INSTALL/installed.txt")"
check "$([ "$(field upgrade_sha256 "$INSTALL/installed.txt")" = "$UPGRADE_HASH" ] && echo 1)" \
  "the record names the upgrade.sh it shipped beside the binary"

# 2. The sentinel hash recorded is the sentinel the install carries. On 2026-10-02 this check failed on the
#    live machine because upgrade.sh had recorded the sentinel it saw BEFORE the deploy replaced it.
check "$([ "$(field sentinel_sha256 "$INSTALL/installed.txt")" = "$(sha "$INSTALL/wa-sentinel")" ] && echo 1)" \
  "the recorded sentinel hash is the installed sentinel" "recorded=$(field sentinel_sha256 "$INSTALL/installed.txt") installed=$(sha "$INSTALL/wa-sentinel")"
check "$([ "$(field sha256 "$INSTALL/installed.txt")" = "$(sha "$INSTALL/wa")" ] && echo 1)" \
  "the recorded node hash is the installed node"
check "$([ "$(grep -c '^via=upgrade.sh$' "$INSTALL/installed.txt")" = "0" ] && echo 1)" \
  "the interim record is gone, not merely appended to"

# 3. Written twice (early, then as the deploy's last act): the same facts both times, so neither call is the
#    one that decides what a verifier reads. `at=` is the time of writing, which is the one field that may
#    differ; everything else must be identical, or the early call would be overwriting the late one's meaning.
FIRST="$(grep -v '^at=' "$INSTALL/installed.txt")"
OUT="$(run_record 2)"; STATUS=$?
[ "$STATUS" = "0" ] || fail "the second record write refused: status $STATUS - $OUT"
check "$([ "$(grep -v '^at=' "$INSTALL/installed.txt")" = "$FIRST" ] && echo 1)" \
  "writing the record twice is idempotent" "the early and final calls agree on every field but the time of writing"
EARLY_LINE="$(grep -n '^record_installed$' "$DEPLOY" | head -1 | cut -d: -f1)"
SHIP_LINE="$(grep -n 'ship_file "$DEPLOY_SRC"' "$DEPLOY" | head -1 | cut -d: -f1)"
check "$([ -n "$EARLY_LINE" ] && [ -n "$SHIP_LINE" ] && [ "$EARLY_LINE" -lt "$SHIP_LINE" ] && echo 1)" \
  "the record is written before the steps that can die after the install" \
  "record at line $EARLY_LINE, the self-ship that killed the 2026-10-02 deploy at line $SHIP_LINE"

# 6. Atomic: the record reaches the name `installed.txt` by being RENAMED there, so a reader never sees a
#    half-written record. This is observed, not described (finding F3 of the review of change/deploy-unbound:
#    the earlier version of this check only asserted that no staging file survived, and the reviewer's
#    mutation M8 - a direct `> installed.txt`, no staging and no rename - kept all 24 checks green). For one
#    run `mv` is shadowed by a wrapper that records the rename and the state of the destination at that
#    instant, then does the real rename. A writer that truncates installed.txt directly is caught twice
#    over: it never renames anything, and the destination would be observed as a prefix, not as a record.
WATCH="$WORK/bin"; mkdir -p "$WATCH"
REAL_MV="$(command -v mv)"
cat > "$WATCH/mv" <<'MVWATCH'
#!/usr/bin/env bash
src=""; dst=""
for a in "$@"; do case "$a" in -*) ;; *) if [ -z "$src" ]; then src="$a"; else dst="$a"; fi ;; esac; done
{
  printf 'rename src=%s dst=%s\n' "$src" "$dst"
  printf 'staged-complete=%s\n' "$(grep -c '^reason=' "$src" 2>/dev/null)"
  printf 'dest-before-complete=%s\n' "$( [ -f "$dst" ] && grep -c '^commit=' "$dst" 2>/dev/null || echo absent)"
  printf 'dest-before-lines=%s\n' "$( [ -f "$dst" ] && wc -l < "$dst" | tr -d ' ' || echo absent)"
} >> "$MV_WATCH_LOG"
exec "$REAL_MV" "$@"
MVWATCH
chmod +x "$WATCH/mv"
interim_record "$INSTALL/installed.txt"
INTERIM_LINES="$(wc -l < "$INSTALL/installed.txt" | tr -d ' ')"
export REAL_MV MV_WATCH_LOG="$WORK/mv-watch.log"
rm -f "$MV_WATCH_LOG"
run_record 1 "$WATCH" >/dev/null 2>&1 || true
check "$([ -s "$MV_WATCH_LOG" ] && echo 1)" \
  "the record is committed by renaming, not by writing the name directly" \
  "a direct > installed.txt (mutation M8) calls no mv at all, and fails this check"
check "$([ "$(grep -c '^rename src=[^ ]*\.installed\.txt\.deploy\.[0-9]* ' "$MV_WATCH_LOG" 2>/dev/null)" = "1" ] && echo 1)" \
  "the rename takes a staged sibling into place" "$(grep '^rename ' "$MV_WATCH_LOG" 2>/dev/null | head -1 | cut -c1-120)"
check "$([ "$(grep -c '^staged-complete=[1-9]' "$MV_WATCH_LOG" 2>/dev/null)" = "1" ] && echo 1)" \
  "the staged file was already a complete record when it was renamed"
check "$([ "$(grep -c '^dest-before-complete=[1-9]' "$MV_WATCH_LOG" 2>/dev/null)" = "1" ] && echo 1)" \
  "the destination held a COMPLETE record at the instant of the rename" \
  "the interim record is $INTERIM_LINES line(s); a truncate-then-write is observed here as a prefix of one"
check "$([ "$(ls "$INSTALL"/.installed.txt.deploy.* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && echo 1)" \
  "no half-written record is left behind" "no .installed.txt.deploy.* in $INSTALL"

# 4. upgrade.sh's side of the ownership: interim under a deploy, final on its own. Both run the real
#    record_install out of upgrade.sh against the same fixture install.
run_upgrade_record() { # via [new-binary] -> the record_install block's output, record in installed.txt
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$INSTALL\""
    echo "INSTALLED=\"$INSTALL/wa\""
    echo "NEW=\"${2:-$INSTALL/wa}\""
    echo "PREVIOUS_COMMIT=\"$COMMIT\""
    echo "SOURCE_COMMIT=\"$(git -C "$TREE" rev-parse HEAD)\""
    if [ -n "$1" ]; then echo "WA_UPGRADE_VIA=\"$1\""; fi
    echo 'WA_UPGRADE_REASON="an upgrade request"'
    echo 'file_hash() { [ -f "$1" ] && sha256sum < "$1" 2>/dev/null | awk "{print \$1}" || true; }'
    cat "$WORK/upgrade-record.sh"
    echo 'record_install'
  } > "$WORK/run-upgrade-record.sh"
  bash "$WORK/run-upgrade-record.sh" 2>&1
}
interim_record "$INSTALL/installed.txt"
OUT="$(run_upgrade_record deploy.sh)"; STATUS=$?
[ "$STATUS" = "0" ] || fail "upgrade.sh's record path refused under a deploy: status $STATUS - $OUT"
check "$([ "$(field record_role "$INSTALL/installed.txt")" = "interim" ] && echo 1)" \
  "upgrade.sh records an INTERIM record when a deploy called it" \
  "record_role=$(field record_role "$INSTALL/installed.txt") via=$(field via "$INSTALL/installed.txt")"
check "$([ "$(field via "$INSTALL/installed.txt")" = "deploy.sh" ] && echo 1)" \
  "the interim record names the deploy as its caller" \
  "(a deploy whose caller identity is lost here is what made the 19:30 record read via=upgrade.sh)"
check "$([ "$(field source_provenance "$INSTALL/installed.txt")" = "unverified-binary" ] && echo 1)" \
  "the interim record claims only what upgrade.sh can prove" "source_provenance=unverified-binary"

OUT="$(run_upgrade_record '')"; STATUS=$?
[ "$STATUS" = "0" ] || fail "upgrade.sh's record path refused on its own: status $STATUS - $OUT"
check "$([ "$(field record_role "$INSTALL/installed.txt")" = "final" ] && echo 1)" \
  "a hand-run upgrade is its own final record" "record_role=$(field record_role "$INSTALL/installed.txt") via=$(field via "$INSTALL/installed.txt")"

# 4b. F4 of the review: the role is MONOTONE. A deploy whose build is byte-identical to what is installed
#     (the live node did exactly that on 2026-10-02: "the new binary is byte-identical to ... - nothing to
#     swap, restarting it") calls upgrade.sh only for the restart, and the record it finds is a deploy's own
#     final one FOR THESE BYTES. Overwriting that with `interim` asserts a death that has not happened - and
#     `verify-install.sh` then fails an install that is fine. A new binary still gets `interim`, because
#     that is the fact then.
deploy_final_record() { # commit -> a deploy's own final record, for the bytes the install carries now
  printf 'commit=%s\nbranch=%s\ndirty=0\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\ninstall_dir=%s\nservice_install_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nat=2026-10-02T19:31:00Z\nreason=the deploy that finished\n' \
    "$1" "$BRANCH" "$(sha "$INSTALL/wa")" "$(sha "$INSTALL/wa-sentinel")" "$UPGRADE_HASH" "$INSTALL" "$INSTALL" > "$INSTALL/installed.txt"
}
deploy_final_record "$COMMIT"
OUT="$(run_upgrade_record deploy.sh "$INSTALL/wa")"; STATUS=$?
[ "$STATUS" = "0" ] || fail "upgrade.sh's record path refused on identical bytes: status $STATUS - $OUT"
check "$([ "$(field record_role "$INSTALL/installed.txt")" = "final" ] && echo 1)" \
  "an interim write cannot downgrade a final record for the SAME bytes" \
  "record_role=$(field record_role "$INSTALL/installed.txt") - before the fix this read interim, which names a deploy death that did not happen"
check "$([ "$(field source_provenance "$INSTALL/installed.txt")" = "clean-built-by-deploy" ] && echo 1)" \
  "the kept record keeps the provenance that was true of those bytes" \
  "source_provenance=$(field source_provenance "$INSTALL/installed.txt")"
check "$([ "$(field commit "$INSTALL/installed.txt")" = "$COMMIT" ] && echo 1)" \
  "the kept record still names the commit those bytes came from" "commit=$(field commit "$INSTALL/installed.txt") of $COMMIT"

# ... and the downgrade signal still fires when it is TRUE: the installed bytes are no longer the ones the
# final record names (this is the state after upgrade.sh has swapped a new build in, before the deploy
# writes its own record).
deploy_final_record "$COMMIT"
printf '\n# a different build\n' >> "$INSTALL/wa"
OUT="$(run_upgrade_record deploy.sh "$INSTALL/wa")"; STATUS=$?
[ "$STATUS" = "0" ] || fail "upgrade.sh's record path refused on a new binary: status $STATUS - $OUT"
check "$([ "$(field record_role "$INSTALL/installed.txt")" = "interim" ] && echo 1)" \
  "a NEW binary still gets an interim record" "record_role=$(field record_role "$INSTALL/installed.txt")"
check "$([ "$(field source_provenance "$INSTALL/installed.txt")" = "unverified-binary" ] && echo 1)" \
  "and the interim record claims only what upgrade.sh can prove" "source_provenance=$(field source_provenance "$INSTALL/installed.txt")"
check "$([ "$(field commit "$INSTALL/installed.txt")" = "unknown" ] && echo 1)" \
  "the interim record does not borrow the old commit for new bytes" "commit=$(field commit "$INSTALL/installed.txt")"

# 5. The caller identity reaches upgrade.sh. The invocation is read out of deploy.sh and run against a stub
#    that prints the environment it received.
cat > "$WORK/stub-upgrade.sh" <<'STUB'
#!/usr/bin/env bash
printf 'WA_INSTALL_DIR=%s\nWA_PORT=%s\nWA_CLIENT_PORT=%s\nWA_UPGRADE_REASON=%s\nWA_UPGRADE_VIA=%s\nARG=%s\n' \
  "${WA_INSTALL_DIR:-unset}" "${WA_PORT:-unset}" "${WA_CLIENT_PORT:-unset}" \
  "${WA_UPGRADE_REASON:-unset}" "${WA_UPGRADE_VIA:-unset}" "${1:-unset}"
STUB
# `cp -f` is not the point here; the point is that the block's variables are what deploy.sh has at that line.
run_invocation() { # upgrade : port : client_port : reason
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$INSTALL\""
    echo "PORT=\"$2\""
    echo "CLIENT_PORT=\"$3\""
    echo "REASON=\"$4\""
    echo "UPGRADE=\"$1\""
    echo "NEW=\"$TREE/rust/target/release/wa\""
    cat "$WORK/invocation.sh"
  } > "$WORK/run-invocation.sh"
  bash "$WORK/run-invocation.sh" 2>&1
  cat "$INSTALL/deploy-upgrade.log" 2>/dev/null
}
LOG="$(run_invocation "$WORK/stub-upgrade.sh" 8877 8878 "a reason with spaces")"
for pair in "WA_UPGRADE_VIA=deploy.sh" "WA_UPGRADE_REASON=a reason with spaces" "WA_INSTALL_DIR=$INSTALL" "WA_PORT=8877" "WA_CLIENT_PORT=8878" "ARG=$TREE/rust/target/release/wa"; do
  check "$([ "$(printf '%s\n' "$LOG" | grep -cF "$pair")" = "1" ] && echo 1)" \
    "upgrade.sh receives $(printf '%s' "$pair" | cut -d= -f1)" "$pair"
done

# ...and the shape that lost them, measured: a comment line inside the command's continuation drops the
# whole `VAR=value \` prefix while the command still runs. This is why the comments above the invocation
# are above it, and why nothing may move them back in between.
cat > "$WORK/old-shape.sh" <<OLD
set -uo pipefail
WA_UPGRADE_VIA=deploy.sh \\
  # the comment that used to sit between the assignments and the command
  bash "$WORK/stub-upgrade.sh" > "$WORK/old-shape.out"
OLD
bash "$WORK/old-shape.sh" >/dev/null 2>&1
if [ "$(grep -cF 'WA_UPGRADE_VIA=unset' "$WORK/old-shape.out" 2>/dev/null)" = "1" ]; then
  ok "the old shape is reproduced as losing the caller identity" \
    "WA_UPGRADE_VIA=unset - the command ran, the prefix did not; this is what the 19:30 record showed"
else
  fail "a comment inside the continuation no longer drops the env prefix on this machine - the rule that keeps the comments above the invocation needs re-measuring"
fi

echo "test-deploy-record: ALL PASS ($checks checks; private install directory $INSTALL)"
