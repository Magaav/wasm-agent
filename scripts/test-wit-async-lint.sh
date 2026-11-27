#!/usr/bin/env bash
# THE ASYNC-BORN INTERFACES LINT (Victor 26/11, rule P0). Every rule the lint can refuse, refused here by name.
#
# WHAT IT PINS, one fixture per refusal:
#   a NEW interface with a sync export and no reason          -> wit_sync_export_needs_reason
#   the same interface WITH `// sync-export: <why>` above it  -> passes
#   a GRANDFATHERED interface                                 -> passes (the list, not a pattern)
#   a grandfathered interface that ADDS a sync export          -> wit_sync_grew
#   a new interface with async exports but no stream<          -> wit_async_without_backpressure
#   a new interface whose async export carries no future/stream -> wit_async_without_result
#   the REAL tree                                              -> 0 problems at the baseline
#
# Fixtures, never the product's own wit/: the row writes a small tree under /tmp and points the lint at it with
# --root, so a red here means the LINT is wrong, not the repository's interfaces.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-wit-async-lint: $*" >&2; exit 1; }

BASE="${TMPDIR:-/tmp}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-witasync-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

LINT="$PWD/scripts/lint-wit-async.mjs"
[ -f "$LINT" ] || fail "the lint is not at $LINT"

fixture() { # <root> -> a tree with a grandfather list and three interfaces
  mkdir -p "$1/wit/old" "$1/wit/new"
  # the grandfathered one: one sync export, recorded as 1
  printf 'interface old {\n  read: func() -> string;\n}\n' > "$1/wit/old/old.wit"
  printf '# path max_sync why\nwit/old/old.wit 1 baseline\n' > "$1/wit/async-grandfather.txt"
}

run_lint() { node "$LINT" --root "$1" 2>&1; }

# 1. a NEW interface with a sync export and no reason
R="$W/r1"; fixture "$R"
printf 'interface fresh {\n  read: func() -> string;\n}\n' > "$R/wit/new/fresh.wit"
OUT="$(run_lint "$R")"
printf '%s\n' "$OUT" | grep -q 'wit_sync_export_needs_reason: wit/new/fresh.wit' \
  || { printf '%s\n' "$OUT" | head -4 >&2; fail "a new sync export without a reason must be refused by name"; }
ok

# 2. the same interface WITH the reason line passes
printf 'interface fresh {\n  // sync-export: the kernel calls it while holding the file lock; a future would deadlock the caller\n  read: func() -> string;\n}\n' > "$R/wit/new/fresh.wit"
OUT="$(run_lint "$R")"
printf '%s\n' "$OUT" | grep -q 'wit_sync_export_needs_reason' && { printf '%s\n' "$OUT" | head -4 >&2; fail "a sync export WITH a reason line must pass"; }
ok

# 3. a grandfathered interface passes as it is
rm -f "$R/wit/new/fresh.wit"
OUT="$(run_lint "$R")"
printf '%s\n' "$OUT" | grep -q 'wit_sync_export_needs_reason' && fail "a grandfathered interface must pass"
printf '%s\n' "$OUT" | grep -q 'wit_sync_grew' && fail "a grandfathered interface at its recorded count must not be refused as grown"
ok

# 4. a grandfathered interface that ADDS a sync export is refused
printf 'interface old {\n  read: func() -> string;\n  write: func(v: string);\n}\n' > "$R/wit/old/old.wit"
OUT="$(run_lint "$R")"
printf '%s\n' "$OUT" | grep -q 'wit_sync_grew: wit/old/old.wit' \
  || { printf '%s\n' "$OUT" | head -4 >&2; fail "a grandfathered interface that adds a sync export must be refused"; }
ok

# 5. a new interface with async exports and no stream< has not declared backpressure
R2D="$W/r2"; fixture "$R2D"
printf 'interface fresh {\n  // sync-export: none - all async\n  read: async func() -> future<string>;\n}\n' > "$R2D/wit/new/fresh.wit"
OUT="$(run_lint "$R2D")"
printf '%s\n' "$OUT" | grep -q 'wit_async_without_backpressure: wit/new/fresh.wit' \
  || { printf '%s\n' "$OUT" | head -4 >&2; fail "an async interface without a stream must be refused"; }
ok

# 6. a new async export with neither future< nor stream< is refused
# the stream export is ASYNC too: a sync one returning a stream is refused for being sync, which is a different
# refusal and made this case pass for the wrong reason (found by the row's own first run).
printf 'interface fresh {\n  read: async func() -> string;\n  watch: async func() -> stream<string>;\n}\n' > "$R2D/wit/new/fresh.wit"
OUT="$(run_lint "$R2D")"
printf '%s\n' "$OUT" | grep -q 'wit_async_without_result: wit/new/fresh.wit' \
  || { printf '%s\n' "$OUT" | head -6 >&2; fail "an async export with no future/stream must be refused"; }
ok

# 7. the REAL tree is clean at the baseline
OUT="$(run_lint "$PWD")"
printf '%s\n' "$OUT" | grep -q '0 problem(s)' \
  || { printf '%s\n' "$OUT" | tail -6 >&2; fail "the repository's own wit/ is not clean at the baseline"; }
ok

echo "wit async lint ok ($n checks)"

