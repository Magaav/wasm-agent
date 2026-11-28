#!/bin/bash
# What the gate costs, per row and per run - the command gate-stays-fast asks for.
#
#   bash scripts/rows-cost.sh [--rows N] [--runs N] [--dir <archive>]
#
# Prints, in one screen:
#   * the TOTAL seconds of each of the last N archived runs, and whether it is under the budget;
#   * the N slowest rows of the NEWEST run, with their share of its total;
#   * the rows over 20 s, named apart (the brief requires a one-line reason in such a row's header).
#
# Data: every fast.sh run archives its own lua.tsv (columns: exit, ms, row, last line, kind) under
# $WA_ROWS_ARCHIVE, default ~/.wasm-agent/main-health/rows, named by UTC stamp and commit. Budget:
# WA_SUITE_BUDGET_S, default 600 s (Victor's quiet-machine number).
set -uo pipefail
ROWS=30
RUNS=20
DIR=${WA_ROWS_ARCHIVE:-$HOME/.wasm-agent/main-health/rows}
BUDGET=${WA_SUITE_BUDGET_S:-600}
while [ $# -gt 0 ]; do
  case "$1" in
    --rows) ROWS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --dir) DIR=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "rows-cost: unknown argument: $1" >&2; exit 2 ;;
  esac
done

files=()
if [ -d "$DIR" ]; then
  # The names carry their UTC stamp, so sorting by NAME is exact where mtime is not.
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(ls -1 "$DIR"/*.tsv 2>/dev/null | sort -r | head -"$RUNS")
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "rows-cost: no archived run under $DIR"
  echo "rows-cost: fast.sh archives one per run; a fast.sh round fills this"
  echo "rows-cost: budget ${BUDGET}s, no data to compare it with"
  exit 0
fi

echo "== ${#files[@]} archived run(s), newest first; budget ${BUDGET}s"
printf '   %5s %8s %7s  %s\n' "rows" "seconds" "budget" "archive"
for f in "${files[@]}"; do
  read -r n total_ms < <(awk -F'\t' '$2 ~ /^[0-9]+$/ {n++; s+=$2} END {print n+0, s+0}' "$f")
  secs=$((total_ms/1000))
  verdict=under
  [ "$secs" -gt "$BUDGET" ] && verdict=OVER
  printf '   %5s %8s %7s  %s\n' "$n" "$secs" "$verdict" "$(basename "$f")"
done

newest="${files[0]}"
read -r _ total_ms < <(awk -F'\t' '$2 ~ /^[0-9]+$/ {n++; s+=$2} END {print n+0, s+0}' "$newest")
echo
echo "== the $ROWS slowest rows of $(basename "$newest") (total $((total_ms/1000)) s)"
awk -F'\t' -v total="$total_ms" '$2 ~ /^[0-9]+$/ {printf "%8.1f  %5.1f%%  %s\n", $2/1000, ($2*100)/total, $3}' "$newest" \
  | sort -rn | head -"$ROWS"

echo
echo "== rows that got slower than the runs before them (1.5x their median, the budget's own question)"
if [ "${#files[@]}" -lt 2 ]; then
  echo "   no earlier run archived yet, so nothing to compare"
else
  grew=$(awk -F'\t' '
    FNR==1 { run++ }
    $2 ~ /^[0-9]+$/ { if (run == 1) { now[$3] = $2 } else { prev[$3][++n[$3]] = $2 } }
    END {
      for (row in now) {
        k = n[row]
        if (k == 0) continue
        for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (prev[row][j] < prev[row][i]) { x = prev[row][i]; prev[row][i] = prev[row][j]; prev[row][j] = x }
        median = (k % 2) ? prev[row][int(k/2)+1] : (prev[row][k/2] + prev[row][k/2+1]) / 2
        if (median > 0 && now[row] > median * 1.5 && now[row] > 2000) printf "%8.1f -> %8.1f  (%4.1fx)  %s\n", median/1000, now[row]/1000, now[row]/median, row
      }
    }' "${files[@]}" | sort -k3 -rn | head -10)
  if [ -n "$grew" ]; then printf '%s\n' "$grew"; else echo "   none over 1.5x, and none over 2 s"; fi
fi

echo
echo "== rows over 20 s in the newest run (each needs a reason in its header)"
over=$(awk -F'\t' '$2 ~ /^[0-9]+$/ && $2 > 20000 {printf "%8.1f  %s\n", $2/1000, $3}' "$newest" | sort -rn | head -20)
if [ -n "$over" ]; then printf '%s\n' "$over"; else echo "   none"; fi
