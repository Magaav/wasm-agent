#!/bin/bash
# ONE TEST FOR wa_cargo_lock_matches, and it can fail.
#
# The function exists because a landing deleted `members = [...]` from rust/Cargo.toml and every `--locked` build
# refused hours later, at RELEASE PUBLISH ("cannot update the lock file ... because --locked was passed"), where
# nobody could see the cause. The test builds the states by hand in a scratch workspace - no registry, no network -
# and requires the function to tell them apart:
#   * a lock that matches its members                  -> 0
#   * a member added without a new lock                -> 1, with cargo's own words
#   * a lock naming a package the workspace dropped    -> 1  (the incident: members removed, lock left behind)
#   * nowhere to find cargo                            -> 1 naming what is missing
#
# A check that passes when it could not look is how the incident happened, so the last case is a REFUSAL, not a
# pass. `--no-deps` is never used: with it cargo does not resolve dependencies and accepts ANY tree (measured - a
# memberless workspace with an untouched lock answered 0 until it was dropped).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-lockcheck.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-fast-cargo-lock: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }
. "$HERE/lib/fast-cargo-lock.sh"

R="$WORK/tree"; mkdir -p "$R/rust/wa-one/src" "$R/rust/wa-two/src"
for c in wa-one wa-two; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$c" > "$R/rust/$c/Cargo.toml"
  : > "$R/rust/$c/src/lib.rs"
done
printf '[workspace]\nmembers = ["wa-one", "wa-two"]\nresolver = "2"\n' > "$R/rust/Cargo.toml"

CARGO_BIN=$(wa_cargo_bin) || { echo "SKIP test-fast-cargo-lock: no cargo on this machine, so the states cannot be built" >&2; exit 0; }
( cd "$R/rust" && "$CARGO_BIN" generate-lockfile --offline >/dev/null 2>&1 ) \
  || { echo "SKIP test-fast-cargo-lock: the scratch workspace will not lock offline" >&2; exit 0; }

# 1. a lock that matches the members: accepted, and quiet.
out=$(wa_cargo_lock_matches "$R"); rc=$?
ok "$rc" "0" "a lock that matches its members is accepted"
ok "$out" "" "and says nothing"

# 2. a member the lock does not know about (a new crate landed without its lock entry).
mkdir -p "$R/rust/wa-three/src"
printf '[package]\nname = "wa-three"\nversion = "0.1.0"\nedition = "2021"\n' > "$R/rust/wa-three/Cargo.toml"; : > "$R/rust/wa-three/src/lib.rs"
printf '[workspace]\nmembers = ["wa-one", "wa-two", "wa-three"]\nresolver = "2"\n' > "$R/rust/Cargo.toml"
out=$(wa_cargo_lock_matches "$R"); rc=$?
ok "$rc" "1" "a member the lock does not have is REFUSED"
like "$out" "locked" "and cargo's own words are passed on"

# 3. THE P0 MESSAGE ITSELF: a tree whose lock does not satisfy what it declares. No Cargo.lock at all is the
#    clearest form (a fresh member landed and the lock was never committed, or a landing removed it): cargo must
#    WRITE one, and --locked refuses in exactly the words the release publish failed with.
printf '[workspace]\nmembers = ["wa-one"]\nresolver = "2"\n' > "$R/rust/Cargo.toml"
mv "$R/rust/Cargo.lock" "$WORK/lock.kept"
out=$(wa_cargo_lock_matches "$R"); rc=$?
ok "$rc" "1" "a tree with no lock is REFUSED"
like "$out" "cannot create the lock file" "with the exact words the publish failed on (create for a missing lock, update for a stale one)"
mv "$WORK/lock.kept" "$R/rust/Cargo.lock"

# 4. nowhere to find cargo: refuse, never pass. env -i so no earlier assignment can make it look answerable.
printf '[workspace]\nmembers = ["wa-one"]\nresolver = "2"\n' > "$R/rust/Cargo.toml"
out=$(env -i HOME=/nonexistent PATH=/nonexistent /bin/bash -c '. "$1"; wa_cargo_lock_matches "$2"' _ "$HERE/lib/fast-cargo-lock.sh" "$R" 2>&1); rc=$?
ok "$rc" "1" "with no cargo to ask the answer is a refusal"
like "$out" "no cargo" "that names what was missing"

if [ "$failed" -gt 0 ]; then echo "test-fast-cargo-lock: $failed failed of $checks checks"; exit 1; fi
echo "test-fast-cargo-lock ok ($checks checks)"
