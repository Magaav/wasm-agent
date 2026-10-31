#!/usr/bin/env bash
# Fixture suite for the paste-able launcher line (README "Linux node", scripts/linux/bootstrap.sh header):
# it must run the script it just fetched, not a copy frozen on the day the clone was made, and it must
# leave the shell it was pasted into alive.
# 30/10: a clone made before the static-musl channel kept re-running its old bootstrap.sh, which asked
# for the withdrawn glibc-linked aarch64 bundle and refused every older Ubuntu with
# candidate_does_not_run - re-pasting a line that never updates the clone looked like a broken release.
# 31/10: the first fix ended in `exec bash ...`, replacing the operator's login shell, so the installer's
# exit (a success or a named failure) closed the SSH session and took its own message with it.
# No network and nothing installed: a local `file:` repository, a stub `bootstrap.sh` that echoes its
# own version, and a rewritten `$d`.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
README="$ROOT/README.md"
BOOT="$ROOT/scripts/linux/bootstrap.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-linux-launcher-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -5 | sed 's/^/     /'; }

# the documented line, from the README code block, plus the same line in the script's own header
doc=$(sed -n 's/^d=~\/wasm-agent-bootstrap;.*/&/p' "$README" | head -1)
hdr=$(sed -n 's/^#   \(d=~\/wasm-agent-bootstrap;.*\)/\1/p' "$BOOT" | head -1)
[ -n "$doc" ] && ok 'README documents a launcher line' || { bad 'README launcher line'; exit 1; }
[ "$doc" = "$hdr" ] && ok 'the script header carries the same line as the README' || bad 'header/README launcher lines differ' "$hdr"
grep -q 'fetch .*origin main' <<<"$doc" && grep -q 'reset .*FETCH_HEAD' <<<"$doc" \
  && ok 'the launcher refreshes the clone from main before running the script' \
  || bad 'the launcher never updates an existing clone (a stale clone keeps running its old script)'
# `exec` replaces the login shell (the session ends when the installer exits); `exit` closes it outright.
grep -qE '(^|[;& ])(exec|exit)([ ;]|$)' <<<"$doc" \
  && bad 'the launcher execs/exits the shell it was pasted into: a failure closes the session' "$doc" \
  || ok 'the launcher neither execs nor exits the calling shell'

up="$T/up.git"; git init -q --bare -b main "$up"
seed() { # MARKER - commit a stub bootstrap.sh with this marker on main
  local w="$T/seed"; rm -rf "$w"; git clone -q "$up" "$w" 2>/dev/null || { git init -q -b main "$w"; git -C "$w" remote add origin "$up"; }
  mkdir -p "$w/scripts/linux"
  printf 'echo "stub bootstrap: %s"\n' "$1" > "$w/scripts/linux/bootstrap.sh"
  printf 'readme %s\n' "$1" > "$w/README.md"
  git -C "$w" add -A && git -C "$w" -c user.email=f@x -c user.name=f commit -qm "$1" && git -C "$w" push -q origin main
}
line=$(sed -e 's#https://github.com/Magaav/wasm-agent.git#file://'"$T"'/up.git#' -e 's#^d=~/wasm-agent-bootstrap#d='"$T"'/clone#' <<<"$doc")
grep -q 'github.com' <<<"$line" && { bad 'fixture rewrite missed the URL' "$line"; exit 1; }
# The marker after the line proves the shell survived whatever the line did.
run() { bash -c "$line"'; echo "INVOKING-SHELL-ALIVE rc=$?"' 2>&1; }

seed v1
out=$(run)
grep -q 'stub bootstrap: v1' <<<"$out" && ok 'first paste: clones, then runs the script' || bad 'fresh clone' "$out"

seed v2
out=$(run)
grep -q 'stub bootstrap: v2' <<<"$out" && ok 'second paste after a change on main runs the NEW script' || bad 'stale clone was reused' "$out"

head1=$(git -C "$T/clone" rev-parse HEAD); out=$(run); head2=$(git -C "$T/clone" rev-parse HEAD)
[ "$head1" = "$head2" ] && grep -q 'stub bootstrap: v2' <<<"$out" && ok 'no change on main: the re-run is a no-op' || bad 're-run without a change' "$out"

printf 'local edit\n' >> "$T/clone/scripts/linux/bootstrap.sh"; echo junk > "$T/clone/UNTRACKED"; seed v3
out=$(run)
grep -q 'stub bootstrap: v3' <<<"$out" && ! grep -q 'local edit' "$T/clone/scripts/linux/bootstrap.sh" \
  && ok 'a tracked edit in the tool clone is discarded, then the new script runs' || bad 'dirty tool clone' "$out"
[ -e "$T/clone/UNTRACKED" ] && ok 'an untracked file is left alone (reset --hard deletes no user files)' || bad 'untracked file vanished'

# A failing installer must leave the operator's shell and its own message in place.
seed fail
printf 'echo "stub bootstrap: failing now"\necho "bootstrap: node_busy: a turn is running" >&2\nexit 1\n' > "$T/seed/scripts/linux/bootstrap.sh"
git -C "$T/seed" -c user.email=f@x -c user.name=f commit -qam 'fail' && git -C "$T/seed" push -q origin main
out=$(run)
grep -q 'INVOKING-SHELL-ALIVE rc=1' <<<"$out" && grep -q 'bootstrap: node_busy' <<<"$out" \
  && ok 'a failing installer keeps the shell and prints its own reason' || bad 'failure closed the shell or lost its message' "$out"

rm -rf "$T/clone"; mkdir -p "$T/clone"; echo keep > "$T/clone/keep"
out=$(run)
grep -q 'INVOKING-SHELL-ALIVE rc=1' <<<"$out" && ! grep -q 'stub bootstrap' <<<"$out" \
  && ok 'a directory that is not a clone is refused, not run - and the shell stays' || bad 'non-clone directory' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ] && echo 'ALL PASS' || { echo 'FAIL'; exit 1; }
