#!/usr/bin/env bash
# No old name survives.
#
# ARCHITECTURE.md section 6 renamed three things that had been sharing two words: `session_turns()`
# returned *messages*, `turn_id` identified a *run* in one place and a *message* in another, and the UI
# said "this turn" meaning the run. A rename that leaves both names in the tree is worse than not doing
# it - the next reader cannot tell which is current, and every grep finds two answers - so this is a
# check in the suite, not a convention in a document.
#
# It greps for the old *names*, never for the word "turn": section 6 keeps that word for one speaker's
# contribution, so "a turn with an image" is still the right sentence and must not fail this.
#
# Three things are allowed, and each says why:
#   * a line carrying `naming-check: allow` - used where a name must stay (see the marker in
#     `rust/wa-host/src/host.rs`);
#   * `lua/core/memory.lua`'s `migrate_shape()`: a migration has to name what it moves. Those strings are
#     the *matcher* for rows written before this change, and changing them would stop matching them;
#   * `tests/naming-migration.lua`, which builds the old shape on purpose so it can be migrated, and
#     `ARCHITECTURE.md`, whose table records what things *were* called - that is its whole point.
set -uo pipefail
cd "$(dirname "$0")/.."

OLD_NAMES=(
  'session_turns' 'turn_id' 'turn_span' 'turns_fts' 'turns_session_idx' 'turns_time_idx'
  'FROM turns' 'INTO turns' 'UPDATE turns' 'DELETE FROM turns'
  'renderTurns' 'repaintTurns' 'turnBubble' 'turnPolling' 'turnStartedAt' 'turnId'
  'turn_count' 'parse_turn_body' 'run_turn' 'local_turn' 'search_turns'
  'turn-shape' 'the last turn failed'
)

scanned=0
hits=0
for file in $(git ls-files); do
  case "$file" in
    ARCHITECTURE.md|tests/naming-migration.lua) continue ;;
    *target*|*.wasm|*.png|*.ico|*.bmp) continue ;;
  esac
  [ -f "$file" ] || continue
  # A migration is exempt by name, and only for the function that does the moving.
  if [ "$file" = "lua/core/memory.lua" ]; then
    awk '/^local function migrate_shape\(\)/{inside=1} inside && /^end$/{inside=0; next} !inside' \
      "$file" > /tmp/naming-check-scan.$$
    scan=/tmp/naming-check-scan.$$
  else
    scan="$file"
  fi
  scanned=$((scanned + 1))
  for name in "${OLD_NAMES[@]}"; do
    found="$(grep -nF -- "$name" "$scan" 2>/dev/null | grep -v 'naming-check: allow' || true)"
    if [ -n "$found" ]; then
      printf '  FAIL %s still says %s\n' "$file" "$name"
      printf '%s\n' "$found" | head -3 | sed 's/^/         /'
      hits=$((hits + 1))
    fi
  done
  [ "$file" = "lua/core/memory.lua" ] && rm -f /tmp/naming-check-scan.$$
done

if [ "$hits" -eq 0 ]; then
  echo "naming ok ($scanned files, no old names)"
else
  echo "naming FAILED ($hits old name(s) left)"
  exit 1
fi
