#!/bin/bash
# WHEN MAY A RELEASE WEAR THE LATEST BADGE (Fable 26/11).
#
#   bash scripts/test-release-latest-gate.sh
#
# `gh release create --latest` marks Latest at CREATE time, and a release has one asset per target: a node of the
# other target would see a Latest with no asset for it, and a failed later upload would leave a half release
# wearing the badge. The rule (scripts/lib/release-latest.sh) is therefore decided at the END, and these are the
# cases it must answer - each one naming what stopped it, not just saying no.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/release-latest.sh"
checks=0; failed=0
ok()  { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (got '$2')" ;; esac; }

LINUX='x86_64-unknown-linux-musl aarch64-unknown-linux-musl'
BOTH=$(printf 'wa-linux-x64-musl-aaaa.tar.gz\nwa-linux-arm64-musl-aaaa.tar.gz\nSHA256SUMS\nSHA256SUMS.sig')
X64=$(printf 'wa-linux-x64-musl-aaaa.tar.gz\nSHA256SUMS\nSHA256SUMS.sig')

# 1. every target present and the version is newer: TAKE
d=$(wa_release_latest_decision v0.2.0 v0.1.2 "$LINUX" "$BOTH")
has 'all targets present and newer -> take' "$d" 'take'

# 2. A MISSING TARGET -> not Latest, and the missing target is NAMED
d=$(wa_release_latest_decision v0.2.0 v0.1.2 "$LINUX" "$X64")
has 'a missing target skips the promotion' "$d" 'skip:missing_target'
has 'and the target that is missing is named' "$d" 'aarch64-unknown-linux-musl'
case "$d" in *'x86_64-unknown-linux-musl,'*|*'x86_64-unknown-linux-musl '*) bad 'the present target was named as missing' ;; *) ok 'the present target is not named as missing' ;; esac

# 3. AN OLDER VERSION -> not Latest (a patch of an older line must not take the badge)
d=$(wa_release_latest_decision v0.1.1 v0.1.2 "$LINUX" "$BOTH")
has 'an older version skips the promotion' "$d" 'skip:not_newer'
has 'and says why' "$d" 'older than the Latest v0.1.2'

# 4. the same version twice: nothing to promote
d=$(wa_release_latest_decision v0.1.2 v0.1.2 "$LINUX" "$BOTH")
has 'the version already holding the badge is not promoted again' "$d" 'skip:not_newer'

# 5. the numeric core compares as numbers, not as strings
same '0.1.10 is newer than 0.1.9' "$(wa_release_compare v0.1.10 v0.1.9)" 'gt'
same '0.2.0 is newer than 0.10.0 is false' "$(wa_release_compare v0.2.0 v0.10.0)" 'lt'
same 'equal cores compare eq' "$(wa_release_compare v1.2.3 v1.2.3)" 'eq'

# 6. a suffixed tag never takes it, whatever the assets say
d=$(wa_release_latest_decision v0.2.0-rc1 v0.1.2 "$LINUX" "$BOTH")
has 'a rehearsal tag stays a prerelease' "$d" 'skip:not_full_version'

# 7. no current Latest at all (first release): take, and say so
d=$(wa_release_latest_decision v0.1.0 '' "$LINUX" "$BOTH")
has 'a first release is promoted' "$d" 'take'
has 'and the missing current Latest is stated' "$d" 'none'

# 8. the shipped script promotes LAST, and creates without the badge
sh=$(cat "$ROOT/scripts/release-linux.sh")
case "$sh" in *'gh release create'*'--prerelease'*) ok 'the create is a prerelease (never Latest at create time)' ;; *) bad 'the create does not say --prerelease' ;; esac
# the COMMAND line, not a comment that mentions it: measured trap, the first match was the comment above it
create_said=$(grep -E '^[[:space:]]*gh release create' "$ROOT/scripts/release-linux.sh" | head -1)
case "$create_said" in *'--latest'*) bad 'the create still carries --latest' ;; *) ok 'the create carries no --latest' ;; esac
case "$create_said" in *'--prerelease'*) ok 'and the create names --prerelease' ;; *) bad 'the create does not name --prerelease' ;; esac
case "$sh" in *'gh release edit'*'--latest'*) ok 'the promotion is a separate, final edit' ;; *) bad 'no gh release edit --latest' ;; esac
create_line=$(grep -nE '^[[:space:]]*gh release create' "$ROOT/scripts/release-linux.sh" | head -1 | cut -d: -f1)
edit_line=$(grep -nE '^[[:space:]]*gh release edit' "$ROOT/scripts/release-linux.sh" | head -1 | cut -d: -f1)
if [ -n "$create_line" ] && [ -n "$edit_line" ] && [ "$edit_line" -gt "$create_line" ]; then ok 'and it comes AFTER the create'; else bad 'the edit is not after the create'; fi
grep -q 'wa_release_latest_decision' "$ROOT/scripts/release-linux.sh" && ok 'the decision is the lib rule, not an inline test' || bad 'release-linux.sh does not call the lib'
grep -q 'release-latest.sh' "$ROOT/scripts/release-linux.sh" && ok 'and the lib is sourced' || bad 'the lib is not sourced'

printf 'release-latest-gate: %s checks, %s failed\n' "$checks" "$failed"
if [ "$failed" -eq 0 ]; then echo 'release-latest-gate ok'; exit 0; fi
exit 1
