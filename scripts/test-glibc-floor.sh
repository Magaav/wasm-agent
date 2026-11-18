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
#   * the same artifact whose floor this host satisfies gets PAST that step (the next refusal is the exec
#     test, which is a different sentence), so the guard is not a blanket refusal;
#   * scripts/upgrade.sh refuses the candidate before the proof and before the backup, with the running
#     binary untouched;
#   * scripts/deploy.sh and scripts/upgrade.sh call the guard BEFORE the point where anything is swapped or
#     restarted, and the lib is sourced and shipped beside an installed copy (a copy without it could not
#     make the check at all);
#   * scripts/publish-node-binaries.sh measures with the same function, and a malformed --glibc is refused.
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

# A copy of the script without its lib cannot make the check, and refuses rather than installing blind.
mkdir -p "$WORK/lonely"
cp "$FLEET" "$WORK/lonely/fleet-install.sh"
out="$(WA_GLIBC_HOST=2.35 TARGET="$step/bin/wa" bash "$WORK/lonely/fleet-install.sh" "file://$step/art/wa-needs-2.39" 2>&1)"; rc=$?
expect_status 1 "$rc" "fleet-install without scripts/lib/glibc-floor.sh"
contains "$out" "glibc_floor_lib_missing:" "the missing lib is a named refusal"
[ "$(sha "$step/bin/wa")" = "$old_sha" ] || fail "a fleet-install without its lib replaced the binary"
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
# answer the same question about the same bytes, or the pin is a promise nobody checks).
second="$(grep -rln "grep -a -o 'GLIBC_" "$ROOT/scripts" 2>/dev/null \
  | grep -v 'scripts/lib/glibc-floor.sh' | grep -v 'scripts/test-glibc-floor.sh')"
[ -z "$second" ] || fail "a second copy of the glibc scan lives in: $second"
ok
out="$(bash "$PUBLISH" --glibc 2.3l --check 2>&1)"; rc=$?
expect_status 2 "$rc" "a malformed --glibc floor"
contains "$out" "glibc_floor_malformed:" "the malformed floor is a named refusal"

echo "glibc floor ok ($checks checks)"
