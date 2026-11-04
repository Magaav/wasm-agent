#!/usr/bin/env bash
# Tests scripts/lib/seeded-agents-md.sh: only an unedited published copy is moved, never deleted.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/scripts/lib/seeded-agents-md.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
checks=0; fail() { echo "FAIL: $1" >&2; exit 1; }; ok() { checks=$((checks+1)); }
published="$tmp/published.md"
git -C "$root" show "$(git -C "$root" log --format=%H --all --full-history -- AGENTS.md | tail -1):AGENTS.md" > "$published"

c="$tmp/absent"; mkdir -p "$c"
out="$(retire_seeded_agents_md "$c" 2>&1)"; [ -z "$out" ] && [ ! -e "$c/AGENTS.md.seeded-backup" ] && ok || fail "absent is a silent no-op"

c="$tmp/seeded"; mkdir -p "$c"; cp "$published" "$c/AGENTS.md"
out="$(retire_seeded_agents_md "$c" 2>&1)"
[ ! -e "$c/AGENTS.md" ] && cmp -s "$published" "$c/AGENTS.md.seeded-backup" && ok || fail "unedited seed moved to backup, bytes kept"
case "$out" in *"moved to $c/AGENTS.md.seeded-backup"*) ok ;; *) fail "move is logged" ;; esac

cp "$published" "$c/AGENTS.md"; retire_seeded_agents_md "$c" >/dev/null 2>&1
n=$(ls "$c" | grep -c '^AGENTS.md.seeded-backup'); [ "$n" = 2 ] && [ ! -e "$c/AGENTS.md" ] && ok || fail "an existing backup is never overwritten"

c="$tmp/edited"; mkdir -p "$c"; { cat "$published"; echo "my own rule"; } > "$c/AGENTS.md"; before="$(sha256sum "$c/AGENTS.md")"
out="$(retire_seeded_agents_md "$c" 2>&1)"
[ "$(sha256sum "$c/AGENTS.md")" = "$before" ] && ok || fail "edited seed is kept byte-for-byte"
case "$out" in *WARNING*) ok ;; *) fail "edited seed gets a visible warning" ;; esac

c="$tmp/user"; mkdir -p "$c"; printf '# My rules\nbe brief\n' > "$c/AGENTS.md"; before="$(sha256sum "$c/AGENTS.md")"
out="$(retire_seeded_agents_md "$c" 2>&1)"
[ "$(sha256sum "$c/AGENTS.md")" = "$before" ] && [ -z "$out" ] && ok || fail "user's own file untouched and silent"

c="$tmp/crlf"; mkdir -p "$c"; sed 's/$/\r/' "$published" > "$c/AGENTS.md"
out="$(retire_seeded_agents_md "$c" 2>&1)"; [ -e "$c/AGENTS.md" ] && case "$out" in *WARNING*) true ;; *) false ;; esac && ok || fail "a CRLF copy is not byte-identical: kept with warning"

grep -qx "$(sha256sum "$root/AGENTS.md" | cut -d' ' -f1)" "$root/scripts/lib/seeded-agents-md.sha256" || echo "note: current AGENTS.md is not in the frozen list (expected after 2026-11-04 edits)"
echo "seeded agents-md ok ($checks checks, 0 skipped)"
