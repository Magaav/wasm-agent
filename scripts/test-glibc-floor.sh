#!/usr/bin/env bash
# Proof for the glibc floor at both ends - the class of failure that took mail down for two days (18/11):
# a published binary needed GLIBC_2.39, the node's glibc is 2.35, and the sentinel retried
# "GLIBC_2.39 not found" 424 times with no channel left to correct it.
#
# What is checked, and why each case earns its line:
#   * the measurement itself (scripts/lib/glibc-floor.sh): the newest symbol is read as a VERSION
#     (GLIBC_2.2.5 below GLIBC_2.31), a file with no glibc symbol answers nothing, and a host whose libc is
#     not glibc is "unknown" rather than "satisfied" or "refused";
#   * scripts/fleet-install.sh refuses an artifact that needs a newer glibc than the host, names BOTH
#     versions, and leaves the installed binary byte-identical with no backup and no swap;
#   * a planted `./lib/glibc-floor.sh` in the installer's CURRENT DIRECTORY is never read: the fleet
#     install sources no lib at all, proved under `bash -s` (the `curl | bash` shape) and under a
#     bare relative invocation - 3b01caea sourced `$(dirname $0)/lib` there, which under the pipe is `./lib`;
#   * each of the two copies of the block is the ONLY one in its file: a second begin/end pair would be a
#     second behaviour hiding below the first, where the byte-for-byte diff never reads;
#   * the same artifact whose floor this host satisfies gets PAST that step (the next refusal is the exec
#     test, which is a different sentence), so the guard is not a blanket refusal;
#   * scripts/upgrade.sh refuses the candidate before the proof and before the backup, with the running
#     binary untouched;
#   * scripts/deploy.sh guards BEFORE it executes the candidate - the block is read out of the script by its
#     markers and run against fixtures, and its line is asserted to precede the first `"$NEW" --...`, the
#     `--capability-digest` that used to swallow a too-new binary as a broken one;
#   * a host whose `sort` has no `-V` (busybox, on the same glibc hosts this check exists for) is "unknown",
#     not "refused": the comparison says so out loud and the binary is allowed through, because a check that
#     cannot measure must not refuse every artifact in the fleet;
#   * scripts/fleet-install.sh carries the four functions itself, so the copy of the script a node gets from
#     `curl` still makes the check - and the two copies are diffed here, byte for byte, so there is one
#     implementation and not two that drift;
#   * scripts/upgrade.sh calls the guard before the scratch proof, the backup and the swap, and the lib is
#     sourced and shipped beside an installed deploy.sh;
#   * scripts/publish-node-binaries.sh measures with the same function, and a malformed --glibc is refused;
#   * the byte scan equals the ELF's own `.gnu.version_r` maximum on real linked binaries, and on the built
#     artifacts when WA_GLIBC_ARTIFACT_DIR names them - the check that catches a `GLIBC_x.y` string that is
#     only text in the payload.
#
# No network, no node, no cargo, no zig: the artifacts are fixture ELFs (a header and symbol strings) and
# the host's glibc is stood in for by WA_GLIBC_HOST, the way WA_BOOTSTRAP_LIBC stands in for the probe in
# scripts/linux/bootstrap.sh. The fixtures are NOT executable on purpose: a guard that failed to refuse
# would then stop at the exec/health proof instead of reaching a swap on this machine.
#
#   bash scripts/test-glibc-floor.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LIB="$ROOT/scripts/lib/glibc-floor.sh"
FLEET="$ROOT/scripts/fleet-install.sh"
UPGRADE="$ROOT/scripts/upgrade.sh"
PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
. "$LIB"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "glibc floor FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  # A here-string rather than printf|grep: under "set -o pipefail" a grep that matches and exits early
  # SIGPIPEs the writer and the pipeline reports 141, so a TRUE assertion fails (measured 13/11).
  grep -qF -- "$2" <<< "$1" || fail "$3: '$2' not in: $1"
  ok
}
absent() { # <text> <needle> <what>
  grep -qF -- "$2" <<< "$1" && fail "$3: '$2' unexpectedly in: $1"
  ok
}
line_of() { # <file> <fixed string> -> the first line number holding it (0 when absent)
  awk -v want="$2" 'index($0, want) {print NR; found = 1; exit} END {if (!found) print 0}' "$1"
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
count_of() { # <file> <fixed string> -> how many lines hold it
  awk -v want="$2" 'index($0, want) {n++} END {print n + 0}' "$1"
}

# A fixture artifact: an ELF header of the named machine plus the symbol-version strings the real binary
# would carry in .dynstr. Two bytes of header are enough for the ELF-machine checks downstream; the
# strings are what the floor is read from.
mkelf() { # FILE MACHINE_HEX [STRING...]
  local file="$1" machine="$2"; shift 2
  { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$machine"; printf 'fixture'; printf '%s\n' "$@"; } > "$file"
}

# ---- 1. the measurement, on bytes ---------------------------------------------------------------
multi="$WORK/multi"
mkelf "$multi" 3e GLIBC_2.2.5 GLIBC_2.17 GLIBC_2.31
[ "$(wa_glibc_max_symbol "$multi")" = "2.31" ] || fail "the newest symbol of 2.2.5/2.17/2.31 is $(wa_glibc_max_symbol "$multi"), not 2.31"
ok
# The ordering that matters: 2.2.5 is the base every build needs, and a text sort would report it as the
# newest thing in a file that holds it ("2.2.5" sorts above "2.3" byte-wise). It must sort BELOW 2.31.
old="$WORK/old"; mkelf "$old" 3e GLIBC_2.2.5
[ "$(wa_glibc_max_symbol "$old")" = "2.2.5" ] || fail "GLIBC_2.2.5 alone reads as '$(wa_glibc_max_symbol "$old")'"
ok
wa_glibc_covers 2.31 2.2.5 || fail "2.31 does not cover 2.2.5 as a version"
ok
wa_glibc_covers 2.35 2.31 || fail "2.35 does not cover 2.31"
ok
wa_glibc_covers 2.31 2.31 || fail "2.31 does not cover itself"
ok
if wa_glibc_covers 2.35 2.39; then fail "2.35 was read as covering 2.39"; fi
ok
if wa_glibc_covers "" 2.31; then fail "an unmeasured host version was read as satisfied"; fi
ok
none="$WORK/none"; mkelf "$none" 3e 'some-other-symbol'
[ -z "$(wa_glibc_max_symbol "$none")" ] || fail "a file with no glibc symbol read as '$(wa_glibc_max_symbol "$none")'"
ok
wa_glibc_max_symbol "$WORK/absent" >/dev/null 2>&1
expect_status 2 "$?" "a missing file is not measured"

# ---- 2. the guard: both versions in the sentence, and no refusal it cannot justify ----------------
newer="$WORK/newer"; mkelf "$newer" 3e GLIBC_2.2.5 GLIBC_2.39
out="$(WA_GLIBC_HOST=2.35 wa_glibc_guard "$newer" wa)"; rc=$?
expect_status 3 "$rc" "an artifact needing GLIBC_2.39 on a glibc 2.35 host"
contains "$out" "glibc_floor_exceeded:" "the refusal is named"
contains "$out" "needs GLIBC_2.39" "the refusal names the version the artifact needs"
contains "$out" "has glibc 2.35" "the refusal names the version the host has"
contains "$out" "installed binary was left alone" "the refusal says nothing was replaced"
WA_GLIBC_HOST=2.39 wa_glibc_guard "$newer" >/dev/null; rc=$?
expect_status 0 "$rc" "an artifact needing exactly the host's glibc"
WA_GLIBC_HOST=2.31 wa_glibc_guard "$multi" >/dev/null; rc=$?
expect_status 0 "$rc" "an artifact needing less than the host's glibc"
WA_GLIBC_HOST=2.35 wa_glibc_guard "$none" >/dev/null; rc=$?
expect_status 0 "$rc" "a file with no glibc symbol (a static binary needs no floor)"

# The host probe: whatever this machine is, the answer is a version or "unknown" - never a guess.
if command -v ldd >/dev/null 2>&1 && ! ldd --version 2>&1 | head -1 | grep -qi musl; then
  want="$(ldd --version 2>&1 | head -1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -1)"
  got="$(wa_glibc_host_version)"
  [ "$got" = "$want" ] || fail "the host probe answered '$got', ldd --version says '$want'"
  ok
  # ...and on a glibc host the probe's own /bin/true must pass its own guard: the check is not a blanket
  # refusal on the machine that runs it.
  if [ -x /bin/true ]; then
    wa_glibc_guard /bin/true >/dev/null || fail "this host's own /bin/true was refused by its own glibc check"
    ok
  fi
else
  echo "host probe: SKIPPED (this host has no glibc ldd to compare with)"
fi

# ---- 3. scripts/fleet-install.sh refuses before the swap, and the old binary keeps running ---------
step="$WORK/fleet"; mkdir -p "$step/bin" "$step/art"
printf '#!/bin/sh\necho old-installed-binary\n' > "$step/bin/wa"
chmod +x "$step/bin/wa" 2>/dev/null || true
old_sha="$(sha "$step/bin/wa")"
mkelf "$step/art/wa-needs-2.39" 3e GLIBC_2.2.5 GLIBC_2.39
out="$(WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash "$FLEET" "file://$step/art/wa-needs-2.39" 2>&1)"; rc=$?
expect_status 1 "$rc" "fleet-install with an artifact needing GLIBC_2.39 on a 2.35 host"
contains "$out" "glibc_floor_exceeded:" "fleet-install names the glibc refusal"
contains "$out" "needs GLIBC_2.39" "fleet-install names the artifact's version"
contains "$out" "has glibc 2.35" "fleet-install names the host's version"
absent "$out" "artifact_does_not_run_here" "the glibc refusal comes before the exec test, so it is not reported as a broken artifact"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the installed binary was replaced despite the refusal"
ok
[ -z "$(ls -1 "$step/bin"/wa.prev.* 2>/dev/null)" ] || fail "a backup was written despite the refusal (something was swapped)"
ok

# The control: the same shape, an artifact this host CAN run. It must get past the glibc step - the next
# refusal is the exec test (a fixture is not an executable), which is a different sentence and a different
# cause.
mkelf "$step/art/wa-needs-2.31" 3e GLIBC_2.2.5 GLIBC_2.31
out="$(WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash "$FLEET" "file://$step/art/wa-needs-2.31" 2>&1)"; rc=$?
expect_status 1 "$rc" "fleet-install with a fixture artifact this host's glibc satisfies"
absent "$out" "glibc_floor_exceeded" "an artifact the host's glibc satisfies is not refused by the floor"
contains "$out" "artifact_does_not_run_here" "it reaches the exec test instead"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the installed binary was replaced by an artifact that does not run"
ok

# A copy of the script with NO lib beside it is exactly the shape a node gets from `curl ... fleet-install.sh`,
# and the floor check has to work there: the block travels inside the script. (Before this, that copy refused
# every install with glibc_floor_lib_missing - a gate that was off precisely where it was needed.)
mkdir -p "$WORK/lonely"
cp "$FLEET" "$WORK/lonely/fleet-install.sh"
out="$(WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash "$WORK/lonely/fleet-install.sh" "file://$step/art/wa-needs-2.39" 2>&1)"; rc=$?
expect_status 1 "$rc" "a standalone fleet-install.sh (no lib beside it) with a 2.39 artifact on a 2.35 host"
contains "$out" "glibc_floor_exceeded:" "the standalone copy makes the floor check itself"
contains "$out" "needs GLIBC_2.39" "and names the version the artifact needs"
contains "$out" "has glibc 2.35" "and the version the host has"
absent "$out" "glibc_floor_lib_missing" "it does not refuse for want of a lib it no longer needs"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the standalone copy replaced the binary despite the refusal"
ok
# ...and the control: the same standalone copy lets a 2.31 artifact past the floor and stops at the exec test,
# so the inline block is a check and not a blanket refusal.
out="$(WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash "$WORK/lonely/fleet-install.sh" "file://$step/art/wa-needs-2.31" 2>&1)"; rc=$?
absent "$out" "glibc_floor_exceeded" "the standalone copy does not refuse a 2.31 artifact on a 2.35 host"
contains "$out" "artifact_does_not_run_here" "it reaches the exec test instead"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the standalone copy replaced the binary with one that does not run"
ok

# ---- 4. scripts/upgrade.sh refuses the candidate before the proof and the backup -------------------
inst="$WORK/upgrade"; mkdir -p "$inst"
printf '#!/bin/sh\necho installed\n' > "$inst/wa"; chmod +x "$inst/wa" 2>/dev/null || true
printf 'commit=0000000000000000000000000000000000000000\nbranch=main\n' > "$inst/installed.txt"
inst_sha="$(sha "$inst/wa")"
candidate="$WORK/candidate"; mkelf "$candidate" 3e GLIBC_2.2.5 GLIBC_2.39; chmod +x "$candidate" 2>/dev/null || true
# A fixture tree stands in for the checkout, with ONE stubbed lib: turn-guard.sh. upgrade.sh refuses to run
# inside a turn on the node it would replace (correctly - that is the node this suite is running in), and
# that refusal is about the caller, not about the bytes; the glibc guard is what this case is measuring.
# Everything else upgrade.sh sources is the real file.
fake="$WORK/fakeroot"; mkdir -p "$fake/scripts/lib"
cp "$UPGRADE" "$fake/scripts/upgrade.sh"
cp "$ROOT/scripts/lib/glibc-floor.sh" "$ROOT/scripts/lib/service-target.sh" "$fake/scripts/lib/"
printf 'turn_owner() { :; }\nsentinel_supervises() { return 1; }\n' > "$fake/scripts/lib/turn-guard.sh"
out="$(WA_INSTALL_DIR="$inst" WA_GLIBC_HOST=2.35 bash "$fake/scripts/upgrade.sh" "$candidate" 2>&1)"; rc=$?
expect_status 3 "$rc" "upgrade.sh with a candidate needing GLIBC_2.39 on a 2.35 host"
contains "$out" "glibc_floor_exceeded:" "upgrade.sh names the glibc refusal"
contains "$out" "needs GLIBC_2.39" "upgrade.sh names the candidate's version"
contains "$out" "has glibc 2.35" "upgrade.sh names the host's version"
[ "$(sha "$inst/wa")" = "$inst_sha" ] || fail "upgrade.sh replaced the installed binary despite the refusal"
ok
[ ! -e "$inst/wa.pre-upgrade" ] || fail "upgrade.sh wrote its backup before refusing (the refusal must come first)"
ok

# ---- 5. the guard's place in the order, in deploy.sh and upgrade.sh --------------------------------
# A check that runs after the swap is a post-mortem: deploy.sh proves, then hands the bytes to upgrade.sh,
# which backs up, restarts and rolls back. The guard is only worth its line if it is before all of that.
deploy_guard="$(line_of "$ROOT/scripts/deploy.sh" 'wa_glibc_guard "$glibc_candidate"')"
deploy_prove="$(line_of "$ROOT/scripts/deploy.sh" 'wa_phase proving')"
[ "$deploy_guard" -gt 0 ] || fail "scripts/deploy.sh does not call wa_glibc_guard"
ok
[ "$deploy_guard" -lt "$deploy_prove" ] || fail "deploy.sh guards at line $deploy_guard, after the prove phase at $deploy_prove"
ok
# ...and before the deploy EXECUTES the candidate at all. The first line that runs $NEW is
# "--capability-digest", and a binary built against a newer glibc dies there with "the binary being
# installed cannot state its capability digest": a sentence about a broken artifact where the cause is a
# host that is too old, and the one refusal an operator could act on is never said (review of a9b60cc9).
deploy_exec="$(line_of "$ROOT/scripts/deploy.sh" '"$NEW" --')"
deploy_digest="$(line_of "$ROOT/scripts/deploy.sh" 'cannot state its capability digest')"
deploy_begin="$(line_of "$ROOT/scripts/deploy.sh" '# wa-deploy-glibc-guard: begin')"
deploy_end="$(line_of "$ROOT/scripts/deploy.sh" '# wa-deploy-glibc-guard: end')"
[ "$deploy_begin" -gt 0 ] && [ "$deploy_end" -gt "$deploy_begin" ] \
  || fail "the glibc guard block is not marked in scripts/deploy.sh (begin=$deploy_begin, end=$deploy_end)"
ok
[ "$deploy_exec" -gt 0 ] || fail "scripts/deploy.sh never runs the candidate: there is no '"$NEW" --...' line"
ok
[ "$deploy_end" -lt "$deploy_exec" ] \
  || fail "deploy.sh guards at $deploy_begin-$deploy_end but first RUNS the candidate at $deploy_exec (the --capability-digest line is at $deploy_digest), so a too-new binary is reported as a broken one instead of as glibc_floor_exceeded"
ok
# ...and the bytes it measures are the bytes this deploy would install: the guard is after all three
# assignments of NEW/NEW_SENTINEL (Lua fast path, a published binary, a binary built here).
for assign in 'NEW="$INSTALLED_BIN"' 'NEW="$BINARY_STAGE/wa"' 'fail "no built sentinel at $NEW_SENTINEL"'; do
  assign_line="$(line_of "$ROOT/scripts/deploy.sh" "$assign")"
  [ "$assign_line" -gt 0 ] || fail "scripts/deploy.sh no longer has the line: $assign"
  [ "$deploy_begin" -gt "$assign_line" ] \
    || fail "the guard begins at $deploy_begin, before NEW/NEW_SENTINEL are final at $assign_line ($assign)"
  ok
done
# The block itself, read out of deploy.sh by its markers and RUN against fixtures - the seam
# scripts/test-deploy-node-binaries.sh uses for the prebuilt branch. `fail`/`note` are the only names the
# block uses besides the lib's own functions, so they are the only stubs.
GUARD_BLOCK="$WORK/deploy-glibc-guard.sh"
awk '/^# wa-deploy-glibc-guard: begin$/{on=1; next} on && /^# wa-deploy-glibc-guard: end$/{exit} on{print}' \
  "$ROOT/scripts/deploy.sh" > "$GUARD_BLOCK"
[ -s "$GUARD_BLOCK" ] || fail "could not read the glibc guard out of deploy.sh (its markers are gone)"
ok
guard_block_out=""
guard_block_rc=0
run_guard_block() { # <NEW> <NEW_SENTINEL> <host glibc> [<lib>]
  guard_block_out="$(WA_GLIBC_HOST="$3" NEW="$1" NEW_SENTINEL="$2" bash -c '
    [ -n "$1" ] && . "$1"
    fail() { printf "deploy-refused: %s\n" "$*"; exit 9; }
    note() { printf "deploy-note: %s\n" "$*"; }
    . "$2"
  ' _ "$4" "$GUARD_BLOCK" 2>&1)"
  guard_block_rc=$?
}
run_guard_block "$step/art/wa-needs-2.39" "$step/art/wa-needs-2.31" 2.35 "$LIB"
expect_status 9 "$guard_block_rc" "the deploy guard refuses a candidate needing GLIBC_2.39 on a 2.35 host"
contains "$guard_block_out" "refused(glibc_floor_exceeded)" "deploy.sh's own block names the glibc refusal"
contains "$guard_block_out" "needs GLIBC_2.39" "and the version the candidate needs"
contains "$guard_block_out" "has glibc 2.35" "and the version the host has"
absent "$guard_block_out" "capability digest" "NOT the digest error a too-new binary used to die on"
run_guard_block "$step/art/wa-needs-2.31" "$step/art/wa-needs-2.31" 2.35 "$LIB"
expect_status 0 "$guard_block_rc" "a candidate at 2.31 on a 2.35 host passes the deploy guard"
absent "$guard_block_out" "glibc_floor_exceeded" "nothing is refused when the floor is satisfied"
run_guard_block "$step/art/wa-needs-2.31" "$step/art/wa-needs-2.39" 2.35 "$LIB"
expect_status 9 "$guard_block_rc" "the supervisor is guarded too (a sentinel that cannot start cannot roll back)"
contains "$guard_block_out" "wa-needs-2.39" "the refusal names the supervisor"
run_guard_block "$step/art/wa-needs-2.39" "$step/art/wa-needs-2.31" 2.35 ""
expect_status 0 "$guard_block_rc" "a deploy with no lib beside it degrades to a note"
contains "$guard_block_out" "deploy-note:" "the deploy says the floor was not measured instead of skipping silently"
deploy_upgrade="$(line_of "$ROOT/scripts/deploy.sh" 'bash "$UPGRADE" "$CANDIDATE"')"
[ "$deploy_guard" -lt "$deploy_upgrade" ] || fail "deploy.sh guards at $deploy_guard, after the upgrade.sh call at $deploy_upgrade"
ok
up_guard="$(line_of "$UPGRADE" 'wa_glibc_guard "$NEW"')"
up_proof="$(line_of "$UPGRADE" 'answers on scratch port')"
up_backup="$(line_of "$UPGRADE" 'BACKUP="$INSTALLED.pre-upgrade"')"
up_swap="$(line_of "$UPGRADE" 'mv -f "$INSTALLED.new" "$INSTALLED"')"
[ "$up_guard" -gt 0 ] || fail "scripts/upgrade.sh does not call wa_glibc_guard"
ok
[ "$up_guard" -lt "$up_proof" ] || fail "upgrade.sh guards at $up_guard, after the scratch proof at $up_proof"
ok
[ "$up_guard" -lt "$up_backup" ] || fail "upgrade.sh guards at $up_guard, after the backup at $up_backup"
ok
[ "$up_guard" -lt "$up_swap" ] || fail "upgrade.sh guards at $up_guard, after the swap at $up_swap"
ok
# ...and both scripts source it, and a deploy ships it beside an installed copy: a "request deploy" runs the
# INSTALLED deploy.sh, whose sibling libs are the ones a deploy shipped.
grep -q 'glibc-floor' <<< "$(sed -n '/for wa_lib_part in /p' "$ROOT/scripts/deploy.sh")" \
  || fail "scripts/deploy.sh does not source scripts/lib/glibc-floor.sh in its lib loop"
ok
grep -q 'ship_file "$ROOT/scripts/lib/glibc-floor.sh"' "$ROOT/scripts/deploy.sh" \
  || fail "deploy.sh does not ship scripts/lib/glibc-floor.sh beside itself"
ok

# ---- 6. the publish half measures with the same function, and refuses a malformed floor ------------
grep -q 'wa_glibc_max_symbol' "$PUBLISH" || fail "scripts/publish-node-binaries.sh does not measure with wa_glibc_max_symbol"
ok
# One definition: no second copy of the scan in any script (the publisher and the three installers must
# answer the same question about the same bytes, or the pin is a promise nobody checks). The ONE copy
# allowed is scripts/fleet-install.sh's, which travels inside that script because the script travels alone -
# and it is not a second implementation: section 8 diffs the two blocks and fails on a differing byte.
second="$(grep -rln "grep -a -o 'GLIBC_" "$ROOT/scripts" 2>/dev/null \
  | grep -v 'scripts/lib/glibc-floor.sh' | grep -v 'scripts/test-glibc-floor.sh' | grep -v 'scripts/fleet-install.sh')"
[ -z "$second" ] || fail "a second copy of the glibc scan lives in: $second"
ok
out="$(bash "$PUBLISH" --glibc 2.3l --check 2>&1)"; rc=$?
expect_status 2 "$rc" "a malformed --glibc floor"
contains "$out" "glibc_floor_malformed:" "the malformed floor is a named refusal"

# ---- 7. a host without a version sort: "unknown", not "refused" -----------------------------------
# `sort -V` is GNU coreutils' version sort, and a glibc host can be without it in two ways - both stubbed
# below. A busybox `sort` REJECTS the option, so every pipeline answers nothing and "nothing" read as "not
# covered"; a `sort` that ignores the flag silently answers byte order, which puts 2.9 above 2.10. A third
# shim answers the first two comparisons it is asked and then fails: the shape in which the scan succeeds
# and the comparison does not, which is the guard's own "unknown" branch. None of the three may turn into
# a refusal of a binary the host can run.
mkdir -p "$WORK/nosortv/bin" "$WORK/flaky/bin"
real_sort="$(command -v sort)"
cat > "$WORK/nosortv/bin/sort" <<SHIM
#!/bin/sh
# A busybox `sort`: rejects -V.
for a in "\$@"; do case \$a in *V*) echo "sort: unrecognized option: V" >&2; exit 1 ;; esac; done
exec $real_sort "\$@"
SHIM
cat > "$WORK/flaky/bin/sort" <<SHIM
#!/bin/sh
# Answers with the real sort while its counter allows, then fails on -V.
n=\$(( \$(cat "\$WA_TEST_SORT_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "\$WA_TEST_SORT_COUNT"
[ "\$n" -le 2 ] && exec $real_sort "\$@"
echo "sort: unrecognized option: V" >&2
exit 1
SHIM
chmod +x "$WORK/nosortv/bin/sort" "$WORK/flaky/bin/sort" 2>/dev/null || true
out="$(PATH="$WORK/nosortv/bin:$PATH" bash -c 'printf "2.35\n2.39\n" | sort -V' 2>&1)"; rc=$?
expect_status 1 "$rc" "the shim really is a sort without -V"
contains "$out" "unrecognized option" "and it fails the way busybox does"
out="$(PATH="$WORK/nosortv/bin:$PATH" bash -c '. "$1"; wa_glibc_max_symbol "$2"' _ "$LIB" "$newer" 2>&1)"
contains "$out" "glibc_floor_unknown:" "with no version order the measurement says so instead of answering nothing"
grep -qF "GLIBC_2.39" <<< "$out" && fail "the measurement answered a floor it could not order: $out"
ok
PATH="$WORK/nosortv/bin:$PATH" bash -c '. "$1"; wa_glibc_covers 2.35 2.39' _ "$LIB" >/dev/null 2>&1
expect_status 2 "$?" "without a version sort a comparison answers 2 (unknown), not 1 (not covered)"
out="$(PATH="$WORK/nosortv/bin:$PATH" WA_GLIBC_HOST=2.35 bash -c '. "$1"; wa_glibc_guard "$2" wa' _ "$LIB" "$newer" 2>&1)"; rc=$?
expect_status 0 "$rc" "a 2.39 artifact on a 2.35 host whose sort has no -V is ALLOWED, not refused"
contains "$out" "glibc_floor_unknown:" "the unmeasurable check is said out loud"
absent "$out" "glibc_floor_exceeded" "and it is not reported as exceeding the floor"
# The same rule where the scan HAS answered and only the comparison fails: allow, with the reason, never a
# refusal. A host refusing its own /bin/true off its own check is the shape of the bug this prevents.
SORT_COUNT="$WORK/sort-count"; : > "$SORT_COUNT"
out="$(PATH="$WORK/flaky/bin:$PATH" WA_TEST_SORT_COUNT="$SORT_COUNT" WA_GLIBC_HOST=2.35 bash -c '. "$1"; wa_glibc_guard "$2" wa' _ "$LIB" "$newer" 2>&1)"; rc=$?
expect_status 0 "$rc" "a comparison that answers nothing while the scan answered is still an allow"
contains "$out" "cannot compare the two" "the guard's own unknown branch names the reason"
absent "$out" "glibc_floor_exceeded" "and refuses nothing"

# ---- 8. one implementation: the copy inside fleet-install.sh IS the lib's block ---------------------
# A copy that drifts is two behaviours with one name, and the whole point of this lib is that the publisher
# and the three installers cannot disagree about the same bytes. The blocks are compared byte for byte, so
# "one behaviour" is a text the test can read rather than an intention two files share.
block_of() { awk '/^# wa-glibc-floor-begin$/{on=1} on{print} on && /^# wa-glibc-floor-end$/{exit}' "$1"; }
block_of "$LIB" > "$WORK/block-lib"
block_of "$FLEET" > "$WORK/block-fleet"
[ -s "$WORK/block-lib" ] || fail "the lib carries no wa-glibc-floor block (its markers are gone)"
ok
[ -s "$WORK/block-fleet" ] || fail "scripts/fleet-install.sh carries no wa-glibc-floor block; a copy of the script without it cannot make the check"
ok
if ! diff -u "$WORK/block-lib" "$WORK/block-fleet" > "$WORK/block-diff" 2>&1; then
  sed 's/^/  /' "$WORK/block-diff" >&2
  fail "the fleet-install copy of the glibc floor drifted from the lib's block: one behaviour means one text"
fi
ok
contains "$(cat "$WORK/block-lib")" "wa_glibc_guard()" "the shared block holds the guard itself"
contains "$(cat "$WORK/block-lib")" "wa_glibc_max_symbol()" "and the measurement it guards with"
[ "$(count_of "$LIB" "# wa-glibc-floor-begin")" = 1 ] || fail "the lib has more than one wa-glibc-floor block"
ok
# ...and exactly one copy in the fleet install too: the diff above reads only the text between the FIRST
# begin marker and the next end marker, so a second copy lower in the file - a fix applied to one and not
# the other - would be invisible to it.
[ "$(count_of "$FLEET" "# wa-glibc-floor-begin")" = 1 ] \
  || fail "scripts/fleet-install.sh carries $(count_of "$FLEET" "# wa-glibc-floor-begin") wa-glibc-floor blocks, not 1: one behaviour means one copy, and the diff above reads only the first"
ok
# ...and the closing marker is single in both, so the block the diff reads is the whole block: a stray end
# marker would cut it short and leave the rest of the guard uncompared.
for marked in "$LIB" "$FLEET"; do
  [ "$(count_of "$marked" "# wa-glibc-floor-end")" = 1 ] \
    || fail "$(basename "$marked") carries $(count_of "$marked" "# wa-glibc-floor-end") wa-glibc-floor-end markers, not 1"
  ok
done

# ---- 8b. nothing in the cwd can reach into the guard: the installer sources no lib at all -------------
# 3b01caea sourced the lib from `$(dirname "$0")/lib` when the file was there. Under `curl ... | bash` `$0` is
# `bash`, so that resolved to `./lib/glibc-floor.sh` - a file in the directory the operator happened to be
# standing in. A shell that ran the installer after a `cd` somewhere untrusted (an unpacked tarball, a
# shared build host) would have had its floor check - the one gate that keeps a node alive across a
# restart, on the node that IS the channel you would fix it through - replaced by whatever was lying there.
# The file below is that plant, and it speaks the moment it is sourced: being READ at all is the failure,
# whatever the order of definition would then make of the functions. Neither shape a node gets may read it:
# the pipe (`bash -s`, the `curl | bash` shape) and a bare relative invocation (`bash fleet-install.sh`,
# the same `./` hole by another door).
mkdir -p "$WORK/plant/lib"
cat > "$WORK/plant/lib/glibc-floor.sh" <<'PLANT'
# The guard a cwd can put in front of the real one: it says it was read, and it lets everything through.
printf 'PLANTED_LIB_SOURCED: a cwd lib was sourced by fleet-install.sh\n' >&2
wa_glibc_sort_orders_versions() { return 0; }
wa_glibc_max_symbol() { :; }
wa_glibc_covers() { return 0; }
wa_glibc_host_version() { :; }
wa_glibc_guard() { printf 'PLANTED_LIB_SOURCED: the cwd lib replaced the guard\n'; return 0; }
PLANT
cp "$FLEET" "$WORK/plant/fleet-install.sh"
out="$(cd "$WORK/plant" && WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash -s "file://$step/art/wa-needs-2.39" 2>&1 < fleet-install.sh)"; rc=$?
[ -s "$WORK/plant/lib/glibc-floor.sh" ] || fail "the plant was not written, so this case proves nothing"
ok
expect_status 1 "$rc" "the curl shape (bash -s, cwd holding a planted ./lib/glibc-floor.sh, a 2.39 artifact on a 2.35 host)"
absent "$out" "PLANTED_LIB_SOURCED" "the planted ./lib/glibc-floor.sh was NOT sourced under bash -s"
contains "$out" "glibc_floor_exceeded:" "the inline block refused, so the planted guard was not the one that ran"
contains "$out" "needs GLIBC_2.39" "and it names the version the artifact needs"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the planted-lib run replaced the installed binary"
ok
out="$(cd "$WORK/plant" && WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash fleet-install.sh "file://$step/art/wa-needs-2.39" 2>&1)"; rc=$?
expect_status 1 "$rc" "a bare relative path (bash fleet-install.sh) in the same cwd"
absent "$out" "PLANTED_LIB_SOURCED" "the planted cwd lib is not sourced by a relative invocation either"
contains "$out" "glibc_floor_exceeded:" "the inline block refuses there too"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "the relative-path run replaced the installed binary"
ok

# ---- 9. the scan against the ELF's own answer ------------------------------------------------------
# The byte scan counts ANY `GLIBC_x.y` string in a file: a doc line, a comment, another binary's floor
# embedded in the payload. It is a shortcut that happens to be right for every artifact this project has
# built, and the way to keep it right is to compare it with the answer the loader itself reads -
# `.gnu.version_r`, through `readelf -V` - on real linked binaries. A disagreement means either a payload
# string (this scan would refuse a binary the fleet can run) or a scan bug, and both are wanted here and
# not on mail.
verneed_max() { # <file> -> the newest GLIBC version .gnu.version_r names
  readelf -V "$1" 2>/dev/null | awk '
    /Version needs section/ {on = 1; next}
    /Version symbols section|Version definition section/ {on = 0}
    on {print}
  ' | grep -o 'GLIBC_[0-9][0-9.]*[0-9]' | sed 's/^GLIBC_//' | LC_ALL=C sort -uV | tail -1
}
scan_is_the_elf_answer() { # <file> <what>
  local scan elf
  scan="$(wa_glibc_max_symbol "$1")"
  elf="$(verneed_max "$1")"
  if [ -z "$elf" ] && [ -z "$scan" ]; then return 0; fi
  [ -n "$elf" ] || fail "$2: readelf read no version needs from $1, so there is nothing to compare"
  [ "$scan" = "$elf" ] \
    || fail "$2: the byte scan says '$scan' and .gnu.version_r says '$elf' - a GLIBC_ string that no version need carries is being read as a floor"
  ok
}
if command -v readelf >/dev/null 2>&1; then
  checked_elfs=0
  for candidate in /bin/true /bin/ls "$(command -v sort 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    scan_is_the_elf_answer "$candidate" "the scan against .gnu.version_r of $candidate"
    checked_elfs=$((checked_elfs + 1))
  done
  [ "$checked_elfs" -gt 0 ] || fail "no linked ELF on this host to compare the scan with"
artifacts="${WA_GLIBC_ARTIFACT_DIR:-}"
  if [ -n "$artifacts" ] && [ -d "$artifacts" ]; then
    for artifact in "$artifacts"/wa "$artifacts"/wa-*; do
      [ -f "$artifact" ] || continue
      scan_is_the_elf_answer "$artifact" "the scan against .gnu.version_r of $(basename "$artifact")"
    done
  else
    echo "scan against the ELF: BUILT ARTIFACTS SKIPPED (WA_GLIBC_ARTIFACT_DIR is not a directory - this is the case it earns the most: WA_GLIBC_ARTIFACT_DIR=<proof dir> bash scripts/test-glibc-floor.sh)"
  fi
else
  echo "scan against the ELF: SKIPPED (no readelf here; binutils is what reads .gnu.version_r)"
fi

echo "glibc floor ok ($checks checks)"
